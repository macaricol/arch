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
  configure_hibernation
  install_bootloader
  configure_first_login
  hand_over_to_user
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

  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
  chmod 440 /etc/sudoers.d/10-wheel
  visudo -c -f /etc/sudoers.d/10-wheel > /dev/null || die "Generated sudoers drop-in is invalid"

  run systemctl enable NetworkManager
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

# Auto-login on tty1 for exactly one boot, landing the user in the post
# phase. The .bash_profile hook removes the autologin again *before* running
# it, so the exposure ends at that first login even if the phase fails.
configure_first_login() {
  info "Scheduling the post-install phase for first login..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USER_NAME --noclear %I \$TERM
EOF

  local profile=/home/$USER_NAME/.bash_profile
  cat > "$profile" <<'EOF'
# One-shot hook written by the installer.
sudo rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null
# Unlink first, then copy: bash is still reading this file through an open
# fd, and overwriting it in place would corrupt the rest of the read.
rm -f "$HOME/.bash_profile"
cp /etc/skel/.bash_profile "$HOME/.bash_profile"
[[ -f "$HOME/.arch-setup/setup.sh" ]] && bash "$HOME/.arch-setup/setup.sh" post
EOF
  chown "$USER_NAME:$USER_NAME" "$profile"
}

# Moves this installer into the new user's home for the post phase. Last
# thing in this phase, since the log file lives in the directory being moved.
hand_over_to_user() {
  local dest=/home/$USER_NAME/.arch-setup
  rm -rf "$dest"
  mv "$SETUP_DIR" "$dest"
  chown -R "$USER_NAME:$USER_NAME" "$dest"
}
