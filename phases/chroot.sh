#!/usr/bin/env bash
# Phase 2 — runs inside arch-chroot; "/" is the freshly installed system.

phase_chroot() {
  require_root
  : "${HOST_NAME:?}" "${USER_NAME:?}"
  local root_password user_password
  { IFS= read -r root_password; IFS= read -r user_password; } < "$SETUP_DIR/creds"
  rm -f "$SETUP_DIR/creds"

  configure_locale
  configure_accounts "$root_password" "$user_password"
  configure_boot_splash
  configure_hibernation
  install_bootloader
  hand_over_to_user
  run_post_phase
}

configure_locale() {
  info "Locale, timezone, keymap..."
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc
  local locale
  for locale in "${LOCALES[@]}"; do
    sed -i "s/^#\($locale\)/\1/" /etc/locale.gen
  done
  run locale-gen
  printf 'LANG=%s\nLC_MESSAGES=%s\n' "$LANG_LOCALE" "$MESSAGES_LOCALE" > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

# $1 root password, $2 user password
configure_accounts() {
  info "Hostname, accounts, sudo..."
  echo "$HOST_NAME" > /etc/hostname
  printf '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 %s\n' "$HOST_NAME" > /etc/hosts

  useradd -m -G wheel -s /bin/bash "$USER_NAME"
  # chpasswd reads stdin, so the passwords never appear in argv or env.
  printf 'root:%s\n%s:%s\n' "$1" "$USER_NAME" "$2" | chpasswd

  # No lecture on first use: when the post phase is run by hand, its first
  # sudo is the unlock screen, which is the prompt.
  printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' 'Defaults lecture = never' > /etc/sudoers.d/10-wheel
  chmod 440 /etc/sudoers.d/10-wheel
  visudo -c -f /etc/sudoers.d/10-wheel > /dev/null || die "Generated sudoers drop-in is invalid"

  run systemctl enable NetworkManager
}

# Plymouth splash instead of scrolling boot messages (Esc still shows them),
# using the pacman theme below. Must run before
# configure_hibernation, whose mkinitcpio -P builds the hook in, and before
# install_bootloader, which writes the kernel options into grub.cfg.
configure_boot_splash() {
  info "Configuring the boot splash..."
  # Right after the systemd (or udev) hook, so it starts as early as it can.
  grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf \
    || sed -i -E 's/^(HOOKS=\(.*\b(systemd|udev))\b/\1 plymouth/' /etc/mkinitcpio.conf
  grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf || warn "Couldn't add the plymouth hook — no splash"

  # NVIDIA's driver has to be in the initramfs (early KMS), or the splash
  # only appears late or falls back to text. Intel/AMD get theirs from the
  # stock kms hook.
  if pacman -Q nvidia-open &>/dev/null && ! grep -q '^MODULES=.*nvidia' /etc/mkinitcpio.conf; then
    sed -i -E -e 's/^MODULES=\((.*)\)/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
      -e 's/^MODULES=\( /MODULES=(/' /etc/mkinitcpio.conf
  fi

  if install_splash_theme; then
    run plymouth-set-default-theme pacman
  else
    warn "Splash theme missing from the installer — using the stock bgrt theme"
    run plymouth-set-default-theme bgrt
  fi
  local opt
  for opt in quiet splash; do
    grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=\".*\b$opt\b" /etc/default/grub \
      || sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"|\1 $opt\"|" /etc/default/grub
  done
}

# The pacman theme (assets/plymouth): Arch's logo where firmware logos sit
# and a spinner, both scaled to the screen height by pacman.script, so they
# keep their size relative to the screen at any resolution.
install_splash_theme() {
  local src=$SETUP_DIR/assets/plymouth dir=/usr/share/plymouth/themes/pacman f
  for f in pacman.plymouth pacman.script logo.png spinner.png; do
    [[ -f $src/$f ]] || return 1
  done
  rm -rf "$dir"
  install -Dm644 -t "$dir" "$src"/{pacman.plymouth,pacman.script,logo.png,spinner.png}
}

# A RAM-sized swap partition alone doesn't enable hibernation: the initramfs
# needs the resume hook and the kernel needs to be told where the image is.
configure_hibernation() {
  info "Configuring hibernation..."
  local swap_uuid=''
  swap_uuid=$(blkid -o value -s UUID -t LABEL=SWAP | head -1) || true
  [[ -n $swap_uuid ]] || { warn "Swap partition not found — skipping hibernation"; return; }

  # The systemd initramfs hook resumes on its own; the udev-based default
  # needs the resume hook, ordered before filesystems.
  if ! grep -q '^HOOKS=.*systemd' /etc/mkinitcpio.conf; then
    grep -q '^HOOKS=.*resume' /etc/mkinitcpio.conf \
      || sed -i 's/^\(HOOKS=(.*\)filesystems/\1resume filesystems/' /etc/mkinitcpio.conf
  fi
  grep -q 'resume=UUID=' /etc/default/grub \
    || sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"|\1 resume=UUID=$swap_uuid\"|" /etc/default/grub
  run mkinitcpio -P
}

install_bootloader() {
  info "Installing GRUB (hidden menu, no timeout)..."
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/; s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
  run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  regenerate_grub
}

# Moves this installer into the new user's home, for the post phase and the
# Plasma first-login step. Nothing in this phase logs after it, since the log
# file lives in the directory being moved.
hand_over_to_user() {
  local dest=/home/$USER_NAME/.arch-setup
  rm -rf "$dest"
  mv "$SETUP_DIR" "$dest"
  chown -R "$USER_NAME:$USER_NAME" "$dest"
}

# The desktop setup (phases/post.sh), run here as the new user rather than on
# a first boot: all of it works in the chroot, on the live system's network,
# so the machine reboots once, straight into SDDM. A temporary sudo rule
# stands in for the password the phase would otherwise ask for, and the
# progress bar carries on from the install phase's (STEP, STEP_TOTAL).
run_post_phase() {
  local home=/home/$USER_NAME rule=/etc/sudoers.d/90-arch-setup-install
  echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$rule"
  chmod 440 "$rule"
  visudo -c -f "$rule" > /dev/null || die "Generated sudoers drop-in is invalid"
  trap 'rm -f '"$rule" EXIT
  runuser -u "$USER_NAME" -- env TERM="$TERM" VERBOSE="$VERBOSE" STEP="$STEP" STEP_TOTAL="$STEP_TOTAL" \
    PATCHED_FONT="${PATCHED_FONT:-0}" IN_CHROOT=1 \
    bash "$home/.arch-setup/setup.sh" post
  rm -f "$rule"
}
