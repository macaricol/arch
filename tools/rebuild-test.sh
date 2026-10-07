#!/usr/bin/env bash
# A fresh test round: deletes the test VM and the last USB image, builds the
# image again from the official Arch ISO, and creates and starts a new VM
# with it.
#
#   tools/rebuild-test.sh [--wifi-test] [OFFICIAL_ISO]
#
# --wifi-test builds the image with simulated Wi-Fi networks, for trying the
# Wi-Fi screen in the VM (see tools/build-autoinstall-iso.sh).
# OFFICIAL_ISO defaults to archlinux-2026.10.01-x86_64.iso. Run it as your
# user, not with sudo: VirtualBox VMs belong to the user who made them. It
# asks for your password for the build, which needs root.
#
# The USB fetches the installer from GitHub at boot, from the branch it was
# built for: this builds it for the branch checked out here, and warns when
# that branch has work GitHub doesn't have yet.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
build_options=()
if [[ ${1:-} == --wifi-test ]]; then build_options+=(--wifi-test); shift; fi
official=${1:-archlinux-2026.10.01-x86_64.iso}
image=archlinux-autoinstall.iso
vm=archman-test

(( EUID != 0 )) || { echo "Run this as your user, not with sudo (the VM is yours)." >&2; exit 1; }
[[ -f $official ]] || { echo "No such ISO: $official" >&2; exit 1; }

branch=$(git branch --show-current)
git fetch -q origin "$branch" 2>/dev/null || true
ahead=$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo "?")
if [[ $ahead != 0 ]] || [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "!! $branch has work that isn't on GitHub (unpushed commits: $ahead; or uncommitted changes)."
  echo "   The USB's own screens are built from these files, but the installer it"
  echo "   downloads at boot comes from GitHub: push first to test all of it."
  echo
fi

echo "==> Deleting the test VM ($vm)"
if VBoxManage showvminfo "$vm" &>/dev/null; then
  VBoxManage controlvm "$vm" poweroff &>/dev/null || true
  # Powering off takes a moment; the VM can't be deleted until it's done.
  for _ in {1..20}; do
    VBoxManage showvminfo "$vm" --machinereadable | grep -q '^VMState="\(poweroff\|aborted\)"' && break
    sleep 0.5
  done
  sleep 1
  VBoxManage unregistervm "$vm" --delete
else
  echo "    (there wasn't one)"
fi

echo "==> Deleting $image"
sudo rm -f "$image"

echo "==> Building $image from $official, for branch $branch"
sudo BRANCH="$branch" tools/build-autoinstall-iso.sh "${build_options[@]}" "$official" "$image"
sudo chown "$(id -u):$(id -g)" "$image"   # yours, so the next round needn't sudo to delete it

echo "==> Creating the test VM"
tools/new-test-vm.sh "$image" "$vm"
