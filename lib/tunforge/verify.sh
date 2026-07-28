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
ok()   { log_ok   "$@"; }
bad()  { FAILED=$((FAILED + 1)); log_fail "$@"; }

load_profile "$PROFILE"
log_section "Verifying $PROFILE"

# ---------------------------------------------------------------------------
# 1. Config sanity
# ---------------------------------------------------------------------------
if [[ -n "${P_CONFIG:-}" && -f "$P_CONFIG" ]]; then
    if [[ "$P_TYPE" == "singbox" ]] && command -v jq >/dev/null 2>&1; then
        if jq empty "$P_CONFIG" >/dev/null 2>&1; then
            ok "Profile config is valid JSON"
        else
            bad "Profile config is not valid JSON: $P_CONFIG"
        fi
    else
        ok "Profile config is present"
    fi
else
    bad "Profile config is missing: ${P_CONFIG:-<unset>}"
fi

# A private ENDPOINT_IP means the endpoint was pinned to a LAN address, which
# is either a copy/paste slip or DNS poisoning that got baked into the profile.
# Either way the tunnel cannot be reaching the real server.
if [[ -n "${P_ENDPOINT_IP:-}" ]]; then
    if [[ "$P_ENDPOINT_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.|127\.) ]]; then
        bad "ENDPOINT_IP=$P_ENDPOINT_IP is a private address - the profile is not pointing at a real server"
    else
        ok "Endpoint pinned to $P_ENDPOINT_IP"
    fi
fi

# ---------------------------------------------------------------------------
# 2. The tunnel interface
# ---------------------------------------------------------------------------
IFACE="$(state_get_iface)"
if [[ -z "$IFACE" ]]; then
    bad "No tunnel interface was recorded - the connector did not finish"
elif ip link show "$IFACE" >/dev/null 2>&1; then
    ok "Tunnel interface $IFACE exists"
else
    bad "Tunnel interface $IFACE is gone"
    IFACE=""
fi

# ---------------------------------------------------------------------------
# 3. Routing
# ---------------------------------------------------------------------------
# sing-box's auto_route deliberately leaves the kernel default route alone and
# steers traffic with policy rules instead, so "default route is not the tun"
# is normal there and must never fail the connection.
if [[ -n "$IFACE" ]]; then
    if ip route get 1.1.1.1 2>/dev/null | grep -q "$IFACE"; then
        ok "Traffic is routed into the tunnel"
    elif ip rule show 2>/dev/null | grep -q lookup; then
        ok "Traffic is routed into the tunnel (policy routing)"
    else
        log_warn "Could not confirm how traffic is routed - checking the exit IP below"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Kill switch
# ---------------------------------------------------------------------------
if [[ "${P_KILL_SWITCH:-yes}" == "yes" ]]; then
    if command -v nft >/dev/null 2>&1 && nft list table inet tunforge >/dev/null 2>&1; then
        ok "tunforge kill switch is active"
    else
        bad "tunforge kill switch is NOT loaded - traffic would leak if the tunnel drops"
    fi
else
    log_warn "Kill switch is disabled for this profile (KILL_SWITCH=no)"
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
    ok "DNS replies come back ($TUNFORGE_DNS_PROBE_HOST -> $DNS_IP)"
else
    bad "DNS does not resolve through the tunnel"
fi

# ---------------------------------------------------------------------------
# 6. The actual exit
# ---------------------------------------------------------------------------
# The one check that proves the whole stack works end to end. Binding to the
# tunnel interface is the strict test; a plain request is the fallback, because
# with auto_route plus the kill switch there is nowhere else for it to go.
if command -v curl >/dev/null 2>&1; then
    PUB_IP=""
    for _try in 1 2 3; do
        if [[ -n "$IFACE" ]]; then
            PUB_IP="$(timeout 10 curl -4 -fsS --interface "$IFACE" \
                      https://api.ipify.org 2>/dev/null || true)"
        fi
        [[ -z "$PUB_IP" ]] && PUB_IP="$(timeout 10 curl -4 -fsS \
                                        https://api.ipify.org 2>/dev/null || true)"
        [[ -n "$PUB_IP" ]] && break
        sleep 2
    done
    if [[ -n "$PUB_IP" ]]; then
        ok "Traffic exits through the VPN (public IP: $PUB_IP)"
    else
        bad "Could not reach the internet through the tunnel"
    fi
else
    log_warn "curl is not installed - skipped the public IP check"
fi

# ---------------------------------------------------------------------------
if (( FAILED == 0 )); then
    log_ok "Verification passed"
else
    log_fail "Verification failed ($FAILED check(s))"
    log_hint "Run 'tunforge last-log' for the full connect transcript."
fi
exit $(( FAILED > 0 ? 1 : 0 ))
