#!/usr/bin/env bash
# Phase 2 — runs inside arch-chroot; "/" is the freshly installed system.

phase_chroot() {
  : "${HOST_NAME:?}" "${USER_NAME:?}"
  # One password, for both the user and root.
  local password
  IFS= read -r password < "$SETUP_DIR/creds"
  rm -f "$SETUP_DIR/creds"

  # One line for the step ("Setting up your system"), not one per part:
  # they take seconds. The parts only speak up with a warning.
  info "Setting up your language, account and startup..."
  configure_locale
  configure_accounts "$password"
  configure_boot_splash
  configure_hibernation
  install_bootloader
  hand_over_to_user
  run_desktop_phase
}

configure_locale() {
  # Settled by the install phase (resolve_timezone); never left at auto.
  [[ $TIMEZONE != auto && -f /usr/share/zoneinfo/$TIMEZONE ]] || TIMEZONE=UTC
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  run hwclock --systohc   # (through run: it can wait a second or two for the clock)
  # One language for everything (LOCALE), Plasma's too, which follows LANG;
  # dates and times the country's way (TIME_LOCALE, settled by the install
  # phase), when this glibc has that locale. Each enabled in locale.gen by
  # its exact line ("name charset"): a bare prefix would also catch other
  # charsets of it.
  [[ $TIME_LOCALE != auto ]] && grep -q "^#\?$TIME_LOCALE UTF-8 *\$" /etc/locale.gen || TIME_LOCALE=$LOCALE
  local name
  for name in "$LOCALE" "$TIME_LOCALE"; do
    sed -i "s/^#\($name UTF-8 *\)\$/\1/" /etc/locale.gen   # (its lines end in spaces)
  done
  run locale-gen
  printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
  [[ $TIME_LOCALE == "$LOCALE" ]] || printf 'LC_TIME=%s\n' "$TIME_LOCALE" >> /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

# $1 the password, for root and the user
configure_accounts() {
  echo "$HOST_NAME" > /etc/hostname
  printf '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 %s\n' "$HOST_NAME" > /etc/hosts

  useradd -m -G wheel -s /bin/bash "$USER_NAME"
  # chpasswd reads stdin, so the passwords never appear in argv or env.
  printf 'root:%s\n%s:%s\n' "$1" "$USER_NAME" "$1" | chpasswd

  write_sudoers /etc/sudoers.d/10-wheel '%wheel ALL=(ALL:ALL) ALL'

  run systemctl enable NetworkManager
}

# Plymouth splash instead of scrolling boot messages (Esc still shows them),
# using the pacman theme below. Must run before
# configure_hibernation, whose mkinitcpio -P builds the hook in, and before
# install_bootloader, which writes the kernel options into grub.cfg.
configure_boot_splash() {
  # Right after the systemd (or udev) hook, so it starts as early as it can.
  grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf \
    || sed -i -E 's/^(HOOKS=\(.*\b(systemd|udev))\b/\1 plymouth/' /etc/mkinitcpio.conf
  grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf || warn "Couldn't add the boot screen, startup will show text instead"

  # NVIDIA's driver has to be in the initramfs (early KMS), or the splash
  # only appears late or falls back to text. Intel/AMD get theirs from the
  # stock kms hook.
  if pacman -Q nvidia-open &>/dev/null && ! grep -q '^MODULES=.*nvidia' /etc/mkinitcpio.conf; then
    sed -i -E -e 's/^MODULES=\((.*)\)/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
      -e 's/^MODULES=\( /MODULES=(/' /etc/mkinitcpio.conf
  fi

  if install_splash_theme; then
    run plymouth-set-default-theme archman
  else
    warn "Using the standard boot screen"
    run plymouth-set-default-theme bgrt
  fi
  # vt.global_cursor_default=0: no blinking cursor on the text console, which
  # shows for a moment around the splash (between Plasma exiting and the
  # shutdown splash starting, say).
  local opt
  for opt in quiet splash vt.global_cursor_default=0; do
    add_kernel_option "$opt"
  done

  # loglevel=3 only covers boot: keep kernel messages below "error" off the
  # console for good, or warnings (clocksource, hardware quirks...) end up on
  # the text console and show at shutdown, around the splash.
  echo 'kernel.printk = 3 3 3 3' > /etc/sysctl.d/20-quiet-printk.conf
}

# The archman theme (assets/plymouth): Arch's logo where firmware logos sit
# and a spinner, both scaled to the screen height by archman.script, so they
# keep their size relative to the screen at any resolution.
install_splash_theme() {
  local src=$SETUP_DIR/assets/plymouth dir=/usr/share/plymouth/themes/archman f
  for f in archman.plymouth archman.script logo.png spinner.png; do
    [[ -f $src/$f ]] || return 1
  done
  rm -rf "$dir"
  install -Dm644 -t "$dir" "$src"/{archman.plymouth,archman.script,logo.png,spinner.png}
}

# A RAM-sized swap partition alone doesn't enable hibernation: the initramfs
# needs the resume hook and the kernel needs to be told where the image is.
configure_hibernation() {
  # The install phase's own swap partition (SWAP_PART): looked up by its
  # label instead, a second disk with an older install could answer first.
  local swap_uuid=''
  [[ -z ${SWAP_PART:-} ]] || swap_uuid=$(blkid -o value -s UUID "$SWAP_PART") || true
  [[ -n $swap_uuid ]] || { warn "No swap space found, hibernation won't be available"; return; }

  # The systemd initramfs hook resumes on its own; the udev-based default
  # needs the resume hook, ordered before filesystems.
  if ! grep -q '^HOOKS=.*systemd' /etc/mkinitcpio.conf; then
    grep -q '^HOOKS=.*resume' /etc/mkinitcpio.conf \
      || sed -i 's/^\(HOOKS=(.*\)filesystems/\1resume filesystems/' /etc/mkinitcpio.conf
  fi
  add_kernel_option "resume=UUID=$swap_uuid"
  run mkinitcpio -P
}

# add_kernel_option OPTION — appends OPTION to the kernel command line in
# /etc/default/grub, unless it's there already; install_bootloader writes it
# into grub.cfg.
add_kernel_option() {
  grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=\".*\b$1\b" /etc/default/grub \
    || sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"|\1 $1\"|" /etc/default/grub
}

install_bootloader() {
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/; s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
  run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  regenerate_grub
}

# Moves this installer into the new user's home, for the desktop phase and the
# Plasma first-login step. Nothing in this phase logs after it, since the log
# file lives in the directory being moved.
hand_over_to_user() {
  local dest=/home/$USER_NAME/.arch-setup
  rm -rf "$dest"
  mv "$SETUP_DIR" "$dest"
  chown -R "$USER_NAME:$USER_NAME" "$dest"
}

# The desktop setup (phases/desktop.sh), run here as the new user rather than on
# a first boot: all of it works in the chroot, on the live system's network,
# so the machine reboots once, straight into SDDM. A temporary sudo rule
# stands in for the password the phase would otherwise ask for, and the
# progress bar carries on from the install phase's (lib/ui.sh's progress_env).
run_desktop_phase() {
  local home=/home/$USER_NAME rule=/etc/sudoers.d/90-arch-setup-install
  write_sudoers "$rule" "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL"
  trap 'rm -f '"$rule" EXIT
  local -a progress
  mapfile -t progress < <(progress_env)
  runuser -u "$USER_NAME" -- env TERM="$TERM" \
    X11_LAYOUT="$X11_LAYOUT" X11_VARIANT="$X11_VARIANT" X11_OPTIONS="$X11_OPTIONS" \
    PATCHED_FONT="${PATCHED_FONT:-0}" "${progress[@]}" \
    bash "$home/.arch-setup/setup.sh" desktop
  rm -f "$rule"
}
