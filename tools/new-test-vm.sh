#!/usr/bin/env bash
# Creates a VirtualBox VM to try the ARCHMAN USB in: 4096 MB of memory, 8
# CPUs, a 20.5 GB disk, EFI (the USB boots in UEFI mode only), booting the
# ISO that tools/build-autoinstall-iso.sh made. It starts it, too.
#
#   tools/new-test-vm.sh [ISO] [NAME]
#
# ISO defaults to archlinux-autoinstall.iso, NAME to archman-test. It never
# replaces a VM: with one of that name already there, it says how to delete
# it and stops.
#
# The disk is tried first, then the ISO: the empty disk can't boot, so the
# first start installs; afterwards the installed system starts, with the
# ISO still in the drive but no longer in the way.
set -euo pipefail

iso=${1:-archlinux-autoinstall.iso}
name=${2:-archman-test}

command -v VBoxManage &>/dev/null || { echo "VirtualBox isn't installed (sudo pacman -S virtualbox)" >&2; exit 1; }
[[ -f $iso ]] || { echo "No such ISO: $iso (build it with: sudo tools/build-autoinstall-iso.sh)" >&2; exit 1; }
iso=$(realpath "$iso")
if VBoxManage showvminfo "$name" &>/dev/null; then
  echo "A VM called $name already exists. Delete it first (this deletes its disk too):" >&2
  echo "  VBoxManage unregistervm $name --delete" >&2
  exit 1
fi

folder=$(VBoxManage list systemproperties | sed -n 's/^Default machine folder: *//p')
disk="$folder/$name/$name.vdi"

echo "==> Creating $name"
VBoxManage createvm --name "$name" --ostype ArchLinux_64 --register > /dev/null
# vmsvga: the graphics with an EFI framebuffer, which the USB's splash
# draws on. The clock in UTC, as Linux keeps it.
VBoxManage modifyvm "$name" --memory 4096 --cpus 8 --firmware efi \
  --graphicscontroller vmsvga --vram 128 --rtc-use-utc on \
  --nic1 nat --boot1 disk --boot2 dvd --boot3 none --boot4 none
VBoxManage createmedium disk --filename "$disk" --size 21002 --format VDI > /dev/null   # 20.51 GB
VBoxManage storagectl "$name" --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on
VBoxManage storageattach "$name" --storagectl SATA --port 0 --device 0 --type hdd --medium "$disk"
VBoxManage storageattach "$name" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$iso"

echo "==> Starting $name (from $iso)"
VBoxManage startvm "$name" > /dev/null
