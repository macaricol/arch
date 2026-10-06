#!/usr/bin/env bash
# Phase 3 — the desktop, as the new user: run inside arch-chroot by the
# chroot phase, or by hand on an installed system. Drivers, desktop, apps,
# services.

SUDOERS_DROPIN=/etc/sudoers.d/99-arch-setup-temp

phase_desktop() {
  require_user
  setup_console

  # One password prompt up front (none when run from the installer, which
  # allows sudo without one); a background loop then keeps the ticket alive
  # so no later step stalls on a second prompt under a spinner.
  sudo -n true 2>/dev/null || unlock_sudo
  ( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) &>/dev/null &
  local keepalive_pid=$!
  # -n in the trap: if the ticket is somehow gone, fail quietly rather than
  # hang on a password prompt nobody can answer.
  trap 'kill '"$keepalive_pid"' 2>/dev/null; sudo -n rm -f "$SUDOERS_DROPIN" 2>/dev/null' EXIT
  # Unless carrying on the installer's bar.
  (( PROGRESS_TOTAL )) || PROGRESS_TOTAL=$(step_weights "$SETUP_DIR/phases/desktop.sh")

  step "Updating the system" 8
  info "Making sure everything is up to date..."
  require_network
  # gum: the prompt UI (lib/prompt.sh), for the reboot question at the end.
  run sudo pacman -Syu --noconfirm --needed gum

  step "Installing the desktop" 53
  info "Installing KDE Plasma, the desktop you'll log into. This is the big download."
  pkg_install "${KDE_PACKAGES[@]}"

  step "Installing apps" 17
  info "Adding apps: video player, code editor, remote desktop, fonts..."
  pkg_install "${EXTRA_PACKAGES[@]}"

  step "Tuning the video player" 1
  info "Scroll to seek, tilt the wheel for volume"
  configure_mpv

  step "Setting up sound" 1
  configure_audio

  step "Personalising" 5
  info "Setting up the login screen, wallpapers and keyboard layout..."
  install_look_files
  configure_login_screen
  configure_keyboard

  step "Setting up file sharing" 1
  info "Letting you share folders with other computers on your network"
  configure_samba

  step "Installing games & extras" 203
  install_gaming_and_aur

  step "Preparing your first login" 1
  info "Your desktop layout and theme will be applied the first time you log in"
  schedule_plasma_tweaks

  step "Finishing up" 2
  info "Turning on Bluetooth and the login screen..."
  enable_service --now bluetooth
  # No --now for SDDM: run by hand, it would take over tty1, where this phase
  # is still running, before the prompt below. The reboot starts it.
  enable_service sddm

  # Run from the installer: it asks for the look itself, then shows its own
  # last screen and reboots. The last step's time goes in the log first.
  if in_chroot; then log_step_time; return 0; fi
  choose_look
  run sudo env LOOK="$LOOK" bash "$SETUP_DIR/setup.sh" look
  finish "All done! Reboot to see your new setup"
  if confirm "Reboot now?"; then
    info "Rebooting..."
    sleep 2
    sudo reboot
  else
    info "Reboot manually when ready to apply everything."
  fi
}

# The password screen, until sudo accepts what's typed. The password goes
# to sudo on stdin, never in argv; lecture and prompt are suppressed, as the
# screen is the prompt.
unlock_sudo() {
  local password error=''
  while :; do
    unlock_screen password "Enter your password to finish setting up" "$error"
    printf '%s\n' "$password" | sudo -S -p '' -v 2>/dev/null && break
    error="Wrong password, try again"
  done
  clear
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

# PipeWire ships upmixing off: a stereo stream on a surround card feeds front
# L/R and leaves every other speaker silent. The same drop-in has to go in two
# places, because the channel mixing happens in whichever client library the
# app uses — client.conf.d covers native PipeWire apps (mpv, Firefox/Zen's
# native backend), pipewire-pulse.conf.d covers everything speaking PulseAudio.
# Miss either one and half your applications quietly stay stereo.
configure_audio() {
  if (( ! UPMIX_SURROUND )); then
    info "Keeping standard stereo sound"
    return
  fi
  info "Spreading stereo sound to all your speakers"

  local dir
  for dir in client pipewire-pulse; do
    sudo mkdir -p "/etc/pipewire/$dir.conf.d"
    sudo tee "/etc/pipewire/$dir.conf.d/20-upmix.conf" > /dev/null <<EOF
# Managed by arch-setup. Upmix stereo onto all surround speakers.
stream.properties = {
    channelmix.upmix        = true
    channelmix.upmix-method = $UPMIX_METHOD
    channelmix.lfe-cutoff   = $UPMIX_LFE_CUTOFF
    channelmix.fc-cutoff    = $UPMIX_FC_CUTOFF
    channelmix.rear-delay   = $UPMIX_REAR_DELAY
}
EOF
  done

  # Deliberately nothing here for mpv: it already hands PipeWire a stereo
  # stream and lets the upmix do the work. Forcing audio-channels=7.1 would
  # make mpv pad the extra channels with silence itself, and PipeWire would
  # then see 8ch and skip upmixing entirely — front L/R only again.
}

# These three run here, as root (sudo), before the first boot, rather than
# in plasma-tweaks: that runs as the user in the first Plasma session, after
# the login screen has been shown and typed into, with no sudo.

# The files of both looks, whichever is chosen at the end (phases/look.sh
# switches one on; the other stays available in System Settings): the
# astronaut SDDM theme, with the wallpapers and its fonts, and the ARCHMAN
# login screen.
install_look_files() {
  local astronaut=/usr/share/sddm/themes/$ASTRONAUT_THEME
  share 0 700   # the step's bar shares (lib/ui.sh's share): the clone is the big one
  git_clone "$ASTRONAUT_REPO" "$astronaut" as_root
  share 700 1000
  sudo cp -r "$astronaut"/Fonts/* /usr/share/fonts/
  run sudo fc-cache -f

  # The unlock screen's look (assets/sddm/archman).
  local theme_dir=/usr/share/sddm/themes/$SDDM_THEME
  sudo rm -rf "$theme_dir"
  sudo install -Dm644 -t "$theme_dir" "$SETUP_DIR/assets/sddm/archman"/*
}

# SDDM's settings, the same with either look; its theme comes with the look
# (phases/look.sh). Read when the login screen starts.
configure_login_screen() {
  local conf=/etc/sddm.conf.d/kde_settings.conf
  sudo mkdir -p /etc/sddm.conf.d
  sudo kwriteconfig6 --file "$conf" --group General --key HaltCommand   "/usr/bin/systemctl poweroff"
  sudo kwriteconfig6 --file "$conf" --group General --key RebootCommand "/usr/bin/systemctl reboot"
  sudo kwriteconfig6 --file "$conf" --group Users   --key MinimumUid 1000
  sudo kwriteconfig6 --file "$conf" --group Users   --key MaximumUid 60513
}

# X11_LAYOUT for the login screen and for Plasma, both read when they start.
configure_keyboard() {
  # SDDM's greeter runs on X11 and ignores Plasma's keyboard setting
  # (kxkbrc): without this, the first password is typed on a US layout, and
  # one with characters that move between layouts is refused.
  sudo mkdir -p /etc/X11/xorg.conf.d
  sudo tee /etc/X11/xorg.conf.d/00-keyboard.conf > /dev/null <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$X11_LAYOUT"
EndSection
EOF
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
  info "Adding Steam and a few extras from the Arch community..."
  # The step's bar shares (lib/ui.sh's share): build tools, Steam, then an
  # equal share for each AUR package.
  share 0 150
  pkg_install base-devel
  share 150 450
  if [[ -n $(gpu_vendors) ]]; then
    pkg_install "${GAMING_PACKAGES[@]}"
  else
    # Without a real GPU driver, steam's 32-bit Vulkan dependency can only be
    # met by software Vulkan (breaks the login screen's video) or by pacman
    # picking lib32-nvidia-utils. Neither is worth it on a VM.
    warn "Skipping Steam: no gaming graphics card found"
  fi

  # makepkg's internal `sudo pacman` calls don't pick up the cached ticket no
  # matter how it's shared. Rather than fight that: passwordless sudo for
  # pacman only, for this step only — created here, removed at the end.
  write_sudoers "$SUDOERS_DROPIN" "$USER ALL=(ALL) NOPASSWD: /usr/bin/pacman"

  local i n=${#AUR_PACKAGES[@]}
  for (( i = 0; i < n; i++ )); do
    share $(( 450 + 550 * i / n )) $(( 450 + 550 * (i + 1) / n ))
    aur_install "${AUR_PACKAGES[i]}"
  done

  sudo rm -f "$SUDOERS_DROPIN"
}

# Plasma writes several of the config files plasma-tweaks edits during its own
# startup, so that phase can't run from here: autostart it in the first
# session instead, in phase 2 (after the shell is up) plus a real delay.
schedule_plasma_tweaks() {
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/arch-plasma-tweaks.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Arch setup: Plasma first-login tweaks
Exec=/bin/sh -c "sleep 10 && bash '$SETUP_DIR/setup.sh' plasma-tweaks"
X-KDE-autostart-phase=2
EOF
}
