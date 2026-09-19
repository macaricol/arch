#!/usr/bin/env bash
# Patches an official Arch Linux ISO with an extra "Automated Install" boot
# entry that runs bootstrap.sh unattended — no archiso rebuild, no typing.
#
# How it works:
#   - Stock Arch ISOs auto-run /root/.automated_script.sh on login if it
#     exists. Ours only fires when "archauto" is on the kernel command line,
#     so the normal boot entries are untouched.
#   - A new systemd-boot entry boots the same kernel/initramfs with
#     "archauto" appended: a one-keypress opt-in at the boot menu.
#
# Requires root (to loop-mount the EFI image), xorriso and squashfs-tools:
#   sudo pacman -S --needed xorriso squashfs-tools
#
# This only produces a new ISO file; it never touches a block device. Test it
# in a VM, then write it yourself:
#   sudo dd if=OUTPUT.iso of=/dev/sdX bs=4M status=progress oflag=sync
#
# Usage: sudo ./build-autoinstall-iso.sh <input-arch.iso> [output.iso]
# The repo/branch baked into the ISO come from ../config.sh (REPO, BRANCH),
# both overridable from the environment.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"
BOOTSTRAP_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/bootstrap.sh"
CMDLINE_FLAG=archauto

IN_ISO=${1:?Usage: $0 <input-arch.iso> [output.iso]}
OUT_ISO=${2:-archlinux-autoinstall.iso}
[[ -f $IN_ISO ]] || { echo "No such file: $IN_ISO" >&2; exit 1; }
(( EUID == 0 )) || { echo "Must be run as root (needed to loop-mount the EFI image)" >&2; exit 1; }
for bin in xorriso mksquashfs unsquashfs; do
  command -v "$bin" &>/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
cat > "$work/airootfs/root/.automated_script.sh" <<EOF
#!/bin/bash
grep -qw $CMDLINE_FLAG /proc/cmdline || exit 0

echo "Waiting for network..."
for _ in \$(seq 1 30); do
  ping -c1 -W1 archlinux.org &>/dev/null && break
  sleep 1
done
if ! ping -c1 -W1 archlinux.org &>/dev/null; then
  echo "No network after 30s."
  echo "Connect manually (iwctl for Wi-Fi), then run:"
  echo "  curl -fsSL $BOOTSTRAP_URL | REPO=$REPO BRANCH=$BRANCH bash"
  exit 1
fi

curl -fsSL $BOOTSTRAP_URL | REPO=$REPO BRANCH=$BRANCH bash
EOF
chmod +x "$work/airootfs/root/.automated_script.sh"

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
sed -i "s/^options \(.*\)/options \1 $CMDLINE_FLAG/" "$new_entry"
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
