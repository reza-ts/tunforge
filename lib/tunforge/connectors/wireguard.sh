#!/usr/bin/env bash
# tunforge/connectors/wireguard.sh
#
# Up:
#   1. Sanitize the user's .conf into a tmp file (strip DNS=, force Table=auto).
#      We strip DNS so wg-quick does NOT shell-out to resolvconf and fight
#      systemd-resolved; we own DNS via dns.sh.
#   2. Extract Endpoint host:port -> resolve to IP(s) for the kill-switch
#      whitelist.
#   3. wg-quick up <tmp>.
#   4. Apply DNS lock + kill switch.

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"
# core.sh has been sourced; P_NAME etc. should be defined by the caller.
# When called standalone (e.g. tests), require the profile name as $2.

_iface_for_profile() {
    # wg-quick uses the basename of the conf file as the iface name. We control
    # that by writing to /run/tunforge/wg-<profile>.conf -> iface "wg-<profile>".
    printf 'wg-%s\n' "$P_NAME"
}

_sanitize_wg_conf() {
    local src="$1" dst="$2"
    install -d -m 0700 "$TUNFORGE_RUN"
    # When IPV6=disable, leak-prevent.sh sets net.ipv6.conf.{all,default}
    # .disable_ipv6=1, which means new interfaces (including this wg one)
    # come up without IPv6. wg-quick then aborts with "IPv6 is disabled on
    # nexthop device" the moment it tries `ip -6 route add ::/0`. The fix is
    # to strip IPv6 entries from AllowedIPs / Address before wg-quick sees
    # them so it never attempts the v6 plumbing in the first place.
    awk -v ipv6_mode="${P_IPV6:-disable}" '
        function strip_v6(value,    n, parts, out, i) {
            n = split(value, parts, /[ \t]*,[ \t]*/)
            out = ""
            for (i = 1; i <= n; i++) {
                if (parts[i] ~ /:/) continue
                if (out != "") out = out ", "
                out = out parts[i]
            }
            return out
        }
        /^[[:space:]]*DNS[[:space:]]*=/ { next }
        /^[[:space:]]*Table[[:space:]]*=/ { print "Table = auto"; next }
        ipv6_mode == "disable" && /^[[:space:]]*(AllowedIPs|Address)[[:space:]]*=/ {
            eq = index($0, "=")
            key = substr($0, 1, eq-1)
            value = substr($0, eq+1)
            sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
            sub(/^[[:space:]]+/, "", key);   sub(/[[:space:]]+$/, "", key)
            new = strip_v6(value)
            if (new == "") next
            printf "%s = %s\n", key, new
            next
        }
        { print }
    ' "$src" > "$dst"
    chmod 0600 "$dst"
}

_extract_endpoint_host() {
    local conf="$1"
    awk -F'=' '
        /^[[:space:]]*Endpoint[[:space:]]*=/ {
            v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit
        }
    ' "$conf"
}

# Remove orphan wg-* interfaces from previously failed runs so wg-quick's
# `ip route add` of the AllowedIPs doesn't trip over routes still attached
# to a stale interface (RTNETLINK "File exists"). We only delete interfaces
# whose name matches an existing tunforge profile - we do NOT touch wg
# interfaces created by anything else (NetworkManager, Tailscale, manual).
_sweep_orphan_wg_interfaces() {
    local current_iface="$1"
    local stale=() p cand
    while IFS= read -r p; do
        cand="wg-$p"
        [[ "$cand" == "$current_iface" ]] && continue
        if ip link show "$cand" >/dev/null 2>&1; then
            stale+=("$cand")
        fi
    done < <(list_profiles)
    if (( ${#stale[@]} == 0 )); then
        return 0
    fi
    log_warn "Removing orphan interfaces from earlier failed attempts: ${stale[*]}"
    local s sconf
    for s in "${stale[@]}"; do
        sconf="${TUNFORGE_RUN}/${s}.conf"
        if [[ -f "$sconf" ]]; then
            wg-quick down "$sconf" >/dev/null 2>&1 || true
        fi
        ip link delete dev "$s" 2>/dev/null || true
        rm -f "$sconf"
    done
    # wg-quick's policy-routing leftover (table 51820 + the fwmark rules)
    # can survive a bare `ip link delete` if the interface was torn down
    # outside wg-quick - flush them so wg-quick can recreate cleanly.
    ip -4 route flush table 51820 2>/dev/null || true
    ip -6 route flush table 51820 2>/dev/null || true
    while ip -4 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do :; done
    while ip -4 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do :; done
    while ip -6 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do :; done
    while ip -6 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do :; done
}

# List wireguard interfaces currently on the system that are NOT named after
# any tunforge profile (e.g. wg0 created by a manual `wg-quick up`, or by
# NetworkManager). These will collide with our AllowedIPs routes.
_foreign_wg_interfaces() {
    local -A ours=()
    local p
    while IFS= read -r p; do
        ours["wg-$p"]=1
    done < <(list_profiles)
    local iface
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        [[ -n "${ours[$iface]:-}" ]] && continue
        printf '%s\n' "$iface"
    done < <(ip -o link show type wireguard 2>/dev/null \
             | awk -F': ' '{ split($2, a, "@"); print a[1] }')
}

# Refuse to bring up a new tunnel if a foreign WG iface is sitting there
# holding routes - it WILL conflict on AllowedIPs (we just spent four
# rounds debugging exactly that). The user can either bring it down
# manually, or set TUNFORGE_PURGE_FOREIGN_WG=1 (or run `tunforge purge-wg`)
# to have us nuke it.
_check_foreign_wg_interfaces() {
    local -a foreign
    readarray -t foreign < <(_foreign_wg_interfaces)
    (( ${#foreign[@]} == 0 )) && return 0

    local f routes
    if [[ "${TUNFORGE_PURGE_FOREIGN_WG:-}" == "1" ]]; then
        log_warn "TUNFORGE_PURGE_FOREIGN_WG=1 - removing foreign WireGuard interfaces: ${foreign[*]}"
        for f in "${foreign[@]}"; do
            wg-quick down "$f" >/dev/null 2>&1 \
                || ip link delete dev "$f" 2>/dev/null \
                || true
        done
        ip -4 route flush table 51820 2>/dev/null || true
        ip -6 route flush table 51820 2>/dev/null || true
        while ip -4 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do :; done
        while ip -4 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do :; done
        return 0
    fi

    log_fail "Foreign WireGuard interface(s) are up and not managed by tunforge:"
    for f in "${foreign[@]}"; do
        log_hint "  - $f"
        routes="$(ip -4 route show dev "$f" 2>/dev/null | sed 's/^/      /')"
        [[ -n "$routes" ]] && printf '%s\n' "$routes" >&2
    done
    log_hint "These collide with this profile's AllowedIPs routes."
    log_hint "Tear them down and retry. Either:"
    log_hint "    sudo tunforge purge-wg          # tunforge-side cleanup"
    log_hint "  or:"
    for f in "${foreign[@]}"; do
        log_hint "    sudo wg-quick down $f       # if you brought $f up via wg-quick"
        log_hint "    sudo ip link delete dev $f  # blunt-force fallback"
    done
    log_hint "Or set TUNFORGE_PURGE_FOREIGN_WG=1 to have tunforge auto-purge them."
    die "Foreign WireGuard interface(s) are blocking this connect: ${foreign[*]}"
}

# Full kernel routing state for a wg-quick route conflict. We normally name
# the conflicting interface outright (see wireguard_up), which is the answer
# the user actually needs - so these tables are journal-only unless
# TUNFORGE_VERBOSE=1. They stay in the journal either way for post-mortems.
_dump_routing_diag() {
    local section cmd line
    for section in \
        "routes (main table)|ip -4 route show" \
        "policy rules|ip -4 rule show" \
        "wg-quick table 51820|ip -4 route show table 51820" \
        "wireguard links|ip -d link show type wireguard"
    do
        cmd="${section#*|}"
        log_detail "--- ${section%%|*} ---"
        while IFS= read -r line; do
            log_detail "  $line"
        done < <(eval "$cmd" 2>&1 || true)
    done
}

wireguard_up() {
    [[ -n "${P_CONFIG:-}" ]] || die "wireguard: profile not loaded"
    command -v wg-quick >/dev/null 2>&1 || die "wg-quick is not installed (apt install wireguard-tools)"

    local iface; iface="$(_iface_for_profile)"
    local conf="${TUNFORGE_RUN}/${iface}.conf"

    log_detail "wireguard: sanitizing config -> $conf"
    _sanitize_wg_conf "$P_CONFIG" "$conf"

    local endpoint_hp endpoint_host endpoint_ips=()
    endpoint_hp="$(_extract_endpoint_host "$conf")"
    [[ -n "$endpoint_hp" ]] || die "No 'Endpoint =' line in $P_CONFIG"
    endpoint_host="${endpoint_hp%:*}"
    if [[ -n "${P_ENDPOINT_IP:-}" ]]; then
        endpoint_ips=("$P_ENDPOINT_IP")
    else
        readarray -t endpoint_ips < <(resolve_endpoint_ipv4 "$endpoint_host")
    fi
    if ((${#endpoint_ips[@]} == 0)); then
        log_fail "Could not resolve the VPN endpoint $endpoint_host"
        log_hint "Your network is most likely blocking outbound DNS entirely."
        log_hint "Fix options, best first:"
        log_hint "  1. Pin the IP:  add ENDPOINT_IP=<real-ip> to $P_NAME.profile"
        log_hint "  2. Bypass poisoned DNS:  sudo tunforge dns-direct add '^${endpoint_host//./\\.}$'"
        log_hint "  3. Use a provider whose domains resolve reliably here"
        exit 1
    fi
    log_ok "Resolved VPN endpoint: $endpoint_host -> ${endpoint_ips[*]}"

    # Pin the resolved IP into the sanitized config so wg-quick itself does
    # NOT have to call getaddrinfo() against the (poisoned) system resolver.
    # WireGuard does NOT do TLS-style hostname verification - peers are
    # authenticated by public-key, so swapping host -> IP is safe.
    local _ep_port="${endpoint_hp##*:}"
    local _ep_ip="${endpoint_ips[0]}"
    awk -v ip="$_ep_ip" -v port="$_ep_port" '
        /^[[:space:]]*Endpoint[[:space:]]*=/ { print "Endpoint = " ip ":" port; next }
        { print }
    ' "$conf" > "${conf}.new" && mv "${conf}.new" "$conf"
    chmod 0600 "$conf"

    local wan; wan="$(default_wan_iface)"
    [[ -n "$wan" ]] || die "No default WAN interface - are you online?"

    # Belt-and-braces: kill any stale instance of the SAME iface (idempotent
    # if nothing is there), then sweep orphan wg-<other-profile> interfaces
    # from prior failed attempts that may still own AllowedIPs routes we
    # need to claim.
    if ip link show "$iface" >/dev/null 2>&1; then
        log_warn "Interface $iface already exists - tearing it down first"
        wg-quick down "$conf" >/dev/null 2>&1 || ip link delete dev "$iface" 2>/dev/null || true
    fi
    _sweep_orphan_wg_interfaces "$iface"
    _check_foreign_wg_interfaces

    log_detail "wireguard: wg-quick up $iface"
    # Capture wg-quick output so we can log its actual error message (key piece
    # of evidence) instead of relying on journald which gets filtered.
    local _wg_out _wg_rc=0
    _wg_out="$(wg-quick up "$conf" 2>&1)" || _wg_rc=$?
    if (( _wg_rc != 0 )); then
        log_fail "wg-quick could not bring up $iface (rc=$_wg_rc)"
        local _l
        while IFS= read -r _l; do log_hint "$_l"; done <<<"$_wg_out"
        # If the failure is the classic route-conflict, emit a routing
        # snapshot so the user can see WHICH route is in the way.
        if [[ "$_wg_out" == *"File exists"* ]]; then
            log_hint "A route this profile needs is already owned by another interface."
            _dump_routing_diag
            # Try to attribute the conflict to a specific interface.
            local _conflict_iface=""
            local _line _allowed_ip
            while IFS= read -r _line; do
                [[ "$_line" =~ ^\[\#\][[:space:]]ip[[:space:]]-[46][[:space:]]route[[:space:]]add[[:space:]]+([^[:space:]]+)[[:space:]]+dev ]] || continue
                _allowed_ip="${BASH_REMATCH[1]}"
                _conflict_iface="$(ip -4 route show "$_allowed_ip" 2>/dev/null \
                    | awk '/^/{ for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit} }')"
                [[ -n "$_conflict_iface" ]] && break
            done <<<"$_wg_out"
            if [[ -n "$_conflict_iface" ]]; then
                log_hint "Route '$_allowed_ip' is currently held by '$_conflict_iface'."
                if [[ "$_conflict_iface" != wg-* ]] || ! list_profiles | grep -qx "${_conflict_iface#wg-}"; then
                    log_hint "'$_conflict_iface' is NOT managed by tunforge. To fix:"
                    log_hint "  sudo tunforge purge-wg      (or: sudo wg-quick down $_conflict_iface)"
                    log_hint "  or set TUNFORGE_PURGE_FOREIGN_WG=1 to auto-purge on the next connect"
                fi
            fi
        fi
        # Make sure we don't leave a half-up wg interface behind.
        if ip link show "$iface" >/dev/null 2>&1; then
            ip link delete dev "$iface" 2>/dev/null || true
        fi
        return "$_wg_rc"
    fi

    log_ok "WireGuard interface $iface is up"
    state_set_iface "$iface"
    bypass_apply_routes || true

    if [[ -n "${P_MTU:-}" ]]; then
        ip link set dev "$iface" mtu "$P_MTU" 2>/dev/null || \
            log_warn "Could not set MTU=$P_MTU on $iface"
    fi

    local _dns_rc=0
    # shellcheck disable=SC2086
    TUNFORGE_BYPASS_DNS_IFACE="$wan" "$LIB/dns.sh" lock "$iface" $P_DNS_SERVERS || _dns_rc=$?
    "$LIB/dns.sh" set-dot "$iface" "${P_DNS_OVER_TLS:-opportunistic}" || true
    if (( _dns_rc != 0 )); then return 1; fi

    if [[ "${P_KILL_SWITCH:-yes}" == "yes" ]]; then
        local _fw_rc=0
        "$LIB/firewall.sh" up "$wan" "$iface" "${endpoint_ips[@]}" || _fw_rc=$?
        if (( _fw_rc != 0 )); then return 1; fi
    fi
}

wireguard_down() {
    local iface
    iface="$(state_get_iface)"
    if [[ -z "$iface" ]]; then
        # Best-effort: maybe the profile name is loaded
        if [[ -n "${P_NAME:-}" ]]; then
            iface="$(_iface_for_profile)"
        fi
    fi

    if [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1; then
        local conf="${TUNFORGE_RUN}/${iface}.conf"
        log_detail "wireguard: wg-quick down $iface"
        if [[ -f "$conf" ]]; then
            wg-quick down "$conf" 2>/dev/null || ip link del "$iface" 2>/dev/null || true
        else
            ip link del "$iface" 2>/dev/null || true
        fi
    fi
    [[ -n "$iface" ]] && rm -f "${TUNFORGE_RUN}/${iface}.conf"
    bypass_clear_routes || true
    state_set_iface ""
}

case "${1:-}" in
    up)
        load_profile "${2:?usage: wireguard.sh up <profile>}"
        wireguard_up ;;
    down)
        # Accept optional profile name; if provided, load it so we can derive
        # iface name from $P_NAME. If absent, rely on state_get_iface().
        if [[ -n "${2:-}" ]]; then load_profile "$2"; fi
        wireguard_down ;;
    *)    echo "usage: wireguard.sh <up|down> [profile]" >&2; exit 2 ;;
esac
