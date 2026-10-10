#!/usr/bin/env bash
# Patches an official Arch Linux ISO into an automated installer: it boots
# straight into bootstrap.sh, no menu, no typing — and no archiso rebuild.
#
# How it works:
#   - The UEFI boot menu is replaced by one entry, booted at once: the same
#     kernel/initramfs with "archauto" and quiet-boot options appended.
#   - archauto.service, added to the live system, runs only when "archauto"
#     is on the kernel command line. It takes tty1 before the root autologin
#     does, shows the ARCHMAN logo across two thirds of the screen, with
#     "Checking if this device is ready..." under it 2 seconds in, while
#     the network comes up, then runs bootstrap.sh. The installer keeps the
#     logo up through its own checks (at least 4 seconds in all).
#
# Requires root (to loop-mount the EFI image), through sudo, and these
# packages (it checks first, and prints the command for any missing):
#   sudo pacman -S --needed libisoburn squashfs-tools devtools git curl
# devtools builds the AUR packages that compile from source (AUR_PACKAGES in
# config.sh, all but the -bin ones) into the ISO, so installs from it don't
# compile them.
#
# This only produces a new ISO file; it never touches a block device. Test it
# in a VM, then write it yourself:
#   sudo dd if=OUTPUT.iso of=/dev/sdX bs=4M status=progress oflag=sync
#
# Usage: sudo ./build-autoinstall-iso.sh [input-arch.iso] [output.iso]
#        sudo ./build-autoinstall-iso.sh --download [output.iso]
# With no input ISO it asks whether to fetch the latest official one or use a
# local file; --download skips the question, for unattended use.
# The repo/branch baked into the ISO come from ../config.sh (REPO, BRANCH),
# both overridable from the environment, as is the ISO mirror (ISO_MIRROR).
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/config.sh"
BOOTSTRAP_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/bootstrap.sh"
CMDLINE_FLAG=archauto
QUIET_OPTIONS='quiet loglevel=3 rd.udev.log_level=3 systemd.show_status=false vt.global_cursor_default=0'

usage() {
  cat <<USAGE
Usage: sudo $0 [input-arch.iso] [output.iso]
       sudo $0 --download [output.iso]

  input-arch.iso   an official Arch ISO to patch; omit it to be asked
  output.iso       defaults to archlinux-autoinstall.iso
  -d, --download   fetch the latest official ISO instead of asking
  --build-user=NAME  prebuild the AUR packages with plain makepkg as NAME
                   (who can run sudo pacman without a password), not in a
                   devtools clean chroot: for a throwaway clean Arch container,
                   such as the monthly GitHub build (tools/ci-build-iso.sh)
  --wifi-test      for testing in a VM: simulated Wi-Fi networks, and the
                   Wi-Fi screen shown even with a cable
  -h, --help       this message
USAGE
}

DOWNLOAD=0
WIFI_TEST=0
BUILD_USER=''
declare -a positional=()
for arg in "$@"; do
  case $arg in
    -d|--download) DOWNLOAD=1 ;;
    --wifi-test)   WIFI_TEST=1 ;;
    --build-user=*) BUILD_USER=${arg#*=} ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    *)             positional+=("$arg") ;;
  esac
done
# With --download there is no input ISO, so the lone positional is the output.
if (( DOWNLOAD )); then
  (( ${#positional[@]} <= 1 )) \
    || { echo "With --download, only an output path may be given." >&2; exit 1; }
  IN_ISO=
  OUT_ISO=${positional[0]:-archlinux-autoinstall.iso}
else
  IN_ISO=${positional[0]:-}
  OUT_ISO=${positional[1]:-archlinux-autoinstall.iso}
fi

# Every command this needs from outside a base install, and its package.
# All checked up front, before anything is done: a run that stops halfway,
# minutes in, for want of one of them helps nobody.
declare -A DEPENDENCIES=(
  [xorriso]=libisoburn                # reads and writes the ISO
  [mksquashfs]=squashfs-tools         # repacks the live system
  [unsquashfs]=squashfs-tools
  [makechrootpkg]=devtools            # prebuilds the AUR packages, in a clean chroot
  [mkarchroot]=devtools               # (not with --build-user: makepkg instead)
  [git]=git                           # fetches their build recipes
  [curl]=curl                         # downloads the official ISO
)
if [[ -n $BUILD_USER ]]; then unset 'DEPENDENCIES[makechrootpkg]' 'DEPENDENCIES[mkarchroot]'; fi
missing_commands=() missing_packages=()
for bin in "${!DEPENDENCIES[@]}"; do
  command -v "$bin" &>/dev/null && continue
  missing_commands+=("$bin")
  [[ " ${missing_packages[*]} " == *" ${DEPENDENCIES[$bin]} "* ]] || missing_packages+=("${DEPENDENCIES[$bin]}")
done
if (( ${#missing_commands[@]} )); then
  {
    echo "Building the ISO needs commands this machine doesn't have: ${missing_commands[*]}"
    echo "Install them with this, then run it again:"
    echo
    echo "  sudo pacman -S --needed ${missing_packages[*]}"
  } >&2
  exit 1
fi
(( EUID == 0 )) || { echo "Must be run as root (needed to loop-mount the EFI image): sudo $0 $*" >&2; exit 1; }

# On disk (/var/tmp), not in /tmp: that's usually RAM (tmpfs), and the live
# system unpacked is some 3.5 GB, then repacked beside itself.
work=$(mktemp -d -p /var/tmp archman-build.XXXXXX)
trap 'rm -rf "$work"' EXIT

# Prints "<filename> <sha256>" for the current release. sha256sums.txt lists
# the image twice — under its dated name and under the undated alias — so take
# the dated one: the file left on disk then says which release it is.
latest_iso_info() {
  local sums
  sums=$(curl -fsSL --max-time 60 "$ISO_MIRROR/sha256sums.txt") \
    || { echo "Couldn't fetch $ISO_MIRROR/sha256sums.txt" >&2; exit 1; }
  awk '$2 ~ /^archlinux-[0-9].*x86_64\.iso$/ {print $2, $1; exit}' <<<"$sums"
}

sha_ok() { [[ $(sha256sum "$1" | awk '{print $1}') == "$2" ]]; }

# The ISO is signed by an Arch release engineer whose key ships in the pacman
# keyring, so this works out of the box on Arch. It matters: the checksum file
# comes from the same mirror as the image, so on its own it only proves the
# download wasn't corrupted, not that the mirror was honest. A bad signature is
# fatal; a missing key or tool is only a warning, so the script still runs on
# non-Arch hosts.
verify_signature() {
  local iso=$1 out
  command -v pacman-key &>/dev/null \
    || { echo "    !! pacman-key not available — cannot verify authenticity" >&2; return; }
  curl -fsL --max-time 60 -o "$work/iso.sig" "$ISO_MIRROR/$iso.sig" \
    || { echo "    !! no detached signature published — cannot verify authenticity" >&2; return; }
  echo "==> Verifying GPG signature..."
  if out=$(pacman-key --verify "$work/iso.sig" "$iso" 2>&1); then
    echo "    $(awk -F'"' '/Good signature from/{print "good signature: " $2; exit}' <<<"$out")"
  elif grep -q 'No public key' <<<"$out"; then
    echo "    !! signing key missing from the pacman keyring — cannot verify" >&2
    echo "       fix with: pacman -Sy archlinux-keyring" >&2
  else
    echo "GPG verification FAILED for $iso:" >&2; echo "$out" >&2; exit 1
  fi
}

# Downloads $1 from the mirror, discarding whatever was there before.
refetch() {
  rm -f "$1"
  curl -fL --progress-bar -o "$1" "$ISO_MIRROR/$1" \
    || { echo "Download failed" >&2; exit 1; }
}

# Sets IN_ISO to a verified copy of the latest official ISO, downloading it
# into the current directory unless a good one is already sitting there.
download_iso() {
  echo "==> Looking up the latest official ISO..."
  local name sum
  read -r name sum < <(latest_iso_info) || true
  [[ -n ${name:-} && -n ${sum:-} ]] \
    || { echo "Couldn't parse an ISO name out of sha256sums.txt" >&2; exit 1; }
  echo "    latest release: $name"

  if [[ -f $name ]] && sha_ok "$name" "$sum"; then
    echo "    already here and verified — not downloading it again"
  else
    [[ -e $name ]] && echo "    local copy is stale or incomplete — resuming" || true
    echo "==> Downloading $name..."
    # -C - continues an interrupted earlier run. Not every mirror serves byte
    # ranges, though, so fall back to a clean fetch rather than leaving the
    # stale stub in place to fail again on every future run.
    curl -fL --progress-bar -C - -o "$name" "$ISO_MIRROR/$name" \
      || { echo "    resume failed — starting over"; refetch "$name"; }
    echo "==> Verifying SHA-256..."
    if ! sha_ok "$name" "$sum"; then
      # A leftover file of the right size but the wrong content makes -C - a
      # no-op, so resuming can never repair it. Throw it away and start clean,
      # otherwise every future run repeats this same failure.
      echo "    checksum mismatch — discarding and downloading afresh"
      refetch "$name"
      sha_ok "$name" "$sum" \
        || { echo "SHA-256 mismatch on $name — refusing to use it" >&2; exit 1; }
    fi
  fi
  verify_signature "$name"
  # We run as root, so without this the user is left with a root-owned 1.6G
  # file they can't delete without sudo.
  if [[ -n ${SUDO_UID:-} ]]; then chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$name"; fi
  IN_ISO=$name
}

ask_for_iso() {
  local reply path home
  echo "No input ISO given."
  echo
  echo "  1) Download the latest official Arch ISO"
  echo "  2) Use an ISO already on this machine"
  echo
  while :; do
    read -rp "Choice [1]: " reply
    case ${reply:-1} in
      1) download_iso; return ;;
      2)
        # -e for tab completion. Under sudo, ~ is root's home, which is not
        # where the user's downloads are — expand it against their account.
        read -rep "Path to the ISO: " path
        home=${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}
        path=${path/#\~/${home:-$HOME}}
        [[ -f $path ]] || { echo "No such file: $path" >&2; continue; }
        IN_ISO=$path; return ;;
      *) echo "Enter 1 or 2." ;;
    esac
  done
}

if (( DOWNLOAD )); then
  download_iso
elif [[ -z $IN_ISO ]]; then
  [[ -t 0 ]] || { echo "No input ISO given. Pass one, or --download." >&2; usage >&2; exit 1; }
  ask_for_iso
fi
[[ -f $IN_ISO ]] || { echo "No such file: $IN_ISO" >&2; exit 1; }

# Quiet on success, full output on failure.
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

# Prints "<lba> <blocks>" (2048-byte blocks) of the UEFI El Torito boot image.
# On current archiso releases it isn't a regular file in the ISO tree but a
# hidden boot-catalog entry, only addressable by sector range.
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

echo "==> Locating airootfs squashfs and EFI boot image..."
find_log=$(mktemp)
xorriso -indev "$IN_ISO" -find / -name '*.sfs' >"$find_log" 2>&1 \
  || { echo "xorriso failed while searching for the squashfs:" >&2; cat "$find_log" >&2; exit 1; }
sfs_path=$(awk -F"'" '/airootfs/{print $2; exit}' "$find_log")
rm -f "$find_log"
[[ -n $sfs_path ]] || { echo "Couldn't find airootfs*.sfs in the ISO" >&2; exit 1; }
read -r efi_lba efi_blocks < <(locate_efi_image "$IN_ISO")
echo "    squashfs: $sfs_path"
echo "    efiboot:  LBA $efi_lba, $efi_blocks blocks"

echo "==> Extracting airootfs squashfs..."
run xorriso -osirrox on -indev "$IN_ISO" -extract "$sfs_path" "$work/airootfs.sfs"
echo "==> Extracting EFI boot image..."
dd if="$IN_ISO" of="$work/efiboot.img" bs=2048 skip="$efi_lba" count="$efi_blocks" status=none

echo "==> Adding the automated-install hook..."
run unsquashfs -d "$work/airootfs" "$work/airootfs.sfs"
# The install runs from its own service on tty1, not from the root autologin:
# with getty@tty1 never starting, no login line, /etc/issue or motd is
# printed. ConditionKernelCommandLine keeps the stock boot entries (and the
# stock .automated_script.sh, which handles script=) exactly as they were.
cat > "$work/airootfs/etc/systemd/system/archauto.service" <<EOF
[Unit]
Description=Automated install
ConditionKernelCommandLine=$CMDLINE_FLAG
After=systemd-user-sessions.service
Before=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
ExecStart=/usr/local/bin/archauto
Environment=TERM=linux HOME=/root
WorkingDirectory=/root
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../archauto.service "$work/airootfs/etc/systemd/system/multi-user.target.wants/archauto.service"

# The script it runs: tools/archauto.sh, the splash, the network, then the
# installer. Copied alongside: the patched console fonts the text logo needs
# (assets/consolefonts), the logo files and fb-logo.py, and its settings.
mkdir -p "$work/airootfs/usr/local/bin"
install -Dm644 -t "$work/airootfs/usr/local/share/archauto" "$repo_dir"/assets/consolefonts/*.psfu.gz \
  "$repo_dir"/assets/logo/logo-hd.{txt,colors} "$repo_dir"/tools/fb-logo.py
# The Wi-Fi screen (phases/wifi.sh) has to work before the installer can be
# downloaded: so the USB carries what it needs of this installer, its
# screens and prompts.
installer="$work/airootfs/usr/local/share/archauto/installer"
install -Dm644 -t "$installer" "$repo_dir"/{setup.sh,config.sh}
install -Dm644 -t "$installer/lib" "$repo_dir"/lib/*.sh
install -Dm644 -t "$installer/phases" "$repo_dir"/phases/wifi.sh
install -Dm644 -t "$installer/assets/logo" "$repo_dir"/assets/logo/*.{txt,colors}
install -Dm644 -t "$installer/assets/consolefonts" "$repo_dir"/assets/consolefonts/*.psfu.gz
# Its settings, baked in at build time: config.sh's values and the logo as
# lib/ui.sh draws it on the console (coloured lines).
{
  echo '# Generated by tools/build-autoinstall-iso.sh: tools/archauto.sh reads it.'
  declare -p REPO BRANCH BOOTSTRAP_URL TAGLINE CONSOLE_PALETTE WIFI_TEST
  logo=$(SETUP_DIR=$repo_dir TERM=linux PATCHED_FONT=1 bash -c \
    'source "$SETUP_DIR/config.sh"; source "$SETUP_DIR/lib/ui.sh"; logo_lines; printf "%s\n" "$LOGO_WIDTH" "${LOGO_LINES[@]}"')
  printf 'LOGO_WIDTH=%q\nLOGO=%q\n' "${logo%%$'\n'*}" "${logo#*$'\n'}"
} > "$work/airootfs/usr/local/share/archauto/archauto.conf"
install -Dm755 "$repo_dir/tools/archauto.sh" "$work/airootfs/usr/local/bin/archauto"

# The AUR packages that compile from source (all but -bin), built here and
# put in the live system for the installer (lib/system.sh's aur_install).
# Built as a regular user (makepkg won't build as root): SUDO_USER, in a
# clean chroot (devtools' makechrootpkg), kept between runs and updated each
# time; or, with --build-user, that user with plain makepkg, on this system,
# which is then the clean one (a fresh container: makechrootpkg runs its own
# container, which doesn't work inside Docker). A build that fails is
# skipped; installs then build it themselves.
AUR_CHROOT=/var/lib/archman-build
prebuild_aur_packages() {
  local dest=$1 user pkg dir
  local -a from_source=()
  for pkg in "${AUR_PACKAGES[@]}"; do [[ $pkg == *-bin ]] || from_source+=("$pkg"); done
  (( ${#from_source[@]} )) || return 0
  echo "==> Prebuilding AUR packages: ${from_source[*]}..."
  if [[ -n $BUILD_USER ]]; then
    user=$BUILD_USER
  else
    if [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
      echo "    skipped: run this through sudo as a regular user (makepkg won't build as root)"
      return 0
    fi
    user=$SUDO_USER
    if [[ ! -d $AUR_CHROOT/root ]]; then
      echo "    creating the clean build chroot in $AUR_CHROOT (once)..."
      mkdir -p "$AUR_CHROOT"
      run mkarchroot "$AUR_CHROOT/root" base-devel || { echo "    skipped: couldn't create the chroot"; return 0; }
    fi
  fi
  mkdir -p "$dest"
  for pkg in "${from_source[@]}"; do
    dir=$(sudo -u "$user" mktemp -d)
    sudo -u "$user" mkdir "$dir/out"
    if sudo -u "$user" git clone -q --depth 1 "https://aur.archlinux.org/$pkg.git" "$dir/$pkg" \
       && build_aur_package "$user" "$dir/$pkg" "$dir/out"; then
      find "$dir/out" -name '*.pkg.tar.zst' ! -name '*-debug-*' -exec install -m644 -t "$dest" {} +
      echo "    $pkg: $(cd "$dest" && ls "$pkg"-[0-9]*.pkg.tar.zst 2>/dev/null)"
    else
      echo "    $pkg: build failed, skipped; installs will compile it"
    fi
    rm -rf "$dir"
  done
}
# build_aur_package USER RECIPE_DIR OUT_DIR — one package, on every core.
build_aur_package() {
  if [[ -n $BUILD_USER ]]; then
    run sudo -u "$1" env -C "$2" PKGDEST="$3" MAKEFLAGS="-j$(nproc)" makepkg --syncdeps --noconfirm
  else
    (cd "$2" && PKGDEST="$3" MAKEFLAGS="-j$(nproc)" run makechrootpkg -c -u -r "$AUR_CHROOT")
  fi
}
prebuild_aur_packages "$work/airootfs/usr/local/share/archauto/packages"

# What the first Plasma session (phases/plasma-tweaks.sh) would download:
# the icon theme (ICON_THEME from ICON_THEME_REPO) and the widgets
# (PLASMOID_REPOS' widgets, as package/ directories), fetched now and carried on the
# USB, so the new system has them even with no internet at its first login.
# Only what's used is kept, without git's history. Any that can't be
# fetched are left out; that first session then downloads them as before.
carry_plasma_extras() {
  local dest=$1 tmp repo name
  echo "==> Fetching the first login's icon theme and widgets..."
  tmp=$(mktemp -d)
  if git clone -q --depth 1 "$ICON_THEME_REPO" "$tmp/icons" && [[ -d $tmp/icons/$ICON_THEME ]]; then
    mkdir -p "$dest/icons"
    cp -r "$tmp/icons/$ICON_THEME" "$dest/icons/"
    echo "    icons: $ICON_THEME"
  else
    echo "    icons: couldn't fetch $ICON_THEME; the first login will"
  fi
  for repo in "${PLASMOID_REPOS[@]}"; do
    name=${repo##*/} name=${name%.git}
    # The widget: the repo's package/, or the repo itself when its
    # metadata.json is at the top (only what Plasma needs of it).
    if git clone -q --depth 1 "$repo" "$tmp/$name" && [[ -d $tmp/$name/package ]]; then
      mkdir -p "$dest/plasmoids/$name"
      cp -r "$tmp/$name/package" "$dest/plasmoids/$name/"
      echo "    widget: $name"
    elif [[ -f $tmp/$name/metadata.json && -d $tmp/$name/contents ]]; then
      mkdir -p "$dest/plasmoids/$name/package"
      cp -r "$tmp/$name"/{metadata.json,contents} "$dest/plasmoids/$name/package/"
      echo "    widget: $name"
    else
      echo "    widget: couldn't fetch $name; the first login will"
    fi
  done
  rm -rf "$tmp"
}
carry_plasma_extras "$work/airootfs/usr/local/share/archauto/extras"

echo "==> Repacking squashfs (this takes a while)..."
rm -f "$work/airootfs.sfs"
# The official ISO's own settings (archiso's releng profiledef.sh): xz in
# 1 MB blocks packs it some 110 MB smaller than zstd did, keeping the image
# well under GitHub's 2 GB for release files. Slower to pack, a few minutes;
# the live system unpacking more slowly costs an install a few seconds.
run mksquashfs "$work/airootfs" "$work/airootfs.sfs" -comp xz -Xbcj x86,arm64 -b 1M -Xdict-size 1M

echo "==> Adding a boot entry to the EFI image..."
efi_mnt="$work/efi_mnt"
mkdir -p "$efi_mnt"
mount -o loop "$work/efiboot.img" "$efi_mnt"
# Pick the plain install entry by content, not directory order: it has a
# `linux` line (memtest doesn't) and no accessibility=on (the speech one does).
default_entry=""
for f in "$efi_mnt"/loader/entries/*.conf; do
  grep -q '^linux[[:space:]]' "$f" || continue
  grep -q 'accessibility=on' "$f" && continue
  default_entry=$f
  break
done
[[ -n $default_entry ]] || { umount "$efi_mnt"; echo "No suitable Arch boot entry found in efiboot.img" >&2; exit 1; }
new_entry="$efi_mnt/loader/entries/archauto.conf"
sed "s|^title .*|title   Automated Install ($REPO)|" "$default_entry" > "$new_entry"
# Quiet boot: no kernel, initramfs or systemd messages and no cursor, so
# the firmware logo stays up until the graphics driver takes over, and the
# next thing on screen is archauto's logo.
sed -i "s/^options \(.*\)/options \1 $CMDLINE_FLAG $QUIET_OPTIONS/" "$new_entry"
# No menu: this is the only entry, booted at once. (The ISO's own entries are
# removed; the BIOS boot menu, syslinux, is untouched, but the installer
# needs UEFI anyway.)
find "$efi_mnt/loader/entries" -name '*.conf' ! -name archauto.conf -delete
printf 'default archauto.conf\ntimeout 0\neditor no\n' > "$efi_mnt/loader/loader.conf"
umount "$efi_mnt"

# Only the squashfs needs xorriso's remastering (it changed size). The EFI
# image kept its size, so it's overwritten in place afterwards — at the
# offset re-queried from the *output* ISO, since remastering can move it.
echo "==> Assembling patched ISO..."
run xorriso -indev "$IN_ISO" -outdev "$OUT_ISO" \
  -boot_image any replay \
  -map "$work/airootfs.sfs" "$sfs_path" \
  -changes_pending yes

echo "==> Patching EFI boot image into place..."
read -r new_efi_lba new_efi_blocks < <(locate_efi_image "$OUT_ISO")
if (( new_efi_blocks != efi_blocks )); then
  echo "EFI image size changed after remastering ($efi_blocks -> $new_efi_blocks blocks); aborting." >&2
  exit 1
fi
dd if="$work/efiboot.img" of="$OUT_ISO" bs=2048 seek="$new_efi_lba" conv=notrunc status=none

echo "==> Done: $OUT_ISO"
echo "Test it first, e.g.: qemu-system-x86_64 -m 2048 -cdrom '$OUT_ISO' -boot d"
