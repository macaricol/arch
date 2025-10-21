#!/bin/bash

# Ensure stdin is bound to the terminal
exec </dev/tty

# Update the system before installing packages
sudo pacman -Syu

clear
echo "####################################################################"
echo "#################### Install minimal essentials ####################"
echo "####################################################################"
echo ""

sudo pacman -S --noconfirm sddm sddm-kcm plasma-desktop bluedevil kscreen konsole kate kwalletmanager dolphin ark kdegraphics-thumbnailers ffmpegthumbs plasma-pa plasma-nm gwenview plasma-systemmonitor pipewire-jack

clear
echo "####################################################################"
echo "################ Enable and start Bluetooth service ################"
echo "####################################################################"
echo ""
 
sudo systemctl start bluetooth.service
sudo systemctl enable bluetooth.service

clear
echo "####################################################################"
echo "##################### Install CPU/GPU packages #####################"
echo "####################################################################"
echo ""

# Detect CPU vendor
cpu_vendor=$(lscpu | grep "Vendor ID" | awk '{print $3}')
case "$cpu_vendor" in
    GenuineIntel)
        echo "Detected Intel CPU. Installing intel-ucode..."
        sudo pacman -S --noconfirm intel-ucode || exit 1
        ;;
    AuthenticAMD)
        echo "Detected AMD CPU. Installing amd-ucode..."
        sudo pacman -S --noconfirm amd-ucode || exit 1
        ;;
    *)
        echo "Error: Unknown CPU vendor: $cpu_vendor. Skipping microcode installation."
        ;;
esac

# Detect GPU vendor
gpu_vendor=$(lspci | grep -E "VGA|3D" | grep -Ei "intel|amd|nvidia" | awk '{print tolower($0)}')
if [[ $gpu_vendor == *intel* ]]; then
    echo "Detected Intel GPU. Installing Intel GPU packages..."
    ##TODO
    #sudo pacman -S --noconfirm mesa libva-intel-driver intel-media-driver || exit 1
elif [[ $gpu_vendor == *amd* ]]; then
    echo "Detected AMD GPU. Installing AMD GPU packages..."
    sudo pacman -S --noconfirm mesa vulkan-radeon libva-mesa-driver mesa-vdpau radeontop || exit 1
elif [[ $gpu_vendor == *nvidia* ]]; then
    echo "Detected NVIDIA GPU. Installing NVIDIA GPU packages..."
    ##TODO
    #sudo pacman -S --noconfirm nvidia nvidia-utils || exit 1
else
    echo "Warning: No supported GPU detected (Intel, AMD, or NVIDIA). Skipping GPU driver installation."
fi

clear
echo "####################################################################"
echo "###################### Install extra packages ######################"
echo "####################################################################"
echo ""

sudo pacman -S fastfetch mpv krdc freerdp ttf-liberation firefox kde-gtk-config kio-admin git vscode pacman-contrib fakeroot

clear
echo "####################################################################"
echo "####################### Setting up Fast Boot #######################"
echo "####################################################################"
echo ""

sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sudo sed -i 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub

# Update grub configuration
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Comment out all lines containing 'echo' in /boot/grub/grub.cfg
sudo sed -i '/echo/s/^/#/' /boot/grub/grub.cfg

clear
echo "####################################################################"
echo "###################### Setting up Login Screen #####################"
echo "####################################################################"
echo ""

sudo git clone -b master --depth 1 https://github.com/macaricol/sddm-astronaut-theme.git /usr/share/sddm/themes/sddm-astronaut-theme
sudo cp -r /usr/share/sddm/themes/sddm-astronaut-theme/Fonts/* /usr/share/fonts/

# Define the directory and file
SDDM_CONFIG_DIR="/etc/sddm.conf.d"
KDE_SETTINGS_FILE="/etc/sddm.conf.d/kde_settings.conf"

[[ -d "$SDDM_CONFIG_DIR" ]] || sudo mkdir -p "$SDDM_CONFIG_DIR"

# Create or overwrite the kde_settings.conf file with the specified content
sudo tee "$KDE_SETTINGS_FILE" > /dev/null << 'EOF'
[Autologin]
Relogin=false
Session=
User=

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=sddm-astronaut-theme

[Users]
MaximumUid=60513
MinimumUid=1000
EOF

echo "Created $KDE_SETTINGS_FILE with the specified content."

# Verify the Current= line in the [Theme] section
if grep -q "^Current=sddm-astronaut-theme" "$KDE_SETTINGS_FILE"; then
    echo "Confirmed: Current=sddm-astronaut-theme is set in $KDE_SETTINGS_FILE"
else
    echo "Error: Failed to set Current=sddm-astronaut-theme in $KDE_SETTINGS_FILE"
fi

clear
echo "####################################################################"
echo "######################## Setting mpv configs #######################"
echo "####################################################################"
echo ""

# Define the directory and file
MPV_DIR="/etc/mpv"
MPV_CONFIG_FILE="/etc/mpv/input.conf"

[[ -d "$MPV_DIR" ]] || sudo mkdir -p "$MPV_DIR"

# Create or overwrite the input.conf file with the specified content
sudo tee "$MPV_CONFIG_FILE" > /dev/null << 'EOF'
WHEEL_UP      seek 10                  # seek 10 seconds forward
WHEEL_DOWN    seek -10                 # seek 10 seconds backward
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF

echo "Created $MPV_CONFIG_FILE with the specified content."

# Verify the file contents
if grep -q "WHEEL_UP.*seek 10" "$MPV_CONFIG_FILE"; then
    echo "Confirmed: input.conf contains the correct settings."
else
    echo "Error: Failed to create $MPV_CONFIG_FILE with the correct content."
fi

clear
echo "####################################################################"
echo "################### Setting Wallpaper / ScreenLock #################"
echo "####################################################################"
echo ""

# Define the wallpaper file path
WALLPAPER_FILE="/usr/share/sddm/themes/sddm-astronaut-theme/Wallpapers/cyberpunk2077.jpg"

# Check if the wallpaper file exists
if [ ! -f "$WALLPAPER_FILE" ]; then
    echo "Error: Wallpaper file $WALLPAPER_FILE does not exist."
    exit 1
fi

# Set lock screen image
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key Image "file://$WALLPAPER_FILE"

XML_FILE="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"

# Ensure wallpaper file is readable
sudo chmod 644 "$WALLPAPER_FILE"

# Update XML file
sudo sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>file://$WALLPAPER_FILE</default>|" "$XML_FILE"

# Verify change
if grep -q "file://$WALLPAPER_FILE" "$XML_FILE"; then
  echo "Wallpaper set to $WALLPAPER_FILE in $XML_FILE"
else
  echo "Error: Failed to update $XML_FILE"
fi

echo "####################################################################"
echo "#################### KDE Plasma configs init ####################"
echo "####################################################################"
echo ""

# Set Portuguese (pt) as the only keyboard layout
kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "pt"
kwriteconfig6 --file kxkbrc --group Layout --key Use "true"

#screen edges functions
kwriteconfig6 --file kwinrc --group Effect-overview --key BorderActivate 9
kwriteconfig6 --file kwinrc --group Effect-windowview --key BorderActivate 7
kwriteconfig6 --file kwinrc --group ElectricBorders --key BottomLeft ShowDesktop
kwriteconfig6 --file kwinrc --group ElectricBorders --key BottomRight ShowDesktop

# ScreenEdges: Keep edge triggers active in fullscreen
kwriteconfig6 --file kwinrc --group ScreenEdges --key RemainActiveOnFullscreen "true"

# File manager thumbnails config
kwriteconfig6 --file dolphinrc --group IconsMode --key PreviewSize 96
kwriteconfig6 --file kdeglobals --group PreviewSettings --key EnableRemoteFolderThumbnail false
kwriteconfig6 --file kdeglobals --group PreviewSettings --key MaximumRemoteSize 10000000000

### Modern Clock
###TODO: move to /home/ishmael/.local/share/plasma/plasmoids/
#git clone https://github.com/prayag2/kde_modernclock && cd kde_modernclock/

#sudo pacman -S plasma-sdk
#kpackagetool6 -i package

#copy plasma session autostartscript
url="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/kde_init.sh"

# Download the script
if ! curl -s -o "$HOME/kde_init.sh" "$url"; then
    echo "Error: Failed to download script"
    exit 1
fi

# Make the script executable
if ! chmod +x "$HOME/kde_init.sh"; then
    echo "Error: Failed to set executable permissions"
    exit 1
fi

echo "####################################################################"
echo "################ Enabling and starting sddm service ################"
echo "####################################################################"
echo ""
# This needs to be run last otherwise it will simply exit running script and present the login GUI

sudo systemctl enable sddm
sudo systemctl start sddm
