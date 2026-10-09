#!/usr/bin/env bash
# Hardware detection, and package, service and download helpers.

# Runs a command as root: directly when already root, through sudo otherwise.
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }

# retry DELAY COMMAND... — runs COMMAND up to 3 times, DELAY seconds apart.
# For downloads: a dropped connection shouldn't lose a run that's minutes in.
# On a step's screen each try's warning takes the last one's place (nothing
# else is printed between them there: run keeps a command's output off it),
# so only the latest shows; elsewhere they follow each other.
retry() {
  local delay=$1 attempt lines=0; shift
  for attempt in 1 2 3; do
    "$@" && return 0
    if (( attempt < 3 )); then
      (( FACTS_ON && lines )) && printf '\e[%dA\e[J' "$lines" >&2
      warn "Download hiccup, trying again ($((attempt + 1)) of 3)..."
      lines=$(( ${#WRAPPED[@]} + 1 ))   # its lines (centred_message's), and the blank after
      sleep "$delay"
    fi
  done
  return 1
}

# Where the USB keeps the AUR packages built with it (tools/
# build-autoinstall-iso.sh), on the live system. The install phase copies
# them into the installer's packages/ for the desktop phase.
ISO_PACKAGES=/usr/local/share/archauto/packages
# And the first Plasma session's downloads, made when the USB was built
# (plasma-tweaks' icon theme and widgets): extras/icons/<theme>,
# extras/plasmoids/<repo name>/package. Copied into the installer's extras/.
ISO_EXTRAS=/usr/local/share/archauto/extras

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

# aur_install PACKAGE — installs an AUR package: the prebuilt one the USB
# brought (in the installer's packages/), even when the AUR has a newer
# one by now, as paru (installed first, AUR_PACKAGES) brings it up to date
# with the rest; otherwise, or if that fails, built with makepkg here. Its
# dependencies must be in the official repos (makepkg -s installs them; -r
# removes the build-only ones afterwards). Built on disk:
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
    run as_root pacman -U --needed --noconfirm "$prebuilt" && return 0
    note "Couldn't install the prebuilt $1, building it instead"
  fi
  local build from=$PROGRESS_FROM to=$PROGRESS_TO
  build=$(mktemp -d -p /var/tmp)
  share "$from" $(( from + (to - from) / 20 ))
  git_clone "https://aur.archlinux.org/$1.git" "$build/$1"
  share $(( from + (to - from) / 20 )) "$to"
  retry 10 run env -C "$build/$1" MAKEFLAGS="-j$(nproc)" makepkg -sri --noconfirm --needed \
    || die "Couldn't install $1, one of the extras from the Arch community."
  rm -rf "$build"
}

# write_sudoers FILE LINE... — a sudoers drop-in, root-only from the start and
# checked before sudo reads it; an invalid one is removed, as it would break
# sudo altogether.
write_sudoers() {
  local file=$1; shift
  printf '%s\n' "$@" | as_root install -m 440 /dev/stdin "$file" || die "Couldn't set up administrator access."
  as_root visudo -c -f "$file" > /dev/null || { as_root rm -f "$file"; die "Couldn't set up administrator access."; }
}

# enable_service UNIT... — enabled, not started: in the installer's chroot
# nothing can be started, and the first boot starts them.
enable_service() { run as_root systemctl enable "$@"; }

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
git_clone() { local name=${1##*/}; retry 5 fresh_clone "$@" || die "Couldn't download ${name%.git}. Check your internet connection."; }
fresh_clone() {
  ${3:-} rm -rf "$2"
  run ${3:-} git clone --progress --depth 1 "$1" "$2"   # --progress: for the bar
}
