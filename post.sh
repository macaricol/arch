#!/usr/bin/env bash
# Post-install configuration: hardware drivers, KDE Plasma, theming, Samba,
# and gaming/AUR tools. Runs as the regular user (created by main.sh) after
# first login, using sudo for anything privileged.
set -euo pipefail
IFS=$'\n\t'

# ── Source utilities ─────────────────────────────────────────────────────
REPO_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/clauding"
UTILS_URL="$REPO_URL/utils.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
curl -fsSL -o "${SCRIPT_DIR}/utils.sh" "$UTILS_URL"
source "${SCRIPT_DIR}/utils.sh" || { echo "Failed to load utils.sh" >&2; exit 1; }

# ── PRE-FLIGHT ────────────────────────────────────────────────────────
preflight_checks() {
  info "Running pre-flight checks..."
  (( EUID != 0 )) || die "Run this as your regular user (it uses sudo itself), not as root"
  ping -c1 -W3 archlinux.org &>/dev/null || die "No network connectivity"
}
preflight_checks

# Prompt for the sudo password once, up front, instead of mid-way through a
# spinner (run() backgrounds commands, which would otherwise garble the
# first password prompt) — everything after this reuses the cached ticket.
info "Requesting sudo access..."
sudo -v

# Keep that ticket alive for the whole script. Without this, sudo's default
# ~5-15 minute credential timeout can lapse partway through (this script has
# enough long steps to hit that), forcing a second password prompt that
# collides with whatever run() spinner is on screen at the time. -n refreshes
# without ever prompting; the loop dies on its own once this script exits.
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) &>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ── Hardware Setup ───────────────────────────────────────────────────────
clear
box "[1/13] Installing CPU microcode" 70 Ω
# || true: fall through to the catch-all case on unexpected/missing output
# instead of aborting the whole script under set -o pipefail.
cpu_vendor=$(lscpu | grep "Vendor ID" | awk '{print $3}') || true
case "$cpu_vendor" in
    GenuineIntel) run sudo pacman -S --noconfirm intel-ucode ;;
    AuthenticAMD) run sudo pacman -S --noconfirm amd-ucode ;;
    *) echo "Unknown CPU vendor: $cpu_vendor. Skipping microcode." ;;
esac
step_done

box "[2/13] Installing GPU drivers" 70 Ω
gpu_vendor=$(lspci | grep -E "VGA|3D" | grep -Ei "intel|amd|nvidia" | awk '{print tolower($0)}') || true
if [[ $gpu_vendor == *intel* ]]; then
    run sudo pacman -S --noconfirm mesa vulkan-intel intel-media-driver
elif [[ $gpu_vendor == *amd* ]]; then
    run sudo pacman -S --noconfirm mesa vulkan-radeon radeontop
elif [[ $gpu_vendor == *nvidia* ]]; then
    run sudo pacman -S --noconfirm nvidia nvidia-utils nvidia-settings opencl-nvidia
else
    echo "No supported GPU detected. Skipping GPU drivers."
fi
step_done

# ── KDE Plasma ───────────────────────────────────────────────────────────
# Package list lives in KDE_PACKAGES (utils.sh) — edit it there.
box "[3/13] Installing KDE Plasma essentials" 70 Ω
run sudo pacman -S --noconfirm "${KDE_PACKAGES[@]}"
step_done

# ── Extra Applications ───────────────────────────────────────────────────
# Package list lives in EXTRA_PACKAGES (utils.sh) — edit it there.
box "[4/13] Installing extra applications" 70 Ω
run sudo pacman -S --noconfirm "${EXTRA_PACKAGES[@]}"
step_done

# ── Quality of Life ──────────────────────────────────────────────────────
box "[5/13] Setting up fast boot (GRUB)" 70 Ω
sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sudo sed -i 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
run sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo sed -i '/echo/s/^/#/' /boot/grub/grub.cfg
step_done

box "[6/13] Setting mpv wheel controls" 70 Ω
sudo mkdir -p /etc/mpv
sudo tee /etc/mpv/input.conf > /dev/null << 'EOF'
WHEEL_UP      seek 10
WHEEL_DOWN    seek -10
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF
step_done

# ── SDDM Theme & Desktop Config ──────────────────────────────────────────
box "[7/13] Installing SDDM Astronaut theme" 70 Ω
# Clear out a previous partial attempt first — git clone refuses to target a
# non-empty directory.
sudo rm -rf /usr/share/sddm/themes/sddm-astronaut-theme
run sudo git clone -b master --depth 1 https://github.com/macaricol/sddm-astronaut-theme.git /usr/share/sddm/themes/sddm-astronaut-theme
sudo cp -r /usr/share/sddm/themes/sddm-astronaut-theme/Fonts/* /usr/share/fonts/
run sudo fc-cache -fv

sudo mkdir -p /etc/sddm.conf.d
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Theme --key Current sddm-astronaut-theme
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group General --key HaltCommand "/usr/bin/systemctl poweroff"
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group General --key RebootCommand "/usr/bin/systemctl reboot"
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Users --key MinimumUid 1000
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Users --key MaximumUid 60513
step_done

box "[8/13] Setting wallpaper, lock screen & keyboard" 70 Ω
WALLPAPER="file:///usr/share/sddm/themes/sddm-astronaut-theme/Wallpapers/cyberpunk2077.jpg"

kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key Image "$WALLPAPER"

XML="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"
sudo sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>$WALLPAPER</default>|" "$XML"

kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "pt"
kwriteconfig6 --file kxkbrc --group Layout --key Use "true"
step_done

# ── Samba ────────────────────────────────────────────────────────────────
box "[9/13] Setting up Samba file sharing" 70 Ω
sudo mkdir -p /var/lib/samba/usershares
sudo groupadd -r sambashare 2>/dev/null || true  # already exists on a re-run
sudo chown root:sambashare /var/lib/samba/usershares
sudo chmod 1770 /var/lib/samba/usershares
sudo gpasswd sambashare -a "$USER"

sudo tee /etc/samba/smb.conf > /dev/null << 'EOF'
[global]
   workgroup = WORKGROUP
   server string = Samba Server %v
   netbios name = %h
   security = user
   map to guest = Bad User
   dns proxy = no

   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
   usershare owner only = yes
EOF

run sudo systemctl enable --now smb nmb
step_done

# ── Multilib + Steam + AUR Tools ─────────────────────────────────────────
box "[10/13] Enabling multilib + installing Steam, Paru, Zen & qimgv" 70 Ω
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
run sudo pacman -Syyu --noconfirm steam base-devel

# makepkg/paru run unwrapped (no `run`) because both can shell out to their
# own internal `sudo` for build dependencies — a nested sudo prompt inside
# run()'s backgrounded, redirected subshell can't reliably reach the
# terminal and times out. Full build output stays visible here instead.
rm -rf paru  # leftover from a previous partial attempt, if any
run git clone https://aur.archlinux.org/paru.git
(cd paru && makepkg -si --noconfirm)
rm -rf paru
paru -S --noconfirm zen-browser-bin qimgv-git
step_done

# ── Final Steps ──────────────────────────────────────────────────────────
box "[11/13] Downloading KDE autostart script" 70 Ω
curl -s -o "$HOME/kde_init.sh" "$REPO_URL/kde_init.sh"
chmod +x "$HOME/kde_init.sh"

# Phase 2 = runs after the desktop shell is up, not during Plasma's own
# startup. Phase alone wasn't enough though — some files kde_init.sh depends
# on still weren't written yet when it fired. Phase only controls ordering,
# not timing, so the Exec line also sleeps 10s as a real delay before
# running it. kde_init.sh removes this file itself once it's run, so it
# only ever fires once.
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/kde_init.desktop" <<EOF
[Desktop Entry]
Type=Application
Exec=/bin/sh -c "sleep 10 && $HOME/kde_init.sh"
Hidden=false
NoDisplay=false
X-KDE-autostart-phase=2
Name=KDE Init
Comment=Applies first-login Plasma configuration tweaks
EOF
step_done

box "[12/13] Enabling Bluetooth" 70 Ω
run sudo systemctl enable --now bluetooth.service
step_done

box "[13/13] Enabling SDDM (final step)" 70 Ω
run sudo systemctl enable --now sddm
step_done

box "DONE! Reboot to see your new setup" 70 Ω
ask "Reboot now? [Y/n]: "; read -r do_reboot
if [[ $do_reboot =~ ^[Nn] ]]; then
  info "Skipping reboot — log out or reboot manually to apply everything."
else
  info "Rebooting..."
  sleep 2
  sudo reboot
fi
