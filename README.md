# Arch Linux + KDE Plasma installer

Unattended-ish installer for a UEFI machine: Btrfs root with `@`/`@home`
subvolumes, RAM-sized swap with working hibernation, GRUB, a minimal KDE
Plasma desktop, GPU drivers (64- and 32-bit), Steam, and a handful of AUR
packages. Tuned for Portuguese locale/keyboard by default — see `config.sh`.

## Quick start

Boot the official Arch ISO, connect to the network, and run:

    curl -fsSL https://raw.githubusercontent.com/macaricol/arch/main/bootstrap.sh | bash

Answer three prompts (hostname, username, and one password used for both
your user and root),
pick the drive from an arrow-key menu, type `YES`, and walk away. When the
base install is done it asks you to remove the USB, and reboots as soon as
you unplug it (or press Enter). The machine then comes up in a one-time tty
autologin that runs the desktop setup,
reboots again into SDDM, and the first Plasma session applies the desktop
tweaks. Two reboots in total, and one password prompt after the first.

To install from a different branch: `curl ... | BRANCH=clauding bash`.

**This erases the selected drive.** Test in a VM first.

### No-typing USB

`tools/build-autoinstall-iso.sh` adds an "Automated Install" entry to an
official ISO's boot menu that runs the command above by itself. That entry
boots quietly: no kernel or systemd messages and no login text, just the
firmware logo, then the installer's logo with "Waiting for network…" /
"Fetching the installer…" until the installer takes over. If either fails,
it says so and leaves a root shell on tty1. The ISO's own entries are
unchanged.

    sudo pacman -S --needed xorriso squashfs-tools
    sudo tools/build-autoinstall-iso.sh

Run with no arguments it asks whether to fetch the current official ISO or
use one you already have. `--download` skips the question for scripted use,
and an explicit path still works as before:

    sudo tools/build-autoinstall-iso.sh --download my-autoinstall.iso
    sudo tools/build-autoinstall-iso.sh archlinux-x86_64.iso archlinux-autoinstall.iso

Downloads land in the current directory under their dated release name, are
checked against the mirror's `sha256sums.txt` and GPG-verified against the
pacman keyring, and are reused instead of re-fetched on later runs. The
mirror is `ISO_MIRROR` in `config.sh`.

## How it fits together

    bootstrap.sh          fetches the repo tarball to /tmp, runs setup.sh install
    setup.sh <phase>      single entry point; loads config + lib, runs one phase
    config.sh             every tunable value: locale, disk, package lists, theme
    logo.txt              the logo drawn above every step
    assets/plymouth/      the boot splash theme: script, logo, spinner
    assets/consolefonts/  the console fonts, with Pac-Man added (tools/make-console-fonts.py)
    lib/ui.sh             console font/palette, centred step screens, run() spinner + setup.log
    lib/prompt.sh         validated input, passwords, confirm, arrow-key menu
    lib/system.sh         checks, CPU/GPU detection, pacman/AUR/service helpers
    phases/install.sh     live ISO: partition, format, pacstrap (+ CPU/GPU drivers), hand off to chroot
    phases/chroot.sh      locale, accounts, sudo, hibernation, GRUB, first-login hook
    phases/post.sh        first login: Plasma, theming, Samba, Steam, AUR
    phases/kde-init.sh    first Plasma session: kwin, theme, widgets, panel, icons

The installer directory travels with the install: `/tmp/arch-setup` on the
ISO → `/root/arch-setup` in the chroot → `~/.arch-setup` for the post and
Plasma phases, which then deletes itself, leaving only `~/arch-setup.log`.

Every command that goes through `run()` is logged there, with its full
output shown on the terminal only if it fails. `VERBOSE=1 setup.sh <phase>`
streams everything live instead.

## Running phases by hand

From a local checkout, phases can be run directly — useful for re-applying
the desktop setup or iterating on it:

    ./setup.sh post        # as your user; idempotent (--needed everywhere)
    ./setup.sh kde-init    # as your user, inside a Plasma session

Running from a checkout never deletes it; only the staged `~/.arch-setup`
copy cleans itself up.

## Configuration

Everything lives in `config.sh`: the installer's tagline and console
palette (`TAGLINE`, `CONSOLE_PALETTE`), timezone, keymaps, locales, mirror
countries, EFI size, Btrfs mount options, the package lists (`BASE_`,
`KDE_`, `EXTRA_`, `GAMING_`, `AUR_PACKAGES`, per-vendor `GPU_PACKAGES_*`),
the surround-upmix settings (`UPMIX_*`), the SDDM theme and wallpaper, icon
theme, Plasma widgets, and the Samba workgroup.

## Design notes

Things that look odd but are deliberate:

- **Passwords** are written to a root-only `creds` file inside the staged
  installer for the chroot phase (deleted first thing there, and by a trap
  if the chroot never starts), then fed to `chpasswd` on stdin — they never
  appear in argv, the environment, or the log.
- **32-bit GPU drivers are installed before Steam.** `steam` depends on the
  virtual `lib32-vulkan-driver`, and `pacman --noconfirm` picks the first
  provider — `lib32-nvidia-utils`, which pulls the whole NVIDIA userspace
  even on AMD/Intel. Having the right provider installed first avoids that.
  With no Intel/AMD/NVIDIA GPU detected (VMs), only plain `mesa` is installed
  and Steam is skipped: software Vulkan (`vulkan-swrast`) would satisfy the
  dependency, but a 64-bit Vulkan device makes the SDDM theme's video
  background render blank under VirtualBox.
- **Surround upmixing is written twice**, to
  `/etc/pipewire/client.conf.d/` and `/etc/pipewire/pipewire-pulse.conf.d/`.
  PipeWire mixes channels in the client library, so the native path (mpv,
  Zen) and the PulseAudio path each need their own copy — configure one and
  half your applications silently stay stereo. Upmixing is off in stock
  PipeWire: without this, a stereo stream on a 5.1/7.1 card only ever
  reaches front L/R. `lfe-cutoff`/`fc-cutoff` have to be set explicitly too;
  left at their defaults the subwoofer and centre stay silent even with
  `channelmix.upmix = true`. Nothing is set for mpv on purpose — forcing
  `audio-channels=7.1` makes mpv pad the extra channels itself, so PipeWire
  sees 8 channels and skips the upmix.
- **Microcode and GPU drivers go in with `pacstrap`**, so the first
  initramfs and `grub.cfg` already include them and nothing needs
  regenerating later; an NVIDIA machine runs `nvidia-open` from its very
  first boot rather than nouveau. That needs multilib (for the 32-bit
  drivers) enabled before `pacstrap`: the install phase turns it on in the
  live ISO's `pacman.conf`, which `pacstrap` reads, and `pacstrap -P` copies
  that config into the new system.
- **The post phase enables SDDM without `--now`.** `sddm.service` conflicts
  with `getty@tty1`; starting it would SIGHUP the very session the phase is
  running in. The reboot starts it.
- **Passwordless `sudo pacman`** exists only during the AUR step (makepkg's
  own sudo calls don't see the cached ticket) and is removed right after,
  with the EXIT trap as backstop.
- **kde-init is autostarted, not run from post.sh**, because Plasma writes
  several of the config files it edits during its own startup. The
  containment and applet IDs it uses come from Plasma's stock first-session
  layout.
- **The installer restyles the console** while it runs (on a real tty only,
  `TERM=linux`): it picks the largest of three stock kbd fonts that keeps
  about 48 rows and 80 columns, so text isn't tiny on high-resolution
  screens, and swaps the 16 VGA colours for `CONSOLE_PALETTE`. The fonts
  are copies from `assets/consolefonts` with two unused glyphs redrawn as
  Pac-Man: `ᗧ`, the tag on every message, and `⬤`, its closed mouth, which
  the spinner alternates with it while eating a row of pellets. No stock
  console font has either character; `tools/make-console-fonts.py`
  rebuilds the copies. Each step
  then clears the screen and redraws the logo, a progress bar and the step
  title in one centred column; earlier output stays in the log, which is
  why `warn` writes there too. None of this persists after a reboot.
- **Prompts use [gum](https://github.com/charmbracelet/gum) when it runs.**
  The install phase fetches it onto the live ISO (`pacman -Sy gum`, a few
  MB of RAM) and the post phase installs it on the new system. That first
  install is a partial upgrade, so gum is only used after `gum --version`
  succeeds; if it can't be fetched or won't start, the plain prompts in
  `lib/prompt.sh` take over. Esc asks again, Ctrl+C aborts. Typing `YES` to
  erase the drive stays plain typed text on purpose.
- **Boot is quiet, behind a Plymouth splash.** The chroot phase adds the
  `plymouth` hook right after `systemd`/`udev`, `quiet splash` to the kernel
  options, and its own `pacman` theme (`assets/plymouth`): Arch's logo
  where firmware logos sit and a spinner, on black. It's a Plymouth script
  theme, so `pacman.script` can size both from the screen height: the logo
  is 24.5% of it (196 px at 1280×800, the size of VirtualBox's firmware
  logo), and the images are rendered large enough for 4K and only scaled
  down. Press Esc during boot to see the
  messages. On NVIDIA the driver modules go into the initramfs too, so the
  splash has a display that early.
- The live USB is filtered out of the drive menu, and `udevadm settle`
  runs after partitioning so the new device nodes exist before they're used.

## Annex: installed packages

Grouped as they appear in `config.sh`, which is the source of truth — this
table is a description of those lists, not a second copy of them.

### `BASE_PACKAGES` — pacstrapped onto the new root

| Package | Purpose |
|---|---|
| `base` | Core meta-package for a minimal Arch system (glibc, pacman, systemd) |
| `linux` | The main Linux kernel |
| `linux-firmware` | Firmware blobs for hardware devices (Wi-Fi, GPU, etc.) |
| `btrfs-progs` | Btrfs filesystem tools, needed for the `@`/`@home` subvolumes |
| `grub` | Bootloader |
| `efibootmgr` | UEFI boot manager, required by GRUB in UEFI mode |
| `nano` | Simple text editor, so the installed system is usable before a desktop exists |
| `networkmanager` | Network management daemon (Wi-Fi, Ethernet, VPN) |
| `sudo` | Lets the created user run commands as root |
| `plymouth` | Boot splash (the `pacman` theme) instead of scrolling boot messages |

CPU microcode (`intel-ucode` / `amd-ucode`) is added here too, picked from the
detected vendor — see the design note on why it goes in at this stage.

### GPU drivers — `GPU_PACKAGES_*`, by detected vendor, pacstrapped too

- **Intel** — `mesa`, `lib32-mesa`, `vulkan-intel`, `lib32-vulkan-intel`,
  `intel-media-driver`: graphics drivers (64- and 32-bit), Vulkan, and
  hardware video decode/encode
- **AMD** — `mesa`, `lib32-mesa`, `vulkan-radeon`, `lib32-vulkan-radeon`,
  `radeontop`: the same, plus a GPU usage monitor
- **NVIDIA** — `nvidia-open`, `nvidia-utils`, `lib32-nvidia-utils`,
  `nvidia-settings`, `opencl-nvidia`: open kernel modules plus the userspace
  driver (64- and 32-bit), config GUI, OpenCL. `nvidia-open` drives Turing
  (RTX 20xx) and newer only; older cards fall back to nouveau, since the
  proprietary package no longer exists in the repos.
- **Fallback** (VMs, unrecognised hardware) — `mesa`, `lib32-mesa` only.
  Deliberately no software Vulkan: see the design note above.

Hybrid setups get every matching vendor. The 32-bit halves are what Steam
needs, and installing them first is what stops pacman pulling the NVIDIA
userspace onto an AMD or Intel machine.

### `KDE_PACKAGES` — the desktop

**Core Plasma**
- `plasma-desktop` — Plasma shell, panels, widgets, workspace
- `sddm` — Login screen (display manager)
- `sddm-kcm` — KDE settings module for configuring SDDM
- `kscreen` — Display configuration and multi-monitor support

**System tray & management**
- `plasma-pa` — Audio volume control
- `plasma-nm` — Network management
- `plasma-systemmonitor` — System resource monitor
- `kwalletmanager` — Password and credential manager (KWallet)

**Hardware & connectivity**
- `bluedevil` — Bluetooth support and tray applet
- `kdeconnect` — Phone integration (notifications, file sharing, remote control)
- `kdenetwork-filesharing` — The "Share" tab in Dolphin, for Samba shares

**Applications**
- `konsole` — Terminal emulator
- `dolphin` — File manager
- `ark` — Archive manager (zip, 7z, rar, …)
- `featherpad` — Lightweight text editor
- `kio-admin` — Lets Dolphin edit root-owned files behind a polkit prompt,
  instead of running a whole file manager as root

**Multimedia & thumbnails**
- `kdegraphics-thumbnailers` — Thumbnails for images and PDFs
- `ffmpegthumbs` — Video thumbnails in Dolphin
- `pipewire-jack` — JACK audio support via PipeWire

### `EXTRA_PACKAGES` — applications and fonts

- `fastfetch` — System information display
- `mpv` — Lightweight, scriptable video player
- `krdc` — Remote desktop client (VNC/RDP)
- `krdp` — Remote desktop server (RDP)
- `git` — Version control
- `code` — The open-source build of Visual Studio Code
- `ttf-liberation` — Metric-compatible Arial / Times New Roman / Courier New
- `noto-fonts-cjk` — Chinese, Japanese and Korean coverage
- `ntfs-3g`, `exfatprogs`, `dosfstools` — format and repair NTFS, exFAT and
  FAT32. Only formatting and repair need these; mounting works without them.

### `GAMING_PACKAGES` and `AUR_PACKAGES`

- `steam` — Installed only when a real GPU was detected, and after the 32-bit
  drivers, for the reason in the design notes. Needs the multilib repo, which
  the install phase enables.
- `base-devel` — Build tools, required to compile anything from the AUR
- `paru` (AUR) — AUR helper, built from source so it always matches the
  installed pacman's libalpm; the Rust toolchain is removed again afterwards
- `zen-browser-bin` (AUR) — Firefox-based privacy-focused browser
- `qview` (AUR) — Lightweight, fast image viewer
