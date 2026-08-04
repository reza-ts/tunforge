#!/usr/bin/env bash
# tunforge uninstall.sh - mirrors install.sh.

set -o errexit
set -o nounset
set -o pipefail

PURGE_USER_DATA=0
ASSUME_YES=0
while (($#)); do
    case "$1" in
        --purge)  PURGE_USER_DATA=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) cat <<EOF
usage: uninstall.sh [--purge] [--yes]
  --purge   also remove /etc/tunforge and /var/lib/tunforge (user data)
  --yes     do not prompt
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

if [[ -t 1 ]]; then
    _C_B=$'\033[1;36m'; _C_Y=$'\033[33m'; _C_G=$'\033[32m'; _C_0=$'\033[0m'
else
    _C_B=''; _C_Y=''; _C_G=''; _C_0=''
fi
say()  { printf '%s▸%s %s\n' "$_C_B" "$_C_0" "$*"; }
warn() { printf '%s⚠️%s %s\n' "$_C_Y" "$_C_0" "$*"; }
ok()   { printf '%s✅%s %s\n' "$_C_G" "$_C_0" "$*"; }

# 1) Disconnect any active session
if command -v tunforge >/dev/null 2>&1; then
    say "disconnecting any active tunforge session"
    tunforge disconnect 2>/dev/null || true
fi

# 2) Stop/disable killswitch unit
say "removing systemd units"
systemctl disable --now tunforge-killswitch.service 2>/dev/null || true
rm -f /etc/systemd/system/tunforge-killswitch.service
rm -f /etc/systemd/system/tunforge@.service
systemctl daemon-reload

# 3) Revert NM + resolved drop-ins (restores resolv.conf backup if any)
say "removing NetworkManager dispatcher hook"
rm -f /etc/NetworkManager/dispatcher.d/50-tunforge-dot
# Drop the remembered DNS-over-TLS servers too, otherwise nothing would ever
# clear them and the next tool to read /var/lib/tunforge would see stale state.
rm -f /var/lib/tunforge/dot-active

if [[ -x /usr/local/lib/tunforge/nm-tame.sh ]]; then
    /usr/local/lib/tunforge/nm-tame.sh revert || true
else
    rm -f /etc/NetworkManager/conf.d/99-tunforge.conf
    rm -f /etc/systemd/resolved.conf.d/tunforge.conf
    systemctl restart systemd-resolved 2>/dev/null || true
fi

# 4) Remove binaries + libs
say "removing binaries and library"
rm -f /usr/local/bin/tunforge /usr/local/bin/tunforge-logs /usr/local/bin/tunforge-import /usr/local/bin/tunforge-subscription /usr/local/bin/tunforge-scaffold
rm -rf /usr/local/lib/tunforge

# 5) Optional purge of user data
if (( PURGE_USER_DATA )); then
    if (( ! ASSUME_YES )); then
        read -r -p "Really delete /etc/tunforge and /var/lib/tunforge? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { warn "skipped"; PURGE_USER_DATA=0; }
    fi
fi
if (( PURGE_USER_DATA )); then
    say "purging /etc/tunforge /var/lib/tunforge /run/tunforge"
    rm -rf /etc/tunforge /var/lib/tunforge /run/tunforge
fi

cat <<EOF

${_C_G}tunforge removed.${_C_0}

Apt packages NOT removed (they may be used by other things). To remove them
manually if you want:
  apt-get purge wireguard-tools openvpn nftables whiptail jq dnsutils moreutils
  apt-get purge sing-box

EOF
