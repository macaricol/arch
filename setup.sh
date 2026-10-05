#!/usr/bin/env bash
# Arch Linux + KDE Plasma installer — single entry point.
#
#   setup.sh install    on the live ISO (as root): partition, install, then
#                       re-invokes itself inside the new system with "chroot"
#   setup.sh chroot     (internal) inside arch-chroot: system configuration
#   setup.sh post       first login (as the new user): desktop, drivers, apps
#   setup.sh kde-init   (internal) first Plasma session: desktop tweaks
#
# VERBOSE=1 shows command output live instead of a spinner. Everything run
# through run() is logged to setup.log next to this file in any case.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_DIR

source "$SETUP_DIR/config.sh"
source "$SETUP_DIR/lib/ui.sh"
source "$SETUP_DIR/lib/prompt.sh"
source "$SETUP_DIR/lib/system.sh"

phase=${1:-}
case $phase in
  install|chroot|post|kde-init) ;;
  *) echo "Usage: $0 <install|chroot|post|kde-init>" >&2; exit 1 ;;
esac

source "$SETUP_DIR/phases/$phase.sh"
"phase_${phase//-/_}"
