#!/bin/bash

# Configuration
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'

# Cosmetics (colours for text).
BOLD='\e[1m'
BGREEN='\e[92m'
BYELLOW='\e[93m'
RESET='\e[0m'

# Pretty print (function).
info_print () {
    echo -e "${BOLD}${BGREEN}[ ${BYELLOW}•${BGREEN} ] $1${RESET}"
}

exec </dev/tty

# ── Drive Selection Menu ─────────────────────────────────────────────
select_drive() {
  # Get block devices, exclude loop devices
  mapfile -t options < <(lsblk -dno PATH | grep -v loop)
  [[ ${#options[@]} -eq 0 ]] && { echo "No drives found. Exiting."; exit 1; }

  selected=0
  total_options=${#options[@]}

  draw_menu() {
    clear
    info_print "###########################################"
    info_print "#        Select installation drive        #"
    info_print "###########################################"
    info_print "#"

    for ((i=0; i<total_options; i++)); do
      [[ $i -eq $selected ]] && info_print "# > \033[7m${options[i]}\033[0m" || info_print "#   ${options[i]}  "
    done
    
    info_print "#"
    info_print "###########################################"
    info_print "#   Use ↑↓ to navigate, Enter to select   #"
    info_print "###########################################"
  }

  read_arrow() {
    local key
    read -rsn1 key
    [[ $key == $'\x1b' ]] && { read -rsn2 -t 0.1 key 2>/dev/null; case $key in
      '[A') ((selected--)); [[ $selected -lt 0 ]] && selected=$((total_options-1)); return 1 ;;
      '[B') ((selected++)); [[ $selected -ge $total_options ]] && selected=0; return 1 ;;
      *) return 1 ;;
    esac; }
    [[ -z $key ]] && return 0
    return 1
  }

  while true; do
    draw_menu
    read_arrow
    [[ $? -eq 0 ]] || continue  # Only proceed if Enter was pressed (return 0)
    DRIVE=${options[selected]}
    [[ -b $DRIVE ]] || { echo "Error: Invalid block device."; exit 1; }
    echo "Use $DRIVE for Arch install? ALL DATA WILL BE LOST! (Enter to confirm, Esc/other to cancel)"
    read -rsn1 confirm
    [[ -z $confirm ]] && { echo "Selected: $DRIVE"; DRIVE_TYPE=$(get_drive_type "$DRIVE"); return 0; }
  done
}

get_drive_type() {
  case $1 in
    /dev/nvme*) echo "nvme" ;;
    /dev/sd*) echo "sda" ;;
    *) echo "unknown"; exit 1 ;;
  esac
}


# ── Partitioning ─────────────────────────────────────────────────────
partition_drive() {
  local drive="$1"
  parted -s "$drive" mklabel gpt mkpart primary fat32 1MiB 513MiB set 1 boot on mkpart primary linux-swap 513MiB 8705MiB mkpart primary btrfs 8705MiB 100%
  partition_suffix=$([[ $DRIVE_TYPE == "nvme" ]] && echo "p" || echo "")
  BOOT_PARTITION="${drive}${partition_suffix}1"
  SWAP_PARTITION="${drive}${partition_suffix}2"
  ROOT_PARTITION="${drive}${partition_suffix}3"
}

format_filesystems() {
  mkfs.fat -F 32 -n boot "$BOOT_PARTITION"
  mkfs.btrfs -f -L root "$ROOT_PARTITION"
  mkswap -L swap "$SWAP_PARTITION"
}

mount_filesystems() {
  mount "$ROOT_PARTITION" /mnt
  btrfs subvolume create /mnt/@{,home}
  umount /mnt
  mount -o subvol=@ "$ROOT_PARTITION" /mnt
  mkdir -p /mnt/{home,boot}
  mount -o subvol=@home "$ROOT_PARTITION" /mnt/home
  mount "$BOOT_PARTITION" /mnt/boot
  swapon "$SWAP_PARTITION"
}

# ── Setup (Outside Chroot) ───────────────────────────────────────────
setup() {
  read -p "Enter hostname: " HOSTNAME
  echo "Enter root password:"
  stty -echo; read ROOT_PASSWORD; stty echo
  read -p "Enter username: " USER_NAME
  echo "Enter password for $USER_NAME:"
  stty -echo; read USER_PASSWORD; stty echo

  select_drive
  local drive="$DRIVE"

  info_print "##### Creating partitions #####"
  partition_drive "$drive"
  info_print "##### Formatting filesystems #####"
  format_filesystems
  echinfo_printo "##### Mounting filesystems #####"
  mount_filesystems
  info_print "##### Installing base system #####"
  pacstrap -K /mnt base linux linux-firmware
  info_print "##### Generating fstab #####"
  genfstab -U /mnt >> /mnt/etc/fstab
  info_print "##### Chrooting #####"
  cp "$0" /mnt/setup.sh
  arch-chroot /mnt env HOSTNAME="$HOSTNAME" ROOT_PASSWORD="$ROOT_PASSWORD" USER_NAME="$USER_NAME" USER_PASSWORD="$USER_PASSWORD" ./setup.sh chroot
  reboot
}

# ── Configure (Inside Chroot) ────────────────────────────────────────
configure() {
  info_print "##### Installing essential packages #####"
  pacman -Sy --noconfirm grub efibootmgr btrfs-progs nano networkmanager sudo

  info_print "##### Setting timezone & region settings #####"
  ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
  hwclock --systohc
  sed -i 's/#en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  sed -i 's/#pt_PT\.UTF-8 UTF-8/pt_PT.UTF-8 UTF-8/' /etc/locale.gen
  echo -e 'LANG=pt_PT.UTF-8\nLC_MESSAGES=en_US.UTF-8' > /etc/locale.conf
  locale-gen
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

  info_print "##### Setting hostname, sudoers and users #####"
  echo "$HOSTNAME" > /etc/hostname
  sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
  echo -en "$ROOT_PASSWORD\n$ROOT_PASSWORD" | passwd
  useradd -mG wheel -s /bin/bash "$USER_NAME"
  echo -en "$USER_PASSWORD\n$USER_PASSWORD" | passwd "$USER_NAME"

  info_print "##### Installing bootloader #####"
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
  
  info_print "##### Enabling network manager #####"
  systemctl enable NetworkManager

  info_print "##### Downloading post reboot script #####"
  curl -s -o "/home/$USER_NAME/post.sh" "https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post.sh" && \
    chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/post.sh" && chmod 755 "/home/$USER_NAME/post.sh" || \
    echo "Error: Failed to download or set up post.sh"
    
  rm /setup.sh
}

# ── Main ─────────────────────────────────────────────────────────────
[[ $1 == chroot ]] && configure || setup
