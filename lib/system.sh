#!/usr/bin/env bash
# Environment checks, hardware detection, and package/service helpers.

require_root()    { (( EUID == 0 )) || die "Must be run as root"; }
require_user()    { (( EUID != 0 )) || die "Run this as your regular user (it uses sudo itself), not as root"; }
require_uefi()    { [[ -d /sys/firmware/efi ]] || die "This computer started in legacy (BIOS) mode. Restart and boot the USB in UEFI mode."; }
require_network() { ping -c1 -W3 archlinux.org &>/dev/null || die "No internet connection. Plug in a cable or connect Wi-Fi (iwctl), then try again."; }

# Runs a command as root: directly when already root, through sudo otherwise.
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

pkg_install()    { run as_root pacman -S --needed --noconfirm "$@"; }

# retry DELAY COMMAND... — runs COMMAND up to 3 times, DELAY seconds apart.
# For downloads: a dropped connection shouldn't lose a run that's minutes in.
retry() {
  local delay=$1 attempt; shift
  for attempt in 1 2 3; do
    "$@" && return 0
    (( attempt < 3 )) && { warn "Download hiccup, trying again ($((attempt + 1)) of 3)..."; sleep "$delay"; }
  done
  return 1
}

# aur_install PACKAGE — builds and installs an AUR package with makepkg, no
# AUR helper: building one (paru is Rust) took longer than the packages
# themselves. Its dependencies must be in the official repos (makepkg -s
# installs them; -r removes the build-only ones afterwards). Built on disk:
# in the installer's chroot, /tmp is in RAM. Both the clone (from
# aur.archlinux.org, which drops connections now and then) and the build
# (which downloads the sources) are retried.
aur_install() {
  local build; build=$(mktemp -d -p /var/tmp)
  git_clone "https://aur.archlinux.org/$1.git" "$build/$1"
  (cd "$build/$1" && retry 10 run makepkg -sri --noconfirm --needed) || die "Could not install $1 from the AUR"
  rm -rf "$build"
}

# write_sudoers FILE LINE... — a sudoers drop-in, root-only from the start and
# checked before sudo reads it; an invalid one is removed, as it would break
# sudo altogether.
write_sudoers() {
  local file=$1; shift
  printf '%s\n' "$@" | as_root install -m 440 /dev/stdin "$file" || die "Couldn't write $file"
  as_root visudo -c -f "$file" > /dev/null || { as_root rm -f "$file"; die "Generated sudoers drop-in is invalid"; }
}

# True inside a chroot, such as the installer's arch-chroot. IN_CHROOT=1
# says so for processes that can't check themselves: systemd-detect-virt
# needs to read /proc/1/root, which only root may.
in_chroot() { [[ ${IN_CHROOT:-0} == 1 ]] || systemd-detect-virt --chroot &>/dev/null; }

# enable_service [--now] UNIT... — --now also starts them, except in a
# chroot, where nothing can be started (the first boot does it).
enable_service() {
  local -a args=()
  local arg
  for arg; do
    [[ $arg == --now ]] && in_chroot && continue
    args+=("$arg")
  done
  run as_root systemctl enable "${args[@]}"
}

# Regenerates grub.cfg, then comments out its "Loading Linux..." echo lines
# (there is no /etc/default/grub knob for those).
regenerate_grub() {
  run as_root grub-mkconfig -o /boot/grub/grub.cfg
  as_root sed -i '/^[[:space:]]*echo/s/^/#/' /boot/grub/grub.cfg
}

# Prints intel | amd | unknown
cpu_vendor() {
  case $(lscpu | awk '/Vendor ID/{print $NF}') in
    GenuineIntel) echo intel ;;
    AuthenticAMD) echo amd ;;
    *)            echo unknown ;;
  esac
}

# Prints the detected GPU vendors, one per line (intel / amd / nvidia).
# Hybrid machines list every vendor present.
gpu_vendors() {
  local line
  while read -r line; do
    line=${line,,}
    [[ $line == *intel*  ]] && echo intel
    [[ $line == *amd*    ]] && echo amd
    [[ $line == *nvidia* ]] && echo nvidia
  done < <(lspci | grep -E 'VGA|3D|Display') | sort -u
}

# Prints the GPU_PACKAGES_* list for every detected vendor, or the fallback
# list when none is found (VMs). Hybrid machines get each vendor's list.
gpu_packages() {
  local -a vendors
  mapfile -t vendors < <(gpu_vendors)
  (( ${#vendors[@]} )) || vendors=(fallback)
  local vendor list
  for vendor in "${vendors[@]}"; do
    list="GPU_PACKAGES_${vendor^^}[@]"
    printf '%s\n' "${!list}"
  done | sort -u
}

# partition_path DEVICE N — sda → sda1, but nvme0n1 → nvme0n1p1 (and the same
# "p" rule applies to mmcblk/loop: any device name ending in a digit).
partition_path() { if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi; }

# git_clone URL DEST [as_root] — shallow clone into a fresh directory,
# retried. as_root clones into a directory only root can write.
git_clone() { retry 5 fresh_clone "$@" || die "Could not clone $1"; }
fresh_clone() {
  ${3:-} rm -rf "$2"
  run ${3:-} git clone --depth 1 "$1" "$2"
}
