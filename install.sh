#!/bin/bash

#config variables
#DRIVE='/dev/sda'
HOSTNAME=''
ROOT_PASSWORD=''
USER_NAME=''
USER_PASSWORD=''
TIMEZONE='Europe/Lisbon'
KEYMAP='pt-latin9'

# Ensure stdin is bound to the terminal
exec </dev/tty

#############################################################
######### SELECTION MENU ####################################
#############################################################

select_drive() {

  # Initialize empty variable to store drive paths
  DRIVE_PATHS=""
  # Get list of all block devices using lsblk, exclude header and loop devices
  DRIVES=$(lsblk -d -o PATH | grep -v '^PATH' | grep -v loop)

  # Check if any drives were found
  if [ -z "$DRIVES" ]; then
    echo "No drives found. Exiting."
    exit 1
  fi

  # Loop through each drive and append to DRIVE_PATHS
  while IFS= read -r drive; do
    DRIVE_PATHS="$DRIVE_PATHS $drive"
  done <<< "$DRIVES"

  # Remove leading/trailing whitespace
  DRIVE_PATHS=$(echo "$DRIVE_PATHS" | xargs)

  # Array of menu options
  options=($DRIVE_PATHS)
  # Current selected index
  selected=0
  # Total number of options
  total_options=${#options[@]}

  # Function to draw the menu
  draw_menu() {
    clear
    echo "###########################################"
    echo "#        Select installation drive        #"
    echo "###########################################"
    echo "#"
    for ((i=0; i<total_options; i++)); do
      if [ $i -eq $selected ]; then
        # Highlight selected option with > and background color
        echo -e "# > \033[7m${options[$i]}\033[0m "
      else
        echo "#   ${options[$i]}   "
      fi
    done
    echo "#"
    echo "###########################################"
    echo "#   Use ↑↓ to navigate, Enter to select   #"
    echo "###########################################"
  }

  # Function to handle key input
  read_arrow() {
    local key
    read -rsn1 key # Read one character silently from /dev/tty (already set by exec)
    if [[ $key == $'\x1b' ]]; then
      read -rsn2 -t 0.1 key 2>/dev/null # Read two more characters with timeout
      case $key in
        '[A') # Up arrow
          ((selected--))
          if [ $selected -lt 0 ]; then
            selected=$((total_options-1))
          fi
          return 1
          ;;
        '[B') # Down arrow
          ((selected++))
          if [ $selected -ge $total_options ]; then
            selected=0
          fi
          return 1
          ;;
        *) # Escape key alone or other sequences
          return 1
          ;;
      esac
    elif [[ $key == "" ]]; then
      # Enter key
      return 0
    fi
    return 1 # Other keys return to menu
  }

  # Drive selection loop
  while true; do
    draw_menu
    read_arrow
    key_status=$?

    if [ $key_status -eq 0 ]; then
      # Enter was pressed, handle selection
      echo "Are you sure you want to use drive ${options[$selected]} to install Arch? ALL DATA WILL BE LOST!"
      echo "Press Enter to continue, Esc or any other key to cancel..."
      read -rsn1 confirm
      if [ -z "$confirm" ]; then
        # Enter was pressed, set DRIVE and proceed
        DRIVE="${options[$selected]}"
        # Validate drive
        if [ ! -b "$DRIVE" ]; then
          echo "Error: $DRIVE is not a valid block device."
          exit 1
        fi
        echo "Selected drive: $DRIVE"
        DRIVE_TYPE=$(get_drive_type "$DRIVE")
        return 0 # Proceed with installation
      elif [ "$confirm" == $'\x1b' ]; then
        # Escape was pressed, return to menu
        continue
      else
        # Any other key, return to menu
        continue
      fi
    fi
    # Escape or other keys (key_status -eq 1) redraw the menu
  done
}


#############################################################
######### END SELECTION MENU ################################
#############################################################

# Function to determine drive type
get_drive_type() {
  local drive="$1"
  if [[ $drive == /dev/nvme* ]]; then
    echo "nvme"
  elif [[ $drive == /dev/sd* ]]; then
    echo "sda"
  else
    echo "unknown"
  fi
}

setup() {

    if [ -z "$HOSTNAME" ]; then
        echo "Enter your hostname:"
        read -p '' HOSTNAME
    fi

    if [ -z "$ROOT_PASSWORD" ]; then
        echo 'Enter the root password:'
        stty -echo
        read -p '' ROOT_PASSWORD
        stty echo
    fi

    if [ -z "$USER_NAME" ]; then
        echo "Enter your username:"
        read -p '' USER_NAME
    fi
    if [ -z "$USER_PASSWORD" ]; then
        echo "Enter the password for user $USER_NAME"
        stty -echo
        read -p '' USER_PASSWORD
        stty echo
    fi

    # Select drive
    select_drive
    local installation_drive="$DRIVE"

    echo '##### Creating partitions #####'
    partition_drive "$installation_drive"

    echo '##### Formatting filesystems #####'
    format_filesystems "$installation_drive"

    echo '##### Mounting filesystems #####'
    mount_filesystems "$installation_drive"

    echo '##### Installing base system #####'
    install_base

    echo "##### Generating fstab #####"
    set_fstab

    echo '##### Chrooting into installed system #####'
    cp $0 /mnt/setup.sh
    arch-chroot /mnt env HOSTNAME="$HOSTNAME" ROOT_PASSWORD="$ROOT_PASSWORD" USER_NAME="$USER_NAME" USER_PASSWORD="$USER_PASSWORD" ./setup.sh chroot

    reboot
}

configure() {
    echo '##### Installing additional packages #####'
    install_packages

    echo '##### Setting timezone #####'
    set_timezone "$TIMEZONE"

    echo '##### Setting locale #####'
    set_locale

    echo '##### Setting console keymap #####'
    set_keymap

    echo '##### Setting hostname #####'
    set_hostname "$HOSTNAME"

    echo '##### Configuring sudoers #####'
    set_sudoers

    echo '##### Setting root password #####'
    echo "##### root pass: $ROOT_PASSWORD"
    sleep 5
    set_root_password "$ROOT_PASSWORD"

    echo '##### Creating initial user #####'
    echo "##### user: $USER_NAME"
    echo "##### root pass: $USER_PASSWORD"
    sleep 5
    create_user "$USER_NAME" "$USER_PASSWORD"

    echo '##### Enabling network manager #####'
    enable_network

    echo '##### Installing bootloader #####'
    install_grub

    echo '##### Downloading post reboot script #####'
    dl_post_reboot_script

    rm /setup.sh
}

partition_drive() {
    local installation_drive="$1"

    parted -s "$installation_drive" \
        mklabel gpt \
        mkpart primary fat32 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 8705MiB \
        mkpart primary btrfs 8705MiB 100%

  case "$DRIVE_TYPE" in
    nvme) partition_suffix="p"; echo "Using NVMe scheme (e.g., ${installation_drive}p1)" ;;
    sda) echo "Using SDA scheme (e.g., ${installation_drive}1)" ;;
    *) echo "Unknown drive type"; exit 1 ;;
  esac
  BOOT_PARTITION="${installation_drive}${partition_suffix}1"
  SWAP_PARTITION="${installation_drive}${partition_suffix}2"
  ROOT_PARTITION="${installation_drive}${partition_suffix}3"
}

format_filesystems() {
    mkfs.fat -F 32 -n boot "$BOOT_PARTITION"
    mkfs.btrfs -f -L root "$ROOT_PARTITION"
    mkswap -L swap "$SWAP_PARTITION"
}

mount_filesystems() {
    mount "$ROOT_PARTITION" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt

    mount -o subvol=@ "$ROOT_PARTITION" /mnt
    mkdir -p /mnt/home
    mount -o subvol=@home "$ROOT_PARTITION" /mnt/home
    mkdir /mnt/boot
    mount "$BOOT_PARTITION" /mnt/boot
    swapon "$SWAP_PARTITION"
}

install_base() {
    pacstrap -K /mnt base linux linux-firmware
}

install_packages() {
    local packages=''
    #General utilities/libraries
    packages+='grub efibootmgr btrfs-progs nano networkmanager sudo'
    pacman -Sy --noconfirm $packages
}

set_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}

set_timezone() {
    local timezone="$1"; shift

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc
}

set_locale() {
    sed -i 's/#en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/#pt_PT\.UTF-8 UTF-8/pt_PT.UTF-8 UTF-8/' /etc/locale.gen

    echo 'LANG="pt_PT.UTF-8"' >> /etc/locale.conf
    echo 'LC_MESSAGES="en_US.UTF-8"' >> /etc/locale.conf
    locale-gen
}

set_keymap() {
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

set_hostname() {
    local hostname="$1"; shift
    echo "$hostname" > /etc/hostname
}

set_sudoers() {
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
}

set_root_password() {
    local password="$1"; shift
    echo -en "$password\n$password" | passwd
}

create_user() {
    local name="$1"; shift
    local password="$1"; shift
    
    useradd -m -G wheel -s /bin/bash "$name"
    echo -en "$password\n$password" | passwd "$name"
}

enable_network() {
    systemctl enable NetworkManager
}

install_grub(){
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg
}

dl_post_reboot_script() {
    local script_path=""/home/$USER_NAME/post.sh""
    local url="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/post_reboot.sh"

    # Ensure directory exists and is writable
    local dir_path="/home/$USER_NAME"
    if [ ! -d "$dir_path" ]; then
        mkdir -p "$dir_path" || { echo "Failed to create $dir_path"; return 1; }
        chmod 755 "$dir_path"
    fi

    # Download script
    if curl -s -o "$script_path" "$url"; then
        echo "Script downloaded to $script_path"
    else
        echo "Error: Failed to download script from $url"
        return 1
    fi

    # Set permissions
    if chown "$USER_NAME:$USER_NAME" "$script_path"; then
        chmod 755 "$script_path"
        echo "Script ready at ~/post.sh for $USER_NAME"
        echo "Run after reboot: bash ~/post.sh"
    else
        echo "Error: Failed to set ownership for $script_path"
        return 1
    fi
    
    sleep 5
}

if [ "$1" == "chroot" ]
then
    configure
else
    setup
fi
