#!/usr/bin/env bash
# Phase 1 — runs on the live ISO as root.

phase_install() {
  # Piped in via curl | bash, fd 0 is the script itself, not the keyboard.
  exec < /dev/tty
  loadkeys "$KEYMAP" 2>/dev/null || warn "Couldn't load keymap $KEYMAP"
  setup_console

  header "Arch Linux installer"
  info "Running pre-flight checks..."
  require_root
  require_uefi
  require_network
  install_gum
  STEP_TOTAL=6

  step "Set up your account"
  input HOST_NAME "Hostname" valid_hostname
  input USER_NAME "Username" valid_username
  # One password for both the user and root.
  password PASSWORD "Password"

  select_drive

  step "Review & confirm"
  printf "$MARGIN %s\n" "Hostname:  $HOST_NAME" "Username:  $USER_NAME" "Drive:     $DRIVE" \
    "Timezone:  $TIMEZONE" "Keymap:    $KEYMAP"
  echo
  warn "This will ERASE ALL DATA on $DRIVE. This cannot be undone."
  ask "Type YES to continue >"; read -r ack
  [[ $ack == YES ]] || { info "Aborted."; exit 0; }

  step "Partitioning & formatting"
  partition_and_mount

  step "Installing the base system"
  install_base

  step "Configuring the new system"
  configure_new_system

  # Unmount first so nothing on the new system is lost if the stick is
  # pulled; and the live ISO may be running from that stick, so `reboot`
  # gets loaded into memory now while it can still be read. If it can't be
  # run anyway, sysrq reboots directly — safe, as the target is unmounted.
  swapoff -a 2>/dev/null || true
  umount -R /mnt || warn "Couldn't unmount /mnt — leave the USB in until the reboot starts"
  systemctl --version > /dev/null

  finish "Installed! Remove the installation USB"
  wait_for_usb_removal
  info "Rebooting..."
  sync
  # The new system is unmounted and nothing on the live ISO needs a clean
  # shutdown, so skip stopping its services: --force goes straight to
  # killing processes and rebooting, without the screens of "Stopped ..."
  # lines or the 90 s wait for the Wi-Fi service. RTMIN+21 tells systemd to
  # stop printing status for whatever is left.
  kill -s RTMIN+21 1 2>/dev/null || true
  systemctl reboot --force || echo b > /proc/sysrq-trigger
}

# Left plugged in, the USB can win the boot order and start the installer
# all over again. Reboots once the stick is pulled out, or on Enter (for
# ISOs booted from a VM's virtual CD, or with copytoram, where there is no
# USB to watch).
wait_for_usb_removal() {
  local usb='' key
  usb=$(live_usb_disk) || true
  # Not a typing prompt: a plain message, and no cursor while it waits
  # (the key pressed isn't echoed).
  if [[ -n $usb ]]; then
    info "Unplug the USB to reboot, or press Enter if it's already out."
  else
    info "Remove the installation media, then press Enter to reboot."
  fi
  printf '\e[?25l'
  while :; do
    [[ -n $usb && ! -b $usb ]] && { info "USB removed."; return; }
    read -rs -t 1 key && return
  done
}

# gum draws the prompts (lib/prompt.sh). The live ISO's root is a RAM
# overlay, so this costs a few MB of RAM and nothing on the target disk.
install_gum() {
  command -v gum &>/dev/null && return 0
  info "Fetching the prompt UI (gum)..."
  run pacman -Sy --noconfirm --needed gum || warn "Couldn't install gum — using plain prompts"
}

# Arrow-key menu over the machine's disks, minus the live USB we booted from.
select_drive() {
  local live_disk=''
  live_disk=$(live_usb_disk) || true

  local -a drives
  mapfile -t drives < <(
    lsblk -dpno PATH,SIZE,MODEL,TYPE \
      | awk -v skip="$live_disk" '$NF == "disk" && $1 != skip { $NF = ""; print }'
  )
  (( ${#drives[@]} )) || die "No disks found"

  local cancel='── cancel ──'
  (( ++STEP ))
  menu "Select the installation drive" "$cancel" "${drives[@]}" \
    || { clear; info "Cancelled."; exit 0; }
  [[ $MENU_CHOICE != "$cancel" ]] || { clear; info "Cancelled."; exit 0; }

  DRIVE=${MENU_CHOICE%% *}
  [[ -b $DRIVE ]] || die "Not a block device: $DRIVE"
  echo
  info "Selected $DRIVE"
}

partition_and_mount() {
  local efi swap root
  efi=$(partition_path "$DRIVE" 1)
  swap=$(partition_path "$DRIVE" 2)
  root=$(partition_path "$DRIVE" 3)

  # Undo a half-finished previous attempt so a re-run doesn't hit "busy".
  swapoff "$swap" 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  local ram_mib
  ram_mib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  info "Layout: $EFI_SIZE EFI, ${ram_mib}M swap (= RAM, for hibernation), rest Btrfs"

  run wipefs -af "$DRIVE"
  run sgdisk -Z \
    -n1:0:+"$EFI_SIZE"    -t1:ef00 -c1:EFI \
    -n2:0:+"${ram_mib}M"  -t2:8200 -c2:Swap \
    -n3:0:0               -t3:8300 -c3:Root "$DRIVE"
  partprobe "$DRIVE" 2>/dev/null || true
  # partprobe only makes the kernel re-read the table; udev still has to
  # create the device nodes before the check below can pass.
  udevadm settle
  [[ -b $efi && -b $swap && -b $root ]] || die "Partitioning failed"

  info "Formatting..."
  run mkfs.fat -F32 -n BOOT "$efi"
  run mkswap -L SWAP "$swap"
  run mkfs.btrfs -f -L ROOT "$root"

  info "Creating and mounting Btrfs subvolumes..."
  run mount "$root" /mnt
  run btrfs subvolume create /mnt/@ /mnt/@home
  run umount /mnt
  run mount -o "$BTRFS_MOUNT_OPTS,subvol=@" "$root" /mnt
  mkdir -p /mnt/{boot,home}
  run mount -o "$BTRFS_MOUNT_OPTS,subvol=@home" "$root" /mnt/home
  run mount "$efi" /mnt/boot
  run swapon "$swap"
}

install_base() {
  info "Ranking mirrors ($MIRROR_COUNTRIES)..."
  run reflector --country "$MIRROR_COUNTRIES" --latest 8 --protocol https \
    --sort rate --number 6 --save /etc/pacman.d/mirrorlist \
    || warn "reflector failed — keeping the ISO's default mirrorlist"
  [[ -s /etc/pacman.d/mirrorlist ]] || die "Mirrorlist is empty"

  # Microcode and GPU drivers go in with the base system, so the initramfs
  # the chroot phase builds already includes them: NVIDIA machines boot on
  # nvidia-open from the very first boot instead of nouveau.
  local -a packages=("${BASE_PACKAGES[@]}") gpu vendors
  case $(cpu_vendor) in
    intel) packages+=(intel-ucode) ;;
    amd)   packages+=(amd-ucode) ;;
    *)     warn "Unknown CPU vendor — skipping microcode" ;;
  esac
  mapfile -t vendors < <(gpu_vendors)
  if (( ${#vendors[@]} )); then
    info "Detected GPU(s): ${vendors[*]}"
  else
    warn "No Intel/AMD/NVIDIA GPU detected — installing generic mesa only"
  fi
  mapfile -t gpu < <(gpu_packages)
  packages+=("${gpu[@]}")

  # The drivers' 32-bit halves (for Steam) live in multilib. pacstrap reads
  # the ISO's pacman.conf, and -P copies it into the new system, so enabling
  # it here covers both.
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

  info "Installing: ${packages[*]}"
  run pacstrap -K -P /mnt "${packages[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

# Copies this installer into the new root and re-invokes it there.
configure_new_system() {
  local stage=/mnt/root/arch-setup
  rm -rf "$stage"
  cp -r "$SETUP_DIR" "$stage"

  # Passwords travel in a root-only file, never in argv or the environment.
  # The chroot phase deletes it as its first act; the trap covers the case
  # where arch-chroot never gets that far.
  trap 'rm -f /mnt/root/arch-setup/creds' EXIT
  install -m 600 /dev/null "$stage/creds"
  printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" > "$stage/creds"

  info "Entering chroot..."
  arch-chroot /mnt env HOST_NAME="$HOST_NAME" USER_NAME="$USER_NAME" VERBOSE="$VERBOSE" \
    bash /root/arch-setup/setup.sh chroot
}

# Prints the disk the live ISO booted from (/dev/sdX), if it's still mounted.
live_usb_disk() {
  local name
  name=$(lsblk -no PKNAME "$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)" 2>/dev/null) || return 1
  [[ -n $name ]] && echo "/dev/$name"
}
