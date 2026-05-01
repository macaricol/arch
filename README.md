
# Arch Linux + KDE Plasma Installation Scripts

This repository contains a set of scripts to automate the installation and configuration of **Arch Linux** with a minimal **KDE Plasma** desktop.

The repository includes three main scripts:
- `main.sh`
- `post.sh`
- `kde_init.sh`

## Script Overview

### main.sh
Performs the initial system installation. It handles drive selection, disk partitioning, Btrfs subvolume creation, base system installation, and bootloader setup (GRUB).

### post.sh
Runs after the first reboot. This script configures the system, installs a minimal KDE Plasma desktop, sets up themes, wallpapers, keyboard layout, Samba file sharing, and applies user preferences.

### kde_init.sh
Contains additional user-level configurations that run automatically on first login (autostart).

## Step-by-Step Usage

### 1. Using main.sh (Initial Installation)
1. Boot from the Arch Linux live USB.
2. (Optional but recommended) Connect to the internet.
3. Run the script:

   curl -O https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/main.sh
   chmod -x main.sh
   ./main.sh

5. After the script finishes, reboot the system.

**Warning**: This script will **erase all data** on the selected drive.

### 2. Using post.sh (Post-Installation)
1. After rebooting, log in as the user created during installation.
2. Run the post-installation script:

   ./post.sh
   
3. Wait for the script to complete. The system will configure KDE Plasma, SDDM theme, Samba, and other settings.

### 3. kde_init.sh
This script is automatically copied to your home directory and set to run on first login via autostart. No manual execution is required.

## Installed Packages

### Base System Packages (main.sh)

| Package              | Purpose |
|----------------------|--------|
| `base`               | Core meta-package for a minimal Arch Linux system (glibc, pacman, systemd, etc.) |
| `linux`              | The main Linux kernel |
| `linux-firmware`     | Firmware blobs for hardware devices (Wi-Fi, GPU, etc.) |
| `btrfs-progs`        | Tools for Btrfs filesystem management (required for subvolumes) |
| `grub`               | GRUB bootloader |
| `efibootmgr`         | UEFI boot manager (required for GRUB in UEFI mode) |
| `nano`               | Simple text editor |
| `networkmanager`     | Network management daemon (Wi-Fi, Ethernet, VPN) |
| `sudo`               | Allows normal users to run commands as root |

### Minimal KDE Plasma Packages (post.sh)

**Core Plasma Desktop**
- `plasma-desktop` — Core Plasma desktop shell, panels, widgets, and workspace
- `sddm` — Login screen (display manager)
- `sddm-kcm` — KDE settings module for configuring SDDM

**Hardware & Connectivity**
- `bluedevil` — Bluetooth support and system tray applet
- `kdeconnect` — Phone integration (notifications, file sharing, remote control)
- `kdenetwork-filesharing` — Enables the "Share" tab in Dolphin for easy Samba sharing

**System & Display**
- `kscreen` — Display configuration (multi-monitor support)

**Applications**
- `konsole` — Terminal emulator
- `kate` — Advanced text editor
- `dolphin` — Feature-rich file manager
- `ark` — Archive manager (zip, 7z, rar, etc.)
- `gwenview` — Image viewer

**Multimedia & Thumbnails**
- `kdegraphics-thumbnailers` — Thumbnail generation for images and PDFs
- `ffmpegthumbs` — Video thumbnail support in Dolphin
- `pipewire-jack` — JACK audio support via PipeWire

**System Management**
- `plasma-pa` — Audio volume control (system tray)
- `plasma-nm` — Network management (system tray)
- `plasma-systemmonitor` — System resource monitor
- `kwalletmanager` — Password and credential manager (KWallet)

## Warnings

- `main.sh` will **completely erase** the selected drive. Always back up important data beforehand.
- These scripts are designed for UEFI systems with Btrfs.
- Test in a virtual machine first if you are unsure about your hardware compatibility.

## Safety Recommendations

- Always have a recent backup of your data.
- Verify the correct drive is selected before running `main.sh`.
- Review the scripts before execution if you want to understand or modify the setup.

## Contribution Guidelines

Contributions are welcome!  
1. Fork the repository  
2. Create a new branch for your changes  
3. Submit a Pull Request with a clear description
