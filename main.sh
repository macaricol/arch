#!/usr/bin/env bash
# Arch Linux installer – ultra-compact, robust & fast (2025 edition)
#
# This script runs twice: once on the live ISO (arg-less, runs `main`), and a
# second time inside the freshly installed system via arch-chroot (called with
# "chroot", runs `chroot_phase`) — see the dispatch at the bottom of the file.
set -euo pipefail       # abort on error / unset var / failed pipeline stage
IFS=$'\n\t'             # word-split only on newline+tab, not spaces (safer with paths)
shopt -s nocasematch extglob

# ── CONFIG ─────────────────────────────────────────────────────────────
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'
REPO_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/clauding"
MAIN_URL="$REPO_URL/main.sh"
POST_URL="$REPO_URL/post.sh"
UTILS_URL="$REPO_URL/utils.sh"

# ── Source utilities ─────────────────────────────────────────────────────
# Fetch utils.sh next to this script (not into whatever the cwd happens to be)
# so sourcing works the same whether this is run as ./main.sh or /path/main.sh.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
curl -fsSL -o "${SCRIPT_DIR}/utils.sh" "$UTILS_URL"
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
  ping -c1 -W3 archlinux.org &>/dev/null || die "No network connectivity"
}

# ── PARTITION & FORMAT ───────────────────────────────────────────────
partition_and_mount() {
  # nvme devices need a "p" before the partition number (nvme0n1p1), plain
  # disks don't (sda1) — everything below builds partition paths from this.
  local type=''
  [[ $DRIVE =~ nvme ]] && type=p
  local boot="${DRIVE}${type}1" swap="${DRIVE}${type}2" root="${DRIVE}${type}3"

  # Undo any half-finished previous run so re-running after a failure doesn't
  # choke on "already mounted" / "device busy".
  info "Cleaning up any previous attempt..."
  swapoff "$swap" 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  # Size the swap partition to match installed RAM (enables hibernation).
  local ram_mib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  local swap_end=$((513 + ram_mib))

  # Partition layout: 512M EFI system partition, RAM-sized swap, rest for root.
  info "Wiping & partitioning $DRIVE..."
  run sgdisk -Z \
    -n1:1M:512M           -t1:ef00 -c1:EFI \
    -n2:513M:${swap_end}M -t2:8200 -c2:Swap \
    -n3:${swap_end}M:0    -t3:8300 -c3:Root "$DRIVE"

  [[ -b $boot && -b $swap && -b $root ]] || die "Partitioning failed"

  info "Formatting..."
  run mkfs.fat -F32 -n BOOT "$boot"
  run mkswap -L SWAP "$swap"
  run mkfs.btrfs -f -L ROOT "$root"

  # Create @ (root) and @home as top-level Btrfs subvolumes, then remount
  # under their final paths with zstd compression.
  info "Mounting Btrfs subvolumes..."
  run mount "$root" /mnt
  run btrfs su cr /mnt/@ /mnt/@home
  run umount /mnt

  run mount -o noatime,compress=zstd:1,subvol=@ "$root" /mnt
  mkdir -p /mnt/{boot,home}
  run mount -o noatime,compress=zstd:1,subvol=@home "$root" /mnt/home
  run mount "$boot" /mnt/boot
  run swapon "$swap"
}

# ── BASE INSTALL ─────────────────────────────────────────────────────
install_base() {
  # reflector picks the fastest PT/ES mirrors; if it fails for any reason
  # (e.g. flaky network) don't silently pacstrap from an empty mirrorlist.
  info "Optimizing mirrors (PT+ES)..."
  run reflector --country 'PT,ES' --latest 8 --protocol https --sort rate --number 6 --save /etc/pacman.d/mirrorlist --verbose || true
  [[ -s /etc/pacman.d/mirrorlist ]] || die "Mirrorlist is empty — reflector failed"

  run pacman -Sy --noconfirm
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

  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc --utc

  # Enable just the locales we need, then set PT as the display language with
  # US English for terminal/log messages.
  sed -i 's/#\(en_US\|pt_PT\)\.UTF-8 UTF-8/\1.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen
  echo -e 'LANG=pt_PT.UTF-8\nLC_MESSAGES=en_US.UTF-8' > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

  echo "$HOSTNAME" > /etc/hostname
  echo -e "$ROOT_PASSWORD\n$ROOT_PASSWORD" | passwd root

  useradd -mG wheel -s /bin/bash "$USER_NAME"
  echo -e "$USER_PASSWORD\n$USER_PASSWORD" | passwd "$USER_NAME"
  sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
  systemctl enable NetworkManager

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
  preflight_checks

  clear; box "[1/5] Enter machine details" 70 Ω
  input "Hostname: " HOSTNAME no valid_hostname
  password "Root password (min 6 chars): " ROOT_PASSWORD
  input "Username: " USER_NAME no valid_username
  password "User password (min 6 chars): " USER_PASSWORD

  select_drive

  clear; box "[3/5] Review & confirm" 70 Ω
  printf ' Hostname:  %s\n Username:  %s\n Drive:     %s\n Timezone:  %s\n Keymap:    %s\n\n' \
    "$HOSTNAME" "$USER_NAME" "$DRIVE" "$TIMEZONE" "$KEYMAP"
  info "This will ERASE ALL DATA on $DRIVE. This cannot be undone."
  ask "Type YES to continue: "; read -r ack
  [[ $ack == YES ]] || { info "Aborted."; exit 0; }

  clear; box "[4/5] Partitioning & Formatting" 70 Ω
  partition_and_mount

  clear; box "[5/5] Installing Arch Linux" 70 Ω
  install_base

  # Fetch this script into the new root (rather than `cp "$0"`, which breaks
  # when main.sh is piped straight into bash and $0 isn't a real file) so
  # arch-chroot can re-invoke it there with "chroot" as $1, landing in
  # chroot_phase() above.
  info "Entering chroot..."
  curl -fsSL -o /mnt/setup.sh "$MAIN_URL"
  install -m 600 /dev/null /mnt/creds
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD" > /mnt/creds
  arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" USER_NAME="$USER_NAME" \
    VERBOSE="$VERBOSE" /bin/bash /setup.sh chroot

  clear; box "DONE! Rebooting in 5s..." 70 Ω
  sleep 5 && reboot
}

# Entry point: with no args (live ISO) run the installer; re-invoked with
# "chroot" (from inside main(), above) it only runs the chroot phase.
[[ ${1:-} == chroot ]] && chroot_phase || main
