# Project Overview

This README provides detailed instructions on how to use the scripts included in this repository: `install.sh`, `post_reboot.sh`, and `test_sddm_theme.sh`. Each script serves a specific purpose in the setup and configuration process of the system.

## Script Overviews

### install.sh

This script is responsible for the initial installation of the system. It handles the drive selection, partitioning, and installation of necessary packages. 

### post_reboot.sh

After the initial installation and reboot, this script configures the system settings and applies user preferences. It sets up various system components and ensures everything is in place for the user.


## Step-by-Step Usage

### Using install.sh
1. **Preparation**: Before running the script, ensure you have a backup of your data.
2. **Execution**: Run the script with the command `bash install.sh`. Follow the prompts to select the drive and configure partitioning.
3. **Installation**: Allow the script to complete the installation process. This may take some time. 

### Using post_reboot.sh
1. **Post-Reboot**: After rebooting, log in to your system.
2. **Execution**: Run the command `bash post_reboot.sh` to apply configurations.
3. **Completion**: Wait for the script to finish configuring your system settings.

## Customization

Each script can be customized by editing parameters directly within the script files. Review the code for specific options that can be modified.

## Warnings

- **Data Loss**: Running `install.sh` will format the selected drive. Ensure you have backed up any important data.
- **System Compatibility**: Ensure that your hardware is compatible with the installation scripts.

## Contribution Guidelines

We welcome contributions! Please follow these guidelines:
1. **Fork the repository**: Create your own copy of the repository.
2. **Make changes**: Implement your changes or improvements.
3. **Submit a pull request**: Describe your changes clearly and provide any relevant information.

## Safety Recommendations

- Always back up your data before running installation scripts.
- Test scripts in a virtual environment if possible before deploying on physical hardware.

## Conclusion

This README serves as a comprehensive guide for utilizing the scripts in this repository. Follow the instructions carefully to ensure a smooth installation and configuration process.

## Annex

installed packages in main installer

1. base — Essential (not optional)This is the core meta-package for any Arch Linux installation.
It pulls in the absolute minimum needed for a working system: glibc, bash, pacman, systemd (init system), core utilities (coreutils, file, findutils, etc.), shadow (user management), util-linux, basic networking tools (iproute2, iputils), and more.
Without base, you don't have a functional Arch system.
Note: In modern Arch (post-2019/2020 changes), base is very minimal. It no longer includes a text editor, the Linux kernel, or many tools that used to be in the old "base" group.

2. linux — Essential (highly recommended)The main Linux kernel.
Required to actually boot the system (unless you're using a different kernel like linux-lts, linux-zen, or installing in a container/VM without needing a kernel).
Most users install this or linux-lts.

3. linux-firmware — Essential for most hardwareContains firmware blobs for many devices (Wi-Fi, Bluetooth, GPUs, storage controllers, etc.).
Without it, many laptops and desktops will have non-working hardware (especially wireless networking, graphics, etc.).
Optional only in very specific cases (e.g., virtual machines with virtio drivers or servers with no proprietary firmware needs). For real hardware → keep it.

4. btrfs-progs — Required for this scriptUser-space tools for managing Btrfs filesystems (btrfs command, subvolume creation, scrubbing, snapshots, etc.).
Since the script uses Btrfs with subvolumes (@ and @home), this package is required.
Without it, you can't create subvolumes or manage the filesystem properly after installation.

5. grub — Required (for this bootloader)The GRUB bootloader itself.
Needed to install and configure the boot menu.

6. efibootmgr — Required for UEFI systemsTool to interact with the UEFI firmware (creates boot entries).
Essential when installing GRUB in UEFI mode (grub-install --target=x86_64-efi).
If you were doing BIOS (legacy) boot, this would not be needed — but almost all modern systems use UEFI.

7. nano — Optional (but very convenient)A simple, beginner-friendly text editor.
Not required at all.
The base package no longer includes any text editor. Without nano (or vim, neovim, etc.), you would have to use vi (which is minimal and present via busybox or similar in live environment, but not ideal in the new system) or install another editor later.
Many minimal installs replace it with vim, neovim, or even skip it and use cat + redirection for simple edits.

8. networkmanager — Highly recommended / practically essentialFull-featured network management daemon (handles wired, Wi-Fi, VPNs, etc.).
Makes networking easy after reboot (systemctl enable --now NetworkManager).
You could replace it with systemd-networkd + iwd (for Wi-Fi) for a more minimal setup, but that requires more manual configuration.
For a user-friendly first install → keep it.

9. sudo — Highly recommendedAllows the normal user to run commands as root with a password.
The script enables the %wheel group in /etc/sudoers, so your created user can use sudo.
Technically optional (you could use su or run everything as root), but almost everyone installs it. A system without any privilege escalation tool is inconvenient.


