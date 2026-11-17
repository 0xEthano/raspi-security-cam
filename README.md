# Raspberry Pi 5 Networked Security Camera

A hardened home security camera application built around a Raspberry Pi 5, a USB UVC-compliant webcam, and Raspberry Pi OS Lite (64-bit, Debian 13 "trixie"), run headless.

This is a Raspberry Pi 5 port of [0xEthano/bbb-security-cam](https://github.com/0xEthano/bbb-security-cam), which targets the BeagleBone Black. See [What changed from the BeagleBone version](#what-changed-from-the-beaglebone-version).

It provides:

- 720p live camera streaming @ 15fps
- Motion-triggered recording, 6-minute post-trigger event capture
- Recording to a dedicated drive (USB SSD/flash drive or NVMe), separate from the boot microSD
- Remote administration over WireGuard, SSH restricted to WireGuard VPN peers
- nftables firewalling / [fail2ban](https://github.com/fail2ban/fail2ban) setup
- systemd-managed camera and recording services
- Auto saved event pruning and storage limits

The project was designed to run on limited resources, so video processing is avoided whenever possible. A Pi 5 has far more headroom than the original board, but the same low-overhead design keeps it cool and leaves the MJPG frames untouched.

For installation and initial configuration, see the project's setup guide.

**---**

## Hardware

Developed with:

- Raspberry Pi 5 (any RAM size) with a microSD card for the OS
- A USB UVC webcam (the original project used a Microsoft LifeCam Cinema)
- A dedicated recording drive, 32 GB or larger: USB SSD, USB flash drive, or NVMe on an M.2 HAT
- Ethernet (recommended) or Wi-Fi
- The official 27 W USB-C power supply. With a 5 V / 3 A supply the Pi 5 limits its USB ports to 600 mA in total, which a webcam plus a USB drive can exceed.

Not supported: Raspberry Pi Camera Modules on the CSI connectors. On a Pi 5 those are only reachable through libcamera, and the Motion package in Debian does not speak libcamera. Use a USB webcam.

Camera configuration:

- Resolution: `1280x720`
- Frame rate: `15 FPS`
- Camera format: hardware MJPG

The OS and application stack run from the boot microSD, while camera recordings are written to the dedicated recording drive.

**---**

## Software

This setup uses:

- [Raspberry Pi OS Lite (64-bit)](https://www.raspberrypi.com/software/operating-systems/), Debian 13 "trixie" based
- [Motion](https://motion-project.github.io/)
- [FFmpeg](https://ffmpeg.org/download.html)
- [WireGuard](https://www.wireguard.com/install/)
- [OpenSSH](https://www.openssh.org/)
- [nftables](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- [fail2ban](https://github.com/fail2ban/fail2ban)

**---**

# Architecture

The camera device is owned by Motion, which handles the video stream and motion detection.
A separate FFmpeg process reads Motion's local MJPG stream and maintains a rolling collection of 30-second video segments.
When Motion detects activity, the event collector preserves recent pre-trigger segments and continues collecting video for at least six minutes after the event trigger.

Saved events are stored under:

```text
/var/lib/security-cam/saved_events/
```

The rolling buffer is stored under:

```text
/var/lib/security-cam/ring/
```

`/var/lib/security-cam` is the mount point of the recording drive, so video recording never consumes (or wears out) the boot microSD. The recorder refuses to run if nothing is mounted there.

**---**

# Security Model

The system is configured with a default-deny firewall. External access is intended to occur only through WireGuard.

Because a headless Pi has no easy console to fall back on, the installer leaves SSH open to the LAN (key-only) until a WireGuard peer has actually connected, and closes it when you re-run it with `--lockdown`. See the setup guide.

The default VPN addresses are:

```text
Pi:             10.10.10.1
Computer 1:     10.10.10.2
Computer 2:     10.10.10.3
Computer 3:     10.10.10.4
```

Additional peers can be configured as needed.
SSH and the live camera stream are restricted to authenticated WireGuard peers.
The Motion control interface remains localhost-only.

**---**

# Camera Control

The main camera control utility is:

```bash
sudo /usr/local/sbin/security-cam-ctl {status|on|off|restart}
```

`status` reports the state of the segment-ring and Motion services.

`off` stops the camera/recording services.

`on` brings the camera system back online.

`restart` runs `off` then `on`.

**---**

# Check Storage

Check free space on the recording drive:
```bash
df -h /var/lib/security-cam
```

Inspect saved-event and rolling-buffer usage:
```bash
sudo du -sh /var/lib/security-cam/saved_events
sudo du -sh /var/lib/security-cam/ring
```

Confirm that the recording filesystem is actually mounted:
```bash
findmnt /var/lib/security-cam
```

**---**

# Export Saved Events to a PC

The event files are owned by the restricted `motion` account. To export them, stop camera activity and create an archive directly on the recording drive:
```bash
sudo /usr/local/sbin/security-cam-ctl off
```

```bash
sudo tar -cf /var/lib/security-cam/saved_events.tar \
  -C /var/lib/security-cam saved_events
```

MJPG video is already compressed, so an uncompressed `.tar` avoids unnecessary CPU usage.

Make the archive accessible to the normal SSH user:
```bash
sudo chown "$USER": /var/lib/security-cam/saved_events.tar
sudo chmod 600 /var/lib/security-cam/saved_events.tar
sudo chmod 751 /var/lib/security-cam
```

From Windows PowerShell:
```powershell
scp pi-cam:/var/lib/security-cam/saved_events.tar "$env:USERPROFILE\Videos\"
```

After confirming the transfer:
```bash
sudo rm -f /var/lib/security-cam/.current_event
sudo rm -f /var/lib/security-cam/saved_events.tar
sudo chmod 750 /var/lib/security-cam
sudo /usr/local/sbin/security-cam-ctl on
```

**---**

# Clearing Saved Events

Stop the services that write to the recording drive:
```bash
sudo systemctl stop segment-ring.service motion.service prune-saved-events.timer
```

Confirm that nothing is actively writing:
```bash
sudo fuser -vm \
  /var/lib/security-cam/saved_events \
  /var/lib/security-cam/ring
```

A kernel mount entry for `/var/lib/security-cam` is normal.

Remove all saved events while preserving the directory itself:
```bash
sudo find /var/lib/security-cam/saved_events \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

Optionally clear the rolling buffer:
```bash
sudo find /var/lib/security-cam/ring \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

And the created saved_events.tar if present:
```bash
sudo rm -f /var/lib/security-cam/saved_events.tar
```

Restore ownership and permissions:
```bash
sudo chown motion:motion \
  /var/lib/security-cam/ring \
  /var/lib/security-cam/saved_events
```

```bash
sudo chmod 750 \
  /var/lib/security-cam/ring \
  /var/lib/security-cam/saved_events \
  /var/lib/security-cam
```

Restart recording:
```bash
sudo systemctl start motion.service
sudo systemctl start segment-ring.service
sudo systemctl start prune-saved-events.timer
```

**---**

# Storage Retention

Saved-event retention is configured through:
```text
/etc/security-cam/storage.conf
```

Default:
```text
MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2
```

The pruning service periodically removes old recordings according to these limits.

**---**

# Important Paths

```text
*Configuration:
/etc/motion/motion.conf
/etc/nftables.conf
/etc/security-cam/storage.conf
/etc/wireguard/wg0.conf

*Project:
/opt/security-cam/

*Camera control:
/usr/local/sbin/security-cam-ctl

*Video storage:
/var/lib/security-cam/ring/
/var/lib/security-cam/saved_events/
```

**---**

# Design Goals

The project prioritizes:

1. Low CPU usage
2. Minimal writes to the boot microSD
3. Automatic recording to removable storage when motion is detected
4. Secure, hardened remote access
5. No publicly exposed camera or SSH interfaces
6. Automatic recovery after reboot
7. Service isolation using systemd
8. Simple maintenance through standard/builtin Linux utilities

# What changed from the BeagleBone version

- **Admin account.** Nothing assumes a `debian` user. The installer uses the account that ran `sudo` (the one created in Raspberry Pi Imager) for `AllowUsers` and the sudoers rule, or `--admin-user=NAME`.
- **No lockout on a headless board.** The BBB has a USB serial console to recover with; a Pi 5 does not. SSH from the LAN stays open until WireGuard has a handshake, then `--lockdown` closes it.
- **SSH hardening that actually wins.** The sshd drop-in is installed as `01-security-cam.conf`. Raspberry Pi OS provisions with cloud-init, whose `50-cloud-init.conf` can set `PasswordAuthentication yes` and would override the original `90-` file. The installer also checks the effective settings with `sshd -T`.
- **Camera device.** A Pi 5 has many `/dev/video*` nodes of its own, so the installer points Motion at the webcam's stable `/dev/v4l/by-id/...` path instead of assuming `/dev/video0`.
- **Storage.** Recordings go to a USB/NVMe drive instead of a second SD slot; the boot microSD plays the role of the eMMC.
- **Motion service.** A systemd drop-in creates `/run/motion` and restarts Motion on failure, and the installer restarts Motion so the new config replaces the package default.
- **True 30-second segments.** Motion's stream has no timestamps, so FFmpeg assumed 25 fps and each "30-second" segment actually spanned 50 seconds at 15 fps (and played back fast). The ring writer now timestamps frames by arrival time, so segments, pre-roll and the six-minute post-trigger window match what this README describes.
- **Fixes carried along.** The prune timer's unit no longer fails when no event is active, sudoers/nftables are validated before they are installed, and re-running the installer keeps `storage.conf` and backs up `motion.conf`.

**---**

# Block Diagram

Diagram of the original BeagleBone project; the architecture is unchanged. Created by gitdiagram.com.

[![Architecture diagram of 0xethano/bbb-security-cam](https://gitdiagram.com/0xethano/bbb-security-cam/diagram.png)](https://gitdiagram.com/0xethano/bbb-security-cam?utm_source=readme&utm_medium=picture)