#!/usr/bin/env bash
# tunforge/connectors/singbox.sh
#
# Strategy:
#   - sing-box runs in TUN mode (auto_route + strict_route) so it transparently
#     captures ALL system traffic, not just SOCKS-aware apps. This is what
#     makes V2Ray work as a system-wide VPN even though v2ray-core itself is
#     only a SOCKS proxy.
#   - The user supplies a sing-box JSON CONFIG directly. They can also paste
#     a vmess://, vless://, trojan:// or ss:// URI through `tunforge import`,
#     which is a thin wrapper that converts URIs into JSON configs that match
#     this normalizer's expectations.
#   - We force the tun interface name to "tun-opus0" via JSON post-processing
#     so we always know what to lock DNS on and which iface the kill switch
#     should pin.

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

SB_IFACE="tun-opus0"

_pid_file_for_profile() { printf '%s/singbox-%s.pid\n' "$TUNFORGE_RUN" "$P_NAME"; }
_log_file()             { printf '%s/singbox-%s.log\n' "$TUNFORGE_RUN" "$P_NAME"; }
_run_conf()             { printf '%s/singbox-%s.json\n' "$TUNFORGE_RUN" "$P_NAME"; }

# Patch the user's sing-box config so the TUN iface is renamed to SB_IFACE and
# auto_route/strict_route are forced on. This is what makes it a SYSTEM-wide
# tunnel instead of a SOCKS proxy.
_normalize_config() {
    local src="$1" dst="$2"
    command -v jq >/dev/null 2>&1 || die "singbox: jq not installed (apt install jq)"

    # Validate JSON
    jq empty "$src" >/dev/null 2>&1 || die "singbox: $src is not valid JSON"

    # Inject / override TUN inbound. If the user already has a tun inbound, we
    # rewrite it; otherwise we prepend one. Field names follow sing-box >= 1.12
    # (`address` instead of `inet4_address`, `sniff` is a route-rule action,
    # not an inbound field).
    #
    # We ALSO migrate legacy `dns.servers[].address` entries (sing-box <1.12)
    # to the new `type`+`server` schema. sing-box 1.13 makes this fatal, so a
    # config pasted from a legacy template fails `sing-box check` outright.
    jq --arg iface "$SB_IFACE" '
        def _hp($s):
            ($s | split("/") | .[0]) as $a
            | ($a | split(":")) as $p
            | if ($p|length) > 1 and ($p[-1] | test("^[0-9]+$"))
              then {server: ($p[0:-1] | join(":")), server_port: ($p[-1] | tonumber)}
              else {server: $a}
              end;
        def _addr_to_new($a):
            if   ($a | startswith("rcode://")) then null
            elif ($a | startswith("tls://"))   then ({type:"tls"  } + _hp($a | ltrimstr("tls://")))
            elif ($a | startswith("https://")) then ({type:"https"} + _hp($a | ltrimstr("https://")))
            elif ($a | startswith("h3://"))    then ({type:"h3"   } + _hp($a | ltrimstr("h3://")))
            elif ($a | startswith("quic://"))  then ({type:"quic" } + _hp($a | ltrimstr("quic://")))
            elif ($a | startswith("tcp://"))   then ({type:"tcp"  } + _hp($a | ltrimstr("tcp://")))
            elif ($a | startswith("udp://"))   then ({type:"udp"  } + _hp($a | ltrimstr("udp://")))
            elif ($a | startswith("dhcp://"))  then {type:"dhcp", interface:($a | ltrimstr("dhcp://"))}
            elif ($a == "local")               then {type:"local"}
            elif ($a == "fakeip")              then {type:"fakeip"}
            elif ($a == "")                    then null
            else {type:"udp", server:$a}
            end;

        (if (.dns? | type) == "object" then
            .dns.servers = ((.dns.servers // []) | map(
                if (.type // null) != null then .
                else
                    ((.address // "") | tostring) as $a
                    | (_addr_to_new($a)) as $new
                    | if $new == null then null else (del(.address) + $new) end
                end
                # 1.12+ rejects these legacy fields on DNS servers as
                # "unknown field". They no longer have a 1:1 replacement at
                # the server level; sing-box uses sane defaults so dropping
                # them is safe (the user picks the server via dns.rules
                # anyway, and that bit we preserve).
                | del(.address_resolver, .address_strategy, .strategy, .client_subnet)
            ) | map(select(. != null)))
            | ((.dns.servers // []) | map(.tag // empty) | map(select(. != ""))) as $tags
            | .dns.rules = ((.dns.rules // []) | map(
                (.server // null) as $s
                | if $s != null
                     and (($tags | index($s)) // null) == null
                  then null else . end
            ) | map(select(. != null)))
            | ((.dns.final // null) as $f
               | if $f != null
                    and (($tags | index($f)) // null) == null
                 then .dns.final = null else . end)
        else . end)
        | .inbounds = ((.inbounds // []) | map(
            if .type == "tun"
            then ( . + {
                    interface_name: $iface,
                    auto_route: true,
                    strict_route: true,
                    address: ((.address // .inet4_address // ["172.19.0.1/30"])
                              | if type=="array" then . else [.] end),
                    stack: (.stack // "system"),
                    mtu: (.mtu // 9000)
                  }
                  | del(.inet4_address)
                )
            else . end
            # sing-box 1.11 deprecated and 1.13 OUTRIGHT REJECTS these
            # legacy inbound fields. They migrated to route rule actions
            # (sniff is now a rule with action=sniff, etc.). Drop them
            # from EVERY inbound so older imports / pasted configs load.
            # https://sing-box.sagernet.org/migration/#migrate-legacy-inbound-fields-to-rule-actions
            | del(
                .sniff,
                .sniff_override_destination,
                .sniff_timeout,
                .domain_strategy,
                .udp_disable_domain_unmapping,
                .udp_timeout,
                .set_system_proxy
            )
        ))
        | if (any(.inbounds[]; .type == "tun")) then .
          else .inbounds = ([{
              type: "tun",
              tag: "opus-tun-in",
              interface_name: $iface,
              address: [ "172.19.0.1/30" ],
              mtu: 9000,
              auto_route: true,
              strict_route: true,
              stack: "system"
          }] + .inbounds)
          end
        # sing-box 1.11 deprecated and 1.13 OUTRIGHT REMOVED the special
        # outbound types `dns` and `block`. Their replacements live in
        # route.rules as `action: "hijack-dns"` and `action: "reject"`.
        # Older imports / pasted configs still ship them, so:
        #   1. record the tag -> type map BEFORE deletion (we need it to
        #      decide which rule action to substitute);
        #   2. drop those outbounds;
        #   3. walk route.rules - any rule that targeted a dropped tag via
        #      `outbound: <tag>` gets converted to the equivalent action;
        #   4. patch route.final / route.default_outbound if they pointed
        #      at one of the dropped tags (sing-box check would otherwise
        #      fail with "outbound not found").
        # https://sing-box.sagernet.org/migration/#migrate-legacy-special-outbounds-to-rule-actions
        | ( ((.outbounds // []) | map({key:(.tag // ""), value:(.type // "")}) | from_entries) ) as $tag2type
        | ( [(.outbounds // [])[] | select(((.type // "") == "dns") or ((.type // "") == "block")) | (.tag // empty)] ) as $dropped
        | .outbounds = ((.outbounds // []) | map(
              select( ((.type // "") != "dns") and ((.type // "") != "block") )
          ))
        | (
            ((.outbounds // []) | map(select((.type // "") != "direct")) | .[0].tag)
            // ((.outbounds // []) | .[0].tag)
            // "direct"
          ) as $fallback_outbound
        | .route = (.route // {})
        | .route.rules = ((.route.rules // []) | map(
            (.outbound // null) as $ob
            | if $ob != null and ($ob | IN($dropped[]))
              then
                  ($tag2type[$ob] // "") as $t
                  | (if   $t == "dns"   then . + {action:"hijack-dns"}
                     elif $t == "block" then . + {action:"reject"}
                     else . end)
                  | del(.outbound)
              else . end
          ))
        | ((.route.final // null) as $rf
           | if $rf != null and ($rf | IN($dropped[]))
             then .route.final = $fallback_outbound
             else . end)
        | ((.route.default_outbound // null) as $rdo
           | if $rdo != null and ($rdo | IN($dropped[]))
             then .route.default_outbound = $fallback_outbound
             else . end)
        # sing-box 1.12+ requires `route.default_domain_resolver` (or per-dial
        # `domain_resolver`). We add a local DNS server (tag "local-dns") and set
        # the default to it. This is placed *after* the DNS normalization block
        # so it does not get filtered. Keeps our DNS locking on tun-opus0 intact.
        # See: https://sing-box.sagernet.org/migration/#migrate-outbound-dns-rule-items-to-domain-resolver
        | .dns = ((.dns // {}) + {servers: ((.dns.servers // []) + [{ tag: "local-dns", type: "local" }])})
        | .route = (.route // {})
        # VLESS commonly cannot carry UDP DNS reliably. Capture system DNS
        # packets at sing-box and resolve them through sing-box DNS instead of
        # forwarding 1.1.1.1:53 / 9.9.9.9:53 as UDP over the proxy outbound.
        | .route.rules = (
            (if any((.route.rules // [])[]; (.action // "") == "hijack-dns" or (.protocol // "") == "dns")
             then []
             else [{protocol:"dns", action:"hijack-dns"}]
             end)
            + (.route.rules // [])
          )
        | .route.auto_detect_interface = true
        | .route.default_domain_resolver = "local-dns"
    ' "$src" > "$dst"

    chmod 0600 "$dst"
}

# Best-effort extraction of the upstream proxy server IP/host so we can
# whitelist it in the kill switch. Looks for an outbound with a "server" field.
_extract_servers() {
    local conf="$1"
    jq -r '
        [
            (.outbounds[]?
             | select(.type? as $t | $t != "direct" and $t != "block" and $t != "dns")
             | .server // empty),
            (.endpoints[]?
             | select((.type // "") == "wireguard")
             | .peers[]?
             | .address // empty)
        ] | unique | .[]
    ' "$conf"
}

singbox_up() {
    [[ -n "${P_CONFIG:-}" ]] || die "singbox: profile not loaded"
    command -v sing-box >/dev/null 2>&1 || die "singbox: sing-box not installed (re-run install.sh)"

    install -d -m 0700 "$TUNFORGE_RUN"
    local pidf; pidf="$(_pid_file_for_profile)"
    local logf; logf="$(_log_file)"
    local conf; conf="$(_run_conf)"

    : > "$logf"; chmod 0600 "$logf"

    log_detail "singbox: normalizing config -> $conf"
    _normalize_config "$P_CONFIG" "$conf"

    local servers=() endpoint_ips=()
    local -A pinned_server_ip=()
    readarray -t servers < <(_extract_servers "$conf")
    if [[ -n "${P_ENDPOINT_IP:-}" ]]; then
        endpoint_ips=("$P_ENDPOINT_IP")
        local s
        for s in "${servers[@]}"; do
            [[ -n "$s" ]] && pinned_server_ip["$s"]="$P_ENDPOINT_IP"
        done
        log_ok "Using pinned ENDPOINT_IP=$P_ENDPOINT_IP from the profile"
    else
        if (( ${#servers[@]} == 0 )); then
            log_fail "No proxy outbound with a .server field in $P_CONFIG"
            log_hint "Inspect it with: jq '.outbounds' $P_CONFIG"
            log_hint "Or pin the endpoint yourself: add ENDPOINT_IP=<ip> to ${P_NAME}.profile"
            die "Cannot determine the VPN endpoint to allow through the kill switch"
        fi
        log_detail "singbox: upstream server(s): ${servers[*]}"
        local s ip
        for s in "${servers[@]}"; do
            [[ -z "$s" ]] && continue
            local _resolved=""
            while IFS= read -r ip; do
                if [[ -n "$ip" ]]; then
                    endpoint_ips+=("$ip")
                    [[ -z "${pinned_server_ip[$s]:-}" ]] && pinned_server_ip["$s"]="$ip"
                    _resolved+="$ip "
                fi
            done < <(resolve_endpoint_ipv4 "$s")
            if [[ -z "$_resolved" ]]; then
                log_detail "singbox: could not resolve upstream server $s"
            fi
        done
    fi
    if (( ${#endpoint_ips[@]} == 0 )); then
        log_fail "Every upstream server hostname failed to resolve (${servers[*]})"
        log_hint "Your network is most likely blocking outbound DNS entirely."
        log_hint "Fix options, best first:"
        log_hint "  1. Pin the IP:  add ENDPOINT_IP=<real-ip> to ${P_NAME}.profile"
        log_hint "  2. Bypass poisoned DNS:  sudo tunforge dns-direct add '^${servers[0]//./\\.}$'"
        log_hint "  3. Use a provider whose domains resolve reliably here"
        # exit, not die: the failure and its remedy are already on screen, and
        # die would print a second, less useful error line under them.
        exit 1
    fi
    log_ok "Resolved VPN endpoint(s): ${endpoint_ips[*]}"

    # sing-box still resolves outbound.server at runtime. In censored networks
    # that lookup can fail after the TUN and DNS routing are active, even though
    # tunforge already resolved the hostname successfully. Pin proxy outbounds to
    # the resolved IP and preserve the original host as TLS SNI when needed.
    local host first_ip tmp_conf
    for host in "${servers[@]}"; do
        [[ -n "$host" ]] || continue
        first_ip="${pinned_server_ip[$host]:-}"
        [[ -n "$first_ip" ]] || continue
        tmp_conf="$(mktemp "${conf}.XXXXXX")"
        # NOTE: never pin an outbound that has a `detour` (the exit hop of a
        # chained/multi-hop config). That hop is dialed THROUGH an upstream hop,
        # so it must be reached by HOSTNAME and resolved by the upstream's
        # network - pinning it to a client-resolved IP breaks CDN/Cloudflare-
        # fronted exits with "tls: first record does not look like a TLS
        # handshake". Only the WAN-dialing hop (no detour) is pinned.
        jq --arg host "$host" --arg ip "$first_ip" '
            .outbounds = ((.outbounds // []) | map(
                if (.server? // "") == $host and ((.detour // "") == "") then
                    .server = $ip
                    # Preserve the original domain for protocols that validate
                    # SNI/Host. Without this, CDN-backed VLESS/VMess servers
                    # often accept TCP then reset the connection.
                    | if (.tls? | type) == "object" and ((.tls.server_name // "") == "") then
                        .tls.server_name = $host
                      else . end
                    | if (.transport? | type) == "object"
                         and ((.transport.type // "") | IN("ws", "http", "httpupgrade"))
                         and ((.transport.headers.Host // "") == "") then
                        .transport.headers = ((.transport.headers // {}) + {Host: $host})
                      else . end
                  else . end
            ))
            | .endpoints = ((.endpoints // []) | map(
                if (.type // "") == "wireguard" then
                    .peers = ((.peers // []) | map(
                        if (.address // "") == $host then .address = $ip else . end
                    ))
                  else . end
            ))
        ' "$conf" > "$tmp_conf"
        mv -f "$tmp_conf" "$conf"
        chmod 0600 "$conf"
        log_detail "singbox: pinned outbound $host -> $first_ip"
    done

    local wan; wan="$(default_wan_iface)"
    [[ -n "$wan" ]] || die "No default WAN interface - are you online?"

    # Make sing-box's own proxy dial escape the TUN. Without this, TUN
    # auto_route can capture the outbound connection to the VPN server itself,
    # which shows up as repeated VLESS "context canceled" / reset failures.
    # Skip outbounds that have a `detour`: in a chained (multi-hop) config the
    # exit outbound is dialed THROUGH the entry, so it must not be pinned to the
    # WAN - only the hop that actually opens a WAN socket (no detour) gets bound.
    tmp_conf="$(mktemp "${conf}.XXXXXX")"
    jq --arg wan "$wan" '
        .outbounds = ((.outbounds // []) | map(
            if (.server? // "") != "" and ((.type // "") | IN("direct","block","dns") | not)
               and ((.detour // "") == "") then
                .bind_interface = $wan
              else . end
        ))
        | .endpoints = ((.endpoints // []) | map(
            if (.type // "") == "wireguard" then .bind_interface = $wan else . end
        ))
    ' "$conf" > "$tmp_conf"
    mv -f "$tmp_conf" "$conf"
    chmod 0600 "$conf"
    log_detail "singbox: binding WAN-dialing outbound(s) to $wan"

    local bypass_cidrs
    bypass_cidrs="$(bypass_cidrs_iter | tr '\n' ' ')"
    if [[ -n "${bypass_cidrs// }" ]]; then
        tmp_conf="$(mktemp "${conf}.XXXXXX")"
        jq --arg cidrs "$bypass_cidrs" '
            ($cidrs | split(" ") | map(select(. != ""))) as $bypass
            | .route = (.route // {})
            | .route.rules = ([{ip_cidr: $bypass, outbound: "direct"}] + (.route.rules // []))
        ' "$conf" > "$tmp_conf"
        mv -f "$tmp_conf" "$conf"
        chmod 0600 "$conf"
        log_detail "singbox: direct-routing local bypass CIDRs: $bypass_cidrs"
    fi

    # SB_IFACE is a singleton ("tun-opus0"). If a previous sing-box crashed
    # without auto_route's exit hook running, the iface lingers and the
    # next sing-box hits "interface already exists" and dies silently in
    # the background. Pre-clean defensively: kill the leftover sing-box
    # FIRST (so its TUN-owner reference is released), then drop the iface.
    local _stale_pid
    for _stale_pid in $(pgrep -f "sing-box.*${TUNFORGE_RUN}/singbox-" 2>/dev/null); do
        log_warn "Killing stale sing-box process $_stale_pid left by an earlier run"
        kill -TERM "$_stale_pid" 2>/dev/null || true
    done
    # Brief grace period for graceful exit + TUN release.
    if pgrep -f "sing-box.*${TUNFORGE_RUN}/singbox-" >/dev/null 2>&1; then
        sleep 0.3
        pkill -KILL -f "sing-box.*${TUNFORGE_RUN}/singbox-" 2>/dev/null || true
    fi
    if ip link show "$SB_IFACE" >/dev/null 2>&1; then
        log_warn "Removing stale interface '$SB_IFACE' from a previous run"
        ip link delete dev "$SB_IFACE" 2>/dev/null || true
    fi

    local _check_rc=0
    sing-box check -c "$conf" 2>>"$logf" || _check_rc=$?
    if (( _check_rc != 0 )); then
        log_fail "sing-box rejected the generated config"
        _tail_log "$logf"
        return 1
    fi
    log_ok "sing-box config is valid"

log_detail "singbox: launching"
    setsid sing-box run -D "$TUNFORGE_RUN" -c "$conf" \
        >>"$logf" 2>&1 &
    local pid=$!
    echo "$pid" > "$pidf"; chmod 0640 "$pidf"
    disown $pid 2>/dev/null || true

    local i tun_up=0 proc_dead=0
    for ((i=0; i<150; i++)); do
        if ip link show "$SB_IFACE" >/dev/null 2>&1; then tun_up=1; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then proc_dead=1; break; fi
        sleep 0.1
    done
    if (( proc_dead )); then
        log_fail "sing-box exited before the tunnel interface came up"
        _tail_log "$logf"
        return 1
    fi
    if (( ! tun_up )); then
        log_fail "Tunnel interface $SB_IFACE never appeared (waited 15s)"
        _tail_log "$logf"
        kill -TERM "$pid" 2>/dev/null || true
        return 1
    fi
    log_ok "Tunnel interface $SB_IFACE is up"

    state_set_iface "$SB_IFACE"
    bypass_apply_routes || true

    local _dns_rc=0
    # shellcheck disable=SC2086
    TUNFORGE_BYPASS_DNS_IFACE="$wan" "$LIB/dns.sh" lock "$SB_IFACE" $P_DNS_SERVERS || _dns_rc=$?
    # For sing-box TUN, systemd-resolved's DoT probe (1.1.1.1:853) itself
    # traverses the fresh proxy tunnel. That can deadlock early verification on
    # networks where the proxy has not warmed up yet. Plain DNS still goes
    # through tun-opus0 and is protected by the kill switch.
    local _dot_mode="${P_DNS_OVER_TLS:-off}"
    [[ "$_dot_mode" == "opportunistic" ]] && _dot_mode="off"
    "$LIB/dns.sh" set-dot "$SB_IFACE" "$_dot_mode" || true
    if (( _dns_rc != 0 )); then return 1; fi

    if [[ "${P_KILL_SWITCH:-yes}" == "yes" ]]; then
        local _fw_rc=0
        "$LIB/firewall.sh" up "$wan" "$SB_IFACE" "${endpoint_ips[@]}" || _fw_rc=$?
        if (( _fw_rc != 0 )); then return 1; fi
    fi
}

singbox_down() {
    local pidf=""
    if [[ -n "${P_NAME:-}" ]]; then
        pidf="$(_pid_file_for_profile)"
    fi

    if [[ -n "$pidf" && -f "$pidf" ]]; then
        local pid; pid="$(<"$pidf")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_detail "singbox: stopping pid $pid"
            kill -TERM "$pid" 2>/dev/null || true
            local i
            for ((i=0; i<50; i++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$pidf"
    else
        pkill -TERM -x sing-box 2>/dev/null || true
        sleep 0.3
        pkill -KILL -x sing-box 2>/dev/null || true
    fi

    # sing-box's strict_route adds policy routing rules that auto-clean on exit,
    # but if it crashed they may linger. Best-effort cleanup of the iface.
    if ip link show "$SB_IFACE" >/dev/null 2>&1; then
        ip link del "$SB_IFACE" 2>/dev/null || true
    fi

    # Wipe per-profile staging files so /run/tunforge doesn't accumulate
    # stale configs between runs. Keep the .log around briefly - the
    # transcript appender in core.sh tails it for the failure modal.
    if [[ -n "${P_NAME:-}" ]]; then
        rm -f \
            "$TUNFORGE_RUN/singbox-${P_NAME}.json" \
            "$TUNFORGE_RUN/singbox-${P_NAME}.pid" \
            2>/dev/null || true
    fi
    bypass_clear_routes || true
    state_set_iface ""
}

case "${1:-}" in
    up)
        load_profile "${2:?usage: singbox.sh up <profile>}"
        singbox_up ;;
    down)
        if [[ -n "${2:-}" ]]; then load_profile "$2"; fi
        singbox_down ;;
    *)    echo "usage: singbox.sh <up|down> [profile]" >&2; exit 2 ;;
esac
