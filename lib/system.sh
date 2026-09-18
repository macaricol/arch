#!/usr/bin/env bash
# Environment checks, hardware detection, and package/service helpers.

require_root()    { (( EUID == 0 )) || die "Must be run as root"; }
require_user()    { (( EUID != 0 )) || die "Run this as your regular user (it uses sudo itself), not as root"; }
require_uefi()    { [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode"; }
require_network() { ping -c1 -W3 archlinux.org &>/dev/null || die "No network connectivity"; }

# Runs a command as root: directly when already root, through sudo otherwise.
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

pkg_install()    { run as_root pacman -S --needed --noconfirm "$@"; }
aur_install()    { run paru -S --needed --noconfirm "$@"; }
enable_service() { run as_root systemctl enable "$@"; }   # add --now to also start it

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

# partition_path DEVICE N — sda → sda1, but nvme0n1 → nvme0n1p1 (and the same
# "p" rule applies to mmcblk/loop: any device name ending in a digit).
partition_path() { if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi; }

# git_clone URL DEST — shallow clone into a fresh directory. Retried, since
# one reset connection shouldn't abort a run that's minutes in.
git_clone() {
  local attempt
  for attempt in 1 2 3; do
    rm -rf "$2"
    run git clone --depth 1 "$1" "$2" && return 0
    (( attempt < 3 )) && { warn "Clone failed (attempt $attempt/3), retrying in 5s..."; sleep 5; }
  done
  die "Could not clone $1"
}
