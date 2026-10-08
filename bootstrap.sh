#!/usr/bin/env bash
# The ARCHMAN USB's way in: its start-up (tools/build-autoinstall-iso.sh)
# fetches this and pipes it into bash, quietly, under its splash.
#
# Fetches the repo once as a tarball (no per-file downloads), unpacks the
# installer to /tmp and starts the install phase. REPO and BRANCH are baked
# into the USB from config.sh when it's built.
set -euo pipefail

REPO=${REPO:-macaricol/arch}
BRANCH=${BRANCH:-main}
DEST=/tmp/arch-setup

rm -rf "$DEST"
mkdir -p "$DEST"
# GitHub names the tarball's top directory <repo>-<branch>; strip it so
# setup.sh lands directly in $DEST.
curl -fsSL --retry 3 --retry-all-errors "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$DEST" --strip-components=1 "${REPO##*/}-$BRANCH"

exec bash "$DEST/setup.sh" install
