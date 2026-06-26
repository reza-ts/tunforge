#!/usr/bin/env bash
# tunforge/core.sh - shared helpers, locking, dispatch.
# Sourced by /usr/local/bin/tunforge and by every connector under connectors/.
# Never invoked directly.

# shellcheck shell=bash disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Paths (overridable by environment for tests)
# ---------------------------------------------------------------------------
: "${TUNFORGE_PREFIX:=/usr/local}"
: "${TUNFORGE_LIB:=${TUNFORGE_PREFIX}/lib/tunforge}"
: "${TUNFORGE_ETC:=/etc/tunforge}"
: "${TUNFORGE_VAR:=/var/lib/tunforge}"
: "${TUNFORGE_RUN:=/run/tunforge}"

TUNFORGE_PROFILES_DIR="${TUNFORGE_ETC}/profiles"
TUNFORGE_CONFIGS_DIR="${TUNFORGE_ETC}/configs"
TUNFORGE_TEMPLATES_DIR="${TUNFORGE_ETC}/templates"
TUNFORGE_GLOBAL_CONF="${TUNFORGE_ETC}/config.yaml"
TUNFORGE_AUTH_DIR="${TUNFORGE_ETC}/auth"

# V2Ray "soft sub" subscriptions. Each <name>.sub descriptor holds the remote
# URL + metadata; updating it re-fetches the URL, parses the connection list,
# and (re)generates one singbox profile per server tagged with SOURCE=<name>.
# Managed via `tunforge subscription` / tunforge-subscription.
TUNFORGE_SUBS_DIR="${TUNFORGE_ETC}/subscriptions"

# "Direct DNS" allow-list. One regex per line - this is the set of host
# patterns that MUST be resolved via direct public DNS (8.8.8.8, 1.1.1.1,
# ...) and never via the system NSS resolver. Use it for VPN provider
# domains your ISP DNS poisons: with the host on this list, tunforge won't
# silently fall back to the (poisoned) NSS answer if the public lookup
# fails - it will fail loudly so you know the network is blocking it.
# Managed via `tunforge dns-direct`.
TUNFORGE_DNS_DIRECT="${TUNFORGE_ETC}/dns-direct"

# Local-development bypass list. CIDRs here are allowed to leave outside the
# tunnel while the VPN is active, so services on localhost/LAN/Docker networks
# keep working. Domains here are routed to the WAN link's DNS with systemd-
# resolved route-only domains (for names like backend.local or mongo.dev).
TUNFORGE_BYPASS_FILE="${TUNFORGE_ETC}/bypass"

# DNS-over-TLS candidate resolvers, one "IP[#hostname]" per line. Used only
# when the direct (non-VPN) path cannot do plain DNS - some networks blackhole
# outbound UDP entirely, which makes UDP/53 unusable while TCP/853 still works.
# Entries are probed and the ones that pass certificate validation are applied
# to the WAN link. Missing file == use the built-in list in dns.sh.
TUNFORGE_DOT_SERVERS="${TUNFORGE_ETC}/dot-servers"

# The DoT servers that were last proven to work on the direct path, one per
# line. systemd-resolved's per-link DNS is runtime state, so every DHCP renewal
# or `nmcli device reapply` wipes it; this file is what lets the NetworkManager
# dispatcher hook put the setting back without re-probing. Absent == the direct
# path can do plain DNS and needs no help.
TUNFORGE_DOT_ACTIVE="${TUNFORGE_VAR}/dot-active"

# Hostname used for all DNS reachability probes. Overridable for air-gapped
# or split-horizon networks where example.com is not resolvable.
: "${TUNFORGE_DNS_PROBE_HOST:=example.com}"

TUNFORGE_STATE_FILE="${TUNFORGE_VAR}/active"
TUNFORGE_IFACE_FILE="${TUNFORGE_VAR}/active.iface"
TUNFORGE_PRESNAP_FILE="${TUNFORGE_VAR}/pre.snapshot"
TUNFORGE_LOCK_FILE="${TUNFORGE_VAR}/lock"
TUNFORGE_PIDDIR="${TUNFORGE_RUN}"
TUNFORGE_COUNTRY_CACHE="${TUNFORGE_VAR}/country-cache"

# Plain-text transcript of the most recent connect attempt. The TUI shows
# this in the success/failure dialog (whiptail --textbox is scrollable).
TUNFORGE_LAST_LOG="${TUNFORGE_RUN}/connect-last.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Everything goes to journald (tag "tunforge") and to stderr. stderr is what the
# TUI captures into the connect transcript and replays in a whiptail textbox,
# which does NOT render ANSI escapes - so colour is emitted only when stderr is
# a real terminal. Set TUNFORGE_NO_COLOR=1 to force plain output anywhere.
#
# The vocabulary is deliberately small, because the point of these logs is to
# answer one question: which step worked and which one did not.
#
#   log_step   ">" a step is starting          (cyan)
#   log_ok     "OK" that step succeeded        (green)
#   log_fail   "FAIL" that step failed         (red)
#   log_warn   "!" degraded but not fatal      (yellow)
#   log_detail "  " supporting line under a step, dim; suppressed unless
#              TUNFORGE_VERBOSE=1, so the normal run stays readable
#   log_section a heading between phases       (bold)
#
# log_info/log_note are kept as aliases so nothing outside this file breaks.

: "${TUNFORGE_VERBOSE:=0}"

_log_color() {
    [[ "${TUNFORGE_NO_COLOR:-0}" == "1" ]] && return 1
    [[ -t 2 ]]
}

# Symbols are emitted unconditionally: whiptail (which replays the connect
# transcript) renders UTF-8 fine, and keeping them identical everywhere means
# the transcript and the purge report read the same way. Only colour is
# conditional.
_log_sym() {
    case "$1" in
        ok)   printf '\xe2\x9c\x85' ;;
        fail) printf '\xe2\x9d\x8c' ;;
        warn) printf '\xe2\x9a\xa0\xef\xb8\x8f' ;;
        step) printf '\xe2\x96\xb8' ;;
        *)    printf ' ' ;;
    esac
}

_log() {
    local level="$1" kind="$2"; shift 2
    local msg="$*"

    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$msg" | systemd-cat -t tunforge -p "$level" 2>/dev/null || true
    fi

    local sym; sym="$(_log_sym "$kind")"
    if _log_color; then
        local c
        case "$kind" in
            ok)      c='\033[32m' ;;
            fail)    c='\033[31m' ;;
            warn)    c='\033[33m' ;;
            step)    c='\033[36m' ;;
            section) c='\033[1;36m' ;;
            *)       c='\033[2m'  ;;
        esac
        case "$kind" in
            section) printf "\n${c}== %s ==\033[0m\n" "$msg" >&2 ;;
            detail)  printf "${c}     %s\033[0m\n" "$msg" >&2 ;;
            *)       printf "${c}%s\033[0m %s\n" "$sym" "$msg" >&2 ;;
        esac
    else
        case "$kind" in
            section) printf '\n== %s ==\n' "$msg" >&2 ;;
            detail)  printf '       %s\n' "$msg" >&2 ;;
            *)       printf '%s %s\n' "$sym" "$msg" >&2 ;;
        esac
    fi
}

log_step()    { _log info    step    "$@"; }
log_ok()      { _log info    ok      "$@"; }
log_fail()    { _log err     fail    "$@"; }
log_warn()    { _log warning warn    "$@"; }
log_section() { _log info    section "$@"; }

# Actionable guidance printed under a failure - the "here is how to fix it"
# block. Always shown (unlike log_detail): if we are telling the user what to
# do next, hiding it behind a verbosity flag defeats the point. Indented and
# unmarked so a six-line remedy doesn't read as six separate failures.
log_hint() {
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t tunforge -p notice 2>/dev/null || true
    fi
    if _log_color; then
        printf '\033[2m     %s\033[0m\n' "$*" >&2
    else
        printf '     %s\n' "$*" >&2
    fi
}

# Show the tail of a VPN daemon's own log after it failed. This is the one
# piece of "verbose" output worth keeping on a failure path: the daemon's last
# words are usually the entire diagnosis, and the alternative is telling the
# user to go find the file themselves.
_tail_log() {
    local f="$1" n="${2:-15}"
    [[ -s "$f" ]] || return 0
    log_hint "last $n lines of $(basename "$f"):"
    local line
    while IFS= read -r line; do
        log_hint "  $line"
    done < <(tail -n "$n" "$f" 2>/dev/null || true)
}

# Supporting noise. Always journalled (so `tunforge logs` keeps the full story)
# but only printed when the user asked for it.
log_detail() {
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t tunforge -p info 2>/dev/null || true
    fi
    [[ "$TUNFORGE_VERBOSE" == "1" ]] || return 0
    _log info detail "$@"
}

# Back-compat aliases.
log_info()  { log_detail "$@"; }
log_note()  { log_detail "$@"; }
log_err()   { log_fail   "$@"; }
die()       { log_fail "$@"; exit 1; }

# Markers for REPORTS (purge, doctor, verify) as opposed to live logs. Reports
# are captured with $(...) and replayed inside a whiptail msgbox, which renders
# UTF-8 but not ANSI - so these carry a symbol and never a colour escape.
TUNFORGE_MARK_OK="\xe2\x9c\x85"
TUNFORGE_MARK_FAIL="\xe2\x9d\x8c"
TUNFORGE_MARK_WARN="\xe2\x9a\xa0\xef\xb8\x8f"
mark_ok()   { printf "${TUNFORGE_MARK_OK} %s\n"   "$*"; }
mark_fail() { printf "${TUNFORGE_MARK_FAIL} %s\n" "$*"; }
mark_warn() { printf "${TUNFORGE_MARK_WARN} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This action requires root. Re-run with: sudo $(basename "${0:-tunforge}") $*"
    fi
}

# ---------------------------------------------------------------------------
# Lock - serialize all state-mutating operations
# ---------------------------------------------------------------------------
# Usage:
#   with_lock cmd args...
# All connect/disconnect operations MUST be wrapped in this so two TUI sessions
# (or a TUI + a systemd unit) cannot stomp on each other.
with_lock() {
    install -d -m 0750 "$TUNFORGE_VAR"
    [[ -e "$TUNFORGE_LOCK_FILE" ]] || : > "$TUNFORGE_LOCK_FILE"
    exec {_lock_fd}<>"$TUNFORGE_LOCK_FILE"
    if ! flock -w 30 -x "$_lock_fd"; then
        die "could not acquire $TUNFORGE_LOCK_FILE within 30s; another tunforge op is running"
    fi
    # Neutralize errexit around "$@" so the cleanup below always runs even if
    # the wrapped command fails. We capture the rc and return it.
    local rc=0
    "$@" || rc=$?
    flock -u "$_lock_fd" 2>/dev/null || true
    exec {_lock_fd}<&-
    return $rc
}

# ---------------------------------------------------------------------------
# Profile loader - parses /etc/tunforge/profiles/<name>.profile
# ---------------------------------------------------------------------------
# Defines globals: P_NAME P_TYPE P_DESC P_CONFIG P_DNS_SERVERS P_DNS_OVER_TLS
#                  P_KILL_SWITCH P_IPV6 P_ENDPOINT_IP P_MTU P_OPENVPN_AUTH_FILE
#                  P_COUNTRY P_SOURCE
#
# All keys are validated; unknown TYPE aborts.
load_profile() {
    local name="$1"
    local file="${TUNFORGE_PROFILES_DIR}/${name}.profile"
    [[ -f "$file" ]] || die "profile not found: $file"

    P_NAME="$name"
    P_TYPE=""
    P_DESC=""
    P_CONFIG=""
    P_DNS_SERVERS=""
    P_DNS_OVER_TLS="opportunistic"
    P_KILL_SWITCH="yes"
    P_IPV6="disable"
    P_ENDPOINT_IP=""
    P_MTU=""
    P_OPENVPN_AUTH_FILE=""
    P_COUNTRY=""
    P_SOURCE=""

    # Parse KEY=VALUE lines safely (no shell expansion of profile content).
    # Comments are only recognized when '#' is the first non-whitespace char of
    # a line, so values may contain '#' (e.g. DESC="Germany #1").
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # trim leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        # full-line comment or empty
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        # trim trailing whitespace
        line="${line%"${line##*[![:space:]]}"}"
        [[ "$line" == *"="* ]] || die "malformed profile line: $line"
        key="${line%%=*}"
        value="${line#*=}"
        # strip ONE pair of surrounding quotes (matched)
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        case "$key" in
            TYPE)          P_TYPE="$value" ;;
            DESC)          P_DESC="$value" ;;
            CONFIG)        P_CONFIG="$value" ;;
            DNS_SERVERS)   P_DNS_SERVERS="$value" ;;
            DNS_OVER_TLS)  P_DNS_OVER_TLS="$value" ;;
            KILL_SWITCH)   P_KILL_SWITCH="$value" ;;
            IPV6)          P_IPV6="$value" ;;
            ENDPOINT_IP)   P_ENDPOINT_IP="$value" ;;
            MTU)           P_MTU="$value" ;;
            OPENVPN_AUTH_FILE|AUTH_FILE) P_OPENVPN_AUTH_FILE="$value" ;;
            COUNTRY|COUNTRY_CODE|LOCATION) P_COUNTRY="$value" ;;
            SOURCE|SUBSCRIPTION) P_SOURCE="$value" ;;
            *)             log_warn "unknown profile key '$key' in $file (ignored)" ;;
        esac
    done < "$file"

    [[ -n "$P_TYPE" ]] || die "profile $name missing TYPE="
    case "$P_TYPE" in
        direct|wireguard|openvpn|singbox) ;;
        *) die "profile $name has invalid TYPE=$P_TYPE (must be direct|wireguard|openvpn|singbox)" ;;
    esac

    if [[ "$P_TYPE" != "direct" ]]; then
        [[ -n "$P_CONFIG" ]] || die "profile $name (type=$P_TYPE) requires CONFIG="
        [[ -f "$P_CONFIG" ]] || die "profile $name CONFIG=$P_CONFIG does not exist"
        [[ -n "$P_DNS_SERVERS" ]] || die "profile $name (type=$P_TYPE) requires DNS_SERVERS="
        # Block Google DNS - it correlates with logged-in account ID and defeats the
        # whole point of this setup.
        for s in $P_DNS_SERVERS; do
            case "$s" in
                8.8.8.8|8.8.4.4|2001:4860:4860:*|2001:4860:4860::*)
                    die "profile $name uses Google DNS ($s) - forbidden, see README" ;;
            esac
        done
    fi
}

list_profiles() {
    [[ -d "$TUNFORGE_PROFILES_DIR" ]] || return 0
    find "$TUNFORGE_PROFILES_DIR" -maxdepth 1 -type f -name '*.profile' -printf '%f\n' \
        | sed 's/\.profile$//' | sort
}

country_cache_get() {
    local profile="$1"
    [[ -r "$TUNFORGE_COUNTRY_CACHE" ]] || return 1
    awk -F'\t' -v p="$profile" '$1 == p && $3 != "" { country=$3 } END { if (country != "") print country; else exit 1 }' \
        "$TUNFORGE_COUNTRY_CACHE"
}

country_cache_set() {
    local profile="$1" country="$2" now
    [[ -n "$profile" && -n "$country" ]] || return 0
    now="$(date +%s)"
    install -d -m 0750 "$TUNFORGE_VAR"
    local tmp; tmp="$(mktemp "${TUNFORGE_COUNTRY_CACHE}.XXXXXX")"
    if [[ -r "$TUNFORGE_COUNTRY_CACHE" ]]; then
        awk -F'\t' -v p="$profile" '$1 != p { print }' "$TUNFORGE_COUNTRY_CACHE" > "$tmp"
    fi
    printf '%s\t%s\t%s\n' "$profile" "$now" "$country" >> "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$TUNFORGE_COUNTRY_CACHE"
}

country_cache_update_for_profile() {
    local profile="$1" iface="${2:-}" country=""
    [[ -n "$profile" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local -a curl_args=( -fsS --max-time 8 )
    [[ -n "$iface" ]] && curl_args+=( --interface "$iface" )
    country="$(curl "${curl_args[@]}" https://whatismyipaddress.com/ 2>/dev/null \
              | tr -d '\r' \
              | tr '\n' ' ' \
              | sed 's/[[:space:]]\+/ /g' \
              | sed -nE 's#.*<[Tt][Hh][^>]*>[[:space:]]*Country[[:space:]]*</[Tt][Hh]>[[:space:]]*<[Tt][Dd][^>]*>[[:space:]]*([^<]+)[[:space:]]*</[Tt][Dd]>.*#\1#p' \
              | sed -n '1{s/&nbsp;/ /g;s/&amp;/\&/g;s/^[[:space:]]*//;s/[[:space:]]*$//;p}' || true)"
    if [[ -z "$country" || "$country" == *"error"* || "$country" == *"Undefined"* || "$country" == *"<"* || "$country" == *">"* ]]; then
        country="$(curl "${curl_args[@]}" https://ifconfig.co/country 2>/dev/null \
                  | tr -d '\r' | sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p}' || true)"
    fi
    if [[ -z "$country" || "$country" == *"error"* || "$country" == *"Undefined"* ]]; then
        country="$(curl "${curl_args[@]}" https://ipapi.co/country_name/ 2>/dev/null \
                  | tr -d '\r' | sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p}' || true)"
    fi
    if [[ -n "$country" && ${#country} -le 64 ]]; then
        country_cache_set "$profile" "$country"
        log_detail "geo: cached country for '$profile' = $country"
    else
        # Cosmetic only - the country is a label in the profile picker, so a
        # failed lookup is not worth a warning on an otherwise good connect.
        log_detail "geo: could not detect country for '$profile'"
    fi
}

# ---------------------------------------------------------------------------
# State helpers (atomic writes via mv; sourced by everything)
# ---------------------------------------------------------------------------
state_get_active() {
    [[ -f "$TUNFORGE_STATE_FILE" ]] || { echo "none"; return; }
    local v
    v="$(<"$TUNFORGE_STATE_FILE")"
    [[ -n "$v" ]] || v="none"
    printf '%s\n' "$v"
}

state_set_active() {
    install -d -m 0750 "$TUNFORGE_VAR"
    local tmp; tmp="$(mktemp "${TUNFORGE_VAR}/.active.XXXXXX")"
    printf '%s\n' "$1" > "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$TUNFORGE_STATE_FILE"
}

state_get_iface() {
    [[ -f "$TUNFORGE_IFACE_FILE" ]] || { echo ""; return; }
    cat "$TUNFORGE_IFACE_FILE"
}

state_set_iface() {
    install -d -m 0750 "$TUNFORGE_VAR"
    local tmp; tmp="$(mktemp "${TUNFORGE_VAR}/.iface.XXXXXX")"
    printf '%s\n' "$1" > "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$TUNFORGE_IFACE_FILE"
}

state_clear() {
    state_set_active "none"
    rm -f "$TUNFORGE_IFACE_FILE"
}

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
# Return the interface that currently routes traffic to the public internet
# (used to whitelist VPN endpoint traffic in the kill-switch).
default_wan_iface() {
    ip -4 route show default 2>/dev/null \
        | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# Next-hop router for the default route. Falls back to the on-link gateway of
# whichever interface carries the default route, so this still answers while a
# tunnel owns the default route (that case has no "via").
default_gateway_ip() {
    local gw
    gw="$(ip -4 route show default 2>/dev/null \
          | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
    if [[ -z "$gw" ]]; then
        local iface; iface="$(default_wan_iface)"
        [[ -n "$iface" ]] && gw="$(ip -4 route show dev "$iface" 2>/dev/null \
            | awk '/default via/ {print $3; exit}')"
    fi
    printf '%s\n' "$gw"
}

# Is plain UDP/53 usable against this server? Distinguishes "the resolver is
# down" from "this network drops UDP", which is the single most useful signal
# when the box has connectivity but no name resolution.
dns_udp53_works() {
    local server="$1" out
    command -v dig >/dev/null 2>&1 || return 1
    out="$(dig +notcp +time="${2:-2}" +tries=1 +short \
           @"$server" "$TUNFORGE_DNS_PROBE_HOST" A 2>/dev/null)" || return 1
    [[ -n "$out" ]]
}

dns_tcp53_works() {
    local server="$1" out
    command -v dig >/dev/null 2>&1 || return 1
    out="$(dig +tcp +time="${2:-3}" +tries=1 +short \
           @"$server" "$TUNFORGE_DNS_PROBE_HOST" A 2>/dev/null)" || return 1
    [[ -n "$out" ]]
}

# Bootstrap DNS resolver that bypasses /etc/resolv.conf. The whole point of
# this VPN is to be used in networks where the ISP resolver lies about
# provider hostnames; using getent / NSS at this stage walks straight into
# that trap (NXDOMAIN or 20-second timeout). Instead we query trusted public
# resolvers directly over UDP/53, with a TCP fallback for DPI environments
# that drop UDP/53 to non-ISP servers. Override the server list via
# TUNFORGE_BOOTSTRAP_DNS="ip ip ip" if needed.
# Single dig query against one server. Writes the resolved IPv4s into the
# variable named by $4 (one per line), and a short status label into the
# variable named by $5: ok / nxdomain / timeout / refused / servfail /
# noanswer / err. We deliberately call dig with +noall +answer +comments
# +stats so we can distinguish "host doesn't exist" (NXDOMAIN) from "server
# didn't answer in time" (timeout) from "server hates us" (REFUSED) - the
# user needs that distinction in the failure modal to know what to do.
_dig_query() {
    local host="$1" server="$2" proto="$3" out_ips="$4" out_status="$5"
    # Increased timeout (5s) and tries (2) because your network is heavily
    # filtering outbound DNS. This gives each query more time to succeed
    # before we mark it as timeout.
    local args=( +time=5 +tries=2 +noall +answer +comments +stats )
    [[ "$proto" == "tcp" ]] && args+=( +tcp )
    local raw rc status="err" ips=""
    raw="$(dig "${args[@]}" A "$host" "@$server" 2>&1)"
    rc=$?
    if (( rc == 0 )); then
        if   [[ "$raw" == *"status: NXDOMAIN"* ]]; then status="nxdomain"
        elif [[ "$raw" == *"status: SERVFAIL"* ]]; then status="servfail"
        elif [[ "$raw" == *"status: REFUSED"*  ]]; then status="refused"
        elif [[ "$raw" == *"status: NOERROR"*  ]]; then status="noanswer"
        fi
    elif (( rc == 9 )); then
        status="timeout"
    fi
    ips="$(printf '%s\n' "$raw" \
           | awk '/^[^;].*[ \t]+IN[ \t]+A[ \t]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/{print $NF}' \
           | sort -u)"
    [[ -n "$ips" ]] && status="ok"
    printf -v "$out_ips"    '%s' "$ips"
    printf -v "$out_status" '%s' "$status"
}

# ---------------------------------------------------------------------------
# "Direct DNS" allow-list (regex only, NO IPs) - opt-in list of host
# patterns that MUST be resolved via direct public DNS (8.8.8.8 / 1.1.1.1
# / etc.) and never via the system NSS resolver. Use this for VPN
# provider domains your ISP poisons: NSS would silently return a wrong
# IP and the connection would fail in a confusing way. With the host
# matched here, tunforge refuses to use NSS - either public DNS works,
# or the connect fails loudly with a clear DNS error.
# ---------------------------------------------------------------------------

# Iterate the dns-direct file, yielding one regex pattern per line.
# Skips blanks and comments. Returns 0 lines == "no file".
_dns_direct_iter() {
    [[ -r "$TUNFORGE_DNS_DIRECT" ]] || return 0
    local _line _trim
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"
        [[ -z "$_trim" ]] && continue
        [[ "$_trim" == \#* || "$_trim" == \;* ]] && continue
        printf '%s\n' "$_trim"
    done < "$TUNFORGE_DNS_DIRECT"
}

# Return 0 if any pattern in the file matches $1 (case-insensitive),
# 1 otherwise. Silent - no output.
dns_direct_match() {
    local host="$1"
    [[ -n "$host" ]] || return 1
    [[ -r "$TUNFORGE_DNS_DIRECT" ]] || return 1
    local re _h_lc _re_lc
    _h_lc="${host,,}"
    while IFS= read -r re; do
        _re_lc="${re,,}"
        if [[ "$_h_lc" =~ $_re_lc ]]; then
            return 0
        fi
    done < <(_dns_direct_iter)
    return 1
}

# Add a regex pattern to the dns-direct file. Idempotent: adding the same
# pattern again is a no-op (no duplicate row).
dns_direct_add() {
    local re="$1"
    [[ -n "$re" ]] || die "dns_direct_add: regex required"
    # Validate the regex via grep -E. rc=1 means "valid, no match",
    # rc>=2 means "compile error" (with stderr explaining).
    local _grep_err _grep_rc=0
    _grep_err="$(printf '' | grep -E -- "$re" 2>&1 1>/dev/null)" || _grep_rc=$?
    if (( _grep_rc >= 2 )); then
        die "dns_direct_add: invalid regex '$re'${_grep_err:+ ($_grep_err)}"
    fi
    install -d -m 0750 "$(dirname "$TUNFORGE_DNS_DIRECT")"
    if [[ ! -e "$TUNFORGE_DNS_DIRECT" ]]; then
        {
            printf '# tunforge DNS direct-only allow-list\n'
            printf '# One bash extended regex per line. Hosts matching ANY pattern\n'
            printf '# below are resolved exclusively via direct public DNS (8.8.8.8,\n'
            printf '# 1.1.1.1, ...) and never via the system NSS resolver. Use this\n'
            printf '# for VPN provider domains that your ISP DNS poisons.\n'
            printf '#\n'
            printf '# Edited via:  tunforge dns-direct add <regex>\n'
            printf '#              tunforge dns-direct remove <regex>\n'
            printf '#\n'
            printf '# Matching is case-insensitive. Lines starting with `#` or `;`\n'
            printf '# are ignored.\n'
            printf '#\n'
            printf '# Examples:\n'
            printf '#   ^my\\.vpn\\.example\\.com$\n'
            printf '#   .*\\.censored-vpn\\.io$\n'
            printf '#   ^v[0-9]+\\.provider\\.net$\n\n'
        } > "$TUNFORGE_DNS_DIRECT"
        chmod 0640 "$TUNFORGE_DNS_DIRECT"
    fi
    # Replace-on-conflict (exact-match dedup).
    local tmp; tmp="$(mktemp "${TUNFORGE_DNS_DIRECT}.XXXXXX")"
    local _line _trim
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"
        if [[ -z "$_trim" || "$_trim" == \#* || "$_trim" == \;* ]]; then
            printf '%s\n' "$_line" >> "$tmp"
            continue
        fi
        if [[ "$_trim" != "$re" ]]; then
            printf '%s\n' "$_line" >> "$tmp"
        fi
    done < "$TUNFORGE_DNS_DIRECT"
    mv -f "$tmp" "$TUNFORGE_DNS_DIRECT"
    chmod 0640 "$TUNFORGE_DNS_DIRECT"
    printf '%s\n' "$re" >> "$TUNFORGE_DNS_DIRECT"
    log_info "dns-direct: added '$re'"
}

# Remove every entry whose regex matches $1 exactly. Prints the count of
# removed entries on stdout (rc=0 even if zero).
dns_direct_remove() {
    local re="$1"
    [[ -n "$re" ]] || die "dns_direct_remove: regex required"
    if [[ ! -e "$TUNFORGE_DNS_DIRECT" ]]; then
        printf '0\n'; return 0
    fi
    local tmp; tmp="$(mktemp "${TUNFORGE_DNS_DIRECT}.XXXXXX")"
    local removed=0 _line _trim
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"
        if [[ -z "$_trim" || "$_trim" == \#* || "$_trim" == \;* ]]; then
            printf '%s\n' "$_line" >> "$tmp"
            continue
        fi
        if [[ "$_trim" == "$re" ]]; then
            ((++removed))
        else
            printf '%s\n' "$_line" >> "$tmp"
        fi
    done < "$TUNFORGE_DNS_DIRECT"
    mv -f "$tmp" "$TUNFORGE_DNS_DIRECT"
    chmod 0640 "$TUNFORGE_DNS_DIRECT"
    log_info "dns-direct: removed $removed entry(ies) matching '$re'"
    printf '%s\n' "$removed"
}

# Pretty-print the direct file (skipping comments/blanks).
dns_direct_list() {
    if [[ ! -e "$TUNFORGE_DNS_DIRECT" ]]; then
        printf '(empty - %s does not exist)\n' "$TUNFORGE_DNS_DIRECT"
        return 0
    fi
    local n=0 re
    while IFS= read -r re; do
        printf '  %s\n' "$re"
        ((++n))
    done < <(_dns_direct_iter)
    if (( n == 0 )); then
        printf '(no entries in %s)\n' "$TUNFORGE_DNS_DIRECT"
    else
        printf '(%d entr%s)\n' "$n" "$([[ $n -eq 1 ]] && echo 'y' || echo 'ies')"
    fi
}

# ---------------------------------------------------------------------------
# Local bypass list (CIDRs + DNS domains)
# ---------------------------------------------------------------------------

_bypass_defaults_iter() {
    [[ "${TUNFORGE_BYPASS_DEFAULTS:-1}" == "1" ]] || return 0
    printf 'cidr 10.0.0.0/8\n'
    printf 'cidr 172.16.0.0/12\n'
    printf 'cidr 192.168.0.0/16\n'
    printf 'cidr 169.254.0.0/16\n'
}

_bypass_iter_raw() {
    _bypass_defaults_iter
    [[ -r "$TUNFORGE_BYPASS_FILE" ]] || return 0
    local _line _trim _kind _value
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"
        [[ -z "$_trim" ]] && continue
        [[ "$_trim" == \#* || "$_trim" == \;* ]] && continue
        _kind="${_trim%%[[:space:]]*}"
        _value="${_trim#$_kind}"
        _value="${_value#"${_value%%[![:space:]]*}"}"
        case "${_kind,,}" in
            cidr|ip|network)
                [[ -n "$_value" ]] && printf 'cidr %s\n' "$_value"
                ;;
            domain|host|dns)
                [[ -n "$_value" ]] && printf 'domain %s\n' "$_value"
                ;;
            *)
                # Backward-friendly shorthand: a bare CIDR/IP or a bare domain.
                if [[ "$_trim" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                    printf 'cidr %s\n' "$_trim"
                elif [[ "$_trim" == *.* ]]; then
                    printf 'domain %s\n' "$_trim"
                else
                    log_warn "bypass: ignoring malformed line in $TUNFORGE_BYPASS_FILE: $_line"
                fi
                ;;
        esac
    done < "$TUNFORGE_BYPASS_FILE"
}

_bypass_normalize_cidr() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    local ip prefix="" a b c d octet
    ip="${value%%/*}"
    [[ "$value" == */* ]] && prefix="${value##*/}"
    IFS=. read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s/32\n' "$value"
    elif [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ && "$prefix" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        return 1
    fi
}

_bypass_normalize_domain() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    # Accept full dev URLs and extract the host part.
    value="${value#*://}"
    value="${value%%/*}"
    value="${value%%\?*}"
    value="${value%%#*}"
    value="${value##*@}"
    value="${value%%:*}"
    value="${value#.}"
    value="${value%.}"
    [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "${value,,}"
}

bypass_cidrs_iter() {
    local kind value cidr
    while read -r kind value; do
        [[ "$kind" == "cidr" ]] || continue
        if cidr="$(_bypass_normalize_cidr "$value")"; then
            printf '%s\n' "$cidr"
        else
            log_warn "bypass: ignoring invalid IPv4 CIDR '$value'"
        fi
    done < <(_bypass_iter_raw) | awk '!seen[$0]++'
}

bypass_domains_iter() {
    local kind value domain
    while read -r kind value; do
        [[ "$kind" == "domain" ]] || continue
        if domain="$(_bypass_normalize_domain "$value")"; then
            printf '%s\n' "$domain"
        else
            log_warn "bypass: ignoring invalid domain '$value'"
        fi
    done < <(_bypass_iter_raw) | awk '!seen[$0]++'
}

_bypass_ensure_file() {
    install -d -m 0750 "$(dirname "$TUNFORGE_BYPASS_FILE")"
    if [[ ! -e "$TUNFORGE_BYPASS_FILE" ]]; then
        {
            printf '# tunforge local bypass list\n'
            printf '# CIDRs/IPs are allowed outside the VPN while connected.\n'
            printf '# Domains are routed to the WAN link DNS via systemd-resolved.\n'
            printf '#\n'
            printf '# Examples:\n'
            printf '#   cidr 172.17.0.0/16      # Docker bridge\n'
            printf '#   cidr 192.168.1.50/32    # LAN dev server\n'
            printf '#   domain backend.local\n'
            printf '#   domain mongo.dev\n'
            printf '#\n'
            printf '# Built-in CIDR defaults are active unless TUNFORGE_BYPASS_DEFAULTS=0:\n'
            printf '#   127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16\n\n'
        } > "$TUNFORGE_BYPASS_FILE"
        chmod 0640 "$TUNFORGE_BYPASS_FILE"
    fi
}

bypass_add_cidr() {
    local cidr
    cidr="$(_bypass_normalize_cidr "$1")" || die "bypass: invalid IPv4 CIDR/IP '$1'"
    _bypass_ensure_file
    bypass_remove_entry "cidr" "$cidr" >/dev/null || true
    printf 'cidr %s\n' "$cidr" >> "$TUNFORGE_BYPASS_FILE"
    log_info "bypass: added CIDR $cidr"
}

bypass_add_domain() {
    local domain
    domain="$(_bypass_normalize_domain "$1")" || die "bypass: invalid domain/URL '$1'"
    _bypass_ensure_file
    bypass_remove_entry "domain" "$domain" >/dev/null || true
    printf 'domain %s\n' "$domain" >> "$TUNFORGE_BYPASS_FILE"
    log_info "bypass: added domain $domain"
}

bypass_remove_entry() {
    local kind="$1" value="$2" removed=0
    [[ -e "$TUNFORGE_BYPASS_FILE" ]] || { printf '0\n'; return 0; }
    local tmp; tmp="$(mktemp "${TUNFORGE_BYPASS_FILE}.XXXXXX")"
    local line trim cur_kind cur_value norm=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        trim="${line#"${line%%[![:space:]]*}"}"
        trim="${trim%"${trim##*[![:space:]]}"}"
        if [[ -z "$trim" || "$trim" == \#* || "$trim" == \;* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        cur_kind="${trim%%[[:space:]]*}"
        cur_value="${trim#$cur_kind}"
        cur_value="${cur_value#"${cur_value%%[![:space:]]*}"}"
        norm=""
        case "${cur_kind,,}" in
            cidr|ip|network) [[ "$kind" == "cidr" ]] && norm="$(_bypass_normalize_cidr "$cur_value" 2>/dev/null || true)" ;;
            domain|host|dns) [[ "$kind" == "domain" ]] && norm="$(_bypass_normalize_domain "$cur_value" 2>/dev/null || true)" ;;
        esac
        if [[ -n "$norm" && "$norm" == "$value" ]]; then
            ((++removed))
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$TUNFORGE_BYPASS_FILE"
    mv -f "$tmp" "$TUNFORGE_BYPASS_FILE"
    chmod 0640 "$TUNFORGE_BYPASS_FILE"
    printf '%s\n' "$removed"
}

bypass_list() {
    printf 'CIDRs/IPs (traffic may leave outside VPN):\n'
    local n=0 value
    while IFS= read -r value; do
        printf '  %s\n' "$value"; ((++n))
    done < <(bypass_cidrs_iter)
    (( n > 0 )) || printf '  (none)\n'

    printf '\nDomains (DNS routed to WAN link):\n'
    n=0
    while IFS= read -r value; do
        printf '  %s\n' "$value"; ((++n))
    done < <(bypass_domains_iter)
    (( n > 0 )) || printf '  (none)\n'
}

bypass_apply_routes() {
    local cidr
    while IFS= read -r cidr; do
        [[ -n "$cidr" ]] || continue
        ip -4 rule add pref 50 to "$cidr" lookup main 2>/dev/null || true
    done < <(bypass_cidrs_iter)
}

bypass_clear_routes() {
    local cidr
    while IFS= read -r cidr; do
        while ip -4 rule del pref 50 to "$cidr" lookup main 2>/dev/null; do :; done
    done < <(bypass_cidrs_iter)
}

# Bootstrap resolver. Queries trusted public resolvers directly (UDP, then
# TCP fallback) and logs every attempt to log_info so the failure transcript
# in the TUI tells the user exactly what was tried and how each resolver
# responded. This is the diagnostic the user needs in a censored network.
bootstrap_resolve_ipv4() {
    local host="$1"
    if ! command -v dig >/dev/null 2>&1; then
        log_warn "dns: dig not installed - bootstrap resolver disabled (apt-get install dnsutils)"
        return 1
    fi
    local -a servers
    if [[ -n "${TUNFORGE_BOOTSTRAP_DNS:-}" ]]; then
        # shellcheck disable=SC2206
        servers=( ${TUNFORGE_BOOTSTRAP_DNS} )
    else
        # Shekan (178.22.122.100) and Electro (185.51.200.2) first - these
        # are the two Iranian public DNS servers that work reliably in your
        # censored network. Then the global ones as fallback. Increased
        # timeout and tries because outbound DNS is heavily filtered.
        servers=( 178.22.122.100 185.51.200.2 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 208.67.222.222 4.2.2.1 4.2.2.2 )
    fi
    log_info "dns: bootstrap resolving $host via ${servers[*]}"
    local proto s _ips _status
    for proto in udp tcp; do
        for s in "${servers[@]}"; do
            _dig_query "$host" "$s" "$proto" _ips _status
            case "$_status" in
                ok)
                    log_info "dns:   $host @$s/$proto -> $(printf '%s' "$_ips" | tr '\n' ' ')"
                    printf '%s\n' "$_ips"
                    return 0
                    ;;
                nxdomain)
                    # Authoritative "this name does not exist" - no point
                    # asking the other resolvers, they'll all say the same.
                    log_detail "dns:   $host @$s/$proto -> NXDOMAIN (host does not exist)"
                    return 1
                    ;;
                *)
                    log_detail "dns:   $host @$s/$proto -> $_status"
                    ;;
            esac
        done
    done
    log_detail "dns: every public resolver failed for $host"
    return 1
}

# Resolve a hostname (or pass through an IP) for a VPN endpoint. Tries the
# bootstrap resolver first (trusted public DNS direct), falls back to NSS
# only when bootstrap is unavailable (e.g. dig not installed) - NSS is what
# fails in censored networks.
# NSS resolve with explicit retry/backoff. libc's getaddrinfo (which
# `getent` calls) does NOT retry on EAI_AGAIN / transient SERVFAIL the
# way `wg-quick`'s internal resolver does ("Trying again in 1.00
# seconds..."), so we wrap it in our own loop. Eight attempts with
# exponential backoff; each call gets 5s of wall-time before being
# killed. Worst case ~35s, best case ~50ms. Controlled by
# TUNFORGE_NSS_TRIES (default 8).
_nss_resolve_with_retry() {
    local host="$1"
    local max_tries="${TUNFORGE_NSS_TRIES:-5}"
    local i nss waits=( 0 1 2 4 6 8 12 16 )
    for ((i=0; i<max_tries; i++)); do
        if (( ${waits[i]:-0} > 0 )); then sleep "${waits[i]}"; fi
        nss="$(timeout 5 getent ahostsv4 "$host" 2>/dev/null \
               | awk '{print $1}' | sort -u)"
        if [[ -n "$nss" ]]; then
            log_info "dns: NSS resolved $host -> $(printf '%s' "$nss" | tr '\n' ' ') (attempt $((i+1))/$max_tries)"
            printf '%s\n' "$nss"
            return 0
        fi
        log_detail "dns: NSS getent attempt $((i+1))/$max_tries returned nothing for $host"
    done
    return 1
}

resolve_endpoint_ipv4() {
    local host="$1"
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    local out

    # DNS result cache (populated on successful resolution). This is the
    # primary win for repeated connects to the same server - we avoid the
    # full NSS + bootstrap timeout dance once a good IP has been seen.
    if out="$(dns_cache_get "$host")" && [[ -n "$out" ]]; then
        log_info "dns: cache hit for $host -> $out"
        printf '%s\n' "$out"
        return 0
    fi

    # Hosts on the user's `dns-direct` allow-list bypass the system
    # resolver entirely - we go DIRECTLY to public DNS over UDP/TCP and
    # if every server times out (network is blocking outbound DNS), we
    # fail LOUDLY rather than silently using a possibly-poisoned NSS
    # answer. This is the security path: opt-in, explicit.
    if dns_direct_match "$host"; then
        log_info "dns: '$host' is on dns-direct list - public DNS only (no NSS fallback)"
        if out="$(bootstrap_resolve_ipv4 "$host")" && [[ -n "$out" ]]; then
            dns_cache_set "$host" "$out"
            printf '%s\n' "$out"
            return 0
        fi
        log_warn "'$host' is on the dns-direct list and public DNS failed"
        log_hint "Not falling back to the system resolver - it would return a poisoned IP."
        return 1
    fi

    # Default path: NSS first (fast - libc cache hits in ~ms; and in
    # most networks systemd-resolved -> upstream returns the right IP).
    # Add retry/backoff like wg-quick does so a one-off systemd-resolved
    # hiccup ("Trying again in 1.00 seconds...") doesn't kill the
    # connect.
    if command -v getent >/dev/null 2>&1; then
        if out="$(_nss_resolve_with_retry "$host")" && [[ -n "$out" ]]; then
            dns_cache_set "$host" "$out"
            printf '%s\n' "$out"
            return 0
        fi
    fi

    # NSS failed too - either no resolver configured at all (rare on
    # systems with systemd-resolved active), or systemd-resolved itself
    # gave up. Fall back to direct public DNS as a last resort. This
    # also catches the censored-network case where the ISP DNS lies
    # but UDP/53 to 8.8.8.8 still works.
    log_info "dns: NSS path failed for $host - trying direct public DNS as fallback"
    if out="$(bootstrap_resolve_ipv4 "$host")" && [[ -n "$out" ]]; then
        dns_cache_set "$host" "$out"
        printf '%s\n' "$out"
        return 0
    fi
    # Deliberately quiet: the caller (a connector) reports this with the
    # profile name and the fix options attached. Two copies of the same news
    # is what made the old transcript unreadable.
    log_detail "dns: every resolver (NSS + public) failed for $host"
    return 1
}

# ---------------------------------------------------------------------------
# Profile endpoint probe ("ping a server before connecting")
# ---------------------------------------------------------------------------
# Used by `tunforge test` and the TUI's connect picker so the user can see
# which servers are alive (and how fast) before actually connecting. Each
# probe uses ICMP first - it's the only protocol-agnostic measure that
# also works for WireGuard (UDP-only, so TCP-connect would always fail).
# If ICMP is blocked, we fall back to TCP-connect for TCP-based services.
# ---------------------------------------------------------------------------

TUNFORGE_TEST_CACHE="${TUNFORGE_VAR}/test-cache"
TUNFORGE_DNS_CACHE="${TUNFORGE_VAR}/dns-cache"

# Extract the connect target for a profile. Emits a single line:
#   "<ip> <port> <proto>"
# where proto is "tcp" or "udp". Returns 1 (no output) for `direct`
# profiles or anything we can't parse out cleanly. Resolves the host
# to an IP via the same path we use at connect time so the cached
# value is consistent with what the actual connect will see.
_profile_endpoint() {
    local name="$1"
    local pfile="${TUNFORGE_PROFILES_DIR}/${name}.profile"
    [[ -f "$pfile" ]] || return 1
    local host="" port="" proto="udp" config="" type="" ep_ip=""

    # Cheap profile parse: avoid load_profile because it mutates global P_*
    # vars that the caller may still need.
    type="$(awk -F= '/^[[:space:]]*TYPE[[:space:]]*=/    {sub(/^[[:space:]]*TYPE[[:space:]]*=/,"");gsub(/"/,"");gsub(/[[:space:]]/,"");print;exit}'    "$pfile" 2>/dev/null)"
    config="$(awk -F= '/^[[:space:]]*CONFIG[[:space:]]*=/  {sub(/^[[:space:]]*CONFIG[[:space:]]*=/,"");gsub(/"/,"");gsub(/^[[:space:]]+|[[:space:]]+$/,"");print;exit}' "$pfile" 2>/dev/null)"
    ep_ip="$(awk -F= '/^[[:space:]]*ENDPOINT_IP[[:space:]]*=/{sub(/^[[:space:]]*ENDPOINT_IP[[:space:]]*=/,"");gsub(/"/,"");gsub(/[[:space:]]/,"");print;exit}' "$pfile" 2>/dev/null)"

    case "$type" in
        wireguard)
            proto="udp"
            [[ -f "$config" ]] || return 1
            local ep
            ep="$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/ {v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit}' "$config" 2>/dev/null)"
            host="${ep%:*}"
            port="${ep##*:}"
            ;;
        openvpn)
            [[ -f "$config" ]] || return 1
            local rline
            rline="$(awk '$1=="remote"{print $2,$3; exit}' "$config" 2>/dev/null)"
            host="${rline%% *}"
            port="${rline##* }"
            [[ -z "$port" || "$port" == "$host" ]] && port=1194
            local pproto
            pproto="$(awk '$1=="proto"{print $2; exit}' "$config" 2>/dev/null)"
            case "$pproto" in
                tcp*|tcp-client|tcp-server) proto="tcp" ;;
                udp*|"")                    proto="udp" ;;
            esac
            ;;
        singbox)
            [[ -f "$config" ]] || return 1
            command -v jq >/dev/null 2>&1 || return 1
            # First non-direct/non-block/non-dns outbound that actually
            # has a server field is the upstream proxy.
            local sb
            sb="$(jq -r '
                (
                  [.outbounds[]?
                   | select(((.type // "") | IN("direct","block","dns")) | not)
                   | select(.server // null)]
                  + [.endpoints[]?
                     | select((.type // "") == "wireguard")
                     | {server: .peers[0].address, server_port: .peers[0].port, type: "wireguard"}]
                | first) as $o
                | if $o == null then ""
                  else "\($o.server // "") \($o.server_port // "") \($o.type // "")"
                  end
            ' "$config" 2>/dev/null)"
            host="${sb%% *}"
            local rest="${sb#* }"
            port="${rest%% *}"
            local sbtype="${rest##* }"
            # vless / vmess / trojan / ss are all TCP by default; hysteria
            # / tuic are UDP. Use TCP as the safe default - even UDP-based
            # protocols typically also expose the same port over TCP for
            # control-plane connectivity tests.
            case "$sbtype" in
                hysteria*|tuic|wireguard) proto="udp" ;;
                *)                        proto="tcp" ;;
            esac
            ;;
        direct|"")
            return 1
            ;;
    esac

    [[ -n "$host" && "$host" != "null" ]] || return 1
    [[ -n "$port" && "$port" != "null" ]] || return 1

    # Resolve host -> IP. Prefer ENDPOINT_IP from the profile (already
    # resolved + pinned) to avoid a per-test DNS query. Otherwise use
    # the standard resolver path.
    local ip
    if [[ -n "$ep_ip" ]]; then
        ip="$ep_ip"
    elif [[ "$host" =~ ^[0-9.]+$ ]]; then
        ip="$host"
    else
        ip="$(resolve_endpoint_ipv4 "$host" 2>/dev/null | head -n1)"
    fi
    [[ -n "$ip" ]] || return 1

    printf '%s %s %s\n' "$ip" "$port" "$proto"
}

# Probe a single profile. Outputs one of:
#   <integer-ms>     (alive - rtt in milliseconds)
#   DOWN             (no response within timeout)
#   DNS              (could not resolve endpoint)
#   N/A              (profile has no probable endpoint - e.g. direct)
# rc=0 only when the result is a numeric ms; rc=1 otherwise.
_test_one() {
    local name="$1"
    local ep
    ep="$(_profile_endpoint "$name" 2>/dev/null)" || {
        # Distinguish "no endpoint at all" (direct) from "had an endpoint
        # but couldn't resolve it" - use the existence of CONFIG to tell.
        local pfile="${TUNFORGE_PROFILES_DIR}/${name}.profile"
        local type
        type="$(awk -F= '/^[[:space:]]*TYPE[[:space:]]*=/{sub(/^[[:space:]]*TYPE[[:space:]]*=/,"");gsub(/"/,"");gsub(/[[:space:]]/,"");print;exit}' "$pfile" 2>/dev/null)"
        if [[ "$type" == "direct" || -z "$type" ]]; then
            printf 'N/A\n'
        else
            printf 'DNS\n'
        fi
        return 1
    }
    local ip port proto
    read -r ip port proto <<<"$ep"

    local rtt=""
    # Pass 1 - ICMP ping. Single probe, 2s deadline. ping on modern
    # Linux uses cap_net_raw=ep so it works for non-root users too.
    if command -v ping >/dev/null 2>&1; then
        rtt="$(timeout 3 ping -n -c 1 -W 2 "$ip" 2>/dev/null \
               | awk -F'time=' '/time=/{split($2,a," "); print a[1]; exit}')"
        if [[ -n "$rtt" ]]; then
            # Round to integer ms.
            printf '%d\n' "${rtt%.*}"
            return 0
        fi
    fi

    # Pass 2 - TCP-connect (only useful for TCP-protocol services).
    # Times the connect handshake using bash's EPOCHREALTIME (bash 5+).
    if [[ "$proto" == "tcp" && -n "$port" ]]; then
        local t0 t1
        t0="${EPOCHREALTIME:-$(date +%s.%N)}"
        if timeout 3 bash -c "exec 3<>/dev/tcp/${ip}/${port}; exec 3<&-; exec 3>&-" 2>/dev/null; then
            t1="${EPOCHREALTIME:-$(date +%s.%N)}"
            awk -v a="$t0" -v b="$t1" 'BEGIN{ x=(b-a)*1000; if(x<0)x=0; printf "%d\n", x }'
            return 0
        fi
    fi

    printf 'DOWN\n'
    return 1
}

# Probe every profile in parallel and rewrite the cache atomically.
# Concurrency is capped at TUNFORGE_TEST_PARALLEL (default 8) so the box
# isn't flooded by `ping` invocations on a 50-profile setup.
core_test_all() {
    install -d -m 0750 "$TUNFORGE_VAR"
    local cache="$TUNFORGE_TEST_CACHE"
    local tmp; tmp="$(mktemp "${cache}.XXXXXX")"
    local now; now="$(date +%s)"

    local -a names
    readarray -t names < <(list_profiles)
    if (( ${#names[@]} == 0 )); then
        rm -f "$tmp"
        : > "$cache"
        chmod 0644 "$cache" 2>/dev/null || true
        return 0
    fi

    log_info "test: probing ${#names[@]} profile(s) in parallel"
    local max_par="${TUNFORGE_TEST_PARALLEL:-8}"
    local n
    for n in "${names[@]}"; do
        # Cap concurrency.
        while (( $(jobs -rp 2>/dev/null | wc -l) >= max_par )); do
            wait -n 2>/dev/null || sleep 0.05
        done
        (
            local r
            r="$(_test_one "$n" 2>/dev/null)" || true
            [[ -z "$r" ]] && r="DOWN"
            printf '%s\t%s\t%s\n' "$n" "$r" "$now"
        ) >> "$tmp" &
    done
    wait

    mv -f "$tmp" "$cache"
    chmod 0644 "$cache" 2>/dev/null || true
    log_info "test: probe complete -> $cache"
}

# Read the cached probe result for ONE profile. Output is the raw value
# from the cache (integer ms, or "DOWN"/"DNS"/"N/A"). Honors a TTL: if
# the entry is older than $TUNFORGE_TEST_TTL seconds (default 300), it's
# treated as missing and rc=1 is returned. rc=0 only when a fresh value
# is printed.
core_test_get_cached() {
    local name="$1"
    local ttl="${TUNFORGE_TEST_TTL:-300}"
    [[ -r "$TUNFORGE_TEST_CACHE" ]] || return 1
    local now; now="$(date +%s)"
    local n r ts
    while IFS=$'\t' read -r n r ts; do
        if [[ "$n" == "$name" ]]; then
            [[ "$ts" =~ ^[0-9]+$ ]] || return 1
            local age=$(( now - ts ))
            (( age <= ttl )) || return 1
            printf '%s\n' "$r"
            return 0
        fi
    done < "$TUNFORGE_TEST_CACHE"
    return 1
}

# ---------------------------------------------------------------------------
# Simple persistent DNS result cache (host → ip with TTL)
# ---------------------------------------------------------------------------
# This dramatically reduces repeated timeout loops for domains that have
# resolved successfully at least once. Failures are NOT cached so we keep
# trying when the network situation changes.
# Controlled by TUNFORGE_DNS_CACHE_TTL (default 86400s = 24 hours).
# ---------------------------------------------------------------------------

dns_cache_get() {
    local host="$1"
    [[ -r "$TUNFORGE_DNS_CACHE" ]] || return 1
    local now; now="$(date +%s)"
    local h ip ts
    while IFS=$'\t' read -r h ip ts; do
        if [[ "$h" == "$host" ]]; then
            [[ "$ts" =~ ^[0-9]+$ ]] || return 1
            (( now <= ts )) || return 1
            printf '%s\n' "$ip"
            return 0
        fi
    done < "$TUNFORGE_DNS_CACHE"
    return 1
}

dns_cache_set() {
    local host="$1" ip="$2"
    [[ -n "$host" && -n "$ip" ]] || return 1
    install -d -m 0750 "$TUNFORGE_VAR"
    local cache="$TUNFORGE_DNS_CACHE"
    local tmp; tmp="$(mktemp "${cache}.XXXXXX")"
    local now; now="$(date +%s)"
    local ttl="${TUNFORGE_DNS_CACHE_TTL:-86400}"  # default 24h for known-good IPs
    local expiration=$(( now + ttl ))

    # Copy existing entries for other hosts, replace this one if present.
    if [[ -r "$cache" ]]; then
        awk -v h="$host" -v i="$ip" -v ts="$expiration" '
            $1 != h { print }
            END { printf "%s\t%s\t%s\n", h, i, ts }
        ' "$cache" > "$tmp"
    else
        printf '%s\t%s\t%s\n' "$host" "$ip" "$expiration" > "$tmp"
    fi
    mv -f "$tmp" "$cache"
    chmod 0644 "$cache" 2>/dev/null || true
}

# Clear the entire DNS cache. Used by `tunforge dns-cache clear`.
dns_cache_clear() {
    rm -f "$TUNFORGE_DNS_CACHE" 2>/dev/null || true
    log_info "dns-cache: cleared"
}

# Refresh all currently cached hosts. Useful as a background job or after
# network changes. Only successful resolutions update the cache (failures
# are left alone so we keep trying).
dns_cache_refresh() {
    [[ -r "$TUNFORGE_DNS_CACHE" ]] || {
        log_info "dns-cache: nothing to refresh"
        return 0
    }
    log_info "dns-cache: refreshing all known hosts"
    local h ip ts count=0
    while IFS=$'\t' read -r h ip ts; do
        local fresh
        if fresh="$(resolve_endpoint_ipv4 "$h" 2>/dev/null)" && [[ -n "$fresh" ]]; then
            dns_cache_set "$h" "$fresh"
            ((count++))
            log_info "dns-cache: refreshed $h -> $fresh"
        fi
    done < "$TUNFORGE_DNS_CACHE"
    log_info "dns-cache: refreshed $count entries"
}

# Numeric sort key for a profile's cached rtt. Returns 0000-9998 for
# alive (left-padded so string sort == numeric sort), 9999 for missing
# / DOWN / DNS / N/A. Used by _tui_connect to order entries within a
# type bucket.
_test_sort_key() {
    local name="$1" r
    if r="$(core_test_get_cached "$name" 2>/dev/null)" \
       && [[ "$r" =~ ^[0-9]+$ ]]; then
        # Cap at 9998 so DOWN (9999) always sorts last even if a rtt
        # somehow exceeds 9998 ms.
        if (( r > 9998 )); then printf '9998\n'; else printf '%04d\n' "$r"; fi
    else
        printf '9999\n'
    fi
}

# Render the rtt cell for the picker. Always 6 chars wide so columns line
# up. Examples:  "  12ms"   " 240ms"   " DOWN "   "  DNS "   "  N/A "   "   ?  "
_test_format_cell() {
    local name="$1" r
    if r="$(core_test_get_cached "$name" 2>/dev/null)"; then
        case "$r" in
            DOWN) printf ' DOWN ' ;;
            DNS)  printf '  DNS ' ;;
            N/A)  printf '  N/A ' ;;
            *)    if [[ "$r" =~ ^[0-9]+$ ]]; then
                      printf '%4dms' "$r"
                  else
                      printf '   ?  '
                  fi ;;
        esac
    else
        printf '   ?  '
    fi
}

# ---------------------------------------------------------------------------
# Dispatcher - called by bin/tunforge
# ---------------------------------------------------------------------------
# core_connect <profile-name> -> tears down current, brings up new under flock.
# core_disconnect             -> goes back to "direct" (no VPN, no kill switch).
# core_status                 -> human-readable status snapshot.

# Connector script paths
_connector_for() {
    case "$1" in
        direct)    printf '%s\n' "${TUNFORGE_LIB}/connectors/direct.sh" ;;
        wireguard) printf '%s\n' "${TUNFORGE_LIB}/connectors/wireguard.sh" ;;
        openvpn)   printf '%s\n' "${TUNFORGE_LIB}/connectors/openvpn.sh" ;;
        singbox)   printf '%s\n' "${TUNFORGE_LIB}/connectors/singbox.sh" ;;
        *)         return 1 ;;
    esac
}

# Stateless cross-protocol sweep run on every teardown / rollback. Catches
# orphan state that the per-connector down hooks won't touch because they
# only know about the recorded active profile - e.g. a stray openvpn
# daemon from a previous failed attempt that occurred while a wireguard
# tunnel was up. Idempotent, silent on a clean system.
_cross_protocol_sweep() {
    # 1. Kill any tunforge-spawned VPN daemons we don't know about. Each
    # of these tags is unique to tunforge so this never touches third-party
    # OpenVPN/sing-box installs.
    pkill -TERM -f 'openvpn-tunforge-' 2>/dev/null || true
    pkill -TERM -f "sing-box.*${TUNFORGE_RUN}/singbox-" 2>/dev/null || true
    # Brief grace period before SIGKILL.
    local i
    for ((i=0; i<10; i++)); do
        pgrep -f 'openvpn-tunforge-' >/dev/null 2>&1 || \
        pgrep -f "sing-box.*${TUNFORGE_RUN}/singbox-" >/dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -KILL -f 'openvpn-tunforge-' 2>/dev/null || true
    pkill -KILL -f "sing-box.*${TUNFORGE_RUN}/singbox-" 2>/dev/null || true

    # 2. Drop our singleton sing-box iface if it survived.
    if ip link show tun-opus0 >/dev/null 2>&1; then
        ip link delete dev tun-opus0 2>/dev/null || true
    fi

    # 3. Flush wg-quick's policy-routing rules. Routes in table 51820
    # auto-clean when the iface is deleted (kernel reaps), but the IP
    # rules pointing at table 51820 do NOT - they must be explicitly
    # removed or the next wg connect silently routes our fwmarked
    # traffic into an empty table.
    while ip -4 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do :; done
    while ip -4 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do :; done
    while ip -6 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do :; done
    while ip -6 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do :; done
    ip -4 route flush table 51820 2>/dev/null || true
    ip -6 route flush table 51820 2>/dev/null || true
    bypass_clear_routes || true
}

# Internal: run the "down" path for whatever is currently active.
_teardown_current() {
    local current; current="$(state_get_active)"
    if [[ "$current" == "none" || -z "$current" ]]; then
        # Even with no active profile, do a defensive sweep - state can
        # diverge from reality if a previous connect was killed -9 mid-run.
        _cross_protocol_sweep
        # And tear down the kill switch if it's hanging around without a
        # tunnel; otherwise the user has no internet and `disconnect`
        # appears to "do nothing".
        "${TUNFORGE_LIB}/firewall.sh" down 2>/dev/null || true
        "${TUNFORGE_LIB}/dns.sh" revert-all 2>/dev/null || true
        "${TUNFORGE_LIB}/leak-prevent.sh" restore 2>/dev/null || true
        log_ok "No previous VPN was active"
        return 0
    fi
    local pfile="${TUNFORGE_PROFILES_DIR}/${current}.profile"
    if [[ ! -f "$pfile" ]]; then
        log_warn "Active profile '$current' has no profile file - forcing cleanup"
        _cross_protocol_sweep
        "${TUNFORGE_LIB}/firewall.sh" down || true
        "${TUNFORGE_LIB}/leak-prevent.sh" restore || true
        "${TUNFORGE_LIB}/dns.sh" revert-all || true
        state_clear
        log_ok "Stale state cleared"
        return 0
    fi
    load_profile "$current"
    log_step "Tearing down active profile '$current' ($P_TYPE)"
    local script; script="$(_connector_for "$P_TYPE")" || die "No connector for type '$P_TYPE'"
    # Pass the profile name as argv[2] so the connector subprocess can re-load
    # the profile (P_* vars don't survive across process boundaries).
    if "$script" down "$current"; then
        # "direct" is the absence of a tunnel, so there is nothing to announce.
        [[ "$P_TYPE" == "direct" ]] || log_ok "The $P_TYPE tunnel is stopped"
    else
        log_warn "The $P_TYPE down hook returned non-zero (continuing cleanup anyway)"
    fi
    # Cross-protocol sweep BEFORE firewall/dns/leak revert so any orphan
    # daemons can't snatch traffic during the brief window.
    _cross_protocol_sweep
    "${TUNFORGE_LIB}/firewall.sh" down || true
    "${TUNFORGE_LIB}/leak-prevent.sh" restore || true
    "${TUNFORGE_LIB}/dns.sh" revert-all || true
    state_clear
    log_ok "Previous VPN state removed"
}

_do_connect() {
    local name="$1"
    load_profile "$name"
    log_section "Connecting: $name (${P_TYPE}${P_DESC:+ - $P_DESC})"

    _teardown_current

    # _teardown_current may have called load_profile on the OUTGOING profile,
    # which clobbers the global P_* vars. Re-load the incoming profile so
    # downstream dispatch (connector script, P_IPV6, etc.) uses the right
    # values. Without this, switching from a wireguard profile to a singbox
    # profile would dispatch wireguard_up against the singbox config.
    load_profile "$name"

    local script; script="$(_connector_for "$P_TYPE")" || die "No connector for type '$P_TYPE'"

    if [[ "$P_TYPE" != "direct" ]]; then
        "${TUNFORGE_LIB}/leak-prevent.sh" apply "$P_IPV6"
    else
        "${TUNFORGE_LIB}/leak-prevent.sh" restore
    fi

    # The direct connector is not a tunnel and narrates itself, so it would
    # only produce a confusing "starting direct tunnel".
    [[ "$P_TYPE" == "direct" ]] || log_step "Starting the $P_TYPE tunnel"
    local _conn_rc=0
    "$script" up "$name" || _conn_rc=$?
    if (( _conn_rc != 0 )); then
        log_fail "The $P_TYPE tunnel failed to start (rc=$_conn_rc) - rolling back"
        _rollback_connect "$script" "$name"
        exit 1
    fi

    state_set_active "$name"

    if [[ "$P_TYPE" != "direct" ]]; then
        local _ver_rc=0
        "${TUNFORGE_LIB}/verify.sh" "$name" || _ver_rc=$?
        if (( _ver_rc != 0 )); then
            log_fail "Post-connect verification failed - rolling back"
            _rollback_connect "$script" "$name"
            exit 1
        fi
    fi

    country_cache_update_for_profile "$name" "$(state_get_iface)" || true
    log_ok "Profile '$name' is connected and verified"
}

# Undo a half-finished connect. Order matters: stop the tunnel first so no
# traffic can slip out while the kill switch and DNS pins are being removed.
_rollback_connect() {
    local script="$1" name="$2"
    "$script" down "$name" || true
    "${TUNFORGE_LIB}/firewall.sh" down || true
    "${TUNFORGE_LIB}/leak-prevent.sh" restore || true
    "${TUNFORGE_LIB}/dns.sh" revert-all || true
    state_clear
    log_ok "Rolled back to direct connection"
}

# Record everything the connect attempt does (and every sub-process emits) to
# a single transcript file. The TUI's failure modal shows this verbatim, so
# the user no longer needs to chase journalctl when something goes wrong.
_append_protocol_logs() {
    local name="$1" transcript="$2"
    local f
    for f in \
        "$TUNFORGE_RUN/wg-${name}.log" \
        "$TUNFORGE_RUN/openvpn-${name}.log" \
        "$TUNFORGE_RUN/singbox-${name}.log"
    do
        if [[ -f "$f" && -s "$f" ]]; then
            {
                printf '\n=== %s (last 200 lines) ===\n' "$f"
                tail -n 200 "$f" 2>/dev/null || true
            } >> "$transcript" 2>/dev/null || true
        fi
    done
}

core_connect() {
    require_root
    local name="${1:?usage: tunforge connect <profile>}"
    [[ -f "${TUNFORGE_PROFILES_DIR}/${name}.profile" ]] \
        || die "no such profile: $name (looked at ${TUNFORGE_PROFILES_DIR}/${name}.profile)"

    install -d -m 0755 "$TUNFORGE_RUN"
    : > "$TUNFORGE_LAST_LOG"
    chmod 0644 "$TUNFORGE_LAST_LOG"

    {
        printf '=== tunforge connect: %s ===\n' "$name"
        printf 'started: %s\n' "$(date -Iseconds 2>/dev/null || date)"
        printf 'host   : %s\n' "$(uname -srm 2>/dev/null || true)"
        printf 'caller : pid=%s euid=%s\n' "$$" "${EUID:-?}"
        # Version stamp = mtime of THIS very file. If you re-edit the repo
        # but forget to re-run install.sh, the stamp here will not change
        # and we'll know immediately the connect ran against stale code.
        printf 'core.sh: %s (%s)\n' \
            "${BASH_SOURCE[0]}" \
            "$(stat -c '%y' "${BASH_SOURCE[0]}" 2>/dev/null | cut -d. -f1 || echo '?')"
        printf '\n'
    } >> "$TUNFORGE_LAST_LOG"

    # Run the whole connect under the file lock, and tee BOTH stdout and
    # stderr (everything log_* emits, plus connector sub-process output) to
    # the transcript. The brace group runs in a subshell because of the
    # pipe, so a `die` (exit 1) inside it just terminates that subshell and
    # PIPESTATUS[0] carries the rc out.
    local rc=0
    { with_lock _do_connect "$name"; } 2>&1 \
        | tee -a "$TUNFORGE_LAST_LOG" >&2 \
        || rc="${PIPESTATUS[0]}"

    _append_protocol_logs "$name" "$TUNFORGE_LAST_LOG"

    if (( rc != 0 )); then
        printf '\n=== FAILED rc=%s ===\n' "$rc" >> "$TUNFORGE_LAST_LOG"
    else
        printf '\n=== OK ===\n' >> "$TUNFORGE_LAST_LOG"
    fi
    return "$rc"
}

_do_disconnect() {
    log_section "Disconnecting"
    _teardown_current
    # revert-all above drops the LAN link's DNS along with the tunnel's, so on
    # a network where plain UDP/53 is unusable we have to put the DoT servers
    # back ourselves - NM will not re-push anything until its next event.
    local wan; wan="$(default_wan_iface)"
    [[ -n "$wan" ]] && "${TUNFORGE_LIB}/dns.sh" dot-reapply "$wan" 2>/dev/null || true
    log_ok "Disconnected - system is on the direct connection"
}

core_disconnect() {
    require_root
    with_lock _do_disconnect
}

# ---------------------------------------------------------------------------
# Comprehensive cleanup ("the big red button")
# ---------------------------------------------------------------------------
# Use case: switching between protocols, or recovering from a half-failed
# connect, occasionally leaves orphan state behind that the per-connector
# down() paths won't touch (because they only know about the current
# profile). This walks the whole system, kills anything we recognize as
# OURS, and returns the box to a clean direct-connection baseline.
#
# Designed to be safe to run when nothing is wrong: it's idempotent and
# reports what it actually did. NEVER touches non-tunforge processes, with
# the exception of foreign WG interfaces (those are explicitly opt-in via
# TUNFORGE_PURGE_FOREIGN_WG=1, otherwise we just list them).
#
# Outputs a short report to stdout so the TUI / CLI can show "what got
# cleaned".
core_purge() {
    local report=""
    # Helpers for accumulating the human-readable report. Defined as real
    # functions (bash `local` only scopes variables, not functions); we
    # `unset -f` them at the end so they don't leak into the parent shell.
    #
    # _r   raw line (headings, blank lines)
    # _ok / _bad / _hmm  a check that passed / failed / is degraded
    #
    # $cleaned counts the things we actually changed, so an already-clean
    # system can say so instead of printing an empty cleanup section.
    local cleaned=0
    _r()   { report+="${1}"$'\n'; }
    _ok()  { report+="$(mark_ok   "$1")"$'\n'; }
    _bad() { report+="$(mark_fail "$1")"$'\n'; }
    _hmm() { report+="$(mark_warn "$1")"$'\n'; }
    # NOTE: cleaned=$((...)) and not ((cleaned++)) - the latter evaluates to 0
    # on the first call and so *returns 1*, which under `set -o errexit` kills
    # the purge halfway through the report.
    _did() { cleaned=$((cleaned + 1)); _ok "$1"; }

    _r "=== Cleanup ==="

    install -d -m 0755 "$TUNFORGE_RUN" 2>/dev/null || true

    # ---- 1. Kill tunforge-spawned VPN processes -------------------------
    # OpenVPN: every process we spawn has --daemon "openvpn-tunforge-<name>"
    # which is identifiable in /proc.
    local _killed_ovpn=0 pid
    for pid in $(pgrep -f 'openvpn-tunforge-' 2>/dev/null); do
        kill -TERM "$pid" 2>/dev/null && ((_killed_ovpn++)) || true
    done
    if (( _killed_ovpn > 0 )); then
        _did "Stopped $_killed_ovpn OpenVPN process(es) started by tunforge"
        # Give them up to 2s to exit gracefully, then SIGKILL.
        local i
        for ((i=0; i<20; i++)); do
            pgrep -f 'openvpn-tunforge-' >/dev/null 2>&1 || break
            sleep 0.1
        done
        pkill -KILL -f 'openvpn-tunforge-' 2>/dev/null || true
    fi

    # sing-box: we ALWAYS launch it from $TUNFORGE_RUN as cwd, with
    # `-c /run/tunforge/singbox-<name>.json`. That config-path argv
    # match is the surest "this is ours" signal.
    local _killed_sb=0
    for pid in $(pgrep -f "sing-box.*${TUNFORGE_RUN}/singbox-" 2>/dev/null); do
        kill -TERM "$pid" 2>/dev/null && ((_killed_sb++)) || true
    done
    if (( _killed_sb > 0 )); then
        _did "Stopped $_killed_sb sing-box process(es) started by tunforge"
        local i
        for ((i=0; i<20; i++)); do
            pgrep -f "sing-box.*${TUNFORGE_RUN}/singbox-" >/dev/null 2>&1 || break
            sleep 0.1
        done
        pkill -KILL -f "sing-box.*${TUNFORGE_RUN}/singbox-" 2>/dev/null || true
    fi

    # Sweep any other PIDs we tracked but didn't recognize above (edge case:
    # config path got renamed but the pid-file still lists them).
    local pf
    for pf in "$TUNFORGE_RUN"/openvpn-*.pid "$TUNFORGE_RUN"/singbox-*.pid; do
        [[ -f "$pf" ]] || continue
        pid="$(<"$pf" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 0.1
            kill -KILL "$pid" 2>/dev/null || true
            _did "Killed leftover process $pid (from $(basename "$pf"))"
        fi
        rm -f "$pf"
    done

    # ---- 2. Tear down ALL WireGuard interfaces -------------------------
    # tunforge-managed (wg-<profile>) AND foreign (wg0 etc.). Foreign ones
    # are listed but only deleted if explicitly opted in - except in the
    # CLI/TUI purge path, where the user has explicitly asked for this.
    local -A ours=()
    local p
    while IFS= read -r p; do ours["wg-$p"]=1; done < <(list_profiles)

    local iface
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local conf="$TUNFORGE_RUN/${iface}.conf"
        if [[ -n "${ours[$iface]:-}" ]]; then
            wg-quick down "$conf" >/dev/null 2>&1 \
                || ip link delete dev "$iface" 2>/dev/null \
                || true
            rm -f "$conf"
            _did "Removed tunforge WireGuard interface '$iface'"
        else
            # Foreign WG iface (wg0 from a manual wg-quick, NetworkManager,
            # Tailscale, Mullvad, etc.). Only nuke if user opted in.
            if [[ "${TUNFORGE_PURGE_FOREIGN_WG:-0}" == "1" ]]; then
                wg-quick down "$iface" >/dev/null 2>&1 \
                    || ip link delete dev "$iface" 2>/dev/null \
                    || true
                _did "Removed foreign WireGuard interface '$iface' (TUNFORGE_PURGE_FOREIGN_WG=1)"
            else
                _hmm "Left foreign WireGuard interface '$iface' alone (set TUNFORGE_PURGE_FOREIGN_WG=1 to remove it)"
            fi
        fi
    done < <(ip -o link show type wireguard 2>/dev/null \
             | awk -F': ' '{ split($2, a, "@"); print a[1] }')

    # ---- 3. Tear down sing-box's TUN iface ----------------------------
    if ip link show tun-opus0 >/dev/null 2>&1; then
        ip link delete dev tun-opus0 2>/dev/null || true
        _did "Removed sing-box interface 'tun-opus0'"
    fi

    # ---- 4. Tear down orphan tun/tap ifaces with no owning process ----
    # Only ifaces with no associated openvpn/sing-box pid - we don't want
    # to kill a tun owned by Tailscale, OpenConnect, etc. The heuristic:
    # an iface tun42 that openvpn or sing-box once owned will have NO
    # process listed in `ss -tnlp` etc.; rather than do that, take the
    # safe approach of only touching tun ifaces appearing in OUR log
    # files (proven ours) and which have no process holding them.
    local lf
    for lf in "$TUNFORGE_RUN"/openvpn-*.log; do
        [[ -f "$lf" ]] || continue
        local _ifn
        _ifn="$(awk '/ip link set dev (tun|tap)[0-9]+ up/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' "$lf")"
        [[ -n "$_ifn" ]] || continue
        if ip link show "$_ifn" >/dev/null 2>&1; then
            # Only delete if no openvpn process owns it now (we already
            # killed our daemons above - any tun left here is orphan).
            if ! pgrep -f "openvpn.*$_ifn\b" >/dev/null 2>&1; then
                ip link delete dev "$_ifn" 2>/dev/null || true
                _did "Removed orphan TUN interface '$_ifn'"
            fi
        fi
    done

    # ---- 5. Flush wg-quick policy routing -----------------------------
    # wg-quick installs an IP rule + private route table 51820. After we
    # delete the iface, those routes auto-clean (kernel reaps routes
    # tied to a deleted iface), but the IP rules themselves do NOT. They
    # silently break next-connect by sending "fwmark 0xca6c" traffic
    # into a now-empty 51820 table.
    local _flushed_rules=0
    while ip -4 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do _flushed_rules=$((_flushed_rules + 1)); done
    while ip -4 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do _flushed_rules=$((_flushed_rules + 1)); done
    while ip -4 rule del      from all fwmark 0xca6c lookup 51820 2>/dev/null; do _flushed_rules=$((_flushed_rules + 1)); done
    while ip -6 rule del not from all fwmark 0xca6c lookup 51820 2>/dev/null; do _flushed_rules=$((_flushed_rules + 1)); done
    while ip -6 rule del not from all fwmark 0xca6c lookup main suppress_prefixlength 0 2>/dev/null; do _flushed_rules=$((_flushed_rules + 1)); done
    ip -4 route flush table 51820 2>/dev/null || true
    ip -6 route flush table 51820 2>/dev/null || true
    bypass_clear_routes || true
    if (( _flushed_rules > 0 )); then
        _did "Removed $_flushed_rules wg-quick policy routing rule(s) and flushed table 51820"
    fi

    # ---- 6. Drop nft kill switch --------------------------------------
    # Report it only if it was actually loaded: `firewall.sh down` succeeds on
    # a clean system too, and claiming to have removed something that was
    # never there makes the whole report untrustworthy.
    local _ks_was_loaded=0
    if command -v nft >/dev/null 2>&1 && nft list table inet tunforge >/dev/null 2>&1; then
        _ks_was_loaded=1
    fi
    "${TUNFORGE_LIB}/firewall.sh" down >/dev/null 2>&1 || true
    if (( _ks_was_loaded )); then
        _did "Removed the tunforge kill switch"
    fi

    # ---- 7. Restore systemd-resolved on every link --------------------
    "${TUNFORGE_LIB}/dns.sh" revert-all >/dev/null 2>&1 || true

    # ---- 7b. Re-anchor /etc/resolv.conf -------------------------------
    # If a connector (or a third-party hook like resolvconf/openresolv)
    # clobbered the symlink, the system is left with a stale or empty
    # /etc/resolv.conf and the user gets "no internet" even though the
    # tunnel is down. Restore it to the systemd-resolved stub - that's
    # what nm-tame.sh deploys and what NetworkManager 99-tunforge.conf
    # expects.
    local _stub=/run/systemd/resolve/stub-resolv.conf
    if systemctl is-active --quiet systemd-resolved 2>/dev/null \
       && [[ -e "$_stub" ]]; then
        local _need_relink=0 _cur=""
        if [[ -L /etc/resolv.conf ]]; then
            _cur="$(readlink /etc/resolv.conf 2>/dev/null || true)"
            [[ "$_cur" != "$_stub" ]] && _need_relink=1
        else
            _need_relink=1
        fi
        if (( _need_relink )); then
            ln -sfn "$_stub" /etc/resolv.conf 2>/dev/null \
                && _did "Re-anchored /etc/resolv.conf to the systemd-resolved stub (was: ${_cur:-a plain file})"
        fi
    elif [[ -e /etc/resolv.conf.tunforge-bak ]]; then
        # systemd-resolved isn't running (or its stub disappeared). Use
        # the backup we took at install time as a last resort.
        if ! diff -q /etc/resolv.conf.tunforge-bak /etc/resolv.conf >/dev/null 2>&1; then
            cp -a /etc/resolv.conf.tunforge-bak /etc/resolv.conf 2>/dev/null \
                && _did "Restored /etc/resolv.conf from the install-time backup"
        fi
    fi

    # ---- 7c. Try-restart systemd-resolved -----------------------------
    # `try-restart` only acts if the unit is currently active, so this
    # is a no-op on systems that don't use it. A fresh resolved drops
    # any stuck per-link DNS the `revert-all` step couldn't unwedge
    # (rare but observed when wg-quick crashed mid-update).
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl try-restart systemd-resolved 2>/dev/null || true
        # And drop any cached records the daemon was holding.
        resolvectl flush-caches 2>/dev/null || true
    fi

    # ---- 8. Restore sysctl baseline (re-enables IPv6 if disabled, etc.)
    # Same reasoning as the kill switch: the snapshot only exists if a connect
    # actually hardened the box, so its presence is what makes this newsworthy.
    local _had_leak_snapshot=0
    [[ -f "${TUNFORGE_VAR}/leak.snapshot" ]] && _had_leak_snapshot=1
    "${TUNFORGE_LIB}/leak-prevent.sh" restore >/dev/null 2>&1 || true
    if (( _had_leak_snapshot )); then
        _did "Restored the sysctl / avahi baseline (IPv6, rp_filter)"
    fi

    # ---- 9. Wipe staging files ----------------------------------------
    rm -f \
        "$TUNFORGE_RUN"/wg-*.conf \
        "$TUNFORGE_RUN"/openvpn-*.{conf,clean.conf,status,log,pid} \
        "$TUNFORGE_RUN"/singbox-*.{json,log,pid} \
        2>/dev/null || true

    # ---- 10. Force NetworkManager to refresh DNS (if installed) -------
    # Without this, your terminal still resolves via the (now-reverted)
    # systemd-resolved per-link config and feels broken until next DHCP.
    # The `general reload` reapplies the top-level NM dns= setting from
    # 99-tunforge.conf, then `device reapply` re-pushes each link's DNS into
    # systemd-resolved without disturbing the link itself.
    #
    # Bouncing the link (disconnect/connect) is deliberately a LAST RESORT:
    # on Wi-Fi it costs a full WPA + DHCP round trip, kills every open TCP
    # connection (including the SSH session you may be running this over),
    # and leaves the device marked manually-disconnected if we die midway.
    local _line
    if command -v nmcli >/dev/null 2>&1; then
        nmcli general reload 2>/dev/null || true

        local dev i dns_now
        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            nmcli device reapply "$dev" >/dev/null 2>&1 || true

            # Give resolved a chance to pick the config up before judging it.
            dns_now=""
            for ((i=0; i<20; i++)); do
                dns_now="$(resolvectl dns "$dev" 2>/dev/null | sed 's/^[^:]*: *//' || true)"
                [[ -n "${dns_now// }" ]] && break
                sleep 0.5
            done

            if [[ -n "${dns_now// }" ]]; then
                _did "Refreshed DNS on $dev (${dns_now// / })"
                continue
            fi

            _hmm "$dev still had no DNS after reapply - bouncing the link"
            nmcli device disconnect "$dev" >/dev/null 2>&1 || true
            nmcli device connect "$dev" >/dev/null 2>&1 || true
            for ((i=0; i<40; i++)); do
                dns_now="$(resolvectl dns "$dev" 2>/dev/null | sed 's/^[^:]*: *//' || true)"
                [[ -n "${dns_now// }" ]] && break
                sleep 0.5
            done
            if [[ -n "${dns_now// }" ]]; then
                _did "$dev came back with DNS servers (${dns_now// / })"
            else
                _bad "$dev has no DNS servers even after a bounce"
            fi
        done < <(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
                 | awk -F: '($2=="ethernet"||$2=="wifi"||$2=="802-11-wireless") \
                            && $3=="connected" {print $1}')

        resolvectl flush-caches 2>/dev/null || true
    fi

    # ---- 11. Clear tunforge state file ---------------------------------
    # Done BEFORE the DNS work below: the dispatcher hook refuses to touch a
    # link while tunforge believes a VPN is up, so leaving stale state here
    # would make a concurrent NM event silently skip the DoT re-apply.
    state_clear

    # ---- 11b. Make DNS actually usable on the direct path --------------
    # Restoring the pre-VPN DNS config is not the same as restoring working
    # DNS. Networks that blackhole outbound UDP leave systemd-resolved with a
    # perfectly valid server list that can never answer, because resolved
    # degrades EDNS0 options but never the transport. Probe, and fall back to
    # DNS-over-TLS (TCP/853) if that is the only thing that survives here.
    local _wan_iface; _wan_iface="$(default_wan_iface || true)"
    if [[ -n "$_wan_iface" ]]; then
        _r ""
        _r "=== DNS on the direct path ==="
        while IFS= read -r _line; do
            _r "$_line"
        done < <("${TUNFORGE_LIB}/dns.sh" harden-direct "$_wan_iface" 2>/dev/null || true)
    fi

    # ---- 12. Self-verification ----------------------------------------
    # The whole point of purge is "system is back to a clean direct
    # connection", so end with a checklist the user can read at a glance:
    # one line per thing that must be true, and nothing else. Raw `ip rule` /
    # `nft list` / `resolvectl status` dumps used to live here; they are one
    # `tunforge status` away and drowned the actual answer.
    (( cleaned > 0 )) || _r "$(mark_ok "Nothing to clean - the system was already in a clean state")"
    _r ""
    _r "=== Post-purge checks ==="

    # -- The kill switch must be gone, or every check below fails for a
    # reason that has nothing to do with DNS.
    if command -v nft >/dev/null 2>&1 && nft list table inet tunforge >/dev/null 2>&1; then
        _bad "tunforge kill switch is STILL loaded - traffic is being dropped"
    else
        _ok "tunforge kill switch removed"
    fi

    # -- No leftover VPN interfaces
    local _wg_left _tun_left
    _wg_left="$(ip -o link show type wireguard 2>/dev/null \
                | awk -F': ' '{ split($2, a, "@"); print a[1] }' | tr '\n' ' ' || true)"
    _tun_left=""
    ip link show tun-opus0 >/dev/null 2>&1 && _tun_left="tun-opus0"
    if [[ -z "${_wg_left// }" && -z "$_tun_left" ]]; then
        _ok "No VPN interfaces left"
    else
        _bad "VPN interfaces still present: ${_wg_left}${_tun_left}"
    fi

    # -- Link and routing. Everything here is discovered, never hardcoded: a
    # gateway address baked into the source is worthless on any network but
    # the author's.
    local _gw; _gw="$(default_gateway_ip || true)"
    if [[ -n "$_wan_iface" ]]; then
        _ok "Network link is up ($_wan_iface)"
    else
        _bad "No network link - nothing is connected"
    fi
    if [[ -n "$_gw" ]] && ping -c1 -W2 "$_gw" >/dev/null 2>&1; then
        _ok "Routing to the router works ($_gw)"
    elif [[ -n "$_gw" ]]; then
        _bad "Router $_gw does not reply - this is a link problem, not DNS"
    else
        _bad "No default route - no internet access at all"
    fi

    # -- systemd-resolved and its stub file
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        _ok "systemd-resolved is running"
    else
        _bad "systemd-resolved is not running (the stub at 127.0.0.53 is down)"
    fi
    if [[ -L /etc/resolv.conf ]]; then
        _ok "/etc/resolv.conf -> $(readlink /etc/resolv.conf 2>/dev/null || true)"
    elif [[ -e /etc/resolv.conf ]]; then
        _hmm "/etc/resolv.conf is a plain file, not the systemd-resolved stub"
    else
        _bad "/etc/resolv.conf is missing - the system has no DNS config at all"
    fi

    # -- Per-server transport probe. udp-vs-tcp is the whole diagnosis: same
    # server, same route, one works and the other does not.
    local _servers="" _srv _udp_ok=0 _tcp_ok=0 _any=0
    if [[ -n "$_wan_iface" ]]; then
        _servers="$(resolvectl dns "$_wan_iface" 2>/dev/null | sed 's/^[^:]*: *//' || true)"
    fi
    if [[ -n "${_servers// }" ]]; then
        _ok "NetworkManager DNS settings are OK (${_servers// / })"
        for _srv in $_servers; do
            _any=1
            if dns_udp53_works "${_srv%%#*}" 2; then
                _udp_ok=1; _ok "UDP DNS to ${_srv%%#*} works"
            else
                _bad "UDP DNS to ${_srv%%#*} gets no reply"
            fi
            if dns_tcp53_works "${_srv%%#*}" 3; then
                _tcp_ok=1; _ok "TCP DNS to ${_srv%%#*} works"
            else
                _bad "TCP DNS to ${_srv%%#*} gets no reply"
            fi
        done
    else
        _bad "No DNS servers configured on ${_wan_iface:-the WAN link}"
    fi

    if (( _any && !_udp_ok && _tcp_ok )); then
        _r "   -> This network drops outbound UDP/53 but allows TCP/53, so plain"
        _r "      DNS can never work here. See the DNS-over-TLS lines above."
    elif (( _any && !_udp_ok && !_tcp_ok )); then
        _r "   -> No configured resolver answered on either transport."
    fi

    # -- Final end-to-end check through NSS, which is what applications
    # actually use. This is the one that answers "is my browser going to work".
    if command -v getent >/dev/null 2>&1; then
        local _probe="" _try
        for _try in {1..5}; do
            # `|| true` is load-bearing: core.sh runs under errexit+pipefail,
            # so a failing getent here would abort the purge before it prints
            # a single line - exactly when DNS is broken and the report matters.
            _probe="$(timeout 3 getent ahostsv4 "$TUNFORGE_DNS_PROBE_HOST" 2>/dev/null \
                    | awk '{print $1; exit}' || true)"
            [[ -n "$_probe" ]] && break
            sleep 1
        done
        if [[ -n "$_probe" ]]; then
            _ok "DNS replies come back ($TUNFORGE_DNS_PROBE_HOST -> $_probe)"
        else
            _bad "DNS does not resolve ($TUNFORGE_DNS_PROBE_HOST failed) - run 'tunforge status'"
        fi
    fi

    unset -f _r _ok _bad _hmm _did
    printf '%s' "$report"
    return 0
}

core_status() {
    local active iface pubip
    active="$(state_get_active)"
    iface="$(state_get_iface)"
    printf 'profile : %s\n' "$active"
    printf 'iface   : %s\n' "${iface:-<none>}"
    if [[ "$active" != "none" ]] && [[ -f "${TUNFORGE_PROFILES_DIR}/${active}.profile" ]]; then
        load_profile "$active" 2>/dev/null || true
        printf 'type    : %s\n' "${P_TYPE:-?}"
        printf 'desc    : %s\n' "${P_DESC:-}"
        printf 'country : %s\n' "${P_COUNTRY:-<unknown>}"
        printf 'dns     : %s\n' "${P_DNS_SERVERS:-}"
        printf 'killsw  : %s\n' "${P_KILL_SWITCH:-?}"
        printf 'ipv6    : %s\n' "${P_IPV6:-?}"
    fi
    printf 'resolv  : '
    if [[ -L /etc/resolv.conf ]]; then
        readlink /etc/resolv.conf
    else
        echo "<plain file - HARDENING NOT APPLIED>"
    fi
    if [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1; then
        printf 'iface up: yes\n'
        if command -v curl >/dev/null 2>&1; then
            pubip="$(timeout 5 curl -fsS --interface "$iface" https://api.ipify.org 2>/dev/null || true)"
            printf 'public  : %s\n' "${pubip:-<unreachable via tunnel>}"
        fi
    fi
}
