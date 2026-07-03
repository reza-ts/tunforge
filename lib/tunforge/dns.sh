#!/usr/bin/env bash
# tunforge/dns.sh - VPN-first DNS using systemd-resolved per-link routing.
#
# Strategy
# --------
# systemd-resolved supports per-link DNS plus a special routing-only domain "~."
# that catches *all* queries. We set the VPN tunnel's link to own that catch-all
# and revert every other link's DNS so they cannot race.
#
# Subcommands
#   lock    <iface> <servers...>   apply VPN-first lock for the tunnel iface
#   set-dot <iface> <off|opportunistic|yes>
#   revert  <iface>                undo lock for one iface
#   revert-all                     revert every link (used during teardown)
#   show                           debug helper

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

# All real links (skip lo).
_all_links() {
    resolvectl status --no-pager 2>/dev/null \
        | awk '/^Link [0-9]+ /{ gsub(/[()]/,"",$3); print $3 }' \
        | grep -v '^lo$' || true
}

dns_lock() {
    local iface="$1"; shift
    local servers="$*"
    [[ -n "$iface" ]]   || die "dns_lock: iface required"
    [[ -n "$servers" ]] || die "dns_lock: at least one DNS server required"

    log_step "Pinning DNS to the tunnel ($iface -> $servers)"

    # Wait briefly for the iface to be visible to resolved (it polls netlink).
    local i seen=0
    for ((i=0; i<20; i++)); do
        if resolvectl status "$iface" >/dev/null 2>&1; then seen=1; break; fi
        sleep 0.1
    done
    (( seen )) || log_warn "systemd-resolved does not see '$iface' yet - applying anyway"

    # Apply DNS to the VPN link.
    # shellcheck disable=SC2086
    resolvectl dns "$iface" $servers
    resolvectl domain "$iface" '~.'
    resolvectl default-route "$iface" yes
    resolvectl dnssec "$iface" allow-downgrade

    # Revert DNS on every other link so they cannot answer queries. This is the
    # critical step that prevents DNS racing between LAN DHCP DNS and VPN DNS.
    local link reverted=()
    while IFS= read -r link; do
        [[ -z "$link" || "$link" == "$iface" ]] && continue
        resolvectl revert "$link" 2>/dev/null || true
        reverted+=("$link")
    done < <(_all_links)
    (( ${#reverted[@]} == 0 )) \
        || log_detail "cleared DNS on other links so they cannot race: ${reverted[*]}"

    # Optional local-dev DNS bypass. The connector passes the pre-VPN WAN link
    # in TUNFORGE_BYPASS_DNS_IFACE so names like backend.local can still resolve
    # via DHCP/router DNS while ~. stays pinned to the tunnel.
    local bypass_iface="${TUNFORGE_BYPASS_DNS_IFACE:-}"
    if [[ -n "$bypass_iface" && "$bypass_iface" != "$iface" ]]; then
        local domains=() domain
        while IFS= read -r domain; do
            [[ -n "$domain" ]] && domains+=("~$domain")
        done < <(bypass_domains_iter)
        if (( ${#domains[@]} > 0 )); then
            if resolvectl domain "$bypass_iface" "${domains[@]}" 2>/dev/null; then
                resolvectl default-route "$bypass_iface" no 2>/dev/null || true
                log_ok "Bypass domains still resolve via $bypass_iface: ${domains[*]}"
            else
                log_warn "Could not route bypass domains via $bypass_iface"
            fi
        fi
    fi

    resolvectl flush-caches
    log_ok "DNS locked to the tunnel - no other link can answer queries"
}

dns_set_dot() {
    local iface="$1" mode="${2:-opportunistic}"
    case "$mode" in
        off|opportunistic|yes) ;;
        *) die "dns_set_dot: invalid mode '$mode' (off|opportunistic|yes)" ;;
    esac
    if resolvectl dnsovertls "$iface" "$mode" 2>/dev/null; then
        log_detail "dns: DNS-over-TLS on '$iface' set to $mode"
    else
        log_warn "Could not set DNS-over-TLS on $iface (systemd too old?)"
    fi
}

dns_revert() {
    local iface="$1"
    [[ -n "$iface" ]] || die "dns_revert: iface required"
    log_detail "dns: reverting '$iface'"
    resolvectl revert "$iface" 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true
}

dns_revert_all() {
    log_detail "dns: reverting all links"
    local link
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        resolvectl revert "$link" 2>/dev/null || true
    done < <(_all_links)
    resolvectl flush-caches 2>/dev/null || true
}

dns_show() {
    resolvectl status --no-pager
}

# ---------------------------------------------------------------------------
# Direct-path DNS hardening (DNS-over-TLS fallback)
# ---------------------------------------------------------------------------
# Some networks blackhole outbound UDP wholesale - not just port 53 - while
# leaving TCP intact. On those, a VPN over TCP works fine but the moment you
# drop back to a direct connection every plain DNS query times out, because
# systemd-resolved speaks UDP/53 and only ever degrades EDNS0 options, never
# the transport. FallbackDNS= does not rescue this either: resolved consults
# it only when a link has *no* servers at all.
#
# So after a teardown we probe the restored direct path and, if plain DNS is
# genuinely dead, move the link to DNS-over-TLS (TCP/853) instead.

# Built-in DoT candidates, tried in order. Iranian resolvers first to match
# bootstrap_resolve_ipv4()'s ordering - they are the ones that stay reachable
# on the networks this tool targets. Servers whose certificate fails hostname
# or expiry validation are skipped automatically, so listing a stale endpoint
# here is harmless.
_DOT_BUILTIN=(
    "185.51.200.1"      # Shecan
    "178.22.122.101"    # Shecan
    "185.51.200.2"      # Shecan (free tier)
    "178.22.122.100"    # Electro / 403
    "1.1.1.1#cloudflare-dns.com"
    "1.0.0.1#cloudflare-dns.com"
    "8.8.8.8#dns.google"
    "8.8.4.4#dns.google"
    "9.9.9.9#dns.quad9.net"
)

# Servers currently configured on a link, space separated.
_link_dns_servers() {
    resolvectl dns "$1" 2>/dev/null | sed 's/^[^:]*: *//' | tr -s ' '
}

# FallbackDNS= from resolved's config. These are plain-DNS entries but they
# are worth probing for DoT too - most public resolvers offer both.
_resolved_fallback_servers() {
    local f
    for f in /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf; do
        [[ -r "$f" ]] || continue
        sed -n 's/^[[:space:]]*FallbackDNS[[:space:]]*=[[:space:]]*//p' "$f"
    done 2>/dev/null | tr ' ' '\n' | awk 'NF'
}

_dot_configured_servers() {
    [[ -r "$TUNFORGE_DOT_SERVERS" ]] || return 0
    local line trim
    while IFS= read -r line || [[ -n "$line" ]]; do
        # A '#' inside an entry is the SNI separator, not a comment marker, so
        # a line is only a comment when it *starts* with one.
        [[ "$line" =~ ^[[:space:]]*[#\;] ]] && continue
        trim="$line"
        trim="${trim#"${trim%%[![:space:]]*}"}"
        trim="${trim%"${trim##*[![:space:]]}"}"
        [[ -n "$trim" ]] && printf '%s\n' "$trim"
    done < "$TUNFORGE_DOT_SERVERS"
}

# Candidate list: user config first, then whatever the link/resolved already
# know about, then the built-ins. Deduplicated by IP, first spelling wins.
_dot_candidates() {
    local iface="$1"
    {
        _dot_configured_servers
        _link_dns_servers "$iface" | tr ' ' '\n'
        _resolved_fallback_servers
        printf '%s\n' "${_DOT_BUILTIN[@]}"
    } 2>/dev/null \
        | awk 'NF' \
        | grep -v ':' \
        | awk -F'#' '!seen[$1]++'   # IPv6 (contains ':') is out of scope here
}

# Names the server's certificate actually claims, so a bare IP in the
# candidate list still yields an SNI we can validate against.
_dot_cert_names() {
    local ip="$1" pem
    pem="$(timeout 6 openssl s_client -connect "${ip}:853" </dev/null 2>/dev/null)" || return 0
    [[ -n "$pem" ]] || return 0
    {
        printf '%s\n' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
            | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS:\(.*\)$/\1/p'
        printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p'
    } 2>/dev/null | tr -d ' ' | grep -v '^\*' | awk 'NF && !seen[$0]++'
}

# Full certificate validation (chain + hostname + expiry) against one name.
_dot_verify() {
    local ip="$1" sni="$2"
    timeout 8 openssl s_client -connect "${ip}:853" \
        -servername "$sni" -verify_hostname "$sni" -verify_return_error \
        </dev/null >/dev/null 2>&1
}

# Echo "IP#SNI" if this candidate is a usable, certificate-valid DoT server.
_dot_probe() {
    local entry="$1"
    local ip="${entry%%#*}" sni=""
    [[ "$entry" == *#* ]] && sni="${entry#*#}"

    if [[ -n "$sni" ]]; then
        _dot_verify "$ip" "$sni" && { printf '%s#%s\n' "$ip" "$sni"; return 0; }
        return 1
    fi

    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if _dot_verify "$ip" "$name"; then
            printf '%s#%s\n' "$ip" "$name"
            return 0
        fi
    done < <(_dot_cert_names "$ip")
    return 1
}

# Remember / forget the working DoT servers so the NetworkManager dispatcher
# hook can restore them after NM reconfigures the link.
_dot_remember() {
    install -d -m 0750 "$(dirname "$TUNFORGE_DOT_ACTIVE")" 2>/dev/null || true
    printf '%s\n' "$@" > "${TUNFORGE_DOT_ACTIVE}.tmp" 2>/dev/null || return 0
    chmod 0640 "${TUNFORGE_DOT_ACTIVE}.tmp" 2>/dev/null || true
    mv -f "${TUNFORGE_DOT_ACTIVE}.tmp" "$TUNFORGE_DOT_ACTIVE" 2>/dev/null || true
}

_dot_forget() {
    rm -f "$TUNFORGE_DOT_ACTIVE" 2>/dev/null || true
}

# Does the link resolve names right now?
_link_resolves() {
    local host="$TUNFORGE_DNS_PROBE_HOST" i
    for ((i=0; i<"${2:-3}"; i++)); do
        if timeout 5 resolvectl query --legend=no "$host" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Main entry. Prints one report line per decision to stdout; the caller folds
# that into the purge report.
dns_harden_direct() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || { mark_warn "No WAN interface to check DNS on"; return 0; }

    if ! command -v resolvectl >/dev/null 2>&1; then
        mark_warn "resolvectl unavailable - skipped the direct-path DNS check"
        return 0
    fi

    local servers server
    servers="$(_link_dns_servers "$iface")"
    if [[ -z "${servers// }" ]]; then
        mark_warn "$iface has no DNS servers yet - skipped the direct-path check"
        return 0
    fi

    # Plain DNS working is the normal case; leave a healthy network alone. Also
    # drop any remembered DoT config - the laptop has moved to a network that
    # does not need it, and re-applying it there would be a pointless downgrade.
    for server in $servers; do
        if dns_udp53_works "$server"; then
            _dot_forget
            mark_ok "Plain DNS works on $iface via $server - no change needed"
            return 0
        fi
    done

    # UDP/53 is dead. Only worth reaching for DoT if the box has a network at
    # all - otherwise we would blame the transport for an unplugged cable.
    local tcp_ok=0
    for server in $servers; do
        if dns_tcp53_works "$server"; then tcp_ok=1; break; fi
    done
    if (( tcp_ok )); then
        mark_warn "This network blocks UDP/53 but allows TCP/53 - trying DNS-over-TLS"
    else
        mark_fail "No configured resolver answered on either transport (${servers// / })"
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        mark_fail "openssl is missing - cannot fall back to DNS-over-TLS (apt install openssl)"
        return 0
    fi

    # Bounded: every unreachable candidate costs a full TLS timeout, and purge
    # must not turn into a two-minute scan. Two working servers is plenty.
    local -a good=()
    local cand result tried=0
    while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        (( tried++ >= 6 )) && break
        if result="$(_dot_probe "$cand")"; then
            good+=("$result")
            mark_ok "DNS-over-TLS server reachable: ${result%%#*}"
            (( ${#good[@]} >= 2 )) && break
        fi
    done < <(_dot_candidates "$iface")

    if (( ${#good[@]} == 0 )); then
        _dot_forget
        mark_fail "No DNS-over-TLS server is reachable either - DNS will not work off-VPN"
        return 0
    fi

    # Apply, then confirm resolved can actually answer through it. If it
    # cannot, put the link back the way we found it rather than leaving a
    # half-applied config behind.
    resolvectl dns "$iface" "${good[@]}" 2>/dev/null || true
    resolvectl dnsovertls "$iface" yes 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true

    if _link_resolves "$iface" 5; then
        _dot_remember "${good[@]}"
        mark_ok "Switched $iface to DNS-over-TLS - name resolution restored"
        mark_ok "This survives DHCP renewals and reboots (NetworkManager hook)"
        return 0
    fi

    _dot_forget
    mark_fail "DNS-over-TLS did not resolve either - reverted $iface to ${servers// / }"
    resolvectl dnsovertls "$iface" no 2>/dev/null || true
    # shellcheck disable=SC2086
    resolvectl dns "$iface" $servers 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true
    return 0
}

# Fast path: re-apply the remembered DoT servers to a link. Called by the
# NetworkManager dispatcher on every up / DHCP renewal, so it must stay cheap
# and must never probe the network - NM blocks on dispatcher scripts.
dns_dot_reapply() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || return 0

    # Never touch a tunnel: while a VPN is up, dns_lock owns DNS routing and a
    # second resolver on another link is exactly the race it exists to prevent.
    case "$iface" in
        lo|wg-*|wg[0-9]*|tun*|tunforge-*) return 0 ;;
    esac

    [[ -r "$TUNFORGE_DOT_ACTIVE" ]] || return 0

    local active; active="$(state_get_active 2>/dev/null || echo none)"
    [[ "$active" == "none" || -z "$active" ]] || return 0
    [[ -s "$TUNFORGE_IFACE_FILE" ]] && return 0

    local -a servers=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && servers+=("$line")
    done < "$TUNFORGE_DOT_ACTIVE"
    (( ${#servers[@]} )) || return 0

    resolvectl dns "$iface" "${servers[@]}" 2>/dev/null || return 0
    resolvectl dnsovertls "$iface" yes 2>/dev/null || true
    resolvectl flush-caches 2>/dev/null || true
    log_info "dns: re-applied DNS-over-TLS on '$iface' (${servers[*]})"
}

case "${1:-}" in
    lock)          shift; dns_lock "$@" ;;
    set-dot)       shift; dns_set_dot "$@" ;;
    revert)        shift; dns_revert "$@" ;;
    revert-all)    dns_revert_all ;;
    harden-direct) shift; dns_harden_direct "$@" ;;
    dot-reapply)   shift; dns_dot_reapply "$@" ;;
    show)          dns_show ;;
    *) cat >&2 <<EOF
usage: dns.sh <subcommand> [args]
  lock <iface> <servers...>          make iface the only resolver (~. domain)
  set-dot <iface> <off|opportunistic|yes>
  revert <iface>                     undo lock for one iface
  revert-all                         revert every link
  harden-direct <iface>              if plain DNS is dead off-VPN, move the
                                     link to DNS-over-TLS
  dot-reapply <iface>                re-apply the remembered DoT servers
                                     (NetworkManager dispatcher hook)
  show                               print resolvectl status
EOF
        exit 2 ;;
esac
