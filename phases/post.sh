#!/usr/bin/env bash
# Phase 3 — first login, as the new user. Drivers, desktop, apps, services.

SUDOERS_DROPIN=/etc/sudoers.d/99-arch-setup-temp

phase_post() {
  require_user
  require_network

  # One password prompt up front; a background loop then keeps the ticket
  # alive so no later step stalls on a second prompt under a spinner.
  info "Requesting sudo access..."
  sudo -v
  ( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) &>/dev/null &
  local keepalive_pid=$!
  # -n in the trap: if the ticket is somehow gone, fail quietly rather than
  # hang on a password prompt nobody can answer.
  trap 'kill '"$keepalive_pid"' 2>/dev/null; sudo -n rm -f "$SUDOERS_DROPIN" 2>/dev/null' EXIT
  STEP_TOTAL=10

  clear
  step "Enabling multilib & updating the system"
  # Must precede the GPU step, which installs 32-bit drivers from multilib.
  sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
  run sudo pacman -Syu --noconfirm
  step_done

  step "Installing GPU drivers";           install_gpu_drivers;          step_done
  step "Installing KDE Plasma";            pkg_install "${KDE_PACKAGES[@]}";   step_done
  step "Installing extra applications";    pkg_install "${EXTRA_PACKAGES[@]}"; step_done
  step "Setting mpv wheel controls";       configure_mpv;                step_done
  step "Login screen, wallpaper, keyboard"; configure_login_and_desktop; step_done
  step "Setting up Samba file sharing";    configure_samba;              step_done
  step "Installing Steam & AUR packages";  install_gaming_and_aur;       step_done
  step "Scheduling Plasma first-login setup"; schedule_kde_init;         step_done

  step "Enabling services"
  enable_service --now bluetooth
  # No --now for SDDM: its unit conflicts with getty@tty1, so starting it here
  # would SIGHUP this very session before the prompt below. The reboot does it.
  enable_service sddm
  step_done

  box "DONE! Reboot to see your new setup"
  if confirm "Reboot now?"; then
    info "Rebooting..."
    sleep 2
    sudo reboot
  else
    info "Reboot manually when ready to apply everything."
  fi
}

# Sets GPU_SUPPORTED for the Steam decision later.
install_gpu_drivers() {
  local -a vendors
  mapfile -t vendors < <(gpu_vendors)
  if (( ${#vendors[@]} == 0 )); then
    warn "No Intel/AMD/NVIDIA GPU detected — installing generic mesa only"
    pkg_install "${GPU_PACKAGES_FALLBACK[@]}"
    GPU_SUPPORTED=0
    return
  fi
  GPU_SUPPORTED=1
  info "Detected GPU(s): ${vendors[*]}"
  local vendor list
  for vendor in "${vendors[@]}"; do
    list="GPU_PACKAGES_${vendor^^}[@]"
    pkg_install "${!list}"
  done
}

configure_mpv() {
  sudo mkdir -p /etc/mpv
  sudo tee /etc/mpv/input.conf > /dev/null <<'EOF'
WHEEL_UP      seek 10
WHEEL_DOWN    seek -10
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF
}

configure_login_and_desktop() {
  local theme_dir=/usr/share/sddm/themes/$SDDM_THEME
  sudo rm -rf "$theme_dir"
  run sudo git clone --depth 1 "$SDDM_THEME_REPO" "$theme_dir"
  sudo cp -r "$theme_dir"/Fonts/* /usr/share/fonts/
  run sudo fc-cache -f

  local conf=/etc/sddm.conf.d/kde_settings.conf
  sudo mkdir -p /etc/sddm.conf.d
  sudo kwriteconfig6 --file "$conf" --group Theme   --key Current "$SDDM_THEME"
  sudo kwriteconfig6 --file "$conf" --group General --key HaltCommand   "/usr/bin/systemctl poweroff"
  sudo kwriteconfig6 --file "$conf" --group General --key RebootCommand "/usr/bin/systemctl reboot"
  sudo kwriteconfig6 --file "$conf" --group Users   --key MinimumUid 1000
  sudo kwriteconfig6 --file "$conf" --group Users   --key MaximumUid 60513

  # Lock screen wallpaper for this user, plus the system-wide default so the
  # first Plasma session starts with it too.
  kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key Image "file://$WALLPAPER"
  local xml=/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml
  sudo sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>file://$WALLPAPER</default>|" "$xml"

  kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "$X11_LAYOUT"
  kwriteconfig6 --file kxkbrc --group Layout --key Use true
}

configure_samba() {
  sudo mkdir -p /var/lib/samba/usershares
  sudo groupadd -r sambashare 2>/dev/null || true
  sudo chown root:sambashare /var/lib/samba/usershares
  sudo chmod 1770 /var/lib/samba/usershares
  sudo usermod -aG sambashare "$USER"

  sudo tee /etc/samba/smb.conf > /dev/null <<EOF
[global]
   workgroup = $SAMBA_WORKGROUP
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
  enable_service --now smb nmb
}

install_gaming_and_aur() {
  info "Hang tight — this step compiles paru and builds the AUR packages."
  pkg_install base-devel
  if (( GPU_SUPPORTED )); then
    pkg_install "${GAMING_PACKAGES[@]}"
  else
    # Without a real GPU driver, steam's 32-bit Vulkan dependency can only be
    # met by software Vulkan (breaks the login screen's video) or by pacman
    # picking lib32-nvidia-utils. Neither is worth it on a VM.
    warn "No supported GPU — skipping Steam"
  fi

  # makepkg's internal `sudo pacman` calls don't pick up the cached ticket no
  # matter how it's shared. Rather than fight that: passwordless sudo for
  # pacman only, for this step only — created here, removed at the end.
  echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" | sudo tee "$SUDOERS_DROPIN" > /dev/null
  sudo chmod 440 "$SUDOERS_DROPIN"
  sudo visudo -c -f "$SUDOERS_DROPIN" > /dev/null || die "Generated sudoers drop-in is invalid"

  if command -v paru &>/dev/null; then
    info "paru already installed — skipping build"
  else
    # Built from source on purpose: paru-bin is compiled against a fixed
    # libalpm and breaks whenever pacman bumps its ABI (it has been flagged
    # out-of-date for months). -r removes the Rust toolchain again afterwards.
    local build; build=$(mktemp -d)
    git_clone https://aur.archlinux.org/paru.git "$build"
    (cd "$build" && run makepkg -sri --noconfirm)
    rm -rf "$build"
  fi
  aur_install "${AUR_PACKAGES[@]}"

  sudo rm -f "$SUDOERS_DROPIN"
}

# Plasma writes several of the config files kde-init edits during its own
# startup, so that phase can't run from here: autostart it in the first
# session instead, in phase 2 (after the shell is up) plus a real delay.
schedule_kde_init() {
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/arch-kde-init.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Arch setup: Plasma first-login tweaks
Exec=/bin/sh -c "sleep 10 && bash '$SETUP_DIR/setup.sh' kde-init"
X-KDE-autostart-phase=2
EOF
}
