#!/usr/bin/env bash
# A fresh test round: deletes the test VM and the last USB image, builds the
# image again from the official Arch ISO, and creates and starts a new VM
# with it.
#
#   test/rebuild-test.sh [--wifi-test] [--record] [--reuse] [OFFICIAL_ISO]
#
# --wifi-test builds the image with simulated Wi-Fi networks, for trying the
# Wi-Fi screen in the VM (see tools/build-autoinstall-iso.sh). --reuse
# skips the build: the VM boots the image already here (from the last round,
# or tools/build-autoinstall-iso.sh run by hand), as it is; for a change to
# the installer alone, which the image downloads from GitHub anyway. --record
# records the VM's screen, to archman-test-screen0.webm here (see
# test/new-test-vm.sh); the last round's video goes either way.
# OFFICIAL_ISO defaults to the newest official ISO here (archlinux-
# YYYY.MM.DD-x86_64.iso, as the builder downloads it). Run it as your
# user, not with sudo: VirtualBox VMs belong to the user who made them. It
# asks for your password for the build, which needs root.
#
# The USB fetches the installer from GitHub at boot, from the branch it was
# built for: this builds it for the branch checked out here, and warns when
# that branch has work GitHub doesn't have yet.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
build_options=() vm_options=() reuse=0
while [[ ${1:-} == --* ]]; do
  case $1 in
    --wifi-test) build_options+=(--wifi-test) ;;
    --record) vm_options+=(--record) ;;
    --reuse) reuse=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
official=${1:-$(ls archlinux-[0-9]*-x86_64.iso 2>/dev/null | sort -V | tail -1)}
image=archlinux-autoinstall.iso
vm=archman-test

(( EUID != 0 )) || { echo "Run this as your user, not with sudo (the VM is yours)." >&2; exit 1; }
if (( reuse )); then
  [[ -f $image ]] || { echo "No $image here to reuse: build one, without --reuse." >&2; exit 1; }
  (( ${#build_options[@]} == 0 )) || echo "(--wifi-test does nothing with --reuse: the image is used as it was built.)"
else
  [[ -n $official ]] || { echo "No official ISO here: download one with: sudo tools/build-autoinstall-iso.sh --download" >&2; exit 1; }
  [[ -f $official ]] || { echo "No such ISO: $official" >&2; exit 1; }
fi

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
  # And then a moment more before VirtualBox lets go of it: deleting too
  # soon fails (VBOX_E_INVALID_OBJECT_STATE), so a few tries.
  for try in 1 2 3 4 5; do
    sleep 1
    VBoxManage unregistervm "$vm" --delete 2>/dev/null && break
    (( try < 5 )) || VBoxManage unregistervm "$vm" --delete   # the last: its error shown
  done
else
  echo "    (there wasn't one)"
fi

if (( reuse )); then
  echo "==> Reusing $image (built $(date -r "$image" '+%Y-%m-%d %H:%M'))"
else
  echo "==> Deleting $image"
  sudo rm -f "$image"

  echo "==> Building $image from $official, for branch $branch"
  sudo BRANCH="$branch" tools/build-autoinstall-iso.sh "${build_options[@]}" "$official" "$image"
  sudo chown "$(id -u):$(id -g)" "$image"   # yours, so the next round needn't sudo to delete it
fi

echo "==> Creating the test VM"
test/new-test-vm.sh "${vm_options[@]}" "$image" "$vm"
