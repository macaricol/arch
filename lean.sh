#!/usr/bin/env bash
set -eo pipefail
IFS=$'\n\t'

# ── Configuration ─────────────────────────────────────────────────────
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'

# ── Colors ───────────────────────────────────────────────────────────
BOLD='\e[1m' BGREEN='\e[92m' BYELLOW='\e[93m' RESET='\e[0m'


die() { printf '\e[1;31mERROR: %b\e[0m\n' "$*"; exit 1; } >&2
info() { printf '\e[1;92m[•] %b\e[0m\n' "$*"; }
box() {
  local title=" $1 "          # one space before & after
  local w="${2:-70}" c="${3:-#}"
  local line=$(printf '%*s' "$w" '' | tr ' ' "$c")

  local inner=$(( w - 2 ))
  local left=$(( (inner - ${#title}) / 2 ))
  local right=$(( inner - ${#title} - left ))

  local left_fill=$(printf '%*s' "$left" '' | tr ' ' "$c")
  local right_fill=$(printf '%*s' "$right" '' | tr ' ' "$c")

  # top
  printf '\e[35m%s\e[0m\n' "$line"

  # middle: # + fill + title + fill + #
  printf '\e[35m%s\e[36m%s\e[0m\e[35m%s\e[0m\n' \
         "${c}${left_fill}" "$title" "${right_fill}${c}"

  # bottom
  printf '\e[35m%s\e[0m\n' "$line"
}

# ── Colored outputs ──────────────────────────────────────────

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
    box "Select installation drives"
    printf "#"

    for ((i=0; i<total; i++)); do
      [[ $i -eq $selected ]] && \
        info_print "# > \033[7m${options[i]}\033[0m" || \
        info_print "#   ${options[i]}  "
    done

    printf "#"
    box "↑↓ navigate – Enter select – ESC cancel"
  }

  read_key() {
    local key seq
    read -rsn1 key

    if [[ $key == $'\x1b' ]]; then
      if read -rsn2 -t 0.1 seq; then
        [[ $seq == '[A' ]] && ((selected--))
        [[ $seq == '[B' ]] && ((selected++))
        (( selected < 0 )) && selected=$((total-1))
        (( selected >= total )) && selected=0
      else
        clear; info_print "Operation cancelled."; exit 0
      fi
      return 1
    fi

    [[ -z $key ]] && return 0  # Enter
    return 1                   # Ignore others
  }

  while :; do
    draw_menu
    read_key && break
  done

  DRIVE="${options[selected]}"
  read -rn1 -p $'\n\e[33mUse '"$DRIVE"'? ALL DATA WILL BE ERASED! (Enter=yes)\e[0m ' c
  [[ -z $c ]] || exit 0
  info "Selected $DRIVE"
}

# ── Partitioning (sgdisk – one shot) ─────────────────────────────
partition_drive() {
  local dev=$1
  local type=$( (( dev =~ nvme )) && echo p || echo "" )

  info "Wiping & creating GPT partitions"
  sgdisk -Z \
    -n 1:1M:512M -t 1:ef00 -c 1:EFI \
    -n 2:513M:8704M -t 2:8200 -c 2:Swap \
    -n 3:8705M:0 -t 3:8300 -c 3:Root \
    "$dev" || die "sgdisk failed"

  BOOT_PART="${dev}${type}1"
  SWAP_PART="${dev}${type}2"
  ROOT_PART="${dev}${type}3"
}

# ── Filesystems & mount (single mount, subvols on-the-fly) ───────
format_and_mount() {
  info "Formatting"
  mkfs.fat -F32 -n BOOT "$BOOT_PART"
  mkswap -L SWAP "$SWAP_PART"
  mkfs.btrfs -f -L ROOT "$ROOT_PART"

  info "Mounting"
  mount "$ROOT_PART" /mnt
  btrfs su cr /mnt/@
  btrfs su cr /mnt/@home
  umount /mnt

  mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home}
  mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
  mount "$BOOT_PART" /mnt/boot
  swapon "$SWAP_PART"

  info "Generating fstab"
  genfstab -U /mnt >> /mnt/etc/fstab
}

# ── Base system ─────────────────────────────────────────────────
install_base() {
  info "Pacstrap base system"
  pacstrap -K /mnt base linux linux-firmware btrfs-progs \
    grub efibootmgr nano networkmanager sudo || die "pacstrap failed"
}

# ── Setup (Outside Chroot) ───────────────────────────────────────────
setup() {
  box "Capturing machine/user details"
  info_print ""
  read -p "Hostname: " HOSTNAME
  read -s -p "Root password: " ROOT_PASSWORD; echo
  read -p "Username: " USER_NAME
  read -s -p "User password: " USER_PASSWORD; echo

  select_drive

  box "Preparing drive for installation"
  printf ""

  info_print "Creating partitions..."
  partition_drive "$DRIVE"

  info_print "Formatting and mounting..."
  format_and_mount

  box "Installing Arch Linux"
  printf ""
  info_print "Installing base packages..."
  install_base

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
