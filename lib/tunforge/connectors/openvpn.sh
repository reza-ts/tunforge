#!/usr/bin/env bash
# tunforge/connectors/openvpn.sh
#
# Strategy:
#   - Run openvpn with --pull-filter ignore "dhcp-option DNS" so server-pushed
#     DNS does not touch /etc/resolv.conf (we own DNS via dns.sh).
#   - Force --redirect-gateway def1 bypass-dhcp so all traffic goes through tun.
#   - Daemonize and write pid + status to /run/tunforge/.
#   - Wait for the tun device to come up, capture its name, then apply DNS +
#     kill switch.

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

_pid_file_for_profile() { printf '%s/openvpn-%s.pid\n' "$TUNFORGE_RUN" "$P_NAME"; }
_status_file()          { printf '%s/openvpn-%s.status\n' "$TUNFORGE_RUN" "$P_NAME"; }
_log_file()             { printf '%s/openvpn-%s.log\n' "$TUNFORGE_RUN" "$P_NAME"; }
_auth_file_for_profile() {
    if [[ -n "${P_OPENVPN_AUTH_FILE:-}" ]]; then
        printf '%s\n' "$P_OPENVPN_AUTH_FILE"
    else
        printf '%s/openvpn/%s.auth\n' "$TUNFORGE_AUTH_DIR" "$P_NAME"
    fi
}

_extract_remote_host() {
    local conf="$1"
    awk '/^[[:space:]]*remote[[:space:]]+/{print $2; exit}' "$conf"
}

_iface_for_pid() {
    # Find which tun* iface this openvpn pid manages. Walks /sys/class/net.
    local pid="$1" iface
    for iface in /sys/class/net/tun*; do
        [[ -e "$iface/tun_flags" ]] || continue
        local owner
        owner="$(awk '/Owner:/{print $2}' "${iface}"/owner 2>/dev/null || true)"
        # Fall back: openvpn doesn't expose owner, just take the newest tun iface.
        :
    done
    # Simpler & more robust: read the pid's /proc/<pid>/fd for /dev/net/tun then
    # match via openvpn's status file which mentions the iface name.
    local sf; sf="$(_status_file)"
    if [[ -r "$sf" ]]; then
        awk -F, '/^TUN.TAP write bytes/ {next} /^OpenVPN STATISTICS/ {next}' "$sf" >/dev/null
    fi
    # The most reliable: openvpn writes "Initialization Sequence Completed" and
    # earlier "/sbin/ip link set dev tunN up mtu ..." which we can grep from log.
    awk '/^.*ip link set dev (tun|tap)[0-9]+ up/ { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
        "$(_log_file)" 2>/dev/null
}

openvpn_up() {
    [[ -n "${P_CONFIG:-}" ]] || die "openvpn: profile not loaded"
    command -v openvpn >/dev/null 2>&1 || die "openvpn is not installed (apt install openvpn)"

    install -d -m 0700 "$TUNFORGE_RUN"
    local pidf; pidf="$(_pid_file_for_profile)"
    local logf; logf="$(_log_file)"
    local statf; statf="$(_status_file)"

    : > "$logf"; chmod 0600 "$logf"
    : > "$statf"; chmod 0600 "$statf"

    # Many .ovpn files are distributed with Windows CRLF line endings (and
    # sometimes a UTF-8 BOM). awk/sed treat the trailing \r as part of the
    # last field, which silently turns "remote vpn.example.com" into
    # "vpn.example.com\r" and pushes that string into the resolver - hence
    # the bizarre NXDOMAIN for "s6.nimbaha.info\r". Build a normalized,
    # LF-only working copy up-front and use that for ALL downstream parsing
    # AND as openvpn's --config (a CRLF .ovpn does start, but a CRLF that
    # leaks into 'remote' breaks DNS).
    local conf_clean="$TUNFORGE_RUN/openvpn-$P_NAME.clean.conf"
    # Strip BOM (sed 1s/^\xef\xbb\xbf//) and CRs.
    sed -e '1s/^\xef\xbb\xbf//' -e 's/\r$//' "$P_CONFIG" > "$conf_clean"
    chmod 0600 "$conf_clean"

    if (( _cfg_crlf > 0 )); then
        log_detail "openvpn: config had Windows line endings; using normalized copy at $conf_clean"
    fi

    # Pre-resolve remote(s) for the kill switch (we may need to whitelist
    # multiple endpoints if the .ovpn lists fallbacks). Build a host->ip
    # mapping so we can also rewrite the .ovpn to use IPs directly, sparing
    # openvpn itself from calling getaddrinfo() against the poisoned ISP DNS.
    local endpoint_ips=()
    declare -A _host_to_ip=()
    local remote_map="$TUNFORGE_RUN/openvpn-$P_NAME.remotes.tsv"
    : > "$remote_map"; chmod 0600 "$remote_map"
    if [[ -n "${P_ENDPOINT_IP:-}" ]]; then
        endpoint_ips=("$P_ENDPOINT_IP")
    else
        local host
        while IFS= read -r host; do
            [[ -z "$host" ]] && continue
            local ip _resolved="" _first=""
            while IFS= read -r ip; do
                if [[ -n "$ip" ]]; then
                    endpoint_ips+=("$ip")
                    _resolved+="$ip "
                    [[ -z "$_first" ]] && _first="$ip"
                    if ! [[ "$host" =~ ^[0-9.]+$ ]]; then
                        printf '%s\t%s\n' "$host" "$ip" >> "$remote_map"
                    fi
                fi
            done < <(resolve_endpoint_ipv4 "$host")
            if [[ -n "$_first" ]] && ! [[ "$host" =~ ^[0-9.]+$ ]]; then
                _host_to_ip["$host"]="$_first"
            fi
        done < <(awk '/^[[:space:]]*remote[[:space:]]+/{print $2}' "$conf_clean")
    fi
    if ((${#endpoint_ips[@]} == 0)); then
        log_fail "Could not resolve any remote from $P_CONFIG"
        log_hint "Your network is most likely blocking outbound DNS entirely."
        log_hint "Pin the IP instead: add ENDPOINT_IP=<real-ip> to $P_NAME.profile"
        exit 1
    fi
    log_ok "Resolved VPN endpoint(s): ${endpoint_ips[*]}"

    # Rewrite the .ovpn into a sanitized copy with hostnames replaced by IPs.
    # OpenVPN's default cert validation (--remote-cert-tls / --ca) checks the
    # cert chain and nsCertType - it does NOT match against the connect
    # target hostname, so replacing 'remote vpn.foo 443' with 'remote 1.2.3.4
    # 443' does not break TLS. Configs that opt into hostname matching use
    # --verify-x509-name with an explicit name unaffected by this rewrite.
    local conf_pinned="$TUNFORGE_RUN/openvpn-$P_NAME.conf"
    if [[ -s "$remote_map" ]]; then
        awk -v map="$remote_map" '
            BEGIN {
                while ((getline line < map) > 0) {
                    split(line, a, "\t")
                    if (a[1] != "" && a[2] != "") {
                        ips[a[1]] = ips[a[1]] (ips[a[1]] == "" ? "" : " ") a[2]
                    }
                }
            }
            /^[[:space:]]*remote[[:space:]]+/ {
                host = $2
                if (host in ips) {
                    n = split(ips[host], list, " ")
                    for (i = 1; i <= n; i++) {
                        printf "%s %s", $1, list[i]
                        for (j = 3; j <= NF; j++) printf " %s", $j
                        printf "\n"
                    }
                    next
                }
            }
            { print }
        ' "$conf_clean" > "$conf_pinned"
        if ! grep -qE '^[[:space:]]*remote-random([[:space:]]|$)' "$conf_pinned"; then
            printf '\nremote-random\n' >> "$conf_pinned"
        fi
    else
        cp "$conf_clean" "$conf_pinned"
    fi
    chmod 0600 "$conf_pinned"

    # If saved credentials exist for this profile, force auth-user-pass to use
    # them. OpenVPN daemon mode cannot prompt interactively, so this avoids the
    # repeated username/password question and makes CLI/TUI behavior consistent.
    local authf; authf="$(_auth_file_for_profile)"
    if [[ -r "$authf" ]]; then
        local conf_auth="$TUNFORGE_RUN/openvpn-$P_NAME.auth.conf"
        awk -v auth="$authf" '
            BEGIN { replaced=0 }
            /^[[:space:]]*auth-user-pass([[:space:]]+.*)?$/ {
                print "auth-user-pass " auth
                replaced=1
                next
            }
            { print }
            END {
                if (!replaced) print "auth-user-pass " auth
            }
        ' "$conf_pinned" > "$conf_auth"
        chmod 0600 "$conf_auth"
        conf_pinned="$conf_auth"
        log_detail "openvpn: using saved credentials from $authf"
    elif grep -qE '^[[:space:]]*auth-user-pass([[:space:]]*)?$' "$conf_pinned" 2>/dev/null; then
        log_warn "This config needs a username/password but none are saved"
        log_hint "Save them with: sudo tunforge openvpn-auth set $P_NAME"
    fi

    local wan; wan="$(default_wan_iface)"
    [[ -n "$wan" ]] || die "No default WAN interface - are you online?"

    log_detail "openvpn: starting daemon for profile $P_NAME"

    # The --pull-filter pair is critical: server can't override our DNS or
    # routing. We add our own redirect-gateway just in case the server didn't.
    local _spawn_rc=0
    openvpn \
        --config "$conf_pinned" \
        --daemon "openvpn-tunforge-$P_NAME" \
        --writepid "$pidf" \
        --status "$statf" 5 \
        --log "$logf" \
        --script-security 2 \
        --pull-filter ignore "dhcp-option DNS" \
        --pull-filter ignore "dhcp-option DNS6" \
        --pull-filter ignore "dhcp-option DOMAIN" \
        --pull-filter ignore "dhcp-option DOMAIN-SEARCH" \
        --pull-filter ignore "redirect-gateway" \
        --redirect-gateway def1 bypass-dhcp \
        --remote-random \
        --connect-retry 3 10 \
        --connect-retry-max 10 \
        --persist-tun \
        --persist-key \
        ${P_MTU:+--tun-mtu $P_MTU} \
        || _spawn_rc=$?
    if (( _spawn_rc != 0 )); then
        die "openvpn failed to start (rc=$_spawn_rc)"
    fi

    # Wait long enough for OpenVPN to fail over across several pinned remotes.
    # Some provider DNS names resolve to many IPs, and a few may be dead/slow.
    local init_timeout="${TUNFORGE_OPENVPN_INIT_TIMEOUT:-60}"
    local max_iters=$(( init_timeout * 10 ))
    local i ok=0 fatal=0
    for ((i=0; i<max_iters; i++)); do
        if grep -q "Initialization Sequence Completed" "$logf" 2>/dev/null; then
            ok=1; break
        fi
        if grep -qE "Cannot resolve host address|TLS Error|AUTH_FAILED|Exiting due to fatal error" "$logf" 2>/dev/null; then
            fatal=1; break
        fi
        sleep 0.1
    done
    if (( fatal )); then
        log_fail "openvpn reported a fatal error"
        _tail_log "$logf" 20
        return 1
    fi
    if (( !ok )); then
        log_fail "openvpn did not finish connecting within ${init_timeout}s"
        _tail_log "$logf" 20
        return 1
    fi

    # Determine the tun iface. Try the log first, then fall back to "newest tun".
    local iface
    iface="$(awk '/ip link set dev (tun|tap)[0-9]+ up/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' "$logf")"
    if [[ -z "$iface" ]]; then
        iface="$(awk '/TUN\/TAP device (tun|tap)[0-9]+ opened/ {print $(NF-1); exit}' "$logf")"
    fi
    if [[ -z "$iface" ]]; then
        # last-resort: newest tun*
        iface="$(ls -1t /sys/class/net/ 2>/dev/null | grep -E '^(tun|tap)[0-9]+$' | head -n1 || true)"
    fi
    [[ -n "$iface" ]] || die "Could not determine the openvpn tunnel interface"
    log_ok "Tunnel interface $iface is up"

    state_set_iface "$iface"
    bypass_apply_routes || true

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

openvpn_down() {
    local pidf
    if [[ -n "${P_NAME:-}" ]]; then
        pidf="$(_pid_file_for_profile)"
    else
        pidf=""
    fi

    # Determine the tun iface this profile owned BEFORE we kill the daemon,
    # so we can verify it goes away (or force-delete it if it doesn't).
    local owned_iface=""
    if [[ -n "${P_NAME:-}" ]]; then
        local _ovpn_log; _ovpn_log="$(_log_file)"
        if [[ -f "$_ovpn_log" ]]; then
            owned_iface="$(awk '/ip link set dev (tun|tap)[0-9]+ up/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' "$_ovpn_log" 2>/dev/null)"
        fi
    fi

    if [[ -n "$pidf" && -f "$pidf" ]]; then
        local pid; pid="$(<"$pidf")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_detail "openvpn: stopping pid $pid"
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
        # belt-and-braces: kill any tunforge-tagged openvpn
        pkill -TERM -f 'openvpn-tunforge-' 2>/dev/null || true
        sleep 0.2
        pkill -KILL -f 'openvpn-tunforge-' 2>/dev/null || true
    fi

    # If openvpn died without removing its tun (SIGKILL, OOM), drop it
    # ourselves so the next connect attempt doesn't see a half-state.
    if [[ -n "$owned_iface" ]] && ip link show "$owned_iface" >/dev/null 2>&1; then
        log_warn "Interface '$owned_iface' survived openvpn shutdown - deleting it"
        ip link delete dev "$owned_iface" 2>/dev/null || true
    fi

    # Wipe per-profile staging files. Keep the .log around briefly -
    # _append_protocol_logs in core.sh tails it into the transcript.
    if [[ -n "${P_NAME:-}" ]]; then
        rm -f \
            "$TUNFORGE_RUN/openvpn-${P_NAME}.conf" \
            "$TUNFORGE_RUN/openvpn-${P_NAME}.clean.conf" \
            "$TUNFORGE_RUN/openvpn-${P_NAME}.status" \
            2>/dev/null || true
    fi
    bypass_clear_routes || true
    state_set_iface ""
}

case "${1:-}" in
    up)
        load_profile "${2:?usage: openvpn.sh up <profile>}"
        openvpn_up ;;
    down)
        if [[ -n "${2:-}" ]]; then load_profile "$2"; fi
        openvpn_down ;;
    *)    echo "usage: openvpn.sh <up|down> [profile]" >&2; exit 2 ;;
esac
