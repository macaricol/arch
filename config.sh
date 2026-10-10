#!/usr/bin/env bash
# Every user-tunable value lives here; the phases only read from this file.

# ── Source repo (used by bootstrap.sh and the ISO builder) ──────────────
REPO=${REPO:-macaricol/arch}
BRANCH=${BRANCH:-main}

# ── Install media (tools/build-autoinstall-iso.sh) ─────────────────────
# Where the builder fetches the official ISO from when you don't hand it one.
# Any Arch mirror works; this is the project's own geo-balanced one.
ISO_MIRROR='https://geo.mirror.pkgbuild.com/iso/latest'

# ── Installer look ─────────────────────────────────────────────────────
# Shown under the logo (assets/logo) on every step.
TAGLINE='ARCHMAN · KDE Plasma'
# The 16 console colours used while installing, in VT order. Built on the
# palette 01050E near-black, 021742 navy, 033574 blue, A80440 crimson,
# F3065E neon pink, and FFC400 Pac-Man yellow; the grey-white text,
# blue-grey hints, amber warnings and red-orange errors are tints added for
# roles it has no colour for. How lib/ui.sh uses them:
#   0 background · 2 the logo's extrusion · 3 Pac-Man (in the logo, the
#   tags and the spinner) · 6 the logo's letters
#   4 empty progress bar, unselected buttons · 5 Tux's splat (the hints'
#   blue-grey, in a slot the 512-glyph font keeps) · 7 the facts · 8 hints
#   9 errors · 10 closing title · 11 warnings · 13 tagline
#   14 progress · 15 text
# Only applies on a real console (TERM=linux), not in a terminal emulator.
CONSOLE_PALETTE=(
  # black  red    green  yellow blue   magenta cyan   white
  01050E A80440 033574 FFC400 021742 4A5A80 F3065E 8E95A8
  4A5A80 FF5A3C F3065E E0A040 033574 A80440 F3065E C9CEDB
)

# ── Locale ─────────────────────────────────────────────────────────────
# The timezone: auto is where this machine is, by its public IP, looked up
# during the install (UTC if that fails); or a fixed one, e.g. 'Europe/Lisbon'.
# Never asked. (The install phase hands its answer on, hence the ${...:-}.)
TIMEZONE=${TIMEZONE:-auto}
# The keyboard is asked, the layout of where this machine is first (the
# list: lib/keyboard.sh's KEYBOARD_LAYOUTS). These are its answer, handed
# on to the later phases, or US until it's given.
KEYMAP=${KEYMAP:-us}                 # the console's: live ISO and installed system
X11_LAYOUT=${X11_LAYOUT:-us}         # Plasma's and the login screen's
X11_VARIANT=${X11_VARIANT:-}
X11_OPTIONS=${X11_OPTIONS:-}
LOCALE='en_US.UTF-8'                 # the language, everywhere: Plasma, terminal, numbers. Never asked.
# Dates and times (LC_TIME) in the way of where this machine is: auto is the
# country's, by its public IP, looked up during the install (LOCALE's if
# that fails); or a fixed one, e.g. 'en_GB.UTF-8'. Never asked.
TIME_LOCALE=${TIME_LOCALE:-auto}

# ── Disk ───────────────────────────────────────────────────────────────
# Layout is always: EFI, swap sized to RAM (so hibernation works), Btrfs root
# with @ and @home subvolumes.
# Mirrors are ranked in this machine's country, looked up from its public IP
# (auto), or in the countries listed here, e.g. 'PT,ES'.
MIRROR_COUNTRIES='auto'
# Files pacman downloads at once, during the install and on the new system
# (pacman's own default is 5).
PARALLEL_DOWNLOADS=10
EFI_SIZE='512M'
BTRFS_MOUNT_OPTS='noatime,compress=zstd:1'

# ── Packages ───────────────────────────────────────────────────────────
BASE_PACKAGES=(base linux linux-firmware btrfs-progs grub efibootmgr nano networkmanager sudo plymouth pciutils)

KDE_PACKAGES=(
  plasma-desktop sddm sddm-kcm kscreen plasma-pa plasma-nm plasma-systemmonitor
  bluedevil kdeconnect kdenetwork-filesharing kwalletmanager
  konsole dolphin ark featherpad kio-admin
  kdegraphics-thumbnailers ffmpegthumbs pipewire-jack
)

EXTRA_PACKAGES=(
  fastfetch mpv krdc krdp git code
  ttf-liberation noto-fonts-cjk
  ntfs-3g exfatprogs dosfstools   # format/repair NTFS, exFAT, FAT32 (mounting needs nothing extra)
  matugen                         # skwd-wall's desktop colours, from the wallpaper
)

GAMING_PACKAGES=(steam)  # only installed when a supported GPU was detected, see desktop phase
# From the AUR, installed in this order; their dependencies must be in the
# official repos (makepkg). paru first: the AUR helper, which then keeps them
# all up to date (paru -Syu, or Apdatifier in the panel), itself included.
# Those built from source (all but -bin) come prebuilt on the USB.
# skwd-wall, the wallpaper picker, comes as four, each needing the ones
# before it (makepkg only fetches dependencies from the official repos).
AUR_PACKAGES=(paru zen-browser-bin qview skwd-paper-bin skwd-deck-bin skwd-wall-v2-bin skwd-paper-plasma)
# The -bin ones the USB carries prebuilt too (tools/build-autoinstall-iso.sh;
# a -bin package is only a download, otherwise left to installs): skwd-wall's,
# a beta, kept from GitHub and the AUR at install time.
AUR_PREBUILT_BIN=(skwd-paper-bin skwd-deck-bin skwd-wall-v2-bin)

# The lib32-* packages are what Steam needs. Installing the right ones up
# front matters: steam depends on virtual lib32-vulkan-driver / lib32-libgl,
# and pacman --noconfirm would otherwise pick lib32-nvidia-utils (and with it
# the whole NVIDIA userspace) even on AMD/Intel machines.
GPU_PACKAGES_INTEL=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver)
GPU_PACKAGES_AMD=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon radeontop)
# nvidia-open, not nvidia: the proprietary kernel modules are gone from the
# repos (nvidia-open declares Replaces: nvidia<=580.119.02-2), so the old name
# is simply "target not found" and aborts the whole desktop phase. The non-dkms
# build is the right one here because BASE_PACKAGES installs the stock `linux`
# kernel, which it's prebuilt against. Note this only drives Turing (RTX 20xx)
# and newer — NVIDIA's 615 branch dropped Maxwell/Pascal/Volta, and with the
# proprietary package gone those cards now fall back to nouveau.
GPU_PACKAGES_NVIDIA=(nvidia-open nvidia-utils lib32-nvidia-utils nvidia-settings opencl-nvidia)
# VMs and unknown hardware. Deliberately no software Vulkan: a 64-bit Vulkan
# device (vulkan-swrast) makes the SDDM theme's video background render blank
# under VirtualBox (in the astronaut SDDM theme), and lib32-vulkan-swrast
# can't be installed without it.
GPU_PACKAGES_FALLBACK=(mesa lib32-mesa)

# ── Audio ──────────────────────────────────────────────────────────────
# PipeWire does not upmix by default: on a surround card, stereo content
# plays out of front L/R only and the rear/side/centre speakers stay silent.
# These settings feed every speaker. Set UPMIX_SURROUND=0 on a machine with
# plain stereo output, where upmixing does nothing useful.
UPMIX_SURROUND=1
UPMIX_METHOD='psd'        # psd = matrix-decode rears from L-R; also 'simple', 'none'
UPMIX_LFE_CUTOFF=150      # Hz and below go to the subwoofer
UPMIX_FC_CUTOFF=12000     # Hz and below go to the centre speaker
UPMIX_REAR_DELAY=12.0     # ms of Haas delay on the rears, so they stay behind you

# ── Look & feel ────────────────────────────────────────────────────────
# The login screen: the archman theme (assets/sddm/archman), an Omarchy-style
# unlock screen in the installer's look (rebuild with tools/make-sddm-theme.py).
SDDM_THEME='archman'
# Installed too: the wallpapers come from it, and it stays available as an
# alternative login theme in System Settings.
ASTRONAUT_REPO='https://github.com/macaricol/sddm-astronaut-theme.git'
ASTRONAUT_THEME='sddm-astronaut-theme'
# The wallpapers (assets/wallpapers), installed system-wide here and copied
# into the user's ~/Pictures/Wallpapers (skwd-wall's folder); and the one
# applied: the desktop's and the lock screen's.
WALLPAPERS_DIR=/usr/share/wallpapers/archman
WALLPAPER="$WALLPAPERS_DIR/synthwave-city-sunset.jpg"
ICON_THEME_REPO='https://github.com/L4ki/Breeze-Chameleon-Icons.git'
ICON_THEME='Breeze Chameleon Dark'   # a directory inside that repo
PLASMOID_REPOS=(                     # each repo's package/ directory, or the repo itself (metadata.json at its top)
  https://github.com/macaricol/kde_modernclock.git
  https://github.com/exequtic/apdatifier
  https://github.com/luisbocanegra/plasma-panel-colorizer   # the panels' look (the Dock preset)
  https://github.com/yassine20011/kvitals   # system monitor, in its own panel
)

# ── Samba ──────────────────────────────────────────────────────────────
SAMBA_WORKGROUP='WORKGROUP'
