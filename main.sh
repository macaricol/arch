#!/usr/bin/env bash
# Arch Linux installer – ultra-compact, robust & fast (2025 edition)
set -eo pipefail
IFS=$'\n\t'
shopt -s nocasematch extglob

# ── Source utilities ─────────────────────────────────────────────────────
UTILS_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/utils.sh"
curl -fsSL -O "$UTILS_URL"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh" || { echo "Failed to load utils.sh" >&2; exit 1; }

# ── CONFIG ─────────────────────────────────────────────────────────────
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'
POST_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post.sh"

# ── PARTITION & FORMAT ───────────────────────────────────────────────
partition_and_mount() {
  local type=''
  [[ $DRIVE =~ nvme ]] && type=p
  info "Wiping & partitioning $DRIVE..."
  run sgdisk -Z \
    -n1:1M:512M   -t1:ef00 -c1:EFI \
    -n2:513M:8704M -t2:8200 -c2:Swap \
    -n3:8705M:0    -t3:8300 -c3:Root "$DRIVE"

  local boot="${DRIVE}${type}1" swap="${DRIVE}${type}2" root="${DRIVE}${type}3"
  [[ -b $boot && -b $swap && -b $root ]] || die "Partitioning failed"

  info "Formatting..."
  run mkfs.fat -F32 -n BOOT "$boot"
  run mkswap -L SWAP "$swap"
  run mkfs.btrfs -f -L ROOT "$root"

  info "Mounting Btrfs subvolumes..."
  mount "$root" /mnt
  btrfs su cr /mnt/@ /mnt/@home
  umount /mnt

  mount -o noatime,compress=zstd:1,subvol=@ "$root" /mnt
  mkdir -p /mnt/{boot,home}
  mount -o noatime,compress=zstd:1,subvol=@home "$root" /mnt/home
  mount "$boot" /mnt/boot
  swapon "$swap"
}

# ── BASE INSTALL ─────────────────────────────────────────────────────
install_base() {
  info "Optimizing mirrors (PT+ES)..."
  run reflector --country 'PT,ES' --latest 8 --protocol https --sort rate --number 6 --save /etc/pacman.d/mirrorlist --verbose || true

  run pacman -Syy --noconfirm
  sed -i '/\[options\]/a ILoveCandy' /etc/pacman.conf

  info "Pacstrap base system..."
  run pacstrap -K /mnt base linux linux-firmware btrfs-progs grub efibootmgr nano networkmanager sudo

  genfstab -U /mnt >> /mnt/etc/fstab
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

# ── CHROOT PHASE ─────────────────────────────────────────────────────
chroot_phase() {
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc --utc

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

  info "Downloading post-install script..."
  curl -fsSL "$POST_URL" -o "/home/$USER_NAME/post.sh"
  chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/post.sh"
  chmod +x "/home/$USER_NAME/post.sh"
}

# ── MAIN ─────────────────────────────────────────────────────────────
main() {
  clear; box "Enter machine details" 70 Ω
  input "Hostname: " HOSTNAME no valid_hostname
  input "Root password (min 6 chars): " ROOT_PASSWORD yes valid_password
  input "Username: " USER_NAME no valid_username
  input "User password (min 6 chars): " USER_PASSWORD yes valid_password

  select_drive
  clear; box "Partitioning & Formatting" 70 Ω
  partition_and_mount

  clear; box "Installing Arch Linux" 70 Ω
  install_base

  info "Entering chroot..."
  cp "$0" /mnt/setup.sh
  arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_NAME="$USER_NAME" USER_PASSWORD="$USER_PASSWORD" \
    VERBOSE="$VERBOSE" /bin/bash /setup.sh chroot

  clear; box "DONE! Rebooting in 5s..." 70 Ω
  sleep 5 && reboot
}

[[ ${1:-} == chroot ]] && chroot_phase || main
