#!/usr/bin/env bash
# Phase 1 — runs on the live ISO as root.

phase_install() {
  # Piped in via curl | bash, fd 0 is the script itself, not the keyboard.
  exec < /dev/tty
  loadkeys "$KEYMAP" 2>/dev/null || warn "Couldn't load keymap $KEYMAP"

  # The USB's splash is on screen (tools/build-autoinstall-iso.sh): the big
  # logo, and under it "Checking if this computer is ready...". The USB has
  # checked the network; it booted in UEFI mode, as root, and brought gum.
  # The splash stays up at least 4 seconds in all (since SPLASH_SINCE);
  # only then the console's font and colours, which redraw the screen, and
  # the first question.
  local shown=$(( EPOCHSECONDS - ${SPLASH_SINCE:-$EPOCHSECONDS} ))
  (( shown >= 4 )) || sleep $(( 4 - shown ))
  setup_console
  # The progress bar covers the installing, not the questions before it: the
  # steps below from partitioning on, then the desktop phase's, which the chroot
  # phase runs and which carries the bar on. Weights: see lib/ui.sh's step.
  # The desktop phase's AUR step weighs by what this USB brought prebuilt.
  PROGRESS_TOTAL=$(( $(step_weights "$SETUP_DIR/phases/install.sh") + $(step_weights "$SETUP_DIR/phases/desktop.sh")
                     + $(aur_weight "$ISO_PACKAGES") ))

  # The questions, until they end in YES: nothing is touched before. There's
  # no way out of them but answering, or turning the computer off: leaving
  # would end the USB's start-up and leave the screen black.
  while :; do
    header "Set up your account"
    input HOST_NAME "Hostname" valid_hostname
    input USER_NAME "Username" valid_username
    # One password for both the user and root.
    password PASSWORD "Password"

    select_drive

    header "Review & confirm"
    printf "$MARGIN %s\n" "Hostname:  $HOST_NAME" "Username:  $USER_NAME" "Drive:     $DRIVE" \
      "Timezone:  $TIMEZONE" "Keymap:    $KEYMAP"
    echo
    warn "Everything on $DRIVE will be erased. This can't be undone."
    ask "Type YES to continue >"; cursor on; read -r ack; cursor off
    [[ $ack == YES ]] && break
    buttons "Nothing has been changed" 0 \
      "Start over" "Answer the questions again." \
      "Turn off" "Switch the computer off. Nothing on it has been touched."
    (( PICKED == 0 )) || { clear; systemctl poweroff; sleep infinity; }   # until it's off
  done
  # Bash's own clock; it keeps running through arch-chroot and the desktop
  # phase.
  local started=$SECONDS

  step "Preparing the drive" 6
  partition_and_mount

  step "Installing Arch Linux" 58
  install_base

  step "Setting up your system" 13
  configure_new_system
  # The time it took, before the question below waits on you.
  local took=$(( SECONDS - started ))

  choose_look
  info "Applying the look..."
  arch-chroot /mnt env LOOK="$LOOK" bash "/home/$USER_NAME/.arch-setup/setup.sh" look

  # Unmount first so nothing on the new system is lost if the stick is
  # pulled; and the live ISO may be running from that stick, so `reboot`
  # gets loaded into memory now while it can still be read. If it can't be
  # run anyway, sysrq reboots directly — safe, as the target is unmounted.
  swapoff -a 2>/dev/null || true
  umount -R /mnt || warn "Couldn't unmount /mnt, leave the USB in until the reboot starts"
  systemctl --version > /dev/null

  finish "All done! Remove the USB stick"
  info "Archman installed in $(plural $(( took / 60 )) minute) and $(plural $(( took % 60 )) second)"
  wait_for_usb_removal
  info "Restarting..."
  sync
  # The new system is unmounted and synced, and the live ISO's own files
  # are in RAM, so nothing needs a shutdown: --force twice reboots at once,
  # without stopping services ("Stopped ..." screens) or waiting on
  # processes (iwd ignores SIGTERM, which held a single --force for 90 s).
  # dmesg -n 1 keeps any last kernel message off the screen, and systemctl's
  # own "Rebooting." goes nowhere.
  dmesg -n 1 2>/dev/null || true
  systemctl reboot --force --force &>/dev/null || echo b > /proc/sysrq-trigger
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
    info "Unplug the USB stick and your computer will restart into your new system."
  else
    info "Remove the installation media, then press Enter to restart."
  fi
  cursor off
  while :; do
    [[ -n $usb && ! -b $usb ]] && { info "See you on the other side!"; return; }
    read -rs -t 1 key && return
  done
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

  # A drive, then a second look at it: the list is easy to slip on. Esc
  # shows the list again; there's no cancelling (see phase_install).
  local size model
  while :; do
    until menu "Select the installation drive" "${drives[@]}"; do :; done
    DRIVE=${MENU_CHOICE%% *}
    read -r _ size model <<< "$MENU_CHOICE"
    model=${model%%+([[:space:]])}
    buttons "Install on ${model:-$DRIVE} ($size)?" 0 \
      "Use this drive" "$DRIVE: everything on it will be erased." \
      "Choose another" "Back to the list of drives."
    (( PICKED == 0 )) && break
  done
  [[ -b $DRIVE ]] || die "Not a block device: $DRIVE"
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
  info "Creating space for the system, hibernation and your files"
  printf 'Layout: %s EFI, %sM swap (= RAM, for hibernation), rest Btrfs\n' "$EFI_SIZE" "$ram_mib" >> "$LOG_FILE"

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

  info "Setting up the file system..."
  run mkfs.fat -F32 -n BOOT "$efi"
  run mkswap -L SWAP "$swap"
  run mkfs.btrfs -f -L ROOT "$root"

  run mount "$root" /mnt
  run btrfs subvolume create /mnt/@ /mnt/@home
  run umount /mnt
  run mount -o "$BTRFS_MOUNT_OPTS,subvol=@" "$root" /mnt
  mkdir -p /mnt/{boot,home}
  run mount -o "$BTRFS_MOUNT_OPTS,subvol=@home" "$root" /mnt/home
  run mount "$efi" /mnt/boot
  run swapon "$swap"
}

# Prints the countries to rank mirrors in: MIRROR_COUNTRIES, or with auto the
# two-letter code of this machine's public IP's country (ipinfo.io), or
# nothing if that lookup fails.
mirror_countries() {
  if [[ $MIRROR_COUNTRIES != auto ]]; then
    echo "$MIRROR_COUNTRIES"
    return
  fi
  local code
  code=$(curl -fsS --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]') || true
  [[ $code =~ ^[A-Z]{2}$ ]] && echo "$code"
  return 0
}

# Ranks the mirrors pacstrap downloads from: the fastest in our country;
# worldwide when it isn't known or has no HTTPS mirrors reflector can find
# (it then leaves no Server lines). Only mirrors that run at most 4 hours
# behind Arch (--delay; --age isn't enough, a mirror can sync often from a
# stale source): pacman takes the package lists from the first mirror alone,
# and a fast but stale one (glua.ua.pt, days behind) lists versions every
# current mirror has since deleted, so every download 404s.
rank_mirrors() {
  local countries mirrorlist=/etc/pacman.d/mirrorlist
  countries=$(mirror_countries)
  if [[ -n $countries ]]; then
    info "Finding the fastest download servers near you ($countries)..."
    run reflector --country "$countries" --delay 4 --latest 8 --protocol https \
      --sort rate --number 6 --save "$mirrorlist" || true
  fi
  if [[ -z $countries ]] || ! grep -q '^Server' "$mirrorlist"; then
    info "Finding the fastest download servers worldwide..."
    run reflector --delay 4 --latest 20 --protocol https --sort rate --number 6 --save "$mirrorlist" \
      || warn "Couldn't rank download servers, using the default ones"
  fi
  # Last resort, for a file the mirrors above haven't synced yet: pacman
  # tries the servers in order for each package. Arch's own CDN is always
  # current. It goes into the new system's mirrorlist too.
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' >> "$mirrorlist"
}

install_base() {
  share 0 50    # reflector, timing the mirrors: a few seconds
  rank_mirrors

  # Microcode and GPU drivers go in with the base system, so the initramfs
  # the chroot phase builds already includes them: NVIDIA machines boot on
  # nvidia-open from the very first boot instead of nouveau.
  local -a packages=("${BASE_PACKAGES[@]}") gpu vendors
  case $(cpu_vendor) in
    intel) packages+=(intel-ucode) ;;
    amd)   packages+=(amd-ucode) ;;
    *)     warn "Unknown CPU vendor, skipping microcode" ;;
  esac
  mapfile -t vendors < <(gpu_vendors)
  if (( ${#vendors[@]} )); then
    local names='' vendor
    for vendor in "${vendors[@]}"; do
      case $vendor in intel) vendor=Intel ;; amd) vendor=AMD ;; nvidia) vendor=NVIDIA ;; esac
      names+=${names:+ and }$vendor
    done
    info "Found $names graphics, adding the drivers"
  else
    warn "No Intel, AMD or NVIDIA graphics found, using basic graphics drivers"
  fi
  mapfile -t gpu < <(gpu_packages)
  packages+=("${gpu[@]}")

  # pacstrap reads the ISO's pacman.conf, and -P copies it into the new
  # system, so changes here cover both. The drivers' 32-bit halves (for
  # Steam) live in multilib. And PARALLEL_DOWNLOADS files at once (config.sh)
  # rather than pacman's 5: hundreds of small packages, each with a round
  # trip to the mirror before its bytes.
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
  sed -i -E "s/^#?ParallelDownloads.*/ParallelDownloads = $PARALLEL_DOWNLOADS/" /etc/pacman.conf

  share 50 1000
  info "Downloading and installing the core system. This takes a few minutes."
  # pacstrap downloads into the new system's cache (see lib/ui.sh's measured_progress).
  local PACMAN_CACHE=/mnt/var/cache/pacman/pkg
  printf 'Packages: %s\n' "${packages[*]}" >> "$LOG_FILE"
  retry 10 run pacstrap -K -P /mnt "${packages[@]}" || die "Couldn't download the core system"
  genfstab -U /mnt >> /mnt/etc/fstab
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

# Copies this installer into the new root and re-invokes it there.
configure_new_system() {
  carry_wifi_networks
  local stage=/mnt/root/arch-setup
  rm -rf "$stage"
  cp -r "$SETUP_DIR" "$stage"
  # The AUR packages this USB brought prebuilt, for the desktop phase.
  if compgen -G "$ISO_PACKAGES/*.pkg.tar.zst" > /dev/null; then
    mkdir -p "$stage/packages"
    cp "$ISO_PACKAGES"/*.pkg.tar.zst "$stage/packages/"
  fi

  # Passwords travel in a root-only file, never in argv or the environment.
  # The chroot phase deletes it as its first act; the trap covers the case
  # where arch-chroot never gets that far.
  trap 'rm -f /mnt/root/arch-setup/creds' EXIT
  install -m 600 /dev/null "$stage/creds"
  printf '%s\n' "$PASSWORD" > "$stage/creds"

  # The bar carries on in the chroot phase, and from there in the desktop phase.
  local -a progress
  mapfile -t progress < <(progress_env)
  arch-chroot /mnt env HOST_NAME="$HOST_NAME" USER_NAME="$USER_NAME" VERBOSE="$VERBOSE" \
    PATCHED_FONT="${PATCHED_FONT:-0}" "${progress[@]}" \
    bash /root/arch-setup/setup.sh chroot
  # The desktop phase has done every step, and logged the last one's time: the
  # screens that follow show the bar full.
  PROGRESS_DONE=$PROGRESS_TOTAL PROGRESS_STEP=0 PROGRESS_SHOWN=-1 PROGRESS_TITLE=''
}

# Prints the disk the live ISO booted from (/dev/sdX), if it's still mounted.
live_usb_disk() {
  local name
  name=$(lsblk -no PKNAME "$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)" 2>/dev/null) || return 1
  [[ -n $name ]] && echo "/dev/$name"
}

# The Wi-Fi networks the live ISO connected to (its iwd remembers them, in
# /var/lib/iwd: phases/wifi.sh's) as NetworkManager
# connections on the new system, so it's online from its first boot: the
# first Plasma session downloads its widgets and icons. Root-only files, as
# they hold the passwords. iwd names a file by the network's name, or "="
# and the name in hex when it has other characters than letters, digits,
# - and _; NetworkManager then gets the name as its bytes.
carry_wifi_networks() {
  local file base ssid name security secret dir=/mnt/etc/NetworkManager/system-connections
  for file in /var/lib/iwd/*.psk /var/lib/iwd/*.open; do
    [[ -f $file ]] || continue
    base=${file##*/} base=${base%.*}
    if [[ $base == =* ]]; then
      [[ ${base#=} =~ ^([0-9a-fA-F]{2})+$ ]] || continue
      printf -v name '%b' "$(sed 's/../\\x&/g' <<< "${base#=}")"
      ssid=$(sed 's/../&\n/g' <<< "${base#=}" | while read -r byte; do [[ -z $byte ]] || printf '%d;' "0x$byte"; done)
    else
      name=$base ssid=$base
    fi
    security=''
    if [[ $file == *.psk ]]; then
      secret=$(sed -n 's/^Passphrase=//p' "$file" | head -1)
      [[ -n $secret ]] || secret=$(sed -n 's/^PreSharedKey=//p' "$file" | head -1)
      [[ -n $secret ]] || continue
      printf -v security '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n' "$secret"
    fi
    mkdir -p "$dir"
    printf '[connection]\nid=%s\ntype=wifi\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n%s\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
      "$name" "$ssid" "$security" | install -m 600 /dev/stdin "$dir/${name//\//_}.nmconnection"
    printf 'Wi-Fi carried over: %s\n' "$name" >> "$LOG_FILE"
  done
}
