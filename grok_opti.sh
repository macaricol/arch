#!/usr/bin/env bash
# Arch Linux installer – compact, robust, fast
set -eo pipefail
IFS=$'\n\t'

# ── Helpers ─────────────────────────────────────────────────────
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

# ── Config ───────────────────────────────────────────────────────
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'
MNT=/mnt

# ── Drive selection (curses-free) ─────────────────────────────────
select_drive() {
  mapfile -t options < <(printf '/dev/sdummy\n'; lsblk -dplno PATH,TYPE | awk '$2=="disk"{print $1}')
  (( ${#options[@]} )) || die "No block devices found"
  local selected=0 total=${#options[@]}

  draw_menu() {
    clear
    box "Select installation drive"
    for ((i=0; i<${#options[@]}; i++)); do
      if (( i == selected )); then
        printf ' \e[7m>\e[0m %s\n' "${options[i]}"
      else
        printf '   %s\n' "${options[i]}"
      fi
    done
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
        clear; info "Operation cancelled."; exit 0
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

  DRIVE=${options[selected]}
  [[ -b $DRIVE ]] || { info "Invalid drive."; exit 1; }

  echo -e "\n Use $DRIVE? ALL DATA WILL BE ERASED!"
  read -rn1 -p " Press Enter to confirm, any other key to cancel... " confirm
  [[ -z $confirm ]] || exit 0
  info "Selected: $DRIVE"
}

# ── Partitioning (sgdisk – one shot) ─────────────────────────────
partition_drive() {
  local dev=$1
  local type=''
  [[ $dev =~ nvme ]] && type='p'
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
  mount "$ROOT_PART" "$MNT"
  btrfs su cr "$MNT"/@
  btrfs su cr "$MNT"/@home
  umount "$MNT"

  mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" "$MNT"
  mkdir -p "$MNT"/{boot,home}
  mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" "$MNT/home"
  mount "$BOOT_PART" "$MNT/boot"
  swapon "$SWAP_PART"
}

# ── Base system ─────────────────────────────────────────────────
install_base() {
  info "Pacstrap base system"
  pacstrap -K "$MNT" base linux linux-firmware btrfs-progs \
    grub efibootmgr nano networkmanager sudo || die "pacstrap failed"

  info "Generating fstab"
  genfstab -U "$MNT" >> "$MNT/etc/fstab"
}

# ── Chroot phase (executed when script is run with 'chroot' arg) ─
chroot_phase() {
  set -eo pipefail

  pacman -Sy --noconfirm

  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc

  sed -i '/^#.*UTF-8/ d;/en_US\.UTF-8/ s/#//;/pt_PT\.UTF-8/ s/#//' /etc/locale.gen
  locale-gen
  echo -e "LANG=pt_PT.UTF-8\nLC_MESSAGES=en_US.UTF-8" > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

  echo "$HOSTNAME" > /etc/hostname
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd --stdin root
  useradd -mG wheel -s /bin/bash "$USER_NAME"
  printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" | passwd --stdin "$USER_NAME"
  sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
  systemctl enable NetworkManager

  # post-install helper
  curl -fsSL https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post.sh \
      -o /home/"$USER_NAME"/post.sh && \
  chown "$USER_NAME:$USER_NAME" /home/"$USER_NAME"/post.sh && chmod +x /home/"$USER_NAME"/post.sh && \
  info "post.sh downloaded"

  rm -f /setup.sh
}

# ── Main flow ───────────────────────────────────────────────────
main() {
  clear
  box "Capturing machine/user details" 70 =
  read -p "Hostname: " HOSTNAME
  read -s -p "Root password: " ROOT_PASSWORD; echo
  read -p "Username: " USER_NAME
  read -s -p "User password: " USER_PASSWORD; echo

  select_drive

  box "Preparing drive for installation" 70 =
  partition_drive "$DRIVE"
  format_and_mount

  box "Installing Arch Linux" 70 =
  install_base

  info "Entering chroot..."
  cp "$0" /mnt/setup.sh
  arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_NAME="$USER_NAME" \
    USER_PASSWORD="$USER_PASSWORD" \
    /bin/bash /setup.sh chroot

  box "Rebooting in 5 seconds..." 70 =
  sleep 5 && reboot
}

[[ $1 == chroot ]] && chroot_phase || main