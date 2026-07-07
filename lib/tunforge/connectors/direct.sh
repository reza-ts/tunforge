#!/usr/bin/env bash
# tunforge/connectors/direct.sh
#
# "direct" connector = no VPN. The up path simply ensures no leftover state, the
# down path is a no-op (because everything else has already been torn down by
# core._teardown_current).

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

direct_up() {
    log_step "Switching to the direct (no-VPN) baseline"

    "$LIB/firewall.sh" down || true
    "$LIB/dns.sh" revert-all || true
    "$LIB/leak-prevent.sh" restore || true

    # Force NetworkManager to refresh DNS on its managed connections so the LAN
    # DHCP-supplied DNS servers come back. This is much faster than waiting for
    # a DHCP renew.
    if command -v nmcli >/dev/null 2>&1; then
        local active_uuid
        while IFS= read -r active_uuid; do
            [[ -n "$active_uuid" ]] || continue
            nmcli connection up uuid "$active_uuid" >/dev/null 2>&1 || true
        done < <(nmcli -t -f UUID,TYPE connection show --active 2>/dev/null \
                    | awk -F: '$2=="ethernet" || $2=="wifi" || $2=="802-11-wireless"{print $1}')
    fi

    state_set_iface ""
    log_ok "Direct connection restored - no VPN, no kill switch"
}

direct_down() {
    return 0
}

case "${1:-}" in
    up)
        # direct doesn't need profile data, but accept for symmetry
        if [[ -n "${2:-}" ]]; then load_profile "$2"; fi
        direct_up ;;
    down)
        direct_down ;;
    *)    echo "usage: direct.sh <up|down> [profile]" >&2; exit 2 ;;
esac
