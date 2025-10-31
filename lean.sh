#!/bin/bash
set -eo pipefail  # Fail fast: exit on error, pipe fail

# ── Configuration ─────────────────────────────────────────────────────
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'

# ── Colors ───────────────────────────────────────────────────────────
BOLD='\e[1m' BGREEN='\e[92m' BYELLOW='\e[93m' RESET='\e[0m'

info_print() { printf "${BOLD}${BGREEN}[ ${BYELLOW}•${BGREEN} ] %b${RESET}\n" "$1"; }

# ── Redirect stdin from TTY ──────────────────────────────────────────
exec < /dev/tty

# ── Drive Selection Menu ─────────────────────────────────────────────
select_drive() {
  mapfile -t options < <(lsblk -dno PATH | grep -v '^/dev/loop')
  (( ${#options[@]} )) || { info_print "No drives found."; exit 1; }

  local selected=0 total=${#options[@]}

  draw_menu() {
    clear
    info_print "###########################################"
    info_print "#        Select installation drive        #"
    info_print "###########################################"
    info_print ""

    for ((i=0; i<total; i++)); do
      [[ $i -eq $selected ]] && \
        info_print "# > \033[7m${options[i]}\033[0m" || \
        info_print "#   ${options[i]}  "
    done

    info_print ""
    info_print "###########################################"
    info_print "#   ↑↓ to navigate, Enter to select       #"
    info_print "###########################################"
  }

  read_key() {
    local key
    read -rsn1 key
    [[ $key == $'\x1b' ]] && read -rsn2 -t 0.1 key && case $key in
      '[A') ((selected--)); (( selected < 0 )) && selected=$((total-1)) ;;
      '[B') ((selected++)); (( selected >= total )) && selected=0 ;;
    esac
    [[ -z $key ]] && return 0  # Enter pressed
    return 1
  }

  while :; do
    draw_menu
    read_key && break
  done

  DRIVE=${options[selected]}
  [[ -b $DRIVE ]] || { info_print "Invalid drive."; exit 1; }

  echo -e "\nUse $DRIVE? ALL DATA WILL BE ERASED!"
  read -rn1 -p "Press Enter to confirm, any other key to cancel... " confirm
  [[ -z $confirm ]] || exit 0
  info_print "Selected: $DRIVE"
  DRIVE_TYPE=$(get_drive_type "$DRIVE")
}

get_drive_type() { [[ $1 =~ /dev/nvme ]] && echo "nvme" || echo "sda"; }

# ── Partitioning ─────────────────────────────────────────────────────
partition_drive() {
  local drive=$1 suffix=$([[ $DRIVE_TYPE == nvme ]] && echo "p" || echo "")
  parted -s "$drive" mklabel gpt \
    mkpart primary fat32 1MiB 513MiB set 1 esp on \
    mkpart primary linux-swap 513MiB 8705MiB \
    mkpart primary btrfs 8705MiB 100%

  BOOT_PART="${drive}${suffix}1"
  SWAP_PART="${drive}${suffix}2"
  ROOT_PART="${drive}${suffix}3"
}

format_filesystems() {
  mkfs.fat -F32 -n BOOT "$BOOT_PART"
  mkfs.btrfs -f -L ROOT "$ROOT_PART"
  mkswap -L SWAP "$SWAP_PART"
}

mount_filesystems() {
  mount "$ROOT_PART" /mnt
  btrfs subvolume create /mnt/@ /mnt/@home
  umount /mnt

  mount -o subvol=@ "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home}
  mount -o subvol=@home "$ROOT_PART" /mnt/home
  mount "$BOOT_PART" /mnt/boot
  swapon "$SWAP_PART"
}

# ── Setup (Outside Chroot) ───────────────────────────────────────────
setup() {
  read -p "Hostname: " HOSTNAME
  read -s -p "Root password: " ROOT_PASSWORD; echo
  read -p "Username: " USER_NAME
  read -s -p "User password: " USER_PASSWORD; echo

  select_drive

  info_print "Creating partitions..."
  partition_drive "$DRIVE"

  info_print "Formatting..."
  format_filesystems

  info_print "Mounting..."
  mount_filesystems

  info_print "Installing base system..."
  pacstrap -K /mnt base linux linux-firmware

  info_print "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab

  info_print "Entering chroot..."
  cp "$0" /mnt/setup.sh
  arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_NAME="$USER_NAME" \
    USER_PASSWORD="$USER_PASSWORD" \
    /bin/bash /setup.sh chroot

  info_print "Rebooting in 5 seconds..."
  sleep 5 && reboot
}

# ── Configure (Inside Chroot) ────────────────────────────────────────
configure() {
  info_print "Installing essentials..."
  pacman -Sy --noconfirm grub efibootmgr btrfs-progs nano networkmanager sudo

  info_print "Setting timezone & locale..."
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc
  sed -i 's/#en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  sed -i 's/#pt_PT\.UTF-8 UTF-8/pt_PT.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen
  echo -e 'LANG=pt_PT.UTF-8\nLC_MESSAGES=en_US.UTF-8' > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

  info_print "Setting hostname & users..."
  echo "$HOSTNAME" > /etc/hostname
  echo -e "$ROOT_PASSWORD\n$ROOT_PASSWORD" | passwd
  useradd -mG wheel -s /bin/bash "$USER_NAME"
  echo -e "$USER_PASSWORD\n$USER_PASSWORD" | passwd "$USER_NAME"
  sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

  info_print "Installing GRUB..."
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg

  info_print "Enabling NetworkManager..."
  systemctl enable NetworkManager

  info_print "Downloading post-install script..."
  local url="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post.sh"
  local dest="/home/$USER_NAME/post.sh"
  if curl -fsSL "$url" -o "$dest"; then
    chown "$USER_NAME:$USER_NAME" "$dest"
    chmod 755 "$dest"
    info_print "post.sh ready at $dest"
  else
    info_print "Failed to download post.sh"
  fi

  rm -f /setup.sh
}

# ── Main ─────────────────────────────────────────────────────────────
[[ $1 == chroot ]] && configure || setup
