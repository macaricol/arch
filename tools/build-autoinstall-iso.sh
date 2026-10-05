#!/usr/bin/env bash
# Patches an official Arch Linux ISO with an extra "Automated Install" boot
# entry that runs bootstrap.sh unattended — no archiso rebuild, no typing.
#
# How it works:
#   - A new systemd-boot entry boots the same kernel/initramfs with
#     "archauto" and quiet-boot options appended: a one-keypress opt-in at
#     the boot menu, first in the list.
#   - archauto.service, added to the live system, runs only when "archauto"
#     is on the kernel command line. It takes tty1 before the root autologin
#     does, shows the installer's logo while waiting for the network, then
#     runs bootstrap.sh. The normal boot entries are untouched.
#
# Requires root (to loop-mount the EFI image), xorriso and squashfs-tools:
#   sudo pacman -S --needed xorriso squashfs-tools
#
# This only produces a new ISO file; it never touches a block device. Test it
# in a VM, then write it yourself:
#   sudo dd if=OUTPUT.iso of=/dev/sdX bs=4M status=progress oflag=sync
#
# Usage: sudo ./build-autoinstall-iso.sh [input-arch.iso] [output.iso]
#        sudo ./build-autoinstall-iso.sh --download [output.iso]
# With no input ISO it asks whether to fetch the latest official one or use a
# local file; --download skips the question, for unattended use.
# The repo/branch baked into the ISO come from ../config.sh (REPO, BRANCH),
# both overridable from the environment, as is the ISO mirror (ISO_MIRROR).
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config.sh"
BOOTSTRAP_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/bootstrap.sh"
CMDLINE_FLAG=archauto
QUIET_OPTIONS='quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false vt.global_cursor_default=0'

usage() {
  cat <<USAGE
Usage: sudo $0 [input-arch.iso] [output.iso]
       sudo $0 --download [output.iso]

  input-arch.iso   an official Arch ISO to patch; omit it to be asked
  output.iso       defaults to archlinux-autoinstall.iso
  -d, --download   fetch the latest official ISO instead of asking
  -h, --help       this message
USAGE
}

DOWNLOAD=0
declare -a positional=()
for arg in "$@"; do
  case $arg in
    -d|--download) DOWNLOAD=1 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    *)             positional+=("$arg") ;;
  esac
done
# With --download there is no input ISO, so the lone positional is the output.
if (( DOWNLOAD )); then
  (( ${#positional[@]} <= 1 )) \
    || { echo "With --download, only an output path may be given." >&2; exit 1; }
  IN_ISO=
  OUT_ISO=${positional[0]:-archlinux-autoinstall.iso}
else
  IN_ISO=${positional[0]:-}
  OUT_ISO=${positional[1]:-archlinux-autoinstall.iso}
fi

(( EUID == 0 )) || { echo "Must be run as root (needed to loop-mount the EFI image)" >&2; exit 1; }
for bin in xorriso mksquashfs unsquashfs; do
  command -v "$bin" &>/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Prints "<filename> <sha256>" for the current release. sha256sums.txt lists
# the image twice — under its dated name and under the undated alias — so take
# the dated one: the file left on disk then says which release it is.
latest_iso_info() {
  local sums
  sums=$(curl -fsSL --max-time 60 "$ISO_MIRROR/sha256sums.txt") \
    || { echo "Couldn't fetch $ISO_MIRROR/sha256sums.txt" >&2; exit 1; }
  awk '$2 ~ /^archlinux-[0-9].*x86_64\.iso$/ {print $2, $1; exit}' <<<"$sums"
}

sha_ok() { [[ $(sha256sum "$1" | awk '{print $1}') == "$2" ]]; }

# The ISO is signed by an Arch release engineer whose key ships in the pacman
# keyring, so this works out of the box on Arch. It matters: the checksum file
# comes from the same mirror as the image, so on its own it only proves the
# download wasn't corrupted, not that the mirror was honest. A bad signature is
# fatal; a missing key or tool is only a warning, so the script still runs on
# non-Arch hosts.
verify_signature() {
  local iso=$1 out
  command -v pacman-key &>/dev/null \
    || { echo "    !! pacman-key not available — cannot verify authenticity" >&2; return; }
  curl -fsL --max-time 60 -o "$work/iso.sig" "$ISO_MIRROR/$iso.sig" \
    || { echo "    !! no detached signature published — cannot verify authenticity" >&2; return; }
  echo "==> Verifying GPG signature..."
  if out=$(pacman-key --verify "$work/iso.sig" "$iso" 2>&1); then
    echo "    $(awk -F'"' '/Good signature from/{print "good signature: " $2; exit}' <<<"$out")"
  elif grep -q 'No public key' <<<"$out"; then
    echo "    !! signing key missing from the pacman keyring — cannot verify" >&2
    echo "       fix with: pacman -Sy archlinux-keyring" >&2
  else
    echo "GPG verification FAILED for $iso:" >&2; echo "$out" >&2; exit 1
  fi
}

# Downloads $1 from the mirror, discarding whatever was there before.
refetch() {
  rm -f "$1"
  curl -fL --progress-bar -o "$1" "$ISO_MIRROR/$1" \
    || { echo "Download failed" >&2; exit 1; }
}

# Sets IN_ISO to a verified copy of the latest official ISO, downloading it
# into the current directory unless a good one is already sitting there.
download_iso() {
  command -v curl &>/dev/null || { echo "Missing dependency: curl" >&2; exit 1; }
  echo "==> Looking up the latest official ISO..."
  local name sum
  read -r name sum < <(latest_iso_info) || true
  [[ -n ${name:-} && -n ${sum:-} ]] \
    || { echo "Couldn't parse an ISO name out of sha256sums.txt" >&2; exit 1; }
  echo "    latest release: $name"

  if [[ -f $name ]] && sha_ok "$name" "$sum"; then
    echo "    already here and verified — not downloading it again"
  else
    [[ -e $name ]] && echo "    local copy is stale or incomplete — resuming" || true
    echo "==> Downloading $name..."
    # -C - continues an interrupted earlier run. Not every mirror serves byte
    # ranges, though, so fall back to a clean fetch rather than leaving the
    # stale stub in place to fail again on every future run.
    curl -fL --progress-bar -C - -o "$name" "$ISO_MIRROR/$name" \
      || { echo "    resume failed — starting over"; refetch "$name"; }
    echo "==> Verifying SHA-256..."
    if ! sha_ok "$name" "$sum"; then
      # A leftover file of the right size but the wrong content makes -C - a
      # no-op, so resuming can never repair it. Throw it away and start clean,
      # otherwise every future run repeats this same failure.
      echo "    checksum mismatch — discarding and downloading afresh"
      refetch "$name"
      sha_ok "$name" "$sum" \
        || { echo "SHA-256 mismatch on $name — refusing to use it" >&2; exit 1; }
    fi
  fi
  verify_signature "$name"
  # We run as root, so without this the user is left with a root-owned 1.6G
  # file they can't delete without sudo.
  if [[ -n ${SUDO_UID:-} ]]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$name"; fi
  IN_ISO=$name
}

ask_for_iso() {
  local reply path home
  echo "No input ISO given."
  echo
  echo "  1) Download the latest official Arch ISO"
  echo "  2) Use an ISO already on this machine"
  echo
  while :; do
    read -rp "Choice [1]: " reply
    case ${reply:-1} in
      1) download_iso; return ;;
      2)
        # -e for tab completion. Under sudo, ~ is root's home, which is not
        # where the user's downloads are — expand it against their account.
        read -rep "Path to the ISO: " path
        home=${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}
        path=${path/#\~/${home:-$HOME}}
        [[ -f $path ]] || { echo "No such file: $path" >&2; continue; }
        IN_ISO=$path; return ;;
      *) echo "Enter 1 or 2." ;;
    esac
  done
}

if (( DOWNLOAD )); then
  download_iso
elif [[ -z $IN_ISO ]]; then
  [[ -t 0 ]] || { echo "No input ISO given. Pass one, or --download." >&2; usage >&2; exit 1; }
  ask_for_iso
fi
[[ -f $IN_ISO ]] || { echo "No such file: $IN_ISO" >&2; exit 1; }

# Quiet on success, full output on failure.
run() {
  local out; out=$(mktemp)
  if "$@" >"$out" 2>&1; then
    rm -f "$out"
  else
    local status=$?
    echo "Failed: $*" >&2
    cat "$out" >&2
    rm -f "$out"
    return "$status"
  fi
}

# Prints "<lba> <blocks>" (2048-byte blocks) of the UEFI El Torito boot image.
# On current archiso releases it isn't a regular file in the ISO tree but a
# hidden boot-catalog entry, only addressable by sector range.
locate_efi_image() {
  local report; report=$(xorriso -indev "$1" -report_el_torito plain 2>&1) \
    || { echo "xorriso failed to report El Torito boot images:" >&2; echo "$report" >&2; exit 1; }
  local n lba blocks
  n=$(awk '/^El Torito boot img :/ && /UEFI/{print $6}' <<<"$report")
  lba=$(awk '/^El Torito boot img :/ && /UEFI/{print $NF}' <<<"$report")
  blocks=$(awk -v n="$n" '/^El Torito img blks :/ && $6==n{print $NF}' <<<"$report")
  [[ -n $lba && -n $blocks ]] || { echo "Couldn't find a UEFI El Torito boot image in $1" >&2; exit 1; }
  echo "$lba $blocks"
}

echo "==> Locating airootfs squashfs and EFI boot image..."
find_log=$(mktemp)
xorriso -indev "$IN_ISO" -find / -name '*.sfs' >"$find_log" 2>&1 \
  || { echo "xorriso failed while searching for the squashfs:" >&2; cat "$find_log" >&2; exit 1; }
sfs_path=$(awk -F"'" '/airootfs/{print $2; exit}' "$find_log")
rm -f "$find_log"
[[ -n $sfs_path ]] || { echo "Couldn't find airootfs*.sfs in the ISO" >&2; exit 1; }
read -r efi_lba efi_blocks < <(locate_efi_image "$IN_ISO")
echo "    squashfs: $sfs_path"
echo "    efiboot:  LBA $efi_lba, $efi_blocks blocks"

echo "==> Extracting airootfs squashfs..."
run xorriso -osirrox on -indev "$IN_ISO" -extract "$sfs_path" "$work/airootfs.sfs"
echo "==> Extracting EFI boot image..."
dd if="$IN_ISO" of="$work/efiboot.img" bs=2048 skip="$efi_lba" count="$efi_blocks" status=none

echo "==> Adding the automated-install hook..."
run unsquashfs -d "$work/airootfs" "$work/airootfs.sfs"
# The install runs from its own service on tty1, not from the root autologin:
# with getty@tty1 never starting, no login line, /etc/issue or motd is
# printed. ConditionKernelCommandLine keeps the stock boot entries (and the
# stock .automated_script.sh, which handles script=) exactly as they were.
cat > "$work/airootfs/etc/systemd/system/archauto.service" <<EOF
[Unit]
Description=Automated install
ConditionKernelCommandLine=$CMDLINE_FLAG
After=systemd-user-sessions.service
Before=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
ExecStart=/usr/local/bin/archauto
Environment=TERM=linux HOME=/root
WorkingDirectory=/root
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../archauto.service "$work/airootfs/etc/systemd/system/multi-user.target.wants/archauto.service"

# The script it runs: the installer's palette and logo with a status line,
# laid out like lib/ui.sh's step screens so the installer takes over without
# anything moving, then the network wait and bootstrap.sh. Settings are
# baked in from config.sh and logo.txt at build time.
mkdir -p "$work/airootfs/usr/local/bin"
{
  echo '#!/bin/bash'
  echo '# Generated by tools/build-autoinstall-iso.sh; started by archauto.service.'
  declare -p REPO BRANCH BOOTSTRAP_URL TAGLINE CONSOLE_PALETTE
  printf 'LOGO=%q\n' "$(<"$repo_dir/logo.txt")"
  cat <<'EOF'
LAYOUT_WIDTH=72

# Font first, as lib/ui.sh's scale_console_font picks it (nearest ~48 rows
# with 80+ columns), so the installer keeps it and nothing jumps.
best='' best_diff=99999
for font in default8x16 sun12x22 latarcyrheb-sun32; do
  setfont "$font" 2>/dev/null || continue
  read -r rows cols < <(stty size < /dev/tty)
  (( cols >= 80 )) || continue
  diff=$(( rows > 48 ? rows - 48 : 48 - rows ))
  (( diff < best_diff )) && { best=$font; best_diff=$diff; }
done
setfont "${best:-default8x16}" 2>/dev/null

for i in "${!CONSOLE_PALETTE[@]}"; do printf '\e]P%X%s' "$i" "${CONSOLE_PALETTE[i]}"; done
printf '\e[0m\e[?25l'

# center TEXT COLOUR — as lib/ui.sh's center, in one SGR colour
center() {
  local LC_ALL=C.UTF-8 pad=$(( ($(stty size < /dev/tty | cut -d' ' -f2) - ${#1}) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%*s\e[%sm%s\e[0m\n' "$pad" '' "$2" "$1"
}

# splash "Status" — logo, tagline and status where the installer puts its
# logo, tagline and step title
splash() {
  local line
  printf '\e[2J\e[H\n\n'
  while IFS= read -r line; do center "$line" 96; done <<< "$LOGO"
  echo; center "$TAGLINE" 95; echo; echo; echo
  center "$1" '1;97'
}

# Something went wrong before the installer could take over: say so and
# leave a root shell on tty1 to fix it from.
give_up() {
  splash "$1"
  echo; center "Run this once it's fixed:" 97
  center "curl -fsSL $BOOTSTRAP_URL | REPO=$REPO BRANCH=$BRANCH bash" 90
  printf '\e[?25h\n'
  exec zsh -l
}

splash "Waiting for network..."
for _ in $(seq 1 30); do
  ping -c1 -W1 archlinux.org &>/dev/null && break
  sleep 1
done
ping -c1 -W1 archlinux.org &>/dev/null \
  || give_up "No network after 30s. Connect manually (iwctl for Wi-Fi)."

splash "Fetching the installer..."
curl -fsSL "$BOOTSTRAP_URL" | REPO=$REPO BRANCH=$BRANCH bash \
  || give_up "The installer stopped. Its log is in /tmp/arch-setup/setup.log."
EOF
} > "$work/airootfs/usr/local/bin/archauto"
chmod +x "$work/airootfs/usr/local/bin/archauto"

echo "==> Repacking squashfs (this takes a while)..."
rm -f "$work/airootfs.sfs"
run mksquashfs "$work/airootfs" "$work/airootfs.sfs" -comp zstd -Xcompression-level 9

echo "==> Adding a boot entry to the EFI image..."
efi_mnt="$work/efi_mnt"
mkdir -p "$efi_mnt"
mount -o loop "$work/efiboot.img" "$efi_mnt"
# Pick the plain install entry by content, not directory order: it has a
# `linux` line (memtest doesn't) and no accessibility=on (the speech one does).
default_entry=""
for f in "$efi_mnt"/loader/entries/*.conf; do
  grep -q '^linux[[:space:]]' "$f" || continue
  grep -q 'accessibility=on' "$f" && continue
  default_entry=$f
  break
done
[[ -n $default_entry ]] || { umount "$efi_mnt"; echo "No suitable Arch boot entry found in efiboot.img" >&2; exit 1; }
new_entry="$efi_mnt/loader/entries/archauto.conf"
sed "s|^title .*|title   Automated Install ($REPO)|" "$default_entry" > "$new_entry"
# Quiet boot: no kernel, initramfs or systemd messages and no cursor, so
# the firmware logo stays up until the graphics driver takes over, and the
# next thing on screen is archauto's splash.
sed -i "s/^options \(.*\)/options \1 $CMDLINE_FLAG $QUIET_OPTIONS/" "$new_entry"
sed -i "s/^sort-key .*/sort-key 00/" "$new_entry"   # first in the menu
umount "$efi_mnt"

# Only the squashfs needs xorriso's remastering (it changed size). The EFI
# image kept its size, so it's overwritten in place afterwards — at the
# offset re-queried from the *output* ISO, since remastering can move it.
echo "==> Assembling patched ISO..."
run xorriso -indev "$IN_ISO" -outdev "$OUT_ISO" \
  -boot_image any replay \
  -map "$work/airootfs.sfs" "$sfs_path" \
  -changes_pending yes

echo "==> Patching EFI boot image into place..."
read -r new_efi_lba new_efi_blocks < <(locate_efi_image "$OUT_ISO")
if (( new_efi_blocks != efi_blocks )); then
  echo "EFI image size changed after remastering ($efi_blocks -> $new_efi_blocks blocks); aborting." >&2
  exit 1
fi
dd if="$work/efiboot.img" of="$OUT_ISO" bs=2048 seek="$new_efi_lba" conv=notrunc status=none

echo "==> Done: $OUT_ISO"
echo "Test it first, e.g.: qemu-system-x86_64 -m 2048 -cdrom '$OUT_ISO' -boot d"
