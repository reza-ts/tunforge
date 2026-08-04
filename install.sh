#!/usr/bin/env bash
# tunforge install.sh - bootstraps a fresh Ubuntu 22.04 box.
#
# What it does:
#   1. Preflight: Ubuntu 22.04 check, root, arch, systemd-resolved presence.
#   2. Apt deps: install only what's missing.
#   3. sing-box: download arch-matching .deb from GitHub releases, verify SHA256,
#      install via dpkg.
#   4. Deploy files into /usr/local/{bin,lib}/, /etc/tunforge/, /etc/systemd/system/,
#      /etc/NetworkManager/conf.d/, /etc/systemd/resolved.conf.d/.
#   5. Apply NM + resolved drop-ins via lib/nm-tame.sh.
#   6. systemctl enable tunforge-killswitch.service.
#
# Idempotent. Safe to re-run.

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APT_DEPS=(
    wireguard-tools
    openvpn
    nftables
    whiptail
    iproute2
    curl
    jq
    gawk
    dnsutils
    ca-certificates
    moreutils
)

SINGBOX_MIN_VERSION="1.10.0"

PREFIX=/usr/local
LIBDIR="$PREFIX/lib/tunforge"
BINDIR="$PREFIX/bin"
ETCDIR=/etc/tunforge
VARDIR=/var/lib/tunforge
RUNDIR=/run/tunforge

NM_DROPIN=/etc/NetworkManager/conf.d/99-tunforge.conf
NM_DISPATCHER=/etc/NetworkManager/dispatcher.d/50-tunforge-dot
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/tunforge.conf
KILLSWITCH_UNIT=/etc/systemd/system/tunforge-killswitch.service
PROFILE_UNIT=/etc/systemd/system/tunforge@.service
DNS_CACHE_TIMER=/etc/systemd/system/tunforge-dns-cache-refresh.timer
DNS_CACHE_SERVICE=/etc/systemd/system/tunforge-dns-cache-refresh.service

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------
CHECK_ONLY=0
FORCE=0
SKIP_SINGBOX=0
SINGBOX_DEB=""
REINSTALL=0
REINSTALL_SINGBOX=0

usage() {
    cat <<EOF
usage: install.sh [options]
  --check                dry-run, only report what would change
  --force                bypass Ubuntu version check
  --no-singbox           skip sing-box (V2Ray profiles will be disabled)
  --singbox-deb PATH     use a local .deb instead of downloading
  --reinstall            re-deploy tunforge files (scripts, units, templates)
                         (does NOT re-download sing-box if already at >=$SINGBOX_MIN_VERSION)
  --reinstall-singbox    force a fresh download + install of sing-box even if
                         the version on disk is already adequate
  -h, --help             this message
EOF
}

while (($#)); do
    case "$1" in
        --check)              CHECK_ONLY=1 ;;
        --force)              FORCE=1 ;;
        --no-singbox)         SKIP_SINGBOX=1 ;;
        --singbox-deb)        SINGBOX_DEB="${2:?--singbox-deb requires PATH}"; shift ;;
        --reinstall)          REINSTALL=1 ;;
        --reinstall-singbox)  REINSTALL_SINGBOX=1 ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
# Colour only on a terminal; installs are often piped into a log or run from a
# provisioning tool. Symbols match the ones tunforge itself uses at runtime.
if [[ -t 1 ]]; then
    _C_R=$'\033[31m'; _C_G=$'\033[32m'; _C_Y=$'\033[33m'; _C_B=$'\033[1;36m'; _C_0=$'\033[0m'
else
    _C_R=''; _C_G=''; _C_Y=''; _C_B=''; _C_0=''
fi
say()  { printf '%s▸%s %s\n' "$_C_B" "$_C_0" "$*"; }
ok()   { printf '%s✅%s %s\n' "$_C_G" "$_C_0" "$*"; }
warn() { printf '%s⚠️%s %s\n' "$_C_Y" "$_C_0" "$*" >&2; }
err()  { printf '%s❌%s %s\n' "$_C_R" "$_C_0" "$*" >&2; }
die()  { err "$@"; exit 1; }

run() {
    if (( CHECK_ONLY )); then
        printf '%s[dry-run]%s %s\n' "$_C_Y" "$_C_0" "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Self-elevate
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    if (( CHECK_ONLY )); then
        warn "running --check as non-root; some checks will be incomplete"
    else
        say "re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
    say "preflight checks"

    # OS
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            (( FORCE )) || die "this installer targets Ubuntu (found ID=${ID:-?}); pass --force to override"
            warn "non-Ubuntu OS (ID=$ID); continuing because --force"
        fi
        if [[ "${VERSION_ID:-}" != "22.04" ]]; then
            (( FORCE )) || die "this installer targets Ubuntu 22.04 (found ${VERSION_ID:-?}); pass --force to override"
            warn "Ubuntu version ${VERSION_ID:-?} - continuing because --force"
        fi
        ok "OS: ${PRETTY_NAME:-$ID $VERSION_ID}"
    else
        warn "/etc/os-release missing; skipping OS check"
    fi

    # init system
    [[ -d /run/systemd/system ]] || die "systemd not detected; this tool requires systemd"
    ok "init: systemd"

    # arch
    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$ARCH" in
        amd64|arm64) ok "arch: $ARCH" ;;
        x86_64)      ARCH=amd64; ok "arch: amd64 (normalized from x86_64)" ;;
        aarch64)     ARCH=arm64; ok "arch: arm64 (normalized from aarch64)" ;;
        *) (( FORCE )) || die "unsupported arch: $ARCH"; warn "arch=$ARCH (forced)" ;;
    esac

    # systemd-resolved binary present (it ships with Ubuntu 22 systemd)
    command -v resolvectl >/dev/null 2>&1 \
        || die "resolvectl not found; install systemd-resolved (it should be present on Ubuntu 22)"
    ok "systemd-resolved: present"
}

# ---------------------------------------------------------------------------
# Apt dependencies
# ---------------------------------------------------------------------------
install_apt_deps() {
    say "apt: checking dependencies"

    local need=()
    local p
    for p in "${APT_DEPS[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            ok "apt: $p (installed)"
        else
            need+=("$p")
        fi
    done

    if (( ${#need[@]} == 0 )); then
        ok "apt: nothing to install"
        return
    fi

    say "apt: will install: ${need[*]}"

    # apt-get update is best-effort. Many users have third-party repos with
    # expired keys / dead PPAs that make `apt-get update` return non-zero even
    # when the main Ubuntu repos are fine. Treat any failure here as a warning
    # rather than fatal - the subsequent `apt-get install` is the real test.
    if (( CHECK_ONLY )); then
        printf '%s[dry-run]%s apt-get update (best-effort)\n' "$_C_Y" "$_C_0"
    else
        if ! apt-get update; then
            warn "apt: 'apt-get update' returned non-zero (broken third-party repos?). Continuing anyway."
        fi
    fi

    if (( CHECK_ONLY )); then
        printf '%s[dry-run]%s env DEBIAN_FRONTEND=noninteractive apt-get install -y %s\n' \
            "$_C_Y" "$_C_0" "${need[*]}"
    else
        if ! env DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"; then
            die "apt: failed to install ${need[*]} - fix your apt sources and re-run, or install these manually"
        fi
    fi
}

# ---------------------------------------------------------------------------
# sing-box
# ---------------------------------------------------------------------------
_singbox_installed_version() {
    if command -v sing-box >/dev/null 2>&1; then
        sing-box version 2>/dev/null | awk '/^sing-box version/{print $3; exit}'
    fi
}

# Compare semver-ish. Returns 0 if $1 >= $2.
_ver_ge() {
    local a="$1" b="$2"
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" == "$b" ]]
}

install_singbox() {
    if (( SKIP_SINGBOX )); then
        warn "sing-box: skipped per --no-singbox (V2Ray-style profiles will fail to start)"
        return
    fi

    say "sing-box: checking"

    local cur; cur="$(_singbox_installed_version || true)"
    # Skip download if an adequate version is already installed, UNLESS
    # the user explicitly asked to bump it (--reinstall-singbox) or
    # supplied a local .deb (--singbox-deb implies "use this exact file").
    # Plain --reinstall is for code redeployment only and should NOT
    # trigger a multi-megabyte download every time.
    if [[ -n "$cur" ]] && _ver_ge "$cur" "$SINGBOX_MIN_VERSION" \
                       && (( !REINSTALL_SINGBOX )) \
                       && [[ -z "$SINGBOX_DEB" ]]; then
        ok "sing-box: $cur (>= $SINGBOX_MIN_VERSION, ok - skipping download; pass --reinstall-singbox to force re-install)"
        return
    fi

    if [[ -n "$SINGBOX_DEB" ]]; then
        [[ -f "$SINGBOX_DEB" ]] || die "sing-box: --singbox-deb $SINGBOX_DEB does not exist"
        say "sing-box: installing from $SINGBOX_DEB"
        run dpkg -i "$SINGBOX_DEB" || run apt-get install -f -y
        ok "sing-box: installed from local .deb"
        return
    fi

    # In --check mode we cannot meaningfully fetch + parse GitHub release
    # metadata: jq may not be installed yet (it's an apt dep we deferred), and
    # we don't want a dry-run to hit the network. Just describe what would
    # happen and bail.
    if (( CHECK_ONLY )); then
        printf '%s[dry-run]%s sing-box: would fetch latest .deb for arch=%s from GitHub releases and dpkg -i it\n' \
            "$_C_Y" "$_C_0" "$ARCH"
        printf '%s[dry-run]%s sing-box: pass --no-singbox to skip, or --singbox-deb PATH to use a local file\n' \
            "$_C_Y" "$_C_0"
        return
    fi

    # Both jq and curl must be present at this point (apt step ran above). If
    # somehow they're not, fail loudly with a helpful message instead of with
    # `bash: jq: command not found`.
    command -v curl >/dev/null 2>&1 || die "sing-box: curl is missing (apt step did not run?)"
    command -v jq   >/dev/null 2>&1 || die "sing-box: jq is missing (apt step did not run?)"

    # Download from GitHub releases
    say "sing-box: fetching release metadata from GitHub"
    local meta_url='https://api.github.com/repos/SagerNet/sing-box/releases/latest'
    local meta
    if ! meta="$(curl -fsSL --max-time 30 "$meta_url" 2>/dev/null)"; then
        die "sing-box: could not fetch $meta_url (no internet? rate-limited? use --singbox-deb PATH)"
    fi

    local tag deb_url deb_name
    tag="$(printf '%s' "$meta" | jq -r '.tag_name')"
    deb_url="$(printf '%s' "$meta" | jq -r --arg arch "$ARCH" '
        .assets[] | select(.name|test("linux_"+$arch+"\\.deb$")) | .browser_download_url
    ' | head -n1)"
    deb_name="$(basename "$deb_url" 2>/dev/null || true)"
    [[ -n "$deb_url" ]] || die "sing-box: no .deb asset found for arch=$ARCH in release $tag"

    say "sing-box: downloading $deb_name (release $tag)"
    local tmpdir; tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    run curl -fsSL --max-time 120 -o "$tmpdir/$deb_name" "$deb_url"

    # Try to verify SHA256 via the per-file .sha256 sibling (sing-box ships those).
    local sha_url="${deb_url}.sha256"
    if curl -fsSL --max-time 15 -o "$tmpdir/$deb_name.sha256" "$sha_url" 2>/dev/null; then
        ( cd "$tmpdir" && sha256sum -c "$deb_name.sha256" ) \
            || die "sing-box: SHA256 verification FAILED"
        ok "sing-box: SHA256 verified"
    else
        warn "sing-box: no .sha256 sidecar found (skipping checksum)"
    fi

    run dpkg -i "$tmpdir/$deb_name" || run apt-get install -f -y
    ok "sing-box: installed $tag"
}

# ---------------------------------------------------------------------------
# File deployment
# ---------------------------------------------------------------------------
deploy_files() {
    say "deploying files"
    local src; src="$(cd "$(dirname "$0")" && pwd)"

    # bin
    run install -D -m 0755 "$src/bin/tunforge"          "$BINDIR/tunforge"
    run install -D -m 0755 "$src/bin/tunforge-logs"     "$BINDIR/tunforge-logs"
    run install -D -m 0755 "$src/bin/tunforge-import"   "$BINDIR/tunforge-import"
    run install -D -m 0755 "$src/bin/tunforge-subscription" "$BINDIR/tunforge-subscription"
    run install -D -m 0755 "$src/bin/tunforge-scaffold" "$BINDIR/tunforge-scaffold"

    # lib (top level + connectors)
    run install -D -m 0644 "$src/lib/tunforge/core.sh"          "$LIBDIR/core.sh"
    run install -D -m 0755 "$src/lib/tunforge/dns.sh"           "$LIBDIR/dns.sh"
    run install -D -m 0755 "$src/lib/tunforge/firewall.sh"      "$LIBDIR/firewall.sh"
    run install -D -m 0755 "$src/lib/tunforge/leak-prevent.sh"  "$LIBDIR/leak-prevent.sh"
    run install -D -m 0755 "$src/lib/tunforge/verify.sh"        "$LIBDIR/verify.sh"
    run install -D -m 0755 "$src/lib/tunforge/nm-tame.sh"       "$LIBDIR/nm-tame.sh"
    local c
    for c in direct wireguard openvpn singbox; do
        run install -D -m 0755 "$src/lib/tunforge/connectors/${c}.sh" \
            "$LIBDIR/connectors/${c}.sh"
    done

    # systemd
    run install -D -m 0644 "$src/systemd/tunforge-killswitch.service" "$KILLSWITCH_UNIT"
    run install -D -m 0644 "$src/systemd/tunforge@.service"           "$PROFILE_UNIT"
    run install -D -m 0644 "$src/systemd/tunforge-dns-cache-refresh.timer"  "$DNS_CACHE_TIMER"
    run install -D -m 0644 "$src/systemd/tunforge-dns-cache-refresh.service" "$DNS_CACHE_SERVICE"

    # NetworkManager + resolved drop-ins
    run install -D -m 0644 "$src/nm/99-tunforge.conf"          "$NM_DROPIN"
    run install -D -m 0644 "$src/resolved/tunforge.conf"       "$RESOLVED_DROPIN"

    # NetworkManager dispatcher hook. NM refuses to run dispatcher scripts that
    # are group- or world-writable, or not owned by root, so the mode and
    # ownership here are load-bearing rather than cosmetic.
    run install -D -m 0755 -o root -g root \
        "$src/nm/50-tunforge-dot" "$NM_DISPATCHER"

    # Templates
    run install -D -m 0644 "$src/etc/templates/singbox-tun.json.tmpl" \
        "$ETCDIR/templates/singbox-tun.json.tmpl"

    # Directories with proper modes
    run install -d -m 0750 -o root -g root \
        "$ETCDIR" "$ETCDIR/profiles" "$ETCDIR/configs" \
        "$ETCDIR/configs/wireguard" "$ETCDIR/configs/openvpn" "$ETCDIR/configs/singbox" \
        "$ETCDIR/subscriptions" \
        "$VARDIR"
    run install -d -m 0700 -o root -g root "$ETCDIR/auth" "$ETCDIR/auth/openvpn"

    # Default global config (only if absent)
    if [[ ! -f "$ETCDIR/config.yaml" ]]; then
        run bash -c "cat > '$ETCDIR/config.yaml' <<'YAML'
# tunforge global configuration
# This file is informational; the TUI does not yet read it.
default_kill_switch: yes
default_ipv6: disable
log_level: info
YAML
        chmod 0640 '$ETCDIR/config.yaml'"
    fi

    # DNS direct-only allow-list (regex). Hosts matching any pattern are
    # resolved exclusively via direct public DNS (8.8.8.8, 1.1.1.1, ...)
    # and never via the system NSS resolver. Use it for VPN provider
    # domains your ISP DNS-poisons. Managed via `tunforge dns-direct`.
    if [[ ! -f "$ETCDIR/dns-direct" ]]; then
        run bash -c "cat > '$ETCDIR/dns-direct' <<'DIR'
# tunforge DNS direct-only allow-list
#
# One bash extended regex per line. Hosts matching ANY pattern below are
# resolved EXCLUSIVELY via direct UDP/TCP queries to public DNS
# (8.8.8.8, 1.1.1.1, 9.9.9.9, 208.67.222.222). The system NSS resolver
# is NOT consulted for these hosts - so if your ISP poisons their DNS,
# tunforge fails loudly with a clear DNS error instead of silently
# connecting to a fake IP.
#
# Comments  : lines starting with '#' or ';' are ignored
# Matching  : case-insensitive, regex matched against the FQDN
#
# Examples:
#   ^my\\.vpn\\.example\\.com\$
#   .*\\.censored-vpn\\.io\$
#   ^v[0-9]+\\.provider\\.net\$
#
# Manage via:
#   sudo tunforge dns-direct list
#   sudo tunforge dns-direct add '<regex>'
#   sudo tunforge dns-direct remove '<regex>'
#   sudo tunforge dns-direct test <hostname>
DIR
        chmod 0640 '$ETCDIR/dns-direct'"
    fi

    # DNS-over-TLS candidates for the direct (VPN-off) path. Only consulted
    # when plain UDP/53 turns out to be unusable - see dns.sh harden-direct.
    if [[ ! -f "$ETCDIR/dot-servers" ]]; then
        run bash -c "cat > '$ETCDIR/dot-servers' <<'DOT'
# tunforge DNS-over-TLS resolvers for the direct (VPN-off) path
#
# Some networks blackhole outbound UDP entirely - not just port 53 - while
# leaving TCP intact. A TCP-based VPN still works there, but the moment you
# disconnect, every plain DNS query times out: systemd-resolved speaks
# UDP/53 and degrades EDNS0 options, never the transport. FallbackDNS= does
# not help either, since resolved only consults it when a link has no
# servers at all.
#
# After a teardown, tunforge probes the direct path and - if plain DNS is
# genuinely dead - moves the WAN link onto DNS-over-TLS using the first two
# working entries below.
#
# Format   : one 'IP' or 'IP#hostname' per line
#            Without a hostname, the name is read from the server's own
#            certificate. Either way the certificate must pass full chain,
#            hostname and expiry validation, so a stale entry is simply
#            skipped rather than silently trusted.
# Comments : lines starting with '#' or ';' are ignored
# Order    : entries here are tried before the built-in list in dns.sh
#
# Examples:
#   1.1.1.1#cloudflare-dns.com
#   9.9.9.9#dns.quad9.net
#   185.51.200.1
DOT
        chmod 0640 '$ETCDIR/dot-servers'"
    fi

    ok "files deployed"
}

# ---------------------------------------------------------------------------
# Apply NM + resolved + systemd
# ---------------------------------------------------------------------------
apply_system() {
    say "applying NetworkManager & systemd-resolved drop-ins"
    if (( CHECK_ONLY )); then
        printf '%s[dry-run]%s would run %s/nm-tame.sh apply\n' "$_C_Y" "$_C_0" "$LIBDIR"
    else
        "$LIBDIR/nm-tame.sh" apply
    fi

    say "reloading systemd & enabling services"
    run systemctl daemon-reload
    run systemctl enable tunforge-killswitch.service
    run systemctl enable --now tunforge-dns-cache-refresh.timer
    # The dispatcher is D-Bus activated, so it shows as inactive until NM fires
    # an event - but it must be *enabled* or our 50-tunforge-dot hook is dead
    # code. Some minimal installs ship it masked.
    run systemctl enable NetworkManager-dispatcher.service
    ok "systemd: tunforge-killswitch.service and tunforge-dns-cache-refresh.timer enabled"
}

# ---------------------------------------------------------------------------
# Examples (only on first install)
# ---------------------------------------------------------------------------
seed_examples() {
    local src; src="$(cd "$(dirname "$0")" && pwd)"
    local example_src="$src/etc/profiles"

    if [[ ! -d "$example_src" ]]; then return 0; fi

    local existing
    existing="$(find "$ETCDIR/profiles" -maxdepth 1 -type f -name '*.profile' 2>/dev/null | wc -l)"
    if (( existing > 0 )) && (( !REINSTALL )); then
        ok "profiles: $existing already present, not seeding examples"
        return
    fi

    say "seeding example profiles into $ETCDIR/profiles"
    local f
    shopt -s nullglob
    for f in "$example_src"/*.profile.example; do
        local name; name="$(basename "$f" .profile.example)"
        run install -D -m 0640 "$f" "$ETCDIR/profiles/${name}.profile.example"
    done
    shopt -u nullglob
    ok "examples seeded (rename *.profile.example -> *.profile to activate)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_v() {
    # Helper for the summary - reports a version line or "missing".
    local cmd="$1"; shift
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@" 2>/dev/null | head -n1
    else
        echo "missing"
    fi
}

print_summary() {
    local title="tunforge installation complete"
    if (( CHECK_ONLY )); then
        title="tunforge --check (dry run) summary"
    fi
    cat <<EOF

${_C_G}=========================================================================
$title
=========================================================================${_C_0}

Versions detected:
  wg              : $(_v wg --version)
  openvpn         : $(_v openvpn --version | awk '{print $1, $2}')
  sing-box        : $(_singbox_installed_version 2>/dev/null || echo "not installed")
  nft             : $(_v nft --version)
  resolvectl      : $(_v resolvectl --version)

Drop your config files into:
  WireGuard : $ETCDIR/configs/wireguard/<name>.conf   (chmod 600)
  OpenVPN   : $ETCDIR/configs/openvpn/<name>.ovpn
  sing-box  : $ETCDIR/configs/singbox/<name>.json     (V2Ray VMess/VLESS/Trojan etc.)

Then create a profile descriptor in:
  $ETCDIR/profiles/<name>.profile

Or just run the TUI which can create one for you:
  ${_C_B}sudo tunforge${_C_0}

Other handy commands:
  sudo tunforge connect <name>     # CLI connect
  sudo tunforge disconnect         # back to direct
  sudo tunforge status
  sudo tunforge doctor
  sudo tunforge logs               # live colorized journald
  sudo tunforge last-log           # transcript of the most recent connect attempt
  sudo tunforge test                # probe all servers (ping/TCP) + show rtt next to each
  sudo tunforge test <name>         # probe one profile only
  sudo tunforge dns-cache status    # show cached DNS results + time left (default 24h TTL)
  sudo tunforge dns-cache clear     # reset DNS cache (forces fresh resolution)
  sudo tunforge dns-cache refresh   # re-resolve all known-good hosts
  sudo tunforge openvpn-auth set <profile>   # save OpenVPN username/password
  sudo tunforge openvpn-auth status          # list saved OpenVPN credentials
  sudo tunforge purge               # BIG RED BUTTON: nuke ALL VPN state (recover from stuck)
  sudo tunforge purge-wg            # narrower: WireGuard-only purge
  sudo tunforge dns-direct list     # regex allow-list: matched hosts resolve via public DNS only
  sudo tunforge dns-direct add '<regex>'
  sudo tunforge dns-direct test <hostname>
  sudo tunforge import '<uri>'     # import a vmess://, vless://, trojan://, ss:// URI

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
preflight
install_apt_deps
install_singbox
deploy_files
apply_system
seed_examples
print_summary
