#!/usr/bin/env bash
# Arch Linux installer – compact, robust, fast
set -eo pipefail
IFS=$'\n\t'

# ── Helpers ─────────────────────────────────────────────────────
#die() { printf '\e[1;31m[ ✗ ]ERROR: %b\e[0m\n' "$*"; exit 1; } >&2
#info() { printf '\e[1;92m[ Ω ] %b\e[0m\n' "$*"; }
info()    { printf '\e[96;1m[ Ω ]\e[0m \e[97m%b\e[0m\n' "$*"; sleep 3; }
warning() { printf '\e[93;1m[ Ω ]\e[0m \e[97m%b\e[0m\n' "$*" >&2; sleep 3; }
error()   { printf '\e[91;1m[ Ω ]\e[0m \e[97m%b\e[0m\n' "$*" >&2; sleep 3; }
die()     { error "$*"; exit 1; }
info_input() {
    local prompt_msg="$1"
    local var_name="$2"
    local secure="${3:-no}"        # "yes" = hide input
    local validator="${4:-}"       # Optional: function name to validate
    local input

    while :; do
        # Print styled prompt
        printf '\e[96;1m[ \e[5mΩ\e[25m ]\e[0m \e[97m%b\e[0m' "$prompt_msg"

        if [[ $secure == yes ]]; then
            read -rs input
            echo  # Newline after hidden input
        else
            read -r input
            echo "$input"  # Echo visible input
        fi

        # Trim whitespace
        input="${input#"${input%%[![:space:]]*}"}"  # leading
        input="${input%"${input##*[![:space:]]}"}"  # trailing

        # Validate if function provided
        if [[ -n $validator ]] && ! "$validator" "$input"; then
            warning "Invalid input. Try again."
            continue
        fi

        # Non-empty check
        if [[ -z $input ]]; then
            warning "Input cannot be empty."
            continue
        fi

        # Success: assign to variable
        printf -v "$var_name" '%s' "$input"
        return 0
    done
}

# Validators
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && [[ ${#1} -le 63 ]]; }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_password() { [[ ${#1} -ge 8 ]]; }

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
  [[ -b $DRIVE ]] || { die "Invalid drive."; }

  warning "\n Use $DRIVE? ALL DATA WILL BE ERASED!"
  info_prompt " Press Enter to confirm, any other key to cancel... " confirm
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
  mount "$ROOT_PART" /mnt
  btrfs su cr /mnt/@
  btrfs su cr /mnt/@home
  umount /mnt

  mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home}
  mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
  mount "$BOOT_PART" /mnt/boot
  swapon "$SWAP_PART"
}

# ── Base system ─────────────────────────────────────────────────
install_base() {
  info "Pacstrap base system"
  pacstrap -K /mnt base linux linux-firmware btrfs-progs \
    grub efibootmgr nano networkmanager sudo || die "pacstrap failed"

  info "Generating fstab"
  genfstab -U /mnt >> /mnt/etc/fstab
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
  box "Capturing machine/user details" 70 Ω
  sleep 5
  info_input "Hostname: " HOSTNAME no valid_hostname
  info_input "Root password: " ROOT_PASSWORD yes valid_password
  info_input "Username: " USER_NAME no valid_username
  info_input "User password: " USER_PASSWORD yes valid_password

  select_drive

  box "Preparing drive for installation" 70 Ω
  sleep 5
  partition_drive "$DRIVE"
  format_and_mount

  box "Installing Arch Linux" 70 Ω
  sleep 5
  install_base

  info "Entering chroot..."
  cp "$0" /mnt/setup.sh
  arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_NAME="$USER_NAME" \
    USER_PASSWORD="$USER_PASSWORD" \
    /bin/bash /setup.sh chroot

  box "Rebooting in 5 seconds..." 70 Ω
  sleep 5 && reboot
}

[[ $1 == chroot ]] && chroot_phase || main