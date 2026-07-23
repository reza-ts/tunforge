#!/usr/bin/env bash
# tunforge/nm-tame.sh - one-shot NetworkManager + systemd-resolved configurator.
# install.sh calls `nm-tame.sh apply`; uninstall.sh calls `nm-tame.sh revert`.

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

NM_DROPIN=/etc/NetworkManager/conf.d/99-tunforge.conf
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/tunforge.conf
RESOLV_BAK=/etc/resolv.conf.tunforge-bak

nm_apply() {
    require_root

    log_step "Configuring NetworkManager + systemd-resolved"

    if [[ ! -f "$NM_DROPIN" || ! -f "$RESOLVED_DROPIN" ]]; then
        die "Config drop-ins missing - did install.sh deploy nm/99-tunforge.conf and resolved/tunforge.conf?"
    fi

    # Ensure systemd-resolved is running and enabled
    if systemctl enable --now systemd-resolved.service >/dev/null 2>&1; then
        log_ok "systemd-resolved enabled"
    else
        log_warn "Could not enable systemd-resolved"
    fi

    # Fix /etc/resolv.conf -> stub-resolv.conf
    local target=/run/systemd/resolve/stub-resolv.conf
    if [[ -L /etc/resolv.conf ]]; then
        local cur; cur="$(readlink /etc/resolv.conf)"
        if [[ "$cur" != "$target" ]]; then
            log_detail "repointing /etc/resolv.conf symlink ($cur -> $target)"
            ln -sf "$target" /etc/resolv.conf
        fi
    elif [[ -e /etc/resolv.conf ]]; then
        if [[ ! -e "$RESOLV_BAK" ]]; then
            log_detail "backing up /etc/resolv.conf -> $RESOLV_BAK"
            cp -a /etc/resolv.conf "$RESOLV_BAK"
        fi
        ln -sf "$target" /etc/resolv.conf
    else
        ln -sf "$target" /etc/resolv.conf
    fi
    log_ok "/etc/resolv.conf points at the systemd-resolved stub"

    # Reload resolved with new drop-in
    systemctl restart systemd-resolved

    # Reload NM if present (gentle reload, no live conn drops)
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
        log_ok "NetworkManager reloaded with tunforge drop-in"
    else
        log_warn "NetworkManager is not running - drop-in will apply when it starts"
    fi
}

nm_revert() {
    require_root
    log_step "Reverting NetworkManager + systemd-resolved config"
    rm -f "$NM_DROPIN" "$RESOLVED_DROPIN"
    if [[ -e "$RESOLV_BAK" ]]; then
        log_detail "restoring /etc/resolv.conf from $RESOLV_BAK"
        rm -f /etc/resolv.conf
        cp -a "$RESOLV_BAK" /etc/resolv.conf
        rm -f "$RESOLV_BAK"
    fi
    systemctl restart systemd-resolved 2>/dev/null || true
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        nmcli general reload 2>/dev/null || true
    fi
    log_ok "NetworkManager + systemd-resolved restored to defaults"
}

case "${1:-}" in
    apply)  nm_apply ;;
    revert) nm_revert ;;
    *) echo "usage: nm-tame.sh <apply|revert>" >&2; exit 2 ;;
esac
