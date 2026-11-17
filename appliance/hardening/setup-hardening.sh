#!/bin/bash
# Install the hardened security-camera stack on a Raspberry Pi 5 running
# Raspberry Pi OS Lite (64-bit, Debian 13 "trixie"), headless.
#
# Run with sudo from the account you created in Raspberry Pi Imager, after
# confirming that an SSH key works for that account:
#
#   cd appliance && sudo ./hardening/setup-hardening.sh
#
# The script is safe to re-run. A headless Pi has no easy console to recover
# from a firewall lockout, so SSH from the LAN stays open ("setup mode")
# until WireGuard has completed a handshake with at least one peer. Re-run
# the script after that and it closes SSH down to the VPN ("lockdown").
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WG_IF="wg0"

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
CAMERA_DEVICE="${CAMERA_DEVICE:-}"
SSH_MODE="auto"      # auto | lan | lockdown
LAN_SSH_CIDRS=""

usage() {
    cat <<'USAGE'
Usage: sudo ./hardening/setup-hardening.sh [options]

  --admin-user=NAME  Account allowed to log in over SSH.
                     Default: the user who ran sudo.
  --camera=DEVICE    V4L2 device Motion should open.
                     Default: the first USB webcam under /dev/v4l/by-id.
  --lan-ssh[=CIDR]   Keep SSH reachable from the LAN (CIDR is detected from
                     the default route when omitted; several may be given,
                     comma-separated).
  --lockdown         SSH from WireGuard peers only. Refused unless a
                     WireGuard peer has completed a handshake.
  -h, --help         Show this help.

With neither --lan-ssh nor --lockdown the script locks down only when a
WireGuard peer has already completed a handshake, and otherwise leaves LAN
SSH open so a headless Pi cannot be locked out.
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

for arg in "$@"; do
    case "$arg" in
        --admin-user=*) ADMIN_USER="${arg#*=}" ;;
        --camera=*)     CAMERA_DEVICE="${arg#*=}" ;;
        --lan-ssh)      SSH_MODE="lan" ;;
        --lan-ssh=*)    SSH_MODE="lan"; LAN_SSH_CIDRS="${arg#*=}" ;;
        --lockdown)     SSH_MODE="lockdown" ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown option: $arg" ;;
    esac
done

(( EUID == 0 )) || die "Run this script as root (sudo)."

# ---------------------------------------------------------------------------
# Admin account. Raspberry Pi OS has no fixed default user any more; the
# account is whatever was entered in Raspberry Pi Imager.
# ---------------------------------------------------------------------------
[[ -n "$ADMIN_USER" ]] || die "Cannot tell which account is the admin user. Run through sudo from that account or pass --admin-user=NAME."
[[ "$ADMIN_USER" != "root" ]] || die "The admin user must be a normal account, not root (root SSH login is disabled). Pass --admin-user=NAME."
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Unexpected characters in user name '$ADMIN_USER'."
id "$ADMIN_USER" >/dev/null 2>&1 || die "User '$ADMIN_USER' does not exist."
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
[[ -n "$ADMIN_HOME" ]] || die "Cannot find the home directory of '$ADMIN_USER'."

if [[ ! -s "$ADMIN_HOME/.ssh/authorized_keys" ]]; then
    die "Refusing SSH hardening: $ADMIN_HOME/.ssh/authorized_keys is missing or empty. Password logins are about to be disabled, so install and test an SSH key for '$ADMIN_USER' first."
fi

# ---------------------------------------------------------------------------
# Platform sanity checks (warnings only).
# ---------------------------------------------------------------------------
MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
[[ "$MODEL" == *"Raspberry Pi 5"* ]] || warn "This does not look like a Raspberry Pi 5 (model: '${MODEL:-unknown}'). Continuing anyway."
# shellcheck disable=SC1091
CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
[[ "$CODENAME" == "trixie" ]] || warn "Written for Raspberry Pi OS based on Debian 13 (trixie); this system reports '${CODENAME:-unknown}'."

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
TMPDIR_RENDER="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_RENDER"' EXIT

valid_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

# Print the directly-connected IPv4 network of every interface that carries
# a default route (Ethernet and/or Wi-Fi), comma-separated.
detect_lan_cidrs() {
    local dev net out=""
    while read -r dev; do
        [[ -n "$dev" && "$dev" != "$WG_IF" ]] || continue
        while read -r net; do
            valid_cidr "$net" || continue
            [[ ",$out," == *",$net,"* ]] || out="${out:+$out,}$net"
        done < <(ip -4 -o route show dev "$dev" scope link 2>/dev/null | awk '{print $1}')
    done < <(ip -4 route show default 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u)
    printf '%s' "$out"
}

# True once at least one WireGuard peer has completed a handshake, i.e. the
# VPN is a proven way back in.
wireguard_proven() {
    command -v wg >/dev/null 2>&1 || return 1
    wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '$2 > 0 {found = 1} END {exit !found}'
}

detect_camera() {
    local path
    for path in /dev/v4l/by-id/usb-*-video-index0; do
        if [[ -e "$path" ]]; then
            printf '%s' "$path"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
echo "== Installing packages =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    motion ffmpeg wireguard-tools nftables fail2ban python3-systemd \
    unattended-upgrades v4l-utils psmisc

# ---------------------------------------------------------------------------
# Decide how SSH is exposed before touching the firewall.
# ---------------------------------------------------------------------------
case "$SSH_MODE" in
    lockdown)
        wireguard_proven || die "--lockdown refused: no WireGuard peer has completed a handshake on $WG_IF. Bring the tunnel up and connect a client first (sudo wg show), otherwise this headless Pi would be unreachable."
        ;;
    auto)
        if wireguard_proven; then
            SSH_MODE="lockdown"
        else
            SSH_MODE="lan"
        fi
        ;;
esac

LAN_SSH_RULE=""
if [[ "$SSH_MODE" == "lan" ]]; then
    [[ -n "$LAN_SSH_CIDRS" ]] || LAN_SSH_CIDRS="$(detect_lan_cidrs)"
    [[ -n "$LAN_SSH_CIDRS" ]] || die "Could not detect the LAN network from the default route. Re-run with --lan-ssh=CIDR, for example --lan-ssh=192.168.1.0/24."
    IFS=',' read -r -a _cidrs <<< "$LAN_SSH_CIDRS"
    for _c in "${_cidrs[@]}"; do
        valid_cidr "$_c" || die "'$_c' is not an IPv4 CIDR such as 192.168.1.0/24."
    done
    LAN_SSH_RULE="ip saddr { ${LAN_SSH_CIDRS//,/, } } tcp dport 22 accept"
fi

# ---------------------------------------------------------------------------
echo "== Creating service users/storage =="
id motion >/dev/null 2>&1 || die "motion user not found after package install"
install -d -o motion -g motion -m 0750 /var/lib/security-cam
install -d -o motion -g motion -m 0750 /var/lib/security-cam/ring
install -d -o motion -g motion -m 0750 /var/lib/security-cam/saved_events
# Motion writes its own logfile here. Debian's package does not necessarily
# create this directory with permissions suitable for the motion service.
install -d -o motion -g motion -m 0750 /var/log/motion
install -d -o root -g root -m 0755 /opt/security-cam
install -d -o root -g root -m 0755 /etc/security-cam

# Keep retention limits that were tuned on a previous run.
if [[ ! -e /etc/security-cam/storage.conf ]]; then
    cat >/etc/security-cam/storage.conf <<'STORAGE'
# Recording retention limits. Tune these for the size of the recording drive.
# The minimum-free-space floor is an independent safety net.
MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2
STORAGE
fi
chmod 0644 /etc/security-cam/storage.conf

# ---- Motion configuration, pointed at the USB webcam ----
if [[ -z "$CAMERA_DEVICE" ]]; then
    if CAMERA_DEVICE="$(detect_camera)"; then
        echo "Camera: $CAMERA_DEVICE"
    else
        CAMERA_DEVICE="/dev/video0"
        warn "No USB webcam found under /dev/v4l/by-id; falling back to /dev/video0. Plug the camera in and re-run, or pass --camera=DEVICE."
    fi
fi
[[ "$CAMERA_DEVICE" =~ ^/dev/[A-Za-z0-9._:/+-]+$ ]] || die "--camera must be a plain /dev path, for example /dev/video0."
sed "s|^video_device .*|video_device $CAMERA_DEVICE|" \
    "$PROJECT_ROOT/motion/motion.conf" >"$TMPDIR_RENDER/motion.conf"
grep -qx "video_device $CAMERA_DEVICE" "$TMPDIR_RENDER/motion.conf" || die "failed to set video_device in motion.conf"
# When the file changes, a numbered backup (motion.conf.~N~) keeps whatever
# was there before, including detection tuning from a previous install.
if ! cmp -s "$TMPDIR_RENDER/motion.conf" /etc/motion/motion.conf; then
    install --backup=numbered -o root -g root -m 0644 "$TMPDIR_RENDER/motion.conf" /etc/motion/motion.conf
fi
install -d -o root -g root -m 0755 /etc/systemd/system/motion.service.d
install -o root -g root -m 0644 "$PROJECT_ROOT/motion/motion-service-override.conf" \
    /etc/systemd/system/motion.service.d/10-security-cam.conf

install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/segment-ring.sh" /opt/security-cam/segment-ring.sh
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/save-event.sh" /opt/security-cam/save-event.sh
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/prune-saved-events.sh" /opt/security-cam/prune-saved-events.sh
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/security-cam-ctl" /usr/local/sbin/security-cam-ctl
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/security-cam-ssh-control" /usr/local/sbin/security-cam-ssh-control

# Motion owns the footage and ring directories; root owns executables.
# If the recording drive is already mounted here, these permissions are
# applied to that filesystem. If it is mounted later, re-run the documented
# storage permission commands after mounting it.
chown motion:motion /var/lib/security-cam
chown -R motion:motion /var/lib/security-cam/ring /var/lib/security-cam/saved_events
chmod 0750 /var/lib/security-cam /var/lib/security-cam/ring /var/lib/security-cam/saved_events

if ! mountpoint -q /var/lib/security-cam; then
    warn "/var/lib/security-cam is not a separate mounted filesystem."
    warn "The recorder scripts will refuse to write until the recording drive is mounted there."
fi

install -o root -g root -m 0644 "$PROJECT_ROOT/security-cam/segment-ring.service" /etc/systemd/system/segment-ring.service
install -o root -g root -m 0644 "$PROJECT_ROOT/security-cam/prune-saved-events.service" /etc/systemd/system/prune-saved-events.service
install -o root -g root -m 0644 "$PROJECT_ROOT/security-cam/prune-saved-events.timer" /etc/systemd/system/prune-saved-events.timer

# ---------------------------------------------------------------------------
# Render and validate the security configuration BEFORE installing it, so a
# mistake cannot leave the Pi with a broken sudo, firewall or sshd.
# ---------------------------------------------------------------------------
echo "== Validating configuration =="

sed "s|@ADMIN_USER@|$ADMIN_USER|g" "$PROJECT_ROOT/hardening/sudoers-security-cam" >"$TMPDIR_RENDER/sudoers"
visudo -cf "$TMPDIR_RENDER/sudoers"

# The marker line becomes the LAN rule in setup mode and is dropped in
# lockdown.
if [[ -n "$LAN_SSH_RULE" ]]; then
    sed "s|^\( *\)# @LAN_SSH_RULE@.*|\1$LAN_SSH_RULE|" \
        "$PROJECT_ROOT/hardening/nftables.conf" >"$TMPDIR_RENDER/nftables.conf"
    grep -qF -- "$LAN_SSH_RULE" "$TMPDIR_RENDER/nftables.conf" || die "failed to add the LAN SSH rule to nftables.conf"
else
    sed '/# @LAN_SSH_RULE@/d' "$PROJECT_ROOT/hardening/nftables.conf" >"$TMPDIR_RENDER/nftables.conf"
fi
if grep -q '@LAN_SSH_RULE@' "$TMPDIR_RENDER/nftables.conf"; then
    die "nftables.conf still contains the @LAN_SSH_RULE@ marker"
fi
nft -c -f "$TMPDIR_RENDER/nftables.conf"

sed "s|@ADMIN_USER@|$ADMIN_USER|g" "$PROJECT_ROOT/hardening/sshd-security.conf" >"$TMPDIR_RENDER/sshd.conf"

install -o root -g root -m 0440 "$TMPDIR_RENDER/sudoers" /etc/sudoers.d/security-cam
install -o root -g root -m 0644 "$TMPDIR_RENDER/nftables.conf" /etc/nftables.conf
install -o root -g root -m 0644 "$PROJECT_ROOT/hardening/sysctl-hardening.conf" /etc/sysctl.d/99-security-cam.conf
install -o root -g root -m 0644 "$PROJECT_ROOT/hardening/fail2ban-security-cam.local" /etc/fail2ban/jail.d/security-cam.local

# sshd: the drop-in must sort before cloud-init's 50-cloud-init.conf (first
# value wins). Remove the file name used by the BeagleBone version.
SSHD_DROPIN=/etc/ssh/sshd_config.d/01-security-cam.conf
rm -f /etc/ssh/sshd_config.d/90-security-cam.conf
install -o root -g root -m 0644 "$TMPDIR_RENDER/sshd.conf" "$SSHD_DROPIN"
if ! /usr/sbin/sshd -t; then
    rm -f "$SSHD_DROPIN"
    die "sshd rejected the new configuration; it has been removed again and SSH is unchanged."
fi
# Confirm the settings really are the effective ones.
SSHD_EFFECTIVE="$(/usr/sbin/sshd -T 2>/dev/null || true)"
for want in "passwordauthentication no" "permitrootlogin no" "allowusers $ADMIN_USER"; do
    if ! grep -qix -- "$want" <<< "$SSHD_EFFECTIVE"; then
        rm -f "$SSHD_DROPIN"
        die "sshd would not apply '$want' - another file in /etc/ssh/sshd_config or sshd_config.d overrides it. The drop-in was removed; fix the override and re-run."
    fi
done

# ---------------------------------------------------------------------------
echo "== Applying kernel, firewall and service settings =="
sysctl --system >/dev/null

# Debian security updates only. Raspberry Pi kernel/firmware packages are not
# upgraded automatically; run "sudo apt full-upgrade" yourself now and then.
if [[ ! -e /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT
fi

systemctl enable nftables
nft -f /etc/nftables.conf
# nftables.conf starts with "flush ruleset", which also removes Fail2Ban's
# own table; restart Fail2Ban so it re-creates it.
systemctl enable fail2ban
systemctl restart fail2ban
systemctl enable --now unattended-upgrades
# mDNS is firewalled off anyway: after this, reach the Pi by IP address
# rather than <hostname>.local.
systemctl disable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null || true
systemctl disable --now bluetooth.service 2>/dev/null || true

# Reload SSH rather than restarting it. Keep your existing SSH session open
# while you test a new one from another terminal.
systemctl reload ssh

echo "== Motion / ring services =="
systemctl daemon-reload
systemctl enable motion.service segment-ring.service prune-saved-events.timer
# Restart rather than start: the Debian package starts Motion with its stock
# configuration as soon as it is installed.
systemctl restart motion.service
systemctl restart segment-ring.service
systemctl start prune-saved-events.timer

# One immediate retention pass keeps an old installation from consuming the
# entire drive while the new service is being enabled.
if mountpoint -q /var/lib/security-cam; then
    runuser -u motion -- /opt/security-cam/prune-saved-events.sh || true
fi

# The Raspberry Pi kernel ships the WireGuard module; this only catches
# custom kernels.
if ! modprobe wireguard 2>/dev/null; then
    warn "modprobe wireguard failed. Check the running kernel before relying on WireGuard."
fi

cat <<INFO

== Installation complete ==

Admin user:  $ADMIN_USER
Camera:      $CAMERA_DEVICE

Camera control:
  sudo /usr/local/sbin/security-cam-ctl on
  sudo /usr/local/sbin/security-cam-ctl off
  sudo /usr/local/sbin/security-cam-ctl status

Remote access policy:
  - WireGuard UDP 51820 is open on every interface.
  - The camera stream is accepted only from 10.10.10.0/24 on $WG_IF.
  - Motion webcontrol is localhost-only.
  - SSH password logins are disabled; only '$ADMIN_USER' may log in.
INFO

if [[ "$SSH_MODE" == "lan" ]]; then
    cat <<INFO
  - SETUP MODE: SSH is still accepted from the LAN ($LAN_SSH_CIDRS)
    as well as from $WG_IF.

Next: configure WireGuard, connect one client, confirm
"sudo wg show" lists a handshake and that "ssh $ADMIN_USER@10.10.10.1" works,
then close LAN SSH with:

  sudo ./hardening/setup-hardening.sh --lockdown
INFO
else
    cat <<INFO
  - LOCKDOWN: SSH is accepted only from 10.10.10.0/24 on $WG_IF.

Before closing your current session, open a NEW SSH connection through the
VPN (ssh $ADMIN_USER@10.10.10.1) to prove the way back in works. To re-open
LAN SSH later, run this script again with --lan-ssh.
INFO
fi
