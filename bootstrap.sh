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
# The tarball's one top directory (GitHub's <repo>-<branch>, a / in the
# branch's name made a -) stripped, so setup.sh lands directly in $DEST.
# Retried; curl's errors kept off the splash (the USB's start-up says the
# installation stopped if it fails).
curl -fsL --retry 5 --retry-delay 2 --retry-all-errors "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$DEST" --strip-components=1 2>/dev/null

exec bash "$DEST/setup.sh" install
