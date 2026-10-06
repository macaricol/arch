#!/usr/bin/env bash
# Environment checks, hardware detection, and package/service helpers.

require_root()    { (( EUID == 0 )) || die "Must be run as root"; }
require_user()    { (( EUID != 0 )) || die "Run this as your regular user (it uses sudo itself), not as root"; }
require_uefi()    { [[ -d /sys/firmware/efi ]] || die "This computer started in legacy (BIOS) mode. Restart and boot the USB in UEFI mode."; }
require_network() { ping -c1 -W3 archlinux.org &>/dev/null || die "No internet connection. Plug in a cable or connect Wi-Fi (iwctl), then try again."; }

# Runs a command as root: directly when already root, through sudo otherwise.
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

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

# Where the USB keeps the AUR packages built with it (tools/
# build-autoinstall-iso.sh), on the live system. The install phase copies
# them into the installer's packages/ for the desktop phase.
ISO_PACKAGES=/usr/local/share/archauto/packages

# prebuilt_package DIR PACKAGE — prints the path of PACKAGE's prebuilt
# package in DIR, if there is one.
prebuilt_package() {
  local file
  for file in "$1/$2"-[0-9]*.pkg.tar.zst; do
    [[ -f $file && $file != *-debug-* ]] && { echo "$file"; return 0; }
  done
  return 1
}

# aur_weight DIR [PACKAGE] — roughly the seconds installing PACKAGE (or all
# of AUR_PACKAGES) takes, for the progress bar, given the prebuilt packages
# in DIR: a -bin package downloads (15), a prebuilt one installs (3), one
# built from source compiles (165; qview on a VM's single core).
aur_weight() {
  local pkg weight=0
  local -a packages=("${AUR_PACKAGES[@]}")
  [[ -z ${2:-} ]] || packages=("$2")
  for pkg in "${packages[@]}"; do
    if [[ $pkg == *-bin ]]; then weight=$(( weight + 15 ))
    elif prebuilt_package "$1" "$pkg" > /dev/null; then weight=$(( weight + 3 ))
    else weight=$(( weight + 165 ))
    fi
  done
  echo "$weight"
}

# aur_has_newer PACKAGE FILE — true when the AUR has a newer version of
# PACKAGE than the prebuilt FILE; false when it can't tell (no network...).
aur_has_newer() {
  local aur ours
  aur=$(curl -fsS --max-time 10 "https://aur.archlinux.org/rpc/v5/info?arg[]=$1" 2>/dev/null \
    | grep -oE '"Version":"[^"]+"' | cut -d'"' -f4) || return 1
  ours=$(pacman -Qp "$2" 2>/dev/null | cut -d' ' -f2) || return 1
  [[ -n $aur && -n $ours ]] && (( $(vercmp "$aur" "$ours") > 0 ))
}

# aur_install PACKAGE — installs an AUR package: the prebuilt one the USB
# brought (in the installer's packages/), unless the AUR has a newer
# version; otherwise, or if that fails, built with makepkg here. No
# AUR helper: building one (paru is Rust) took longer than the packages
# themselves. Its dependencies must be in the official repos (makepkg -s
# installs them; -r removes the build-only ones afterwards). Built on disk:
# in the installer's chroot, /tmp is in RAM; and on every core, which
# makepkg.conf leaves to the user (MAKEFLAGS). Both the clone (from
# aur.archlinux.org, which drops connections now and then) and the build
# (which downloads the sources) are retried. The clone, a few files, takes
# the first 5% of the progress bar's current share (lib/ui.sh's share).
#
# Not in a subshell (env -C changes directory instead): the progress bar's
# state, moved on by run() during the build, would be lost with it, and the
# bar would jump back when the next step draws it.
aur_install() {
  local prebuilt
  if prebuilt=$(prebuilt_package "$SETUP_DIR/packages" "$1"); then
    if aur_has_newer "$1" "$prebuilt"; then
      info "The AUR has a newer $1 than this USB's, building it"
    else
      run as_root pacman -U --needed --noconfirm "$prebuilt" && return 0
      warn "Couldn't install the prebuilt $1, building it instead"
    fi
  fi
  local build from=$PROGRESS_FROM to=$PROGRESS_TO
  build=$(mktemp -d -p /var/tmp)
  share "$from" $(( from + (to - from) / 20 ))
  git_clone "https://aur.archlinux.org/$1.git" "$build/$1"
  share $(( from + (to - from) / 20 )) "$to"
  retry 10 run env -C "$build/$1" MAKEFLAGS="-j$(nproc)" makepkg -sri --noconfirm --needed \
    || die "Could not install $1 from the AUR"
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
  run ${3:-} git clone --progress --depth 1 "$1" "$2"   # --progress: for the bar
}
