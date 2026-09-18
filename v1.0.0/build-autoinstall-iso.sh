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

REPO_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/clauding"
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

# Runs a command quietly, but shows its full output if it fails. This script
# can't be exercised end-to-end without a real ISO + xorriso + squashfs-tools
# on hand, so a silent failure here is worse than some noise on the step
# that actually breaks.
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

# Finds the UEFI El Torito boot image's raw sector range (LBA + block count,
# 2048 bytes/block) from `xorriso -report_el_torito plain` output. On current
# archiso releases this image isn't a regular file in the ISO tree — it's a
# "hidden" boot-catalog entry only addressable by sector range, so it can't
# be found/extracted by path the way the squashfs can.
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

echo "==> Locating airootfs squashfs and EFI boot image inside the ISO..."
find_log=$(mktemp)
xorriso -indev "$IN_ISO" -find / -name '*.sfs' >"$find_log" 2>&1 \
  || { echo "xorriso failed while searching for the squashfs:" >&2; cat "$find_log" >&2; exit 1; }
sfs_path=$(awk -F"'" '/airootfs/{print $2; exit}' "$find_log")
rm -f "$find_log"
[[ -n $sfs_path ]] || { echo "Couldn't find airootfs*.sfs in the ISO" >&2; exit 1; }

read -r efi_lba efi_blocks < <(locate_efi_image "$IN_ISO")
echo "    squashfs: $sfs_path"
echo "    efiboot:  LBA $efi_lba, $efi_blocks blocks (2048 bytes each)"

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
for i in \$(seq 1 30); do
  ping -c1 -W1 archlinux.org &>/dev/null && break
  sleep 1
done
if ! ping -c1 -W1 archlinux.org &>/dev/null; then
  echo "No network after 30s."
  echo "Connect manually (iwctl for Wi-Fi, mmcli for WWAN), then run:"
  echo "  curl -fsSL $MAIN_URL | bash"
  exit 1
fi

curl -fsSL $MAIN_URL | bash
EOF
chmod +x "$work/airootfs/root/.automated_script.sh"

echo "==> Repacking squashfs (this takes a while)..."
rm -f "$work/airootfs.sfs"
run mksquashfs "$work/airootfs" "$work/airootfs.sfs" -comp zstd -Xcompression-level 9

echo "==> Adding a new boot entry to the EFI image..."
efi_mnt="$work/efi_mnt"
mkdir -p "$efi_mnt"
mount -o loop "$work/efiboot.img" "$efi_mnt"
# `find | head -n1` isn't sorted — it returns whatever order the FAT
# directory stores entries in, which can (and did) land on the wrong one:
# archiso ships separate entries for the plain install medium, a speech/
# accessibility variant, and memtest86+ (which boots straight via `efi=`,
# no kernel/initrd/options at all). Match on content instead of file order:
# has a `linux` line (excludes memtest) and no accessibility=on (excludes
# the speech variant).
default_entry=""
for f in "$efi_mnt"/loader/entries/*.conf; do
  grep -q '^linux[[:space:]]' "$f" || continue
  grep -q 'accessibility=on' "$f" && continue
  default_entry=$f
  break
done
[[ -n $default_entry ]] || { umount "$efi_mnt"; echo "No suitable Arch boot entry found in efiboot.img" >&2; exit 1; }
new_entry="$efi_mnt/loader/entries/archauto.conf"
sed "s/^title .*/title   Automated Install (macaricol\/arch)/" "$default_entry" > "$new_entry"
sed -i "s/^options \(.*\)/options \1 $CMDLINE_FLAG/" "$new_entry"
# Copied verbatim from the template, this ties with the real install-medium
# entry's sort-key — put it first in the menu instead.
sed -i "s/^sort-key .*/sort-key 00/" "$new_entry"
umount "$efi_mnt"

# Only the squashfs goes through xorriso's remastering (-map) — it changed
# size, so the ISO layout has to be rebuilt to fit it. The EFI image didn't
# change size (we only added one small file inside its existing FAT
# filesystem, not grown the container), so it doesn't need remastering —
# just overwriting in place. But rebuilding the ISO for the squashfs can
# shift where the EFI image ends up, so its offset is re-queried on the
# *output* ISO rather than assumed to match the input.
echo "==> Assembling patched ISO (squashfs)..."
run xorriso -indev "$IN_ISO" -outdev "$OUT_ISO" \
  -boot_image any replay \
  -map "$work/airootfs.sfs" "$sfs_path" \
  -changes_pending yes

echo "==> Patching EFI boot image into place..."
read -r new_efi_lba new_efi_blocks < <(locate_efi_image "$OUT_ISO")
if (( new_efi_blocks != efi_blocks )); then
  echo "EFI image size changed after remastering ($efi_blocks -> $new_efi_blocks blocks)" >&2
  echo "— aborting rather than risk writing the wrong-sized image into the wrong place." >&2
  exit 1
fi
dd if="$work/efiboot.img" of="$OUT_ISO" bs=2048 seek="$new_efi_lba" conv=notrunc status=none

echo "==> Done: $OUT_ISO"
echo "Test it first, e.g.: qemu-system-x86_64 -m 2048 -cdrom '$OUT_ISO' -boot d"
