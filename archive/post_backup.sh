#!/bin/bash

# Ensure stdin is bound to the terminal
exec </dev/tty

#uncomment multilib, required to install steam for example
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

# Sync databases + yes to everything + upgrade all installed packages
sudo pacman -Syu

clear
echo "####################################################################"
echo "########## Install minimal essentials for KDE Plasma GUI ###########"
echo "####################################################################"
echo ""

sudo pacman -S --noconfirm sddm sddm-kcm plasma-desktop bluedevil kdeconnect kdenetwork-filesharing kscreen konsole kate kwalletmanager dolphin ark kdegraphics-thumbnailers ffmpegthumbs plasma-pa plasma-nm gwenview plasma-systemmonitor pipewire-jack

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

# Detect GPU vendor TODO check 32bit support packages
gpu_vendor=$(lspci | grep -E "VGA|3D" | grep -Ei "intel|amd|nvidia" | awk '{print tolower($0)}')
if [[ $gpu_vendor == *intel* ]]; then
    echo "Detected Intel GPU. Installing Intel GPU packages..."
    sudo pacman -S --noconfirm mesa vulkan-intel intel-media-driver || exit 1
elif [[ $gpu_vendor == *amd* ]]; then
    echo "Detected AMD GPU. Installing AMD GPU packages..."
    sudo pacman -S --noconfirm mesa vulkan-radeon libva-mesa-driver mesa-vdpau radeontop || exit 1
elif [[ $gpu_vendor == *nvidia* ]]; then
    echo "Detected NVIDIA GPU. Installing NVIDIA GPU packages..."
    sudo pacman -S --noconfirm nvidia nvidia-utils nvidia-settings opencl-nvidia || exit 1
else
    echo "Warning: No supported GPU detected (Intel, AMD, or NVIDIA). Skipping GPU driver installation."
fi

clear
echo "####################################################################"
echo "#################### Install extra utils packages ##################"
echo "####################################################################"
echo ""

sudo pacman -S fastfetch mpv krdc krdp freerdp firefox kde-gtk-config kio-admin git vscode pacman-contrib fakeroot

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
echo "######################## Setting mpv configs #######################"
echo "####################################################################"
echo ""

MPV_CONF="/etc/mpv/input.conf"

# Create dir + write config in one go
sudo mkdir -p /etc/mpv && sudo tee "$MPV_CONF" > /dev/null << 'EOF'
WHEEL_UP      seek 10
WHEEL_DOWN    seek -10
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF

# Verify in one line
grep -q "WHEEL_UP.*seek 10" "$MPV_CONF" && \
  echo "Success: mpv input.conf configured." || \
  echo "Error: Failed to set mpv config."

clear
echo "####################################################################"
echo "###################### Setting up Login Screen #####################"
echo "####################################################################"
echo ""

# 1. Clone theme
sudo git clone -b master --depth 1 https://github.com/macaricol/sddm-astronaut-theme.git /usr/share/sddm/themes/sddm-astronaut-theme

# 2. Install fonts
sudo cp -r /usr/share/sddm/themes/sddm-astronaut-theme/Fonts/* /usr/share/fonts/
sudo fc-cache -fv  # Refresh font cache

# 3. Ensure config dir
sudo mkdir -p /etc/sddm.conf.d

# 4. Set SDDM theme and settings using kwriteconfig6
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Theme --key Current sddm-astronaut-theme

sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Autologin --key Relogin false
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Autologin --key Session ""
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Autologin --key User ""

sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group General --key HaltCommand "/usr/bin/systemctl poweroff"
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group General --key RebootCommand "/usr/bin/systemctl reboot"

sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Users --key MaximumUid 60513
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Users --key MinimumUid 1000

# Verify the Current= line in the [Theme] section
if grep -q "^Current=sddm-astronaut-theme" "$KDE_SETTINGS_FILE"; then
    echo "Confirmed: Current=sddm-astronaut-theme is set in $KDE_SETTINGS_FILE"
else
    echo "Error: Failed to set Current=sddm-astronaut-theme in $KDE_SETTINGS_FILE"
fi

clear
echo "####################################################################"
echo "################### Setting Wallpaper / ScreenLock #################"
echo "####################################################################"
echo ""

WALLPAPER_FILE="/usr/share/sddm/themes/sddm-astronaut-theme/Wallpapers/cyberpunk2077.jpg"

# 1. Lock screen wallpaper (current user)
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
                --group org.kde.image --group General --key Image "file://$WALLPAPER_FILE"
                

# 2. Desktop wallpaper (current user)
XML_FILE="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"

# Update XML file
sudo sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>file://$WALLPAPER_FILE</default>|" "$XML_FILE"

echo "Wallpaper set for current user (lock screen + desktop)."

# Set Portuguese (pt) as the only keyboard layout
kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "pt"
kwriteconfig6 --file kxkbrc --group Layout --key Use "true"

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
echo "################ TESTING SAMBA CONFIGS ################"
echo "####################################################################"
echo ""

sudo mkdir -p /var/lib/samba/usershares
sudo groupadd -r sambashare
sudo chown root:sambashare /var/lib/samba/usershares
sudo chmod 1770 /var/lib/samba/usershares
sudo gpasswd sambashare -a $USER   # add your user

sudo tee /etc/samba/smb.conf > /dev/null << EOF
[global]
   workgroup = WORKGROUP
   server string = Samba Server %v
   netbios name = $(hostnamectl hostname | tr '[:lower:]' '[:upper:]')
   security = user
   map to guest = Bad User
   dns proxy = no

   # Modern SMB versions (safe and recommended)
   server min protocol = SMB2
   server max protocol = SMB3

   # Browser elections & discovery (helps Windows/macOS see you)
   local master = yes
   preferred master = yes
   os level = 65
   multicast dns register = yes

   # Apple Bonjour / Avahi support (optional but harmless)
   fruit:mdns = yes
   server multi channel support = yes

   # THIS IS THE IMPORTANT PART FOR DOLPHIN ===
   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
   usershare owner only = no
EOF

sudo systemctl enable smb nmb

echo "####################################################################"
echo "################ Enabling and starting sddm service ################"
echo "####################################################################"
echo ""
# This needs to be run last otherwise it will simply exit running script and present the login GUI

sudo systemctl enable sddm
sudo systemctl start sddm
