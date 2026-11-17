# Raspberry Pi 5 Security Camera Setup Guide

This guide assumes:

- Raspberry Pi 5 running Raspberry Pi OS Lite (64-bit), the Debian 13 "trixie" based release, with no monitor or keyboard attached
- Ethernet networking (Wi-Fi also works)
- Microsoft LifeCam Cinema or another compatible USB UVC camera
- A dedicated recording drive: USB SSD, USB flash drive, or NVMe on an M.2 HAT
- Windows PC used for setup
- The official 27 W USB-C power supply (a webcam plus a USB drive can exceed the 600 mA USB budget the Pi 5 allows on a 3 A supply)

The intended final architecture is:

```text
Boot microSD holds:
 Raspberry Pi OS Lite
 Motion
 FFmpeg
 WireGuard
 nftables
 security-camera scripts

Recording drive holds:
/var/lib/security-cam
which contains the rolling buffer and saved events.
```

The recording scripts deliberately refuse to write if `/var/lib/security-cam` is not a mounted filesystem, i.e. if the recording drive is not detected, to prevent recordings from accidentally filling (and wearing out) the boot microSD.

**Read this first: there is no serial console to save you.** A headless Pi 5 that firewalls off SSH can only be recovered by plugging in a monitor (micro-HDMI) and USB keyboard. The installer is built around that: SSH from your LAN stays open until WireGuard is proven to work, and only then do you lock it down (step 18).

---

# 1. Flash the microSD

On your PC, generate a dedicated SSH key first, in Windows PowerShell:
```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\pi_security_cam"
```

This creates:
```text
pi_security_cam       # Private key
pi_security_cam.pub   # Public key
```

The private file must stay on your PC. Only the `.pub` file goes onto the Pi. Don't upload private keys anywhere.

In [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

- Device: `Raspberry Pi 5`
- OS: `Raspberry Pi OS (other)` > `Raspberry Pi OS Lite (64-bit)`
- In the customisation settings:
  - set a hostname, e.g. `pi-cam`
  - create your user name and a password (you will need the password for `sudo`)
  - Wi-Fi details, only if you are not using Ethernet
  - enable SSH with public-key authentication and paste the contents of `pi_security_cam.pub`

Throughout this guide `<user>` means the user name you chose here. There is no default `pi` or `debian` account.

Put the card in the Pi, connect Ethernet, the webcam and the recording drive (use the blue USB 3 ports for the drive), and power it on. The first boot takes a couple of minutes.

---

# 2. Connect to the Pi

Find the Pi's LAN IP address in your router's client list, or try its mDNS name from Windows PowerShell:
```powershell
ping pi-cam.local
```

Log in through SSH:
```powershell
ssh -i "$env:USERPROFILE\.ssh\pi_security_cam" <user>@<PI-LAN-IP>
```

If the key has a passphrase, this will ask for the SSH key passphrase.

Once logged in, note the address. The installer turns mDNS off, so `pi-cam.local` stops resolving later and you will need the IP:
```bash
hostname -I
```

Give the Pi a fixed address in your router (a DHCP reservation) so it does not move.

Bring the system up to date before installing anything:
```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Open a second SSH session after the reboot. Keep one session open during setup, especially while changing SSH or firewall settings.

---

# 3. Download the Project

Copy the project folder to the Pi. From Windows PowerShell, in the folder that contains `pi5-security-cam`:
```powershell
scp -i "$env:USERPROFILE\.ssh\pi_security_cam" -r pi5-security-cam <user>@<PI-LAN-IP>:
```

Or, if you have pushed it to your own Git repository:
```bash
sudo apt install -y git
cd ~
git clone <YOUR-REPO-URL> pi5-security-cam
```

Enter the project:
```bash
cd ~/pi5-security-cam
```

Check the files:
```bash
ls
```

Expected top-level contents include:
```text
README.md
guide.md
appliance/
    hardening/
    motion/
    security-cam/
    wireguard/
```

Optionally verify the included file manifest:
```bash
sha256sum -c MANIFEST.sha256
```

All files should report `OK`.

If the scripts were copied through Windows, make sure they are executable:
```bash
chmod +x appliance/hardening/setup-hardening.sh
```

---

# 4. Verify the Camera

Check USB detection:
```bash
lsusb
```

For the Microsoft LifeCam Cinema, expect something similar to:
```text
045e:075d Microsoft Corp. LifeCam Cinema
```

A Pi 5 creates many `/dev/video*` nodes for its own ISP and video decoder, so do not assume the webcam is `/dev/video0`. Look for its stable name instead:
```bash
ls -l /dev/v4l/by-id/
```

Expect an entry ending in `-video-index0`, for example:
```text
usb-Microsoft_Microsoft®_LifeCam_Cinema_TM_-video-index0 -> ../../video0
```

The installer finds this path by itself and writes it into Motion's configuration.

To check the camera's supported formats (`v4l2-ctl` is installed by the installer; run `sudo apt install -y v4l-utils` if you want it now):
```bash
v4l2-ctl --device=/dev/v4l/by-id/<YOUR-CAMERA>-video-index0 --list-formats-ext
```

The tested LifeCam configuration is MJPEG at `1280x720`, 15 FPS. If your camera does not offer that mode, change `width`, `height` and `framerate` in `appliance/motion/motion.conf` before installing. Avoid uncompressed formats, as they use far more USB bandwidth and CPU than necessary.

Do not continue if the camera is not detected. Without a UVC-compatible video source, the rest of the system will not work correctly. If the camera disconnects at random, suspect the power supply first.

---

# 5. Configure the Recording Drive

Be careful here. Identify the drives before formatting anything:
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
```

Typical names on a Pi 5:
```text
mmcblk0     boot microSD (mounted at / and /boot/firmware) - DO NOT FORMAT
sda         USB drive
nvme0n1     NVMe drive on an M.2 HAT
```

Never blindly copy device names or formatting commands from this guide without verifying them on your own board. The examples below use `/dev/sda1`; for NVMe it would be `/dev/nvme0n1p1`.

---

## 5.1 Format the Drive

If the drive already contains the desired ext4 filesystem, or you have data on it you'd like to save, skip this step.

Most new USB drives arrive with one FAT/exFAT partition. Assuming the recording partition is `/dev/sda1`:
```bash
sudo mkfs.ext4 -L SECURITY_CAM /dev/sda1
```

This destroys everything currently on that partition.

Get its UUID:
```bash
sudo blkid /dev/sda1
```

Example:
```text
UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
TYPE="ext4"
```

Copy the UUID.

---

## 5.2 Configure the Permanent Mount

Create the mount point:
```bash
sudo mkdir -p /var/lib/security-cam
```

Edit:
```bash
sudo nano /etc/fstab
```

Add:
```fstab
UUID=<YOUR_DRIVE_UUID> /var/lib/security-cam ext4 defaults,noatime,nofail 0 2
```

Save and exit.

Mount it, verify the mount, and check:
```bash
sudo systemctl daemon-reload
sudo mount -a

findmnt /var/lib/security-cam

df -h /var/lib/security-cam
```

You should see the recording drive, not the microSD root filesystem. Do not continue until this is correct.

`nofail` matters on a headless board: without it, a missing drive would stop the Pi from booting to the point where SSH works.

> No spare drive? You can record to the boot microSD by bind-mounting a directory onto the mount point, which satisfies the "must be a mount point" check: add `/srv/security-cam /var/lib/security-cam none bind,nofail 0 0` to `/etc/fstab` after `sudo mkdir -p /srv/security-cam`. This gives up the protection against filling and wearing the system card, so set `MAX_EVENT_GIB` and `MIN_FREE_GIB` conservatively.

---

# 6. Confirm SSH Public-Key Authentication

The hardening installer disables password logins and refuses to proceed unless your account already has an SSH authorized key. If you pasted the key into Raspberry Pi Imager it is already there:
```bash
cat ~/.ssh/authorized_keys
```

If it is empty or missing, add the key now from Windows PowerShell while password SSH still works:
```powershell
Get-Content "$env:USERPROFILE\.ssh\pi_security_cam.pub" |
ssh <user>@<PI-LAN-IP> 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
```

Test that the key alone is enough:
```powershell
ssh -i "$env:USERPROFILE\.ssh\pi_security_cam" `
    -o PasswordAuthentication=no `
    <user>@<PI-LAN-IP>
```

Do not run the installer until this works.

---

# 7. Run the Installer

From the project directory:
```bash
cd ~/pi5-security-cam/appliance/
```

Run:
```bash
sudo ./hardening/setup-hardening.sh
```

Run it with `sudo` from your own account (not from a root shell): the account that ran `sudo` becomes the only one allowed to log in over SSH. Use `--admin-user=NAME` to choose another.

The installer installs and configures:
```text
Motion
FFmpeg
WireGuard tools
nftables
Fail2Ban
python3-systemd
unattended-upgrades
v4l-utils, psmisc
SSH hardening
camera scripts
systemd units
```

It also creates:
```text
/opt/security-cam/
/etc/security-cam/
/var/log/motion/
/usr/local/sbin/security-cam-ctl
```

and applies the project's firewall and service configuration.

On this first run WireGuard is not set up yet, so the installer finishes in **setup mode**: everything is hardened, except that key-only SSH is still accepted from your LAN subnet. It prints the subnet it detected. If it cannot detect one, pass it yourself:
```bash
sudo ./hardening/setup-hardening.sh --lan-ssh=192.168.1.0/24
```

Open a new SSH session now to confirm you can still get in.

Automatic updates cover Debian security updates only. Raspberry Pi kernel and firmware packages are left alone; run `sudo apt full-upgrade` yourself occasionally.

---

# 8. Fix Recording-Storage Ownership

Because the storage is a separate filesystem, verify ownership after installation:
```bash
sudo chown motion:motion /var/lib/security-cam
sudo chmod 750 /var/lib/security-cam
```

Create/fix the required directories:
```bash
sudo install -d -o motion -g motion -m 0750 \
  /var/lib/security-cam/ring

sudo install -d -o motion -g motion -m 0750 \
  /var/lib/security-cam/saved_events
```

Verify Motion can write:
```bash
sudo -u motion touch /var/lib/security-cam/.write-test
sudo -u motion rm /var/lib/security-cam/.write-test
```

If both commands succeed silently, permissions are correct.

---

# 9. Verify Camera Services

Check:
```bash
sudo /usr/local/sbin/security-cam-ctl status
```

For a more in-depth check:
```bash
systemctl --no-pager --full status motion
systemctl --no-pager --full status segment-ring
systemctl status prune-saved-events.timer
```

If necessary, restart the services:
```bash
sudo /usr/local/sbin/security-cam-ctl restart
```

Confirm Motion opened the right device:
```bash
grep ^video_device /etc/motion/motion.conf
sudo tail -n 30 /var/log/motion/motion.log
```

---

# 10. Verify the Rolling Buffer

Wait roughly one minute, then inspect:
```bash
sudo ls -lh /var/lib/security-cam/ring
```

You should begin seeing AVI segment files. Old ones are discarded as new ones arrive (so long as motion was not triggered).

Check disk usage:
```bash
df -h /
df -h /var/lib/security-cam
```

The files should be consuming space from the recording drive rather than `/`. The root filesystem should remain essentially unchanged while video is being written.

A small amount of temporary variation on `/` is normal, but continuous growth is not. If it grows, stop the camera to avoid filling the microSD:
```bash
sudo /usr/local/sbin/security-cam-ctl off
```

---

# 11. Test Motion Detection

Move in front of the camera for a few seconds. Do a little dance. It's the home stretch now

Check the event log:
```bash
journalctl -t security-cam -n 20 --no-pager
```

Check event directories:
```bash
sudo find /var/lib/security-cam/saved_events \
  -maxdepth 2 -type f -ls
```

A triggered event should create a timestamped directory under:
```text
/var/lib/security-cam/saved_events/
```

The event collector writes in 30-second segments, so give it a minute or two before assuming it failed.

The preserved segments are initially hard links to completed rolling-buffer files. While the corresponding file still exists in the ring buffer, a link count greater than one is expected:
```bash
sudo ls -l /var/lib/security-cam/saved_events/*/*
```

After the source ring-buffer entry is eventually removed, the saved event file may correctly show a link count of `1`.

---

# 12. Configure WireGuard Keys

These are secrets. Keep them safe. Do not upload private keys or preshared keys anywhere.

Each device needs:
```text
A unique private key
A matching public key
A unique preshared key shared with the Pi
```

The intended VPN addresses are:
```text
Pi         10.10.10.1
iPhone     10.10.10.2
Desktop    10.10.10.3
Laptop     10.10.10.4
```

Public keys are safe to share when needed. Private keys and PSKs are not.

Generate the Pi's key pair and one preshared key per client on the Pi:
```bash
sudo -i
umask 077
cd /etc/wireguard
wg genkey | tee pi.key | wg pubkey > pi.pub
wg genpsk > phone.psk
wg genpsk > desktop.psk
wg genpsk > laptop.psk
exit
```

Each client generates its own key pair in its WireGuard app (or with the same `wg genkey | wg pubkey` commands) and gives you only its public key.

---

# 13. Pi WireGuard Configuration

Start with the Pi's conf. From `~/pi5-security-cam/appliance`:
```bash
sudo cp wireguard/pi_wg0.conf.example /etc/wireguard/wg0.conf
```

Secure it:
```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

Edit:
```bash
sudo nano /etc/wireguard/wg0.conf
```

The layout is:
```ini
[Interface]
Address = 10.10.10.1/24
ListenPort = 51820
PrivateKey = <PI_PRIVATE_KEY>

[Peer]
# iPhone
PublicKey = <COMPUTER1_PUBLIC_KEY>
PresharedKey = <COMPUTER1_PSK>
AllowedIPs = 10.10.10.2/32

[Peer]
# Desktop
PublicKey = <COMPUTER2_PUBLIC_KEY>
PresharedKey = <COMPUTER2_PSK>
AllowedIPs = 10.10.10.3/32

[Peer]
# Laptop
PublicKey = <COMPUTER3_PUBLIC_KEY>
PresharedKey = <COMPUTER3_PSK>
AllowedIPs = 10.10.10.4/32
```

The Pi receives each client's **public** key. Don't put a client's private key on the Pi.

Remove the `[Peer]` blocks you are not using; `wg-quick` will not start with placeholder keys left in the file.

---

# 14. Client WireGuard Configuration

Each client gets:
```text
Its own private key
The Pi's public key (sudo cat /etc/wireguard/pi.pub)
Its own PSK shared with the Pi
The Pi endpoint; for a LAN connection, the LAN IP can be used (recommended for initial setup).
```

Example desktop:
```ini
[Interface]
PrivateKey = <DESKTOP_PRIVATE_KEY>
Address = 10.10.10.3/32

[Peer]
PublicKey = <PI_PUBLIC_KEY>
PresharedKey = <DESKTOP_PSK>
Endpoint = <PI-ENDPOINT>:51820
AllowedIPs = 10.10.10.1/32
PersistentKeepalive = 25
```

iPhone:
```text
10.10.10.2/32
```

Desktop:
```text
10.10.10.3/32
```

Laptop:
```text
10.10.10.4/32
```

Remote cellular or laptop connections normally require a public endpoint and UDP port forwarding (UDP 51820 to the Pi's LAN IP), or another NAT-traversal solution such as Tailscale/ZeroTier.

If fewer peers are needed, remove them. If more are needed, add additional unique addresses and keys.

You can upload the .conf's directly to Windows' WireGuard GUI client.

---

# 15. Enable WireGuard

Once `/etc/wireguard/wg0.conf` is complete:
```bash
sudo systemctl enable --now wg-quick@wg0
```

Check:
```bash
sudo wg show
ip addr show wg0
```

The Pi should have:
```text
10.10.10.1/24
```

---

# 16. Test WireGuard Before Relying on It

Activate one client using its corresponding WireGuard configuration.

Testing on the same LAN first is recommended because it separates WireGuard configuration problems from router/port-forwarding problems.

On the Pi:
```bash
sudo wg show
```

A functioning peer should show:
```text
latest handshake: ...
transfer: ... received, ... sent
```

From the client:
```text
ping 10.10.10.1
```

And SSH through the tunnel:
```powershell
ssh -i "$env:USERPROFILE\.ssh\pi_security_cam" <user>@10.10.10.1
```

If the tunnel works over LAN but not from cellular/off-LAN, WireGuard itself is probably configured correctly. Check the public endpoint, router UDP forwarding, upstream NAT, or CGNAT. Make router changes as necessary, just don't expose more than you need to.

---

# 17. Configure the Windows SSH Shortcut

On Windows, edit:
```text
%USERPROFILE%\.ssh\config
```

Add:
```text
Host pi-cam
    HostName 10.10.10.1
    User <user>
    IdentityFile ~/.ssh/pi_security_cam
    PasswordAuthentication no
```

Then test, with the VPN connected:
```powershell
ssh pi-cam
```

Once this works, commands such as:
```powershell
scp pi-cam:/path/to/file .
```

will use the same VPN address and SSH key automatically.

---

# 18. Lock Down SSH

Only do this once `ssh pi-cam` works through the VPN. Keep that session open, then on the Pi:
```bash
cd ~/pi5-security-cam/appliance/
sudo ./hardening/setup-hardening.sh --lockdown
```

The installer refuses `--lockdown` unless `wg show` reports a completed handshake. Afterwards SSH is accepted only from WireGuard peers.

Open one more new `ssh pi-cam` session to prove it before closing the old ones.

If you would rather keep key-only SSH reachable from your LAN permanently, skip this step, or return to that state at any time with:
```bash
sudo ./hardening/setup-hardening.sh --lan-ssh
```

**If you do get locked out:** connect a monitor to a micro-HDMI port and a USB keyboard, log in on the console, and run the `--lan-ssh` command above.

---

# 19. Test the Live Camera Stream

With WireGuard connected, access the Motion stream using `http://10.10.10.1:8081/`. This can be input to a browser, and you should receive a camera feed.

Port `8081` is permitted only from the WireGuard interface by the nftables configuration.

The Motion administrative/control interface on port `8080` remains localhost-only.

---

# 20. Verify nftables

Check the firewall:
```bash
sudo nft -a list ruleset
```

The input chain should follow a default-drop policy.

Expected permitted traffic includes:
```text
loopback
established/related traffic
WireGuard UDP 51820
SSH from wg0
camera stream from wg0
limited ICMP
```

After step 18 there should be no rule accepting port 22 from your LAN subnet. (Fail2Ban adds a table of its own; that is expected.)

The final unmatched traffic rule should silently drop traffic rather than continuously logging it.

Validate the stored firewall configuration:
```bash
sudo nft -c -f /etc/nftables.conf
```

No output means the configuration parsed successfully.

---

# 21. Verify Fail2Ban and SSH

Check:
```bash
sudo systemctl status fail2ban
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

This project uses the systemd journal backend rather than a traditional SSH logfile.

Confirm the SSH settings that are really in effect:
```bash
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|allowusers)'
```

Expect `passwordauthentication no`, `permitrootlogin no` and `allowusers <user>`.

---

# 22. Verify Automatic Startup

The following should be enabled:
```bash
systemctl is-enabled motion.service
systemctl is-enabled segment-ring.service
systemctl is-enabled prune-saved-events.timer
systemctl is-enabled nftables
systemctl is-enabled fail2ban
systemctl is-enabled wg-quick@wg0
```

---

# 23. Reboot Test

Naturally, the application needs to recover correctly after a power loss.

Reboot:
```bash
sudo reboot now
```

Wait for the Pi to boot and reconnect to the network.

Reconnect:
```powershell
ssh pi-cam
```

Then check:
```bash
sudo /usr/local/sbin/security-cam-ctl status
findmnt /var/lib/security-cam
sudo wg show
systemctl --no-pager --full status motion segment-ring
```

Verify new rolling-buffer files are appearing:
```bash
sudo ls -lh /var/lib/security-cam/ring
```

Test the stream again, on a browser. `http://10.10.10.1:8081/`

A Pi 5 has no clock battery unless you fit one, so after a power cut it has the wrong time until it reaches the network. Event folder names are timestamps; fit the RTC battery if the Pi may boot without internet.

---

# 24. Critical Missing-Drive Test

The project is specifically designed not to silently fall back to the boot microSD.

A useful final test is to shut down, unplug the recording drive, and boot without it.

Check:
```bash
findmnt /var/lib/security-cam
```

If the drive is absent, it should not report a mounted recording filesystem. The recording scripts should refuse to write.

Check:
```bash
systemctl status segment-ring
journalctl -u segment-ring -n 50 --no-pager
```

The microSD root filesystem should not begin filling with video files.

Before recording again, plug the drive back in and verify:
```bash
sudo mount -a
findmnt /var/lib/security-cam
```

Then restart the camera services:
```bash
sudo /usr/local/sbin/security-cam-ctl restart
```

---

# 25. Final Health Check

Run:
```bash
echo "=== STORAGE ==="
findmnt /var/lib/security-cam
df -h /
df -h /var/lib/security-cam

echo
echo "=== CAMERA ==="
sudo /usr/local/sbin/security-cam-ctl status

echo
echo "=== WIREGUARD ==="
sudo wg show

echo
echo "=== FIREWALL ==="
sudo nft list chain inet filter input

echo
echo "=== SERVICES ==="
systemctl --no-pager --full status \
  motion \
  segment-ring \
  prune-saved-events.timer

echo
echo "=== POWER ==="
vcgencmd get_throttled
```

`throttled=0x0` means the power supply has been adequate since boot.

At this point the Pi and its services should be fully operational.

For normal operation, exporting recordings, clearing saved events, storage checks, and other day-to-day commands, see `README.md`.
