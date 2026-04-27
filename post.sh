#!/bin/bash

# ── Source utilities ─────────────────────────────────────────────────────
UTILS_URL="https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/utils.sh"
curl -fsSL -O "$UTILS_URL"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh" || { echo "Failed to load utils.sh" >&2; exit 1; }

clear; box "Installing CPU microcode" 70 Ω
cpu_vendor=$(lscpu | grep "Vendor ID" | awk '{print $3}')
case "$cpu_vendor" in
    GenuineIntel) sudo pacman -S --noconfirm intel-ucode ;;
    AuthenticAMD) sudo pacman -S --noconfirm amd-ucode ;;
    *) echo "Unknown CPU vendor: $cpu_vendor. Skipping microcode." ;;
esac

clear; box "Installing GPU drivers" 70 Ω
gpu_vendor=$(lspci | grep -E "VGA|3D" | grep -Ei "intel|amd|nvidia" | awk '{print tolower($0)}')
if [[ $gpu_vendor == *intel* ]]; then
    sudo pacman -S --noconfirm mesa vulkan-intel intel-media-driver
elif [[ $gpu_vendor == *amd* ]]; then
    sudo pacman -S --noconfirm mesa vulkan-radeon libva-mesa-driver mesa-vdpau radeontop
elif [[ $gpu_vendor == *nvidia* ]]; then
    sudo pacman -S --noconfirm nvidia nvidia-utils nvidia-settings opencl-nvidia
else
    echo "No supported GPU detected. Skipping GPU drivers."
fi

clear; box "Enabling Bluetooth" 70 Ω
sudo systemctl enable --now bluetooth.service

clear; box "Adding multilib support and updating system" 70 Ω
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sudo pacman -Syyu --noconfirm

clear; box "Installing KDE Plasma (minimal essentials)" 70 Ω
sudo pacman -S --noconfirm plasma-desktop sddm sddm-kcm \
    bluedevil kdeconnect kdenetwork-filesharing kscreen konsole kate \
    dolphin ark kdegraphics-thumbnailers ffmpegthumbs plasma-pa plasma-nm \
    gwenview plasma-systemmonitor pipewire-jack kwalletmanager




clear; box "Installing extra utilities" 70 Ω
sudo pacman -S --noconfirm fastfetch mpv krdc krdp freerdp firefox kde-gtk-config \
    kio-admin git vscode pacman-contrib fakeroot

clear; box "Setting up fast boot (GRUB)" 70 Ω
sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sudo sed -i 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
# Comment out all lines containing 'echo' in /boot/grub/grub.cfg
sudo sed -i '/echo/s/^/#/' /boot/grub/grub.cfg

clear; box "Setting mpv wheel controls" 70 Ω
sudo mkdir -p /etc/mpv
sudo tee /etc/mpv/input.conf > /dev/null << 'EOF'
WHEEL_UP      seek 10
WHEEL_DOWN    seek -10
WHEEL_LEFT    add volume -2
WHEEL_RIGHT   add volume 2
EOF

clear; box "Installing & configuring SDDM Astronaut theme" 70 Ω
sudo git clone -b master --depth 1 https://github.com/macaricol/sddm-astronaut-theme.git /usr/share/sddm/themes/sddm-astronaut-theme
sudo cp -r /usr/share/sddm/themes/sddm-astronaut-theme/Fonts/* /usr/share/fonts/
sudo fc-cache -fv

sudo mkdir -p /etc/sddm.conf.d
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Theme --key Current sddm-astronaut-theme
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group General --key HaltCommand "/usr/bin/systemctl poweroff"
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group General --key RebootCommand "/usr/bin/systemctl reboot"
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Users --key MinimumUid 1000
sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Users --key MaximumUid 60513

clear; box "Setting wallpaper, lock screen and keyboard layout" 70 Ω
WALLPAPER="file:///usr/share/sddm/themes/sddm-astronaut-theme/Wallpapers/cyberpunk2077.jpg"

# Lock screen
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key Image "$WALLPAPER"

# Desktop wallpaper (system default)
XML="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"
sudo sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>$WALLPAPER</default>|" "$XML"

# Keyboard (Portuguese)
kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "pt"
kwriteconfig6 --file kxkbrc --group Layout --key Use "true"

clear; box "Downloading KDE autostart script" 70 Ω
curl -s -o "$HOME/kde_init.sh" "https://raw.githubusercontent.com/macaricol/arch/refs/heads/main/kde_init.sh"
chmod +x "$HOME/kde_init.sh"

#clear; box "Setting up Samba file sharing" 70 Ω

#sudo mkdir -p /var/lib/samba/usershares
#sudo groupadd -r sambashare 2>/dev/null || true
#sudo chown root:sambashare /var/lib/samba/usershares
#sudo chmod 1770 /var/lib/samba/usershares
#sudo gpasswd sambashare -a "$USER"

#sudo sed -i '/^\[global\]/a\
#   usershare path = /var/lib/samba/usershares\
#   usershare max shares = 100\
#   usershare allow guests = yes\
#   usershare owner only = yes' /etc/samba/smb.conf

#sudo systemctl enable --now smb nmb

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

   # THIS IS THE IMPORTANT PART FOR DOLPHIN ===
   usershare path = /var/lib/samba/usershares
   usershare max shares = 100
   usershare allow guests = yes
   usershare owner only = no
EOF

sudo systemctl enable --now smb nmb


# This needs to be run last otherwise it will simply exit running script and present the login GUI
clear; box "Enabling SDDM (last step)" 70 Ω
sudo systemctl enable --now sddm
