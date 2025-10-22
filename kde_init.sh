#!/bin/bash

### plasma autostart script runs before plasma initializes certain config files so its not appropriate here...

### Run manually after KDE first GUI session starts, until I find a way to execute it post session start
### Reboot system or restart plasma to properly apply the widgets

#############################
####### Apply Dark Theme ########
#############################
plasma-apply-colorscheme BreezeDark
plasma-apply-desktoptheme breeze-dark
plasma-apply-lookandfeel -a org.kde.breezedark.desktop

kwriteconfig6 --file kdeglobals --group General --key accentColorFromWallpaper true

#############################
#### Add modern clock widget #####
#############################
WIDGET_DIR="$HOME/.local/share/plasma/plasmoids/modernclock2"
INSTALL_DIR="/home/ishmael/.local/share/kpackage/generic/com.github.prayag2.modernclock"
PLASMOIDS_DIR="$HOME/.local/share/plasma/plasmoids/"

# Clone the repository
git clone https://github.com/macaricol/kde_modernclock.git "$WIDGET_DIR"
cd "$WIDGET_DIR"

kpackagetool6 -i package

# Copy the installed directory to the plasmoids folder
cp -r "$INSTALL_DIR" "$PLASMOIDS_DIR"

# Remove the original WIDGET_DIR
rm -rf "$WIDGET_DIR"
rm -rf "$INSTALL_DIR"

# [Containments][1]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --key ItemGeometries-1707x960 "Applet-100:320,304,400,160,0"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --key ItemGeometriesHorizontal "Applet-100:320,304,400,160,0"

# [Containments][1][Applets][100]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --key immutability "1"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --key plugin "com.github.prayag2.modernclock"

# [Containments][1][Applets][100][Configuration][Appearance]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group Appearance --key date_font_color "205,227,251"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group Appearance --key day_font_color "242,116,223"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group Appearance --key day_font_size "40"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group Appearance --key time_font_color "205,227,251"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group Appearance --key use_24_hour_format "true"

# [Containments][1][Applets][100][Configuration][ConfigDialog]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group ConfigDialog --key DialogHeight "540"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 100 --group Configuration --group ConfigDialog --key DialogWidth "720"

#############################
#### taskbar vertical on the left #####
#############################
# [Containments][2]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 2 --key formfactor 2
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 2 --key location 3

# Set panel alignment (2 = right)
kwriteconfig6 --file plasmashellrc --group PlasmaViews --group "Panel 2" --key alignment 2
# Set floating panel (1 = enabled)
kwriteconfig6 --file plasmashellrc --group PlasmaViews --group "Panel 2" --key floating 1
# Set floating applets (0 = disabled)
kwriteconfig6 --file plasmashellrc --group PlasmaViews --group "Panel 2" --key floatingApplets 0
# Set panel length mode (1 = auto)
kwriteconfig6 --file plasmashellrc --group PlasmaViews --group "Panel 2" --key panelLengthMode 1
# Set panel opacity (2 = adaptive)
kwriteconfig6 --file plasmashellrc --group PlasmaViews --group "Panel 2" --key panelOpacity 2

# Set panel visibility (2 = auto-hide)
kwriteconfig6 --file ~/.config/plasmashellrc --group PlasmaViews --group "Panel 94" --key panelVisibility 2


systemctl --user restart plasma-plasmashell.service
