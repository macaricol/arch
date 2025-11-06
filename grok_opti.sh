#!/usr/bin/env bash
# Arch Linux installer – ultra-compact, robust & fast (2025 edition)
set -eo pipefail
IFS=$'\n\t'
shopt -s nocasematch extglob

# ── CONFIG ─────────────────────────────────────────────────────────────
VERBOSE=${VERBOSE:-1}
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'
POST_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post.sh"

# ── TOOLS ─────────────────────────────────────────────────────────────
run() { ((VERBOSE)) && "$@" || "$@" &>/dev/null; }
die() { printf '\e[91;1m[ Ω ] %b\e[0m\n' "$*" >&2; exit 1; }
info() { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m\n\n' "$*"; }
box() {
  local t=" $1 " w=${2:-70} c=${3:-Ω}
  local line=$(printf '%*s' "$w" '' | tr ' ' "$c")
  local pad=$(( (w - 2 - ${#t}) / 2 ))
  local side=$(printf '%*s' "$pad" '' | tr ' ' "$c")
  local rest=$(printf '%*s' "$((w - 2 - ${#t} - pad))" '' | tr ' ' "$c")

  printf '\n\e[35m%s\n%s\e[36m%s\e[35m%s\e[0m\n\e[35m%s\e[0m\n\n' \
    "$line" "$c$side" "$t" "$rest$c" "$line"
}

# ── INPUT & VALIDATION ────────────────────────────────────────────────
ask() { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m ' "$1"; }
valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && (( ${#1} <= 63 )); }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_password() { (( ${#1} >= 6 )); }

input() {
  local prompt=$1 var=$2 secure=${3:-no} validator=${4:-}
  while :; do
    ask "$prompt"
    if [[ $secure == yes ]]; then read -rs val; echo; else read -r val; fi
    val="${val##+([[:space:]])}"; val="${val%%+([[:space:]])}"
    [[ -n $validator && -z $val ]] && { echo -e '\e[93m[ Ω ] Cannot be empty\e[0m'; continue; }
    [[ -n $validator ]] && ! "$validator" "$val" && { echo -e '\e[93m[ Ω ] Invalid\e[0m'; continue; }
    printf -v "$var" '%s' "$val"
    return 0
  done
}

# ── DRIVE SELECTION (TUI) ─────────────────────────────────────────────
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
    [[ -z $key ]] && return 0
    return 1  
  }  
  while :; do
    draw_menu
    read_key && break
  done  
  DRIVE=${options[selected]}
  [[ -b $DRIVE ]] || die "Invalid drive."  
  info "Use $DRIVE? ALL DATA WILL BE ERASED!"
  ask "Press Enter to confirm, any other key to cancel... "
  [[ -z $confirm ]] || exit 0
  info "Selected: $DRIVE"
}

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
  input "Root password (≥6): " ROOT_PASSWORD yes valid_password
  input "Username: " USER_NAME no valid_username
  input "User password (≥6): " USER_PASSWORD yes valid_password

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