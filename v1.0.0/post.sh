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
  require_network
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

# The AUR step grants this user passwordless `sudo pacman` just for its builds
# and removes it again itself; the trap is only a backstop in case that step
# dies partway through.
SUDOERS_DROPIN=/etc/sudoers.d/99-post-install-temp
STEP_TOTAL=14

trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; sudo rm -f "$SUDOERS_DROPIN"' EXIT

# ── Repositories ─────────────────────────────────────────────────────────
clear
step "Enabling multilib & updating the system"
# Must precede the GPU step, which installs 32-bit drivers from multilib.
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
run sudo pacman -Syu --noconfirm
step_done

# ── Hardware Setup ───────────────────────────────────────────────────────
step "Installing CPU microcode"
# || true: fall through to the catch-all case on unexpected/missing output
# instead of aborting the whole script under set -o pipefail.
cpu_vendor=$(lscpu | grep "Vendor ID" | awk '{print $3}') || true
case "$cpu_vendor" in
    GenuineIntel) run sudo pacman -S --needed --noconfirm intel-ucode ;;
    AuthenticAMD) run sudo pacman -S --needed --noconfirm amd-ucode ;;
    *) echo "Unknown CPU vendor: $cpu_vendor. Skipping microcode." ;;
esac
step_done

step "Installing GPU drivers"
# One independent check per vendor (not if/elif) so hybrid laptops get both.
# The lib32 packages are not optional: steam depends on the virtual
# lib32-vulkan-driver / lib32-libgl, and with --noconfirm pacman takes the
# first provider it finds — lib32-nvidia-utils, which drags the whole NVIDIA
# userspace onto AMD/Intel machines — unless the right one is already there.
gpus=$(lspci | grep -E "VGA|3D" | awk '{print tolower($0)}') || true
gpu_found=0
if [[ $gpus == *intel* ]]; then
    run sudo pacman -S --needed --noconfirm mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver
    gpu_found=1
fi
if [[ $gpus == *amd* ]]; then
    run sudo pacman -S --needed --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon radeontop
    gpu_found=1
fi
if [[ $gpus == *nvidia* ]]; then
    run sudo pacman -S --needed --noconfirm nvidia nvidia-utils lib32-nvidia-utils nvidia-settings opencl-nvidia
    gpu_found=1
fi
if (( ! gpu_found )); then
    # VMs and unrecognised hardware: plain mesa only. No software Vulkan here —
    # a 64-bit Vulkan device (vulkan-swrast) makes the SDDM theme's video
    # background render blank under VirtualBox, and lib32-vulkan-swrast can't
    # be installed without it. Steam is skipped below for the same reason.
    echo "No Intel/AMD/NVIDIA GPU detected — installing generic mesa only."
    run sudo pacman -S --needed --noconfirm mesa lib32-mesa
fi
step_done

# ── KDE Plasma ───────────────────────────────────────────────────────────
# Package list lives in KDE_PACKAGES (utils.sh) — edit it there.
step "Installing KDE Plasma essentials"
run sudo pacman -S --needed --noconfirm "${KDE_PACKAGES[@]}"
step_done

# ── Extra Applications ───────────────────────────────────────────────────
# Package list lives in EXTRA_PACKAGES (utils.sh) — edit it there.
step "Installing extra applications"
run sudo pacman -S --needed --noconfirm "${EXTRA_PACKAGES[@]}"
step_done

# ── Quality of Life ──────────────────────────────────────────────────────
step "Setting up fast boot (GRUB)"
sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sudo sed -i 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
run sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo sed -i '/echo/s/^/#/' /boot/grub/grub.cfg
step_done

step "Setting mpv wheel controls"
sudo mkdir -p /etc/mpv
sudo tee /etc/mpv/input.conf > /dev/null << 'EOF'
WHEEL_UP      seek 10
WHEEL_DOWN    seek -10
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF
step_done

# ── SDDM Theme & Desktop Config ──────────────────────────────────────────
step "Installing SDDM Astronaut theme"
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

step "Setting wallpaper, lock screen & keyboard"
WALLPAPER="file:///usr/share/sddm/themes/sddm-astronaut-theme/Wallpapers/cyberpunk2077.jpg"

kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key Image "$WALLPAPER"

XML="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"
sudo sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>$WALLPAPER</default>|" "$XML"

kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "pt"
kwriteconfig6 --file kxkbrc --group Layout --key Use "true"
step_done

# ── Samba ────────────────────────────────────────────────────────────────
step "Setting up Samba file sharing"
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

# ── Steam + AUR Tools ────────────────────────────────────────────────────
step "Installing Steam, Paru, Zen & qimgv"
info "Hang tight, this one takes a while to complete..."
run sudo pacman -S --needed --noconfirm base-devel
if (( gpu_found )); then
    run sudo pacman -S --needed --noconfirm steam
else
    # Without a real GPU driver there's no 32-bit Vulkan provider for steam
    # except lib32-nvidia-utils (which --noconfirm would pick) or software
    # Vulkan (which breaks the login screen's video). Neither is worth it.
    echo "No supported GPU — skipping Steam."
fi

# makepkg's internal `sudo pacman` calls (dependency install, then the final
# `pacman -U` after building) don't pick up the cached ticket no matter how
# it's shared — tried making it tty-independent and that didn't help either.
# Sidestepping that mystery entirely: let this user run pacman via sudo
# without a password, scoped to just that one binary and just to this step.
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" | sudo tee "$SUDOERS_DROPIN" > /dev/null
sudo chmod 440 "$SUDOERS_DROPIN"
sudo visudo -c -f "$SUDOERS_DROPIN" > /dev/null || die "Generated sudoers drop-in is invalid"

if command -v paru &>/dev/null; then
    info "paru already installed — skipping build"
else
    # Built from source on purpose: paru-bin is compiled against a fixed
    # libalpm and breaks whenever pacman bumps its ABI (it has been flagged
    # out-of-date for months). -r removes the Rust toolchain again afterwards.
    build_dir=$(mktemp -d)
    run git clone --depth 1 https://aur.archlinux.org/paru.git "$build_dir"
    (cd "$build_dir" && run makepkg -sri --noconfirm)
    rm -rf "$build_dir"
fi
run paru -S --needed --noconfirm zen-browser-bin qimgv-git

sudo rm -f "$SUDOERS_DROPIN"
step_done

# ── Final Steps ──────────────────────────────────────────────────────────
step "Downloading KDE autostart script"
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

step "Enabling Bluetooth"
run sudo systemctl enable --now bluetooth.service
step_done

step "Enabling SDDM (final step)"
# No --now: sddm.service conflicts with getty@tty1, so starting it here would
# SIGHUP the autologin session this script runs in, killing it before the
# reboot prompt below. The reboot brings SDDM up instead.
run sudo systemctl enable sddm
step_done

box "DONE! Reboot to see your new setup" 70 Ω
ask "Reboot now? [Y/n]: "; read -r do_reboot
if [[ $do_reboot =~ ^[Nn] ]]; then
  info "Skipping reboot — reboot manually when ready to apply everything."
else
  info "Rebooting..."
  sleep 2
  sudo reboot
fi
