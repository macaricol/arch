#!/usr/bin/env bash
# Phase 1 — runs on the live ISO as root.

phase_install() {
  # Piped in via curl | bash, fd 0 is the script itself, not the keyboard.
  exec < /dev/tty
  loadkeys "$KEYMAP" 2>/dev/null || warn "Couldn't load keymap $KEYMAP"

  clear
  info "Running pre-flight checks..."
  require_root
  require_uefi
  require_network
  STEP_TOTAL=6

  clear
  step "Machine details"
  input HOST_NAME "Hostname:" valid_hostname
  password ROOT_PASSWORD "Root password (min 6 chars):"
  input USER_NAME "Username:" valid_username
  password USER_PASSWORD "User password (min 6 chars):"
  step_done

  select_drive
  step_done

  clear
  step "Review & confirm"
  printf ' Hostname:  %s\n Username:  %s\n Drive:     %s\n Timezone:  %s\n Keymap:    %s\n\n' \
    "$HOST_NAME" "$USER_NAME" "$DRIVE" "$TIMEZONE" "$KEYMAP"
  warn "This will ERASE ALL DATA on $DRIVE. This cannot be undone."
  ask "Type YES to continue:"; read -r ack
  [[ $ack == YES ]] || { info "Aborted."; exit 0; }
  step_done

  step "Partitioning & formatting"
  partition_and_mount
  step_done

  step "Installing the base system"
  install_base
  step_done

  step "Configuring the new system"
  configure_new_system
  step_done

  box "DONE! Rebooting in 5s..."
  sleep 5
  reboot
}

# Arrow-key menu over the machine's disks, minus the live USB we booted from.
select_drive() {
  local live_disk=''
  live_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)" 2>/dev/null) || true

  local -a drives
  mapfile -t drives < <(
    lsblk -dpno PATH,SIZE,MODEL,TYPE \
      | awk -v skip="/dev/$live_disk" '$NF == "disk" && $1 != skip { $NF = ""; print }'
  )
  (( ${#drives[@]} )) || die "No disks found"

  local cancel='── cancel ──'
  menu "[$((++STEP))/$STEP_TOTAL] Select the installation drive" "$cancel" "${drives[@]}" \
    || { clear; info "Cancelled."; exit 0; }
  [[ $MENU_CHOICE != "$cancel" ]] || { clear; info "Cancelled."; exit 0; }

  DRIVE=${MENU_CHOICE%% *}
  [[ -b $DRIVE ]] || die "Not a block device: $DRIVE"
  clear
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
  grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/\[options\]/a ILoveCandy' /etc/pacman.conf

  # Microcode goes in with the base system so the very first initramfs and
  # grub.cfg already include it.
  local -a packages=("${BASE_PACKAGES[@]}")
  case $(cpu_vendor) in
    intel) packages+=(intel-ucode) ;;
    amd)   packages+=(amd-ucode) ;;
    *)     warn "Unknown CPU vendor — skipping microcode" ;;
  esac

  info "Installing: ${packages[*]}"
  run pacstrap -K /mnt "${packages[@]}"
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
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD" > "$stage/creds"

  info "Entering chroot..."
  arch-chroot /mnt env HOST_NAME="$HOST_NAME" USER_NAME="$USER_NAME" VERBOSE="$VERBOSE" \
    bash /root/arch-setup/setup.sh chroot
}
