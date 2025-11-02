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
  mapfile -t DRIVES < <(printf '/dev/sdummy\n'; lsblk -dplno PATH,TYPE | awk '$2=="disk"{print $1}')
  (( ${#DRIVES[@]} )) || die "No block devices found"

  local i=0 selected=0 key seq

  while :; do
    clear
    box "Select installation drive"
    for ((i=0; i<${#DRIVES[@]}; i++)); do
      if (( i == selected )); then
        printf ' \e[7m>\e[0m %s\n' "${DRIVES[i]}"
      else
        printf '   %s\n' "${DRIVES[i]}"
      fi
    done
    box "↑↓ navigate – Enter select – ESC cancel"

    # Read one character
    read -rsn1 key

    # If it's ESC (start of escape sequence)
    if [[ $key == $'\x1b' ]]; then
      # Try to read the rest of the sequence with timeout
      if read -rsn2 -t 0.1 seq; then
        case "$seq" in
          '[A') ((selected--)) ;;  # Up
          '[B') ((selected++)) ;;  # Down
          '[C'|'[D') : ;;          # Left/Right - ignore
          *) : ;;                  # Unknown sequence
        esac
      else
        # No further input within timeout → this was a lone ESC key
        exit 0
      fi
    elif [[ -z $key ]]; then
      # Enter key (empty input)
      break
    fi

    # Wrap selection
    (( selected < 0 )) && selected=$((${#DRIVES[@]}-1))
    (( selected >= ${#DRIVES[@]} )) && selected=0
  done

  DRIVE="${DRIVES[selected]}"
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
  mount "$ROOT_PART" "$MNT"
  btrfs su cr "$MNT"/@
  btrfs su cr "$MNT"/@home
  umount "$MNT"

  mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" "$MNT"
  mkdir -p "$MNT"/{boot,home}
  mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" "$MNT/home"
  mount "$BOOT_PART" "$MNT/boot"
  swapon "$SWAP_PART"

  info "Generating fstab"
  genfstab -U "$MNT" >> "$MNT/etc/fstab"
}

# ── Base system ─────────────────────────────────────────────────
install_base() {
  info "Pacstrap base system"
  pacstrap -K "$MNT" base linux linux-firmware btrfs-progs \
    grub efibootmgr nano networkmanager sudo || die "pacstrap failed"
}

# ── Chroot (heredoc – no temp file) ─────────────────────────────
chroot_setup() {
  cat > "$MNT/etc/systemd/system/installer-chroot.service" <<'EOF'
[Unit]
Description=Arch post-install
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /installer.sh chroot
StandardInput=tty
StandardOutput=tty
StandardError=tty
EOF
  systemctl --root="$MNT" enable installer-chroot.service

  arch-chroot "$MNT" /bin/bash -c "$(cat <<'INNER'
set -euo pipefail
export HOSTNAME USER_NAME ROOT_PASSWORD USER_PASSWORD TIMEZONE KEYMAP
# ---- inside chroot -------------------------------------------------
info() { printf '\e[1;92m[•] %b\e[0m\n' "$*"; }

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

rm -f /installer.sh
# -------------------------------------------------------------------
INNER
)"
}

# ── Main flow ───────────────────────────────────────────────────
main() {
  clear
  box "Arch Linux Installer" 70 =
  read -p "Hostname: " HOSTNAME
  read -s -p "Root password: " ROOT_PASSWORD; echo
  read -p "Username: " USER_NAME
  read -s -p "User password: " USER_PASSWORD; echo

  select_drive
  partition_drive "$DRIVE"
  format_and_mount
  install_base

  # copy this script for chroot (heredoc will read it later)
  cp "$0" "$MNT/installer.sh"

  info "Entering chroot…"
  chroot_setup

  info "Installation finished – rebooting in 5 s"
  sleep 5 && reboot
}

# ── Dispatch ────────────────────────────────────────────────────
[[ "${1:-}" == "chroot" ]] && exit 0   # placeholder – real chroot runs from heredoc
main