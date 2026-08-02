#!/usr/bin/env bash
# Patches an official Arch Linux ISO to add an "Automated Install" boot menu
# entry that runs main.sh unattended, without a full archiso rebuild.
#
# How it works:
#   - Stock Arch ISOs already auto-run /root/.automated_script.sh on login if
#     it exists. We add one that only fires when booted with "archauto" on
#     the kernel command line (so the normal boot entries are untouched).
#   - We add a new systemd-boot entry that boots the same kernel/initramfs
#     with "archauto" appended, giving you a one-keypress opt-in at the menu.
#
# Requires: xorriso, squashfs-tools (mksquashfs/unsquashfs), and root (for
# loop-mounting the small EFI FAT image). Install with:
#   sudo pacman -S --needed xorriso squashfs-tools
#
# This only produces a new ISO file — it never touches a block device. Write
# it to USB yourself once you've verified it boots (ideally in a VM first):
#   sudo dd if=OUTPUT.iso of=/dev/sdX bs=4M status=progress oflag=sync
#
# Usage: ./build-autoinstall-iso.sh <input-arch.iso> [output.iso]
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main"
MAIN_URL="$REPO_URL/main.sh"
CMDLINE_FLAG="archauto"

IN_ISO=${1:?Usage: $0 <input-arch.iso> [output.iso]}
OUT_ISO=${2:-archlinux-autoinstall.iso}
[[ -f $IN_ISO ]] || { echo "No such file: $IN_ISO" >&2; exit 1; }
(( EUID == 0 )) || { echo "Must be run as root (needed to loop-mount the EFI image)" >&2; exit 1; }
for bin in xorriso mksquashfs unsquashfs; do
  command -v "$bin" &>/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> Locating airootfs squashfs and EFI boot image inside the ISO..."
sfs_path=$(xorriso -indev "$IN_ISO" -find / -name '*.sfs' 2>/dev/null | awk -F"'" '/airootfs/{print $2; exit}')
efi_path=$(xorriso -indev "$IN_ISO" -find / -iname 'efiboot.img' 2>/dev/null | awk -F"'" '{print $2; exit}')
[[ -n $sfs_path ]] || { echo "Couldn't find airootfs*.sfs in the ISO" >&2; exit 1; }
[[ -n $efi_path ]] || { echo "Couldn't find efiboot.img in the ISO" >&2; exit 1; }
echo "    squashfs: $sfs_path"
echo "    efiboot:  $efi_path"

echo "==> Extracting airootfs squashfs..."
xorriso -osirrox on -indev "$IN_ISO" -extract "$sfs_path" "$work/airootfs.sfs" &>/dev/null

echo "==> Adding the automated-install hook..."
unsquashfs -d "$work/airootfs" "$work/airootfs.sfs" &>/dev/null
cat > "$work/airootfs/root/.automated_script.sh" <<EOF
#!/bin/bash
grep -qw $CMDLINE_FLAG /proc/cmdline || exit 0
curl -fsSL $MAIN_URL | bash
EOF
chmod +x "$work/airootfs/root/.automated_script.sh"

echo "==> Repacking squashfs (this takes a while)..."
rm -f "$work/airootfs.sfs"
mksquashfs "$work/airootfs" "$work/airootfs.sfs" -comp zstd -Xcompression-level 9 &>/dev/null

echo "==> Extracting EFI boot image and adding a new boot entry..."
xorriso -osirrox on -indev "$IN_ISO" -extract "$efi_path" "$work/efiboot.img" &>/dev/null
efi_mnt="$work/efi_mnt"
mkdir -p "$efi_mnt"
mount -o loop "$work/efiboot.img" "$efi_mnt"
default_entry=$(find "$efi_mnt/loader/entries" -name '*.conf' | head -n1)
[[ -n $default_entry ]] || { umount "$efi_mnt"; echo "No systemd-boot entry found in efiboot.img" >&2; exit 1; }
new_entry="$efi_mnt/loader/entries/archauto.conf"
sed "s/^title .*/title   Automated Install (macaricol\/arch)/" "$default_entry" > "$new_entry"
sed -i "s/^options \(.*\)/options \1 $CMDLINE_FLAG/" "$new_entry"
umount "$efi_mnt"

echo "==> Assembling patched ISO..."
xorriso -indev "$IN_ISO" -outdev "$OUT_ISO" \
  -boot_image any replay \
  -map "$work/airootfs.sfs" "$sfs_path" \
  -map "$work/efiboot.img" "$efi_path" \
  -changes_pending yes &>/dev/null

echo "==> Done: $OUT_ISO"
echo "Test it first, e.g.: qemu-system-x86_64 -m 2048 -cdrom '$OUT_ISO' -boot d"
