#!/usr/bin/env bash
# Builds the ARCHMAN USB image inside a fresh archlinux container, as the
# monthly GitHub build does (.github/workflows/iso.yml):
#
#   docker run --rm --privileged -v "$PWD:/repo" -w /repo archlinux:latest \
#     tools/ci-build-iso.sh OUTPUT.iso
#
# --privileged: the build loop-mounts the EFI image. As root, in a container
# that's thrown away: it sets up pacman's keys, installs what the build
# needs, and makes a user to build the AUR packages as (makepkg won't build
# as root), allowed sudo pacman without a password for their dependencies.
# The image installs from BRANCH (default main), like any USB.
set -euo pipefail

output=${1:?usage: tools/ci-build-iso.sh OUTPUT.iso}

pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm --needed base-devel sudo git curl libisoburn squashfs-tools gum python

useradd --create-home builder
printf 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/builder
chmod 440 /etc/sudoers.d/builder

# The official ISO, fetched and verified, then the image built from it.
tools/build-autoinstall-iso.sh --download --build-user=builder "$output"
