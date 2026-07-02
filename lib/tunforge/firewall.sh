#!/usr/bin/env bash
# tunforge/firewall.sh - nftables kill switch.
#
# Default-drop egress firewall that only allows:
#   - loopback
#   - the VPN tunnel interface (out-traffic that already went through the tunnel)
#   - the VPN endpoint IP(s) on the WAN iface (so the encrypted handshake itself
#     can leave the box)
#   - DHCP on LAN (so the host can keep its WAN address)
#
# Everything else is dropped, so if the tunnel goes down a packet cannot leak.
# IPv6 is fully dropped at the firewall level as belt-and-braces; sysctl already
# disables it but a misconfigured app could still try v6.
#
# Subcommands
#   up <wan_iface> <tun_iface> <endpoint_ips...>     install rules (active VPN)
#   down                                             remove rules
#   boot-apply                                       called by killswitch.service
#   boot-revert
#   show

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

NFT_TABLE="tunforge"
NFT_PARAMS_FILE="${TUNFORGE_VAR}/firewall.params"

_have_nft() {
    command -v nft >/dev/null 2>&1
}

_persist_params() {
    install -d -m 0750 "$TUNFORGE_VAR"
    {
        printf 'WAN=%s\n' "$1"
        printf 'TUN=%s\n' "$2"
        shift 2
        printf 'ENDPOINTS="%s"\n' "$*"
    } > "${NFT_PARAMS_FILE}.tmp"
    chmod 0640 "${NFT_PARAMS_FILE}.tmp"
    mv -f "${NFT_PARAMS_FILE}.tmp" "$NFT_PARAMS_FILE"
}

_load_params() {
    [[ -f "$NFT_PARAMS_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$NFT_PARAMS_FILE"
}

_render_ruleset() {
    local wan="$1" tun="$2"; shift 2
    local endpoints=("$@")

    # Build the endpoint set body. If empty (defensive), drop everything.
    local ep_v4=()
    local ep_v6=()
    local ep
    for ep in "${endpoints[@]}"; do
        [[ -z "$ep" ]] && continue
        if [[ "$ep" == *:* ]]; then ep_v6+=("$ep"); else ep_v4+=("$ep"); fi
    done
    local ep4_set ep6_set
    if ((${#ep_v4[@]})); then
        ep4_set="$(IFS=,; echo "${ep_v4[*]}")"
    else
        ep4_set=""
    fi
    if ((${#ep_v6[@]})); then
        ep6_set="$(IFS=,; echo "${ep_v6[*]}")"
    else
        ep6_set=""
    fi
    local bypass_v4=() bypass4_set bypass_cidr
    while IFS= read -r bypass_cidr; do
        [[ -n "$bypass_cidr" ]] && bypass_v4+=("$bypass_cidr")
    done < <(bypass_cidrs_iter)
    if ((${#bypass_v4[@]})); then
        bypass4_set="$(IFS=,; echo "${bypass_v4[*]}")"
    else
        bypass4_set=""
    fi

    cat <<EOF
table inet ${NFT_TABLE} {
    set vpn_v4 {
        type ipv4_addr
        flags interval
$( [[ -n "$ep4_set" ]] && printf '        elements = { %s }\n' "$ep4_set" )
    }

    set vpn_v6 {
        type ipv6_addr
        flags interval
$( [[ -n "$ep6_set" ]] && printf '        elements = { %s }\n' "$ep6_set" )
    }

    set bypass_v4 {
        type ipv4_addr
        flags interval
$( [[ -n "$bypass4_set" ]] && printf '        elements = { %s }\n' "$bypass4_set" )
    }

    chain output {
        type filter hook output priority 0; policy drop;

        oifname "lo" accept
        ct state established,related accept

        # Allow everything that already left through the VPN tunnel
        oifname "${tun}" accept

        # Allow handshake traffic to the VPN endpoint IP(s) on the WAN iface
        oifname "${wan}" ip  daddr @vpn_v4 accept
        oifname "${wan}" ip6 daddr @vpn_v6 accept

        # Allow explicit local-development bypasses (LAN, Docker, loopback CIDRs)
        ip daddr @bypass_v4 accept

        # Allow DHCP renewal on the LAN so we don't lose our WAN lease
        oifname "${wan}" udp sport 68 udp dport 67 accept

        # Allow ICMP to gateway so PMTU still works on the WAN
        oifname "${wan}" ip protocol icmp icmp type { destination-unreachable, time-exceeded } accept

        # Drop everything else with logging-rate-limit (visible in journalctl -k)
        log prefix "tunforge-drop-out: " level warn flags ip options limit rate 10/minute
        counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain input {
        type filter hook input priority 0; policy accept;
        # We do not lock down input - the user may want SSH etc. Kill-switch is
        # about preventing data leaving, not about hardening services.
    }
}
EOF
}

firewall_up() {
    local wan="${1:?usage: firewall.sh up <wan> <tun> <endpoint_ip...>}"
    local tun="${2:?missing tun iface}"
    shift 2
    [[ $# -gt 0 ]] || die "firewall.sh up: at least one endpoint IP required"

    _have_nft || die "nft not installed (apt install nftables)"

    log_step "Enabling kill switch (wan=$wan tun=$tun)"
    local bypasses
    bypasses="$(bypass_cidrs_iter | tr '\n' ' ')"
    [[ -n "${bypasses// }" ]] && log_detail "local bypass CIDRs: $bypasses"

    _persist_params "$wan" "$tun" "$@"

    # Make sure the table exists so we can flush it atomically below. The first
    # `add` is a no-op if the table already exists, but newer nft warns; ignore.
    nft 'add table inet '"$NFT_TABLE" 2>/dev/null || true

    # Atomic replace: write a single ruleset (flush + new table contents) and
    # feed it to nft -f -. nft applies the whole file in one transaction, so
    # there is no window where the firewall is partially loaded.
    local tmp; tmp="$(mktemp)"
    {
        echo "flush table inet $NFT_TABLE"
        _render_ruleset "$wan" "$tun" "$@"
    } > "$tmp"

    if ! nft -f "$tmp"; then
        log_fail "Kill switch could not be loaded - the generated ruleset was rejected by nft"
        # The rejected ruleset is the only useful artefact here, so it goes to
        # the journal/transcript rather than the terminal.
        log_detail "$(cat "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"
        die "nft load failed"
    fi
    rm -f "$tmp"

    log_ok "Kill switch active (only $tun and the VPN endpoint can send traffic)"
}

firewall_down() {
    if ! _have_nft; then return 0; fi
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        log_detail "firewall: removing kill switch table"
        nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    fi
    rm -f "$NFT_PARAMS_FILE"
}

firewall_show() {
    if _have_nft && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft list table inet "$NFT_TABLE"
    else
        echo "(no tunforge nft table loaded)"
    fi
}

# Boot-time: re-apply kill switch if /var/lib/tunforge/active points at a
# non-direct profile. This closes the race between boot and the user opening the
# TUI to reconnect.
firewall_boot_apply() {
    local active; active="$(state_get_active)"
    [[ "$active" != "none" && -n "$active" ]] || { log_detail "firewall: no active profile at boot"; return 0; }

    local pfile="${TUNFORGE_PROFILES_DIR}/${active}.profile"
    if [[ ! -f "$pfile" ]]; then
        log_warn "Boot: active profile '$active' has no profile file - kill switch not re-applied"
        return 0
    fi
    load_profile "$active"
    if [[ "$P_TYPE" == "direct" ]]; then return 0; fi
    if [[ "$P_KILL_SWITCH" != "yes" ]]; then return 0; fi

    if ! _load_params; then
        log_warn "Boot: no persisted firewall params - kill switch not re-applied"
        return 0
    fi
    # shellcheck disable=SC2086
    firewall_up "$WAN" "$TUN" $ENDPOINTS
}

firewall_boot_revert() {
    firewall_down
}

case "${1:-}" in
    up)            shift; firewall_up "$@" ;;
    down)          firewall_down ;;
    show)          firewall_show ;;
    boot-apply)    firewall_boot_apply ;;
    boot-revert)   firewall_boot_revert ;;
    *) cat >&2 <<EOF
usage: firewall.sh <subcommand>
  up <wan_iface> <tun_iface> <endpoint_ip>...   install kill switch
  down                                          remove kill switch
  show                                          print active rules
  boot-apply                                    called by tunforge-killswitch.service
  boot-revert
EOF
        exit 2 ;;
esac
