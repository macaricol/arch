#!/usr/bin/env bash
# Arch Linux installer – compact, robust, fast
set -eo pipefail
IFS=$'\n\t'

# ── VERBOSE CONTROL ─────────────────────────────────────────────
: "${VERBOSE:=1}"  # Default: 1 (see all output), set to 0 for silent

run() {
    if (( VERBOSE )); then
        "$@"
    else
        "$@" &>/dev/null
    fi
}

# ── Helpers ─────────────────────────────────────────────────────
info()    { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m\n' "$*"; }
warning() { printf '\e[93;1m[ Ω ]\e[0m \e[97m%s\e[0m\n' "$*" >&2; }
error()   { printf '\e[91;1m[ Ω ]\e[0m \e[97m%s\e[0m\n' "$*" >&2; }
die()     { error "$*"; exit 1; }

info_prompt() {
    local confirm
    read -rn1 -p "$(printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m ' "$1")" confirm
    echo
    [[ $confirm == $'\n' ]] || [[ -z $confirm ]]
}

info_input() {
    local prompt_msg="$1" var_name="$2" secure="${3:-no}" validator="${4:-}"
    local input

    while :; do
        printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m' "$prompt_msg"

        if [[ $secure == yes ]]; then
            read -rs input
            echo
        else
            read -r input
        fi

        # Trim
        input="${input#"${input%%[![:space:]]*}"}"
        input="${input%"${input##*[![:space:]]}"}"

        if [[ -n $validator ]]; then
            [[ -z $input ]] && { warning "Cannot be empty."; continue; }
            if ! "$validator" "$input"; then
                warning "Invalid input."
                continue
            fi
        fi

        printf -v "$var_name" '%s' "$input"
        return 0
    done
}

# Validators
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && (( ${#1} <= 63 )); }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_password() { (( ${#1} >= 6 )); }

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

# ── Drive selection (UNCHANGED as requested) ─────────────────────
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

  warning "Use $DRIVE? ALL DATA WILL BE ERASED!"
  info_prompt "Press Enter to confirm, any other key to cancel... "
  [[ -z $confirm ]] || exit 0
  info "Selected: $DRIVE"
}

# ── Partitioning ─────────────────────────────────────────────────
partition_drive() {
  local dev=$1 type=''
  [[ $dev =~ nvme ]] && type='p'

  info "Wiping and creating GPT partitions..."
  run sgdisk -Z \
    -n 1:1M:512M -t 1:ef00 -c 1:EFI \
    -n 2:513M:8704M -t 2:8200 -c 2:Swap \
    -n 3:8705M:0 -t 3:8300 -c 3:Root \
    "$dev" || die "sgdisk failed"

  BOOT_PART="${dev}${type}1"
  SWAP_PART="${dev}${type}2"
  ROOT_PART="${dev}${type}3"

  # Verify partitions exist
  [[ -b $BOOT_PART ]] || die "EFI partition not created"
  [[ -b $SWAP_PART ]] || die "Swap partition not created"
  [[ -b $ROOT_PART ]] || die "Root partition not created"
}

# ── Format & Mount ───────────────────────────────────────────────
format_and_mount() {
  info "Formatting filesystems..."
  run mkfs.fat -F32 -n BOOT "$BOOT_PART"
  run mkswap -L SWAP "$SWAP_PART"
  run mkfs.btrfs -f -L ROOT "$ROOT_PART"

  info "Mounting with Btrfs subvolumes..."
  mount "$ROOT_PART" /mnt
  run btrfs su cr /mnt/@
  run btrfs su cr /mnt/@home
  umount /mnt

  mount -o noatime,compress=zstd:1,subvol=@ "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home}
  mount -o noatime,compress=zstd:1,subvol=@home "$ROOT_PART" /mnt/home
  mount "$BOOT_PART" /mnt/boot
  swapon "$SWAP_PART"
}

# ── Base Install ─────────────────────────────────────────────────
install_base() {
  info "Optimizing mirrors (Portugal & Spain)..."
  run reflector --country 'PT,ES' --latest 8 --protocol https --sort rate \
            --number 6 --save /etc/pacman.d/mirrorlist --verbose || true

  info "Syncing package databases..."
  run pacman -Syy --noconfirm || die "Failed to sync databases"

  info "Installing base system (this may take a while)..."

  local pkgs=(base linux linux-firmware btrfs-progs grub efibootmgr nano networkmanager sudo)
  local pkg_list="${pkgs[*]}"

  clear
  box "Installing Arch Linux" 70 Ω
  printf '   \e[96;1mResolving dependencies...\e[0m\n\n'
  tput civis

  # ── DYNAMIC TOTAL: Count every package that will be installed ──
  local total_pkgs=0
  local temp_file=$(mktemp)

  # Simulate install to count exact number of packages
  if pacman -Swp --noconfirm $pkg_list >"$temp_file" 2>&1; then
    total_pkgs=$(pacman -Qp --noconfirm $pkg_list 2>/dev/null | wc -l)
    (( total_pkgs == 0 )) && total_pkgs=$(grep -c " installing " "$temp_file" || echo 120)
  else
    total_pkgs=120  # fallback
  fi
  rm -f "$temp_file"

  # Fallback sanity
  (( total_pkgs < 50 )) && total_pkgs=120

  local width=50
  local done=0

  # ── LIVE PROGRESS WITH REAL COUNT ─────────────────────────────
  set +e
  run pacstrap -K /mnt $pkg_list 2>&1 | while IFS= read -r line; do
    if echo "$line" | grep -Eq "installing|retrieving|resolving|checking|::"; then
      ((done++))
      [[ $done -gt $total_pkgs ]] && done=$total_pkgs

      local percent=$(( done * 100 / total_pkgs ))
      local filled=$(( percent * width / 100 ))
      local bar=""
      printf -v bar '%*s' "$filled" ''; bar=${bar// /█}
      printf -v space '%*s' "$(( width - filled ))" ''

      local spin=('Installing   ' 'Installing.  ' 'Installing..' 'Installing...')
      local s="${spin[$(( done % 4 ))]}"

      printf '\r  \e[96;1m%s\e[0m %s%s \e[35m[ %s]\e[0m \e[97m%3d%%\e[0m  \e[2m%d/%d\e[0m' \
             "$s" "$bar" "$space" "█" "$percent" "$done" "$total_pkgs"
    fi
  done
  local exit_code=${PIPESTATUS[0]}
  set -e

  # Final bar
  if (( exit_code == 0 )); then
    printf '\r  \e[92;1mSuccess!\e[0m     %s%s \e[35m[ %s]\e[0m \e[97m100%%\e[0m  \e[32mArch Linux ready!\e[0m     \n\n' \
           "$(printf '█%.0s' {1..50})" "" "█"
  else
    printf '\r  \e[91;1mFailed!\e[0m      %s%s \e[35m[ %s]\e[0m \e[97m 99%%\e[0m  \e[31mretrying...\e[0m\n' \
           "$(printf '█%.0s' {1..49})" "" "█"
    sleep 5
    run pacstrap -K /mnt $pkg_list || die "pacstrap failed after retry"
    printf '\r  \e[92;1mSuccess!\e[0m     %s%s \e[35m[ %s]\e[0m \e[97m100%%\e[0m  \e[32mArch Linux ready!\e[0m     \n\n' \
           "$(printf '█%.0s' {1..50})" "" "█"
  fi

  tput cnorm
  sleep 1.2

  info "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab

  info "Copying optimized mirrorlist..."
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

# ── Chroot Phase ─────────────────────────────────────────────────
chroot_phase() {
  set -eo pipefail

  info "Setting timezone: $TIMEZONE"
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc --utc

  info "Configuring locale..."
  sed -i 's/#en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  sed -i 's/#pt_PT\.UTF-8 UTF-8/pt_PT.UTF-8 UTF-8/' /etc/locale.gen
  run locale-gen
  echo -e 'LANG=pt_PT.UTF-8\nLC_MESSAGES=en_US.UTF-8' > /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

  info "Setting hostname: $HOSTNAME"
  echo "$HOSTNAME" > /etc/hostname

  info "Setting root password..."
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | run passwd root

  info "Creating user: $USER_NAME"
  useradd -mG wheel -s /bin/bash "$USER_NAME"
  printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" | run passwd "$USER_NAME"
  sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

  info "Installing GRUB..."
  run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  run grub-mkconfig -o /boot/grub/grub.cfg

  info "Enabling NetworkManager..."
  run systemctl enable NetworkManager

  info "Downloading post-install helper..."
  local post_url="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post.sh"
  curl -fsSL "$post_url" -o "/home/$USER_NAME/post.sh" && \
    chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/post.sh" && \
    chmod +x "/home/$USER_NAME/post.sh" && \
    info "post.sh ready at /home/$USER_NAME/post.sh"

  rm -f /setup.sh
}

# ── Main ─────────────────────────────────────────────────────────
main() {
  clear
  box "Enter machine/user details" 70 Ω

  info_input "Hostname: " HOSTNAME no valid_hostname
  info_input "Root password (min 6 chars): " ROOT_PASSWORD yes valid_password
  info_input "Username: " USER_NAME no valid_username
  info_input "User password (min 6 chars): " USER_PASSWORD yes valid_password

  select_drive

  clear; box "Partitioning & Formatting" 70 Ω
  partition_drive "$DRIVE"
  format_and_mount

  clear; box "Installing Arch Linux" 70 Ω
  install_base

  info "Entering chroot to finalize..."
  sync  # Ensure all writes are flushed
  cp "$0" /mnt/setup.sh
  arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    USER_NAME="$USER_NAME" \
    USER_PASSWORD="$USER_PASSWORD" \
    /bin/bash /setup.sh chroot

  clear; box "Installation Complete! Rebooting in 5s..." 70 Ω
  sleep 5 && reboot
}

[[ $1 == chroot ]] && chroot_phase || main