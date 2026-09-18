#!/usr/bin/env bash
# Arch Linux installer – ultra-compact, robust & fast (2025 edition)
#
# This script runs twice: once on the live ISO (arg-less, runs `main`), and a
# second time inside the freshly installed system via arch-chroot (called with
# "chroot", runs `chroot_phase`) — see the dispatch at the bottom of the file.
set -euo pipefail       # abort on error / unset var / failed pipeline stage
IFS=$'\n\t'             # word-split only on newline+tab, not spaces (safer with paths)

# ── CONFIG ─────────────────────────────────────────────────────────────
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'
REPO_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/clauding"
MAIN_URL="$REPO_URL/main.sh"
POST_URL="$REPO_URL/post.sh"
UTILS_URL="$REPO_URL/utils.sh"

# ── Source utilities ─────────────────────────────────────────────────────
# Fetch utils.sh next to this script so sourcing works the same whether this
# is run as ./main.sh, /path/main.sh, or piped straight into bash (in which
# case there's no real file and BASH_SOURCE[0] is unset — fall back to /tmp).
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="/tmp"
fi
readonly SCRIPT_DIR
# main() stages a copy alongside the chroot script, so the second (in-chroot)
# run finds it already there instead of fetching it over the network again.
[[ -f "${SCRIPT_DIR}/utils.sh" ]] || curl -fsSL -o "${SCRIPT_DIR}/utils.sh" "$UTILS_URL"
source "${SCRIPT_DIR}/utils.sh" || { echo "Failed to load utils.sh" >&2; exit 1; }

# ── PRE-FLIGHT ────────────────────────────────────────────────────────
# Fail fast on obvious show-stoppers instead of discovering them deep into
# partitioning/pacstrap, minutes into the run.
preflight_checks() {
  # Switch the live session to our keymap up front so typing passwords/
  # hostnames below doesn't require a separate manual `loadkeys` step.
  loadkeys "$KEYMAP" 2>/dev/null || echo "Warning: couldn't load keymap $KEYMAP" >&2

  info "Running pre-flight checks..."
  [[ $EUID -eq 0 ]] || die "Must be run as root"
  [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode"
  require_network
}

# ── PARTITION & FORMAT ───────────────────────────────────────────────
partition_and_mount() {
  # nvme devices need a "p" before the partition number (nvme0n1p1), plain
  # disks don't (sda1) — everything below builds partition paths from this.
  local type=''
  [[ $DRIVE =~ nvme ]] && type=p
  local boot="${DRIVE}${type}1" swap="${DRIVE}${type}2" root="${DRIVE}${type}3"

  # Undo any half-finished previous run so re-running after a failure doesn't
  # choke on "already mounted" / "device busy". partprobe forces the kernel
  # to resync its partition table view, which can otherwise go stale after a
  # failed sgdisk write and cause the next attempt to fail too.
  info "Cleaning up any previous attempt..."
  swapoff "$swap" 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
  partprobe "$DRIVE" 2>/dev/null || true

  # Size the swap partition to match installed RAM (enables hibernation).
  local ram_mib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  local swap_end=$((513 + ram_mib))

  # Partition layout: 512M EFI system partition, RAM-sized swap, rest for root.
  info "Wiping & partitioning $DRIVE..."
  run sgdisk -Z \
    -n1:1M:512M               -t1:ef00 -c1:EFI \
    -n2:513M:${swap_end}M     -t2:8200 -c2:Swap \
    -n3:$((swap_end + 1))M:0  -t3:8300 -c3:Root "$DRIVE"
  partprobe "$DRIVE" 2>/dev/null || true
  # partprobe only makes the kernel re-read the table; udev still has to create
  # the device nodes. Without this wait the check below can run first and
  # report a bogus "Partitioning failed".
  udevadm settle

  [[ -b $boot && -b $swap && -b $root ]] || die "Partitioning failed"

  info "Formatting..."
  run mkfs.fat -F32 -n BOOT "$boot"
  run mkswap -L SWAP "$swap"
  run mkfs.btrfs -f -L ROOT "$root"

  # Create @ (root) and @home as top-level Btrfs subvolumes, then remount
  # under their final paths with zstd compression.
  info "Mounting Btrfs subvolumes..."
  run mount -t btrfs "$root" /mnt
  run btrfs su cr /mnt/@ /mnt/@home
  run umount /mnt

  run mount -t btrfs -o noatime,compress=zstd:1,subvol=@ "$root" /mnt
  mkdir -p /mnt/{boot,home}
  run mount -t btrfs -o noatime,compress=zstd:1,subvol=@home "$root" /mnt/home
  run mount -t vfat "$boot" /mnt/boot
  run swapon "$swap"
}

# ── BASE INSTALL ─────────────────────────────────────────────────────
install_base() {
  # reflector picks the fastest PT/ES mirrors; if it fails for any reason
  # (e.g. flaky network) don't silently pacstrap from an empty mirrorlist.
  info "Optimizing mirrors (PT+ES)..."
  run reflector --country 'PT,ES' --latest 8 --protocol https --sort rate --number 6 --save /etc/pacman.d/mirrorlist --verbose || true
  [[ -s /etc/pacman.d/mirrorlist ]] || die "Mirrorlist is empty — reflector failed"

  # Cosmetic pacman progress bar; grep guard keeps this idempotent on re-runs.
  grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/\[options\]/a ILoveCandy' /etc/pacman.conf

  info "Pacstrap base system..."
  run pacstrap -K /mnt base linux linux-firmware btrfs-progs grub efibootmgr nano networkmanager sudo

  genfstab -U /mnt >> /mnt/etc/fstab
  # Carry the tuned mirrorlist over so the installed system keeps fast mirrors.
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

# ── CHROOT PHASE ─────────────────────────────────────────────────────
# Runs inside arch-chroot, i.e. "/" here is the new install, not the live ISO.
chroot_phase() {
  # Passwords travel via a 0600 file (main() wrote it), never as env/argv,
  # so they don't show up in `ps`/`/proc/*/cmdline`. Delete it immediately.
  local ROOT_PASSWORD USER_PASSWORD
  { IFS= read -r ROOT_PASSWORD; IFS= read -r USER_PASSWORD; } < /creds
  rm -f /creds

  info "Setting locale & timezone..."
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc --utc

  # Enable just the locales we need, then set PT as the display language with
  # US English for terminal/log messages.
  sed -i 's/#\(en_US\|pt_PT\)\.UTF-8 UTF-8/\1.UTF-8 UTF-8/' /etc/locale.gen
  run locale-gen
  echo -e 'LANG=pt_PT.UTF-8\nLC_MESSAGES=en_US.UTF-8' > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

  info "Creating user accounts..."
  echo "$HOST_NAME" > /etc/hostname
  # Passed via the environment, not string interpolation, so passwords with
  # shell metacharacters ($, ", `, etc.) can't break the inner command.
  ROOT_PASSWORD="$ROOT_PASSWORD" run bash -c 'echo -e "$ROOT_PASSWORD\n$ROOT_PASSWORD" | passwd root'

  useradd -mG wheel -s /bin/bash "$USER_NAME"
  USER_NAME="$USER_NAME" USER_PASSWORD="$USER_PASSWORD" \
    run bash -c 'echo -e "$USER_PASSWORD\n$USER_PASSWORD" | passwd "$USER_NAME"'
  # A drop-in rather than an in-place sed on /etc/sudoers: if that pattern ever
  # stopped matching, wheel would silently get no sudo, and that only surfaces
  # at first login when .bash_profile and post.sh both need to elevate.
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
  chmod 440 /etc/sudoers.d/10-wheel
  visudo -c -f /etc/sudoers.d/10-wheel >/dev/null || die "Generated sudoers drop-in is invalid"

  info "Configuring first-login automation..."
  # Auto-login on tty1 for exactly one boot, so the user lands in a shell
  # instead of a text login prompt after reboot. The .bash_profile hook
  # below disables this again as the very first thing it does — before
  # running post.sh, not after — so it's still removed even if post.sh
  # reboots or fails partway through, keeping the exposure window to
  # "until this one login happens" rather than indefinite.
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USER_NAME --noclear %I \$TERM
EOF

  cat > "/home/$USER_NAME/.bash_profile" <<'PROFILE'
sudo rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null
# Unlink before copying: the running shell is still reading this file through
# an open fd, and overwriting it in place would corrupt the rest of the read.
rm -f "$HOME/.bash_profile"
cp /etc/skel/.bash_profile "$HOME/.bash_profile"
[[ -f "$HOME/post.sh" ]] && bash "$HOME/post.sh"
PROFILE
  chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.bash_profile"

  info "Configuring hibernation..."
  # A RAM-sized swap partition on its own doesn't enable hibernation: the
  # kernel has to be told which device holds the image, and the initramfs has
  # to restore it before root is mounted read-write.
  local swap_uuid=''
  swap_uuid=$(blkid -o value -s UUID -t LABEL=SWAP | head -1) || true
  if [[ -n $swap_uuid ]]; then
    # The systemd hook handles resume itself; the udev-based default (what
    # pacstrap installs) needs the resume hook, ordered before filesystems.
    if ! grep -q '^HOOKS=.*systemd' /etc/mkinitcpio.conf; then
      grep -q '^HOOKS=.*resume' /etc/mkinitcpio.conf || \
        sed -i 's/^\(HOOKS=(.*\)filesystems/\1resume filesystems/' /etc/mkinitcpio.conf
    fi
    grep -q 'resume=UUID=' /etc/default/grub || \
      sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"|\1 resume=UUID=$swap_uuid\"|" /etc/default/grub
    run mkinitcpio -P
  else
    echo "Warning: swap partition not found — skipping hibernation setup" >&2
  fi

  info "Installing bootloader..."
  run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  run grub-mkconfig -o /boot/grub/grub.cfg
  run systemctl enable NetworkManager

  # Stage post.sh in the new user's home so it's ready to run after first login.
  info "Downloading post-install script..."
  curl -fsSL "$POST_URL" -o "/home/$USER_NAME/post.sh"
  chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/post.sh"
  chmod +x "/home/$USER_NAME/post.sh"

  # Don't leave the installer's own scratch files in the finished system.
  rm -f /setup.sh /utils.sh
}

# ── MAIN ─────────────────────────────────────────────────────────────
main() {
  # When this script arrives via `curl | bash`, fd 0 is the pipe carrying the
  # script's own source, not the keyboard — every `read` below would silently
  # read from that instead of you. Rebind stdin to the real terminal.
  exec < /dev/tty
  STEP_TOTAL=6

  clear
  preflight_checks

  clear
  step "Enter machine details"
  input "Hostname: " HOST_NAME no valid_hostname
  password "Root password (min 6 chars): " ROOT_PASSWORD
  input "Username: " USER_NAME no valid_username
  password "User password (min 6 chars): " USER_PASSWORD
  step_done

  select_drive "[$((++STEP))/$STEP_TOTAL] Select installation drive"
  step_done

  clear
  step "Review & confirm"
  printf ' Hostname:  %s\n Username:  %s\n Drive:     %s\n Timezone:  %s\n Keymap:    %s\n\n' \
    "$HOST_NAME" "$USER_NAME" "$DRIVE" "$TIMEZONE" "$KEYMAP"
  info "This will ERASE ALL DATA on $DRIVE. This cannot be undone."
  ask "Type YES to continue: "; read -r ack
  [[ $ack == YES ]] || { info "Aborted."; exit 0; }
  step_done

  step "Partitioning & Formatting"
  partition_and_mount
  step_done

  step "Installing Arch Linux"
  install_base
  step_done

  # Fetch this script into the new root (rather than `cp "$0"`, which breaks
  # when main.sh is piped straight into bash and $0 isn't a real file) so
  # arch-chroot can re-invoke it there with "chroot" as $1, landing in
  # chroot_phase() above.
  step "Finalizing installation"
  info "Entering chroot..."
  curl -fsSL -o /mnt/setup.sh "$MAIN_URL"
  cp "${SCRIPT_DIR}/utils.sh" /mnt/utils.sh
  # chroot_phase deletes this as its first act, but if arch-chroot never gets
  # that far the plaintext passwords would be left behind on the new install.
  trap 'rm -f /mnt/creds' EXIT
  install -m 600 /dev/null /mnt/creds
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD" > /mnt/creds
  arch-chroot /mnt env \
    HOST_NAME="$HOST_NAME" USER_NAME="$USER_NAME" \
    VERBOSE="$VERBOSE" /bin/bash /setup.sh chroot
  step_done

  box "DONE! Rebooting in 5s..." 70 Ω
  sleep 5 && reboot
}

# Entry point: with no args (live ISO) run the installer; re-invoked with
# "chroot" (from inside main(), above) it only runs the chroot phase.
# An `a && b || c` dispatch would be wrong twice over: calling chroot_phase
# inside an && list disables `set -e` for its whole body, and a non-zero return
# from it would then fall through to running main() inside the chroot.
if [[ ${1:-} == chroot ]]; then
  chroot_phase
else
  main
fi
