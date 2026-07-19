#!/usr/bin/env bash
# tunforge/leak-prevent.sh - sysctl & service hardening while a VPN is active.
#
# What it does (apply):
#   - Disable IPv6 system-wide (sysctl) if profile says so. Eliminates v6 leak
#     vectors entirely (ULA, SLAAC, DHCPv6, link-local).
#   - rp_filter=1 (strict reverse path), no ICMP redirects, no source routing.
#   - Stop avahi-daemon if running so the host stops broadcasting hostname/mDNS.
#
# What it does (restore):
#   - Restore the previous sysctl values from a snapshot file.
#   - Restart avahi-daemon if it was running.
#
# Snapshot is stored in $TUNFORGE_VAR/leak.snapshot so we always know what to
# restore to even after a reboot.

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

SNAP="${TUNFORGE_VAR}/leak.snapshot"

# sysctl keys we manage. Each line: KEY=VALUE_TO_SET (apply); restore reads the
# snapshot.
_KEYS=(
    "net.ipv4.conf.all.rp_filter"
    "net.ipv4.conf.default.rp_filter"
    "net.ipv4.conf.all.accept_redirects"
    "net.ipv4.conf.default.accept_redirects"
    "net.ipv4.conf.all.send_redirects"
    "net.ipv4.conf.default.send_redirects"
    "net.ipv4.conf.all.accept_source_route"
    "net.ipv4.conf.default.accept_source_route"
    "net.ipv6.conf.all.disable_ipv6"
    "net.ipv6.conf.default.disable_ipv6"
    "net.ipv6.conf.lo.disable_ipv6"
    "net.ipv6.conf.all.accept_redirects"
    "net.ipv6.conf.default.accept_redirects"
    "net.ipv6.conf.all.accept_source_route"
    "net.ipv6.conf.default.accept_source_route"
)

_snapshot_if_absent() {
    if [[ -f "$SNAP" ]]; then return 0; fi
    install -d -m 0750 "$TUNFORGE_VAR"
    log_detail "leak: snapshotting sysctl baseline -> $SNAP"
    : > "${SNAP}.tmp"
    local k v
    for k in "${_KEYS[@]}"; do
        v="$(sysctl -n "$k" 2>/dev/null || echo '')"
        printf '%s=%s\n' "$k" "$v" >> "${SNAP}.tmp"
    done
    # Snapshot avahi service state too
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        echo "avahi=active" >> "${SNAP}.tmp"
    else
        echo "avahi=inactive" >> "${SNAP}.tmp"
    fi
    chmod 0640 "${SNAP}.tmp"
    mv -f "${SNAP}.tmp" "$SNAP"
}

leak_apply() {
    local ipv6_policy="${1:-disable}"   # disable|allow

    _snapshot_if_absent

    log_step "Applying leak prevention (IPv6: $ipv6_policy)"

    # Tolerate failures on hardened/locked-down kernels where some keys may not
    # be writable. The kill switch is the real safety net; sysctls are defence
    # in depth.
    local sk failed=0
    for sk in \
        net.ipv4.conf.all.rp_filter=1 \
        net.ipv4.conf.default.rp_filter=1 \
        net.ipv4.conf.all.accept_redirects=0 \
        net.ipv4.conf.default.accept_redirects=0 \
        net.ipv4.conf.all.send_redirects=0 \
        net.ipv4.conf.default.send_redirects=0 \
        net.ipv4.conf.all.accept_source_route=0 \
        net.ipv4.conf.default.accept_source_route=0 \
        net.ipv6.conf.all.accept_redirects=0 \
        net.ipv6.conf.default.accept_redirects=0 \
        net.ipv6.conf.all.accept_source_route=0 \
        net.ipv6.conf.default.accept_source_route=0
    do
        sysctl -w "$sk" >/dev/null 2>&1 || { failed=1; log_detail "could not set $sk"; }
    done
    (( failed == 0 )) || log_warn "Some sysctl hardening keys are not writable on this kernel"

    if [[ "$ipv6_policy" == "disable" ]]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 \
            || log_warn "Could not disable IPv6 (kernel booted with ipv6.disable=1?)"
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
        # Leave lo enabled; some apps bind ::1 and crash otherwise. The kill
        # switch's IPv6 chains still drop everything as belt-and-braces.
    fi

    # Stop avahi while the VPN is up so the host stops shouting its hostname.
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        systemctl stop avahi-daemon 2>/dev/null || true
        systemctl stop avahi-daemon.socket 2>/dev/null || true
        log_detail "avahi-daemon stopped for the duration of the session"
    fi

    log_ok "Leak prevention active (rp_filter, no redirects, no source routing)"
}

leak_restore() {
    if [[ ! -f "$SNAP" ]]; then
        log_detail "leak-prevent: nothing to restore (no snapshot)"
        return 0
    fi
    log_detail "leak-prevent: restoring sysctl baseline from $SNAP"
    local line k v avahi=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        k="${line%%=*}"; v="${line#*=}"
        if [[ "$k" == "avahi" ]]; then avahi="$v"; continue; fi
        [[ -z "$v" ]] && continue
        sysctl -w "$k=$v" >/dev/null 2>&1 || true
    done < "$SNAP"

    if [[ "$avahi" == "active" ]]; then
        systemctl start avahi-daemon 2>/dev/null || true
    fi

    rm -f "$SNAP"
    log_detail "leak-prevent: sysctl baseline restored"
}

case "${1:-}" in
    apply)   shift; leak_apply "${1:-disable}" ;;
    restore) leak_restore ;;
    *) cat >&2 <<EOF
usage: leak-prevent.sh <apply|restore> [ipv6_policy]
  apply [disable|allow]   harden sysctls, stop avahi
  restore                 restore baseline from snapshot
EOF
        exit 2 ;;
esac
