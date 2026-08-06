#!/usr/bin/env bash
# tunforge/verify.sh - post-connect verification.
#
# core.sh runs this as the last step of every non-direct connect. A non-zero
# exit rolls the connection back, so a check only counts as a FAILURE when the
# connection is genuinely unusable or unsafe. Anything merely surprising is a
# warning: rolling a working tunnel back because of a cosmetic mismatch is a
# worse outcome than leaving it up.
#
# Everything is protocol-agnostic and reads the live interface from tunforge's
# own state, because this same script verifies sing-box TUN, WireGuard and
# OpenVPN connections.

# shellcheck shell=bash disable=SC2155

set -o nounset
set -o pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB/core.sh"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || die "verify: no profile supplied"

FAILED=0
PASSED=0
# Parallel arrays of short check labels for the end summary.
PASS_NAMES=()
FAIL_NAMES=()
SKIP_NAMES=()

ok() {
    local name="$1"; shift
    PASSED=$((PASSED + 1))
    PASS_NAMES+=("$name")
    log_ok "[pass] $name: $*"
}

bad() {
    local name="$1"; shift
    FAILED=$((FAILED + 1))
    FAIL_NAMES+=("$name")
    log_fail "[FAIL] $name: $*"
}

skip() {
    local name="$1"; shift
    SKIP_NAMES+=("$name")
    log_warn "[skip] $name: $*"
}

# Extra context under a failed check - always visible (not verbose-only).
why() {
    log_hint "$@"
}

_print_summary() {
    local n
    log_section "Verification summary"
    log_hint "profile=$PROFILE  type=${P_TYPE:-?}  iface=${IFACE:-<none>}  passed=$PASSED  failed=$FAILED  skipped=${#SKIP_NAMES[@]}"
    if (( PASSED > 0 )); then
        log_ok "Passed ($PASSED):"
        for n in "${PASS_NAMES[@]}"; do
            log_hint "  ✓ $n"
        done
    fi
    if (( ${#SKIP_NAMES[@]} > 0 )); then
        log_warn "Skipped (${#SKIP_NAMES[@]}):"
        for n in "${SKIP_NAMES[@]}"; do
            log_hint "  – $n"
        done
    fi
    if (( FAILED > 0 )); then
        log_fail "Failed ($FAILED) — these caused the rollback:"
        for n in "${FAIL_NAMES[@]}"; do
            log_hint "  ✗ $n"
        done
    fi
}

load_profile "$PROFILE"
log_section "Verifying $PROFILE ($P_TYPE)"
log_hint "Running post-connect checks; any [FAIL] below will roll the tunnel back."

# ---------------------------------------------------------------------------
# 1. Config sanity
# ---------------------------------------------------------------------------
if [[ -n "${P_CONFIG:-}" && -f "$P_CONFIG" ]]; then
    if [[ "$P_TYPE" == "singbox" ]] && command -v jq >/dev/null 2>&1; then
        if jq empty "$P_CONFIG" >/dev/null 2>&1; then
            ok config "Profile config is valid JSON ($P_CONFIG)"
        else
            bad config "Profile config is not valid JSON: $P_CONFIG"
            why "jq could not parse the file — fix or re-import the profile config"
        fi
    else
        ok config "Profile config is present ($P_CONFIG)"
    fi
else
    bad config "Profile config is missing: ${P_CONFIG:-<unset>}"
    why "Expected a config file on disk for type=$P_TYPE"
fi

# A private ENDPOINT_IP means the endpoint was pinned to a LAN address, which
# is either a copy/paste slip or DNS poisoning that got baked into the profile.
# Either way the tunnel cannot be reaching the real server.
if [[ -n "${P_ENDPOINT_IP:-}" ]]; then
    if [[ "$P_ENDPOINT_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|127\.) ]]; then
        bad endpoint "ENDPOINT_IP=$P_ENDPOINT_IP is a private address - not a real server"
        why "Re-resolve the upstream hostname or clear ENDPOINT_IP from the profile"
    else
        ok endpoint "Endpoint pinned to $P_ENDPOINT_IP"
    fi
else
    skip endpoint "No ENDPOINT_IP pinned (connector resolved at connect time)"
fi

# ---------------------------------------------------------------------------
# 2. The tunnel interface
# ---------------------------------------------------------------------------
IFACE="$(state_get_iface)"
if [[ -z "$IFACE" ]]; then
    bad iface "No tunnel interface was recorded - the connector did not finish"
    why "state file has no iface; the up() path likely exited before recording it"
elif ip link show "$IFACE" >/dev/null 2>&1; then
    local_flags="$(ip -o link show "$IFACE" 2>/dev/null | sed -n 's/.*<\([^>]*\)>.*/\1/p' || true)"
    ok iface "Tunnel interface $IFACE exists${local_flags:+ (<$local_flags>)}"
else
    bad iface "Tunnel interface $IFACE is gone"
    why "Connector recorded iface=$IFACE but it is no longer in the kernel"
    IFACE=""
fi

# ---------------------------------------------------------------------------
# 3. Routing
# ---------------------------------------------------------------------------
# sing-box's auto_route deliberately leaves the kernel default route alone and
# steers traffic with policy rules instead, so "default route is not the tun"
# is normal there and must never fail the connection.
if [[ -n "$IFACE" ]]; then
    _route_line="$(ip route get 1.1.1.1 2>/dev/null | head -n1 || true)"
    if [[ -n "$_route_line" ]] && grep -q "$IFACE" <<<"$_route_line"; then
        ok routing "Traffic is routed into the tunnel ($_route_line)"
    elif ip rule show 2>/dev/null | grep -q lookup; then
        ok routing "Traffic is routed into the tunnel (policy routing)"
    else
        skip routing "Could not confirm how traffic is routed - exit IP check decides"
        why "ip route get 1.1.1.1 => ${_route_line:-<empty>}"
    fi
else
    skip routing "Skipped (no tunnel interface)"
fi

# ---------------------------------------------------------------------------
# 4. Kill switch
# ---------------------------------------------------------------------------
if [[ "${P_KILL_SWITCH:-yes}" == "yes" ]]; then
    if command -v nft >/dev/null 2>&1 && nft list table inet tunforge >/dev/null 2>&1; then
        ok killswitch "tunforge kill switch is active (nft table inet tunforge)"
    else
        bad killswitch "tunforge kill switch is NOT loaded - traffic would leak if the tunnel drops"
        if ! command -v nft >/dev/null 2>&1; then
            why "nft binary missing"
        else
            why "nft list table inet tunforge failed — firewall.sh may not have applied"
        fi
    fi
else
    skip killswitch "Kill switch is disabled for this profile (KILL_SWITCH=no)"
fi

# ---------------------------------------------------------------------------
# 5. DNS
# ---------------------------------------------------------------------------
# Through NSS, because that is the path applications actually take. Retried:
# systemd-resolved can need a moment to accept the new per-link config.
DNS_IP=""
for _try in 1 2 3 4 5; do
    DNS_IP="$(timeout 3 getent ahostsv4 "$TUNFORGE_DNS_PROBE_HOST" 2>/dev/null \
              | awk '{print $1; exit}')"
    [[ -n "$DNS_IP" ]] && break
    sleep 1
done
if [[ -n "$DNS_IP" ]]; then
    ok dns "DNS replies come back ($TUNFORGE_DNS_PROBE_HOST -> $DNS_IP)"
else
    bad dns "DNS does not resolve through the tunnel ($TUNFORGE_DNS_PROBE_HOST)"
    why "getent ahostsv4 failed after 5 attempts"
    if [[ -L /etc/resolv.conf ]]; then
        why "resolv.conf -> $(readlink /etc/resolv.conf 2>/dev/null || echo '?')"
    else
        why "resolv.conf is a plain file (hardening may not be applied)"
    fi
    if [[ -n "$IFACE" ]] && command -v resolvectl >/dev/null 2>&1; then
        why "resolvectl dns $IFACE: $(resolvectl dns "$IFACE" 2>/dev/null | tr '\n' ' ' || echo '<unavailable>')"
        why "resolvectl domain $IFACE: $(resolvectl domain "$IFACE" 2>/dev/null | tr '\n' ' ' || echo '<unavailable>')"
    fi
fi

# ---------------------------------------------------------------------------
# 6. The actual exit
# ---------------------------------------------------------------------------
# The one check that proves the whole stack works end to end. Binding to the
# tunnel interface is the strict test; a plain request is the fallback, because
# with auto_route plus the kill switch there is nowhere else for it to go.
if command -v curl >/dev/null 2>&1; then
    PUB_IP=""
    CURL_ERR=""
    _take_ip() {
        # Accept only a bare IPv4 from curl's combined stdout/stderr capture.
        local out="$1"
        if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            PUB_IP="$out"
            CURL_ERR=""
        else
            CURL_ERR="$out"
        fi
    }
    for _try in 1 2 3; do
        if [[ -n "$IFACE" && -z "$PUB_IP" ]]; then
            _take_ip "$(timeout 10 curl -4 -fsS --interface "$IFACE" \
                        https://api.ipify.org 2>&1 || true)"
        fi
        if [[ -z "$PUB_IP" ]]; then
            _take_ip "$(timeout 10 curl -4 -fsS \
                        https://api.ipify.org 2>&1 || true)"
        fi
        [[ -n "$PUB_IP" ]] && break
        sleep 2
    done
    unset -f _take_ip
    if [[ -n "$PUB_IP" ]]; then
        ok exitip "Traffic exits through the VPN (public IP: $PUB_IP)"
    else
        bad exitip "Could not reach the internet through the tunnel"
        why "curl https://api.ipify.org failed after 3 attempts${IFACE:+ (tried --interface $IFACE then plain)}"
        [[ -n "$CURL_ERR" ]] && why "last curl output: $(printf '%s' "$CURL_ERR" | tr '\n' ' ' | head -c 200)"
    fi
else
    skip exitip "curl is not installed - skipped the public IP check"
fi

# ---------------------------------------------------------------------------
_print_summary
if (( FAILED == 0 )); then
    log_ok "Verification passed — all required checks succeeded"
else
    log_fail "Verification failed ($FAILED required check(s) failed, $PASSED passed)"
    log_hint "Fix the [FAIL] items above, then reconnect. Full transcript: tunforge last-log"
fi
exit $(( FAILED > 0 ? 1 : 0 ))
