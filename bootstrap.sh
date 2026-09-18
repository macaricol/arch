#!/usr/bin/env bash
# Live-ISO entry point, meant to be piped into bash:
#
#   curl -fsSL https://raw.githubusercontent.com/macaricol/arch/main/refactor/bootstrap.sh | bash
#
# Fetches the repo once as a tarball (no per-file downloads), unpacks the
# installer to /tmp and starts the install phase. Override the source with
# environment variables, e.g.:  curl ... | BRANCH=clauding bash
set -euo pipefail

REPO=${REPO:-macaricol/arch}
BRANCH=${BRANCH:-main}
DEST=/tmp/arch-setup

echo "Fetching $REPO@$BRANCH..."
rm -rf "$DEST"
mkdir -p "$DEST"
# GitHub names the tarball's top directory <repo>-<branch>; strip that and
# the refactor/ level so setup.sh lands directly in $DEST.
curl -fsSL --retry 3 --retry-all-errors "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar -xz -C "$DEST" --strip-components=2 "${REPO##*/}-$BRANCH/refactor"

exec bash "$DEST/setup.sh" install
