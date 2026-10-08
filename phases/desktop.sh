#!/usr/bin/env bash
# Phase 3 — the desktop, as the new user, inside arch-chroot: run by the
# chroot phase, carrying on the installer's console and progress bar, with
# sudo allowed without a password while it runs. Drivers, desktop, apps,
# services.

phase_desktop() {
  # Weight: measured on a VM (81 s, once merged).
  step "Installing the desktop and apps" 80
  info "Installing KDE Plasma, the desktop you'll log into, and your apps. This is the big download."
  install_desktop_packages

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
  info "Letting you share folders with other devices on your network"
  configure_samba

  # Weight: by whether the USB brought them prebuilt (aur_weight); not a
  # number here, so step_weights leaves it to the totals' callers.
  step "Installing extras from the Arch community" "$(aur_weight "$SETUP_DIR/packages")"
  install_aur_packages

  step "Preparing your first login" 1
  info "Your desktop layout and theme will be applied the first time you log in"
  schedule_plasma_tweaks

  step "Finishing up" 2
  info "Turning on Bluetooth and the login screen..."
  enable_service bluetooth sddm

  # The installer asks for the look, then shows its own last screen and
  # reboots. The last step's time goes in the log first.
  log_step_time
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

  # The ARCHMAN login screen (assets/sddm/archman).
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

# The keyboard layout chosen in the install phase (X11_LAYOUT, X11_VARIANT,
# X11_OPTIONS) for the login screen and for Plasma, both read when they
# start.
configure_keyboard() {
  # SDDM's greeter runs on X11 and ignores Plasma's keyboard setting
  # (kxkbrc): without this, the first password is typed on a US layout, and
  # one with characters that move between layouts is refused.
  sudo mkdir -p /etc/X11/xorg.conf.d
  {
    printf 'Section "InputClass"\n    Identifier "system-keyboard"\n    MatchIsKeyboard "on"\n'
    printf '    Option "XkbLayout" "%s"\n' "$X11_LAYOUT"
    [[ -z $X11_VARIANT ]] || printf '    Option "XkbVariant" "%s"\n' "$X11_VARIANT"
    [[ -z $X11_OPTIONS ]] || printf '    Option "XkbOptions" "%s"\n' "$X11_OPTIONS"
    printf 'EndSection\n'
  } | sudo tee /etc/X11/xorg.conf.d/00-keyboard.conf > /dev/null
  kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "$X11_LAYOUT"
  kwriteconfig6 --file kxkbrc --group Layout --key VariantList "$X11_VARIANT"
  if [[ -n $X11_OPTIONS ]]; then
    kwriteconfig6 --file kxkbrc --group Layout --key Options "$X11_OPTIONS"
    kwriteconfig6 --file kxkbrc --group Layout --key ResetOldOptions true
  fi
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
  enable_service smb nmb
}

# Everything from the official repos in one pacman transaction: the
# package lists in config.sh, plus base-devel (for the AUR builds). One
# transaction, not one per list: pacman's checks and post-install hooks
# (font, icon, desktop caches...) then run once. -S, not -Syu: the package
# lists are the ones pacstrap synced moments ago, so nothing needs updating.
# Unless a version they list is on none of the mirrors any more: the mirrors
# sync at different times, so one ahead of the lists has deleted it while
# one behind never had the new one (seen: dolphin gone from
# geo.mirror.pkgbuild.com, noto-fonts not yet on glua.ua.pt). Then fresh
# lists, and -Syu, as packages from newer lists need the system up to date.
install_desktop_packages() {
  local -a packages=("${KDE_PACKAGES[@]}" "${EXTRA_PACKAGES[@]}" base-devel)
  if [[ -n $(gpu_vendors) ]]; then
    packages+=("${GAMING_PACKAGES[@]}")
  else
    # Without a real GPU driver, steam's 32-bit Vulkan dependency can only be
    # met by software Vulkan (breaks the login screen's video) or by pacman
    # picking lib32-nvidia-utils. Neither is worth it on a VM.
    warn "Skipping Steam: no gaming graphics card found"
  fi
  # Its output on failure only to the log (2>/dev/null): this is handled.
  run sudo pacman -S --needed --noconfirm "${packages[@]}" 2>/dev/null && return 0
  warn "Some downloads weren't available, getting the latest package lists..."
  retry 10 run sudo pacman -Syu --needed --noconfirm "${packages[@]}" \
    || die "Couldn't download the desktop"
}

install_aur_packages() {
  info "Adding a few extras from the Arch community..."
  # The step's bar shares (lib/ui.sh's share), one per package, by its
  # weight (aur_weight).
  local pkg parts used=0 part
  parts=$(aur_weight "$SETUP_DIR/packages")
  for pkg in "${AUR_PACKAGES[@]}"; do
    part=$(aur_weight "$SETUP_DIR/packages" "$pkg")
    share $(( 1000 * used / parts )) $(( 1000 * (used + part) / parts ))
    aur_install "$pkg"
    used=$(( used + part ))
  done
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
