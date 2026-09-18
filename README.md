# Arch Linux + KDE Plasma installer

Unattended-ish installer for a UEFI machine: Btrfs root with `@`/`@home`
subvolumes, RAM-sized swap with working hibernation, GRUB, a minimal KDE
Plasma desktop, GPU drivers (64- and 32-bit), Steam, and a handful of AUR
packages. Tuned for Portuguese locale/keyboard by default — see `config.sh`.

## Quick start

Boot the official Arch ISO, connect to the network, and run:

    curl -fsSL https://raw.githubusercontent.com/macaricol/arch/main/bootstrap.sh | bash

Answer four prompts (hostname, root password, username, user password),
pick the drive from an arrow-key menu, type `YES`, and walk away. The
machine reboots into a one-time tty autologin that runs the desktop setup,
reboots again into SDDM, and the first Plasma session applies the desktop
tweaks. Two reboots in total, and one password prompt after the first.

To install from a different branch: `curl ... | BRANCH=clauding bash`.

**This erases the selected drive.** Test in a VM first.

### No-typing USB

`tools/build-autoinstall-iso.sh` adds an "Automated Install" entry to an
official ISO's boot menu that runs the command above by itself:

    sudo pacman -S --needed xorriso squashfs-tools
    sudo tools/build-autoinstall-iso.sh archlinux-x86_64.iso archlinux-autoinstall.iso

## How it fits together

    bootstrap.sh          fetches the repo tarball to /tmp, runs setup.sh install
    setup.sh <phase>      single entry point; loads config + lib, runs one phase
    config.sh             every tunable value: locale, disk, package lists, theme
    lib/ui.sh             messages, step counter, run() spinner + setup.log
    lib/prompt.sh         validated input, passwords, confirm, arrow-key menu
    lib/system.sh         checks, CPU/GPU detection, pacman/AUR/service helpers
    phases/install.sh     live ISO: partition, format, pacstrap, hand off to chroot
    phases/chroot.sh      locale, accounts, sudo, hibernation, GRUB, first-login hook
    phases/post.sh        first login: multilib, drivers, Plasma, theming, Samba, Steam, AUR
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

Everything lives in `config.sh`: timezone, keymaps, locales, mirror
countries, EFI size, Btrfs mount options, the package lists (`BASE_`,
`KDE_`, `EXTRA_`, `GAMING_`, `AUR_PACKAGES`, per-vendor `GPU_PACKAGES_*`),
the SDDM theme and wallpaper, icon theme, Plasma widgets, and the Samba
workgroup.

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
- **Microcode goes in with `pacstrap`**, so the first initramfs and
  `grub.cfg` already include it and nothing needs regenerating later.
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
- The live USB is filtered out of the drive menu, and `udevadm settle`
  runs after partitioning so the new device nodes exist before they're used.
