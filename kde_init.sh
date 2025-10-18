#!/bin/bash

#requires delay otherwise kde first boot will overwrite what is being applied here
sleep 10

#Apply Dark Theme
plasma-apply-colorscheme BreezeDark
plasma-apply-desktoptheme breeze-dark
plasma-apply-lookandfeel -a org.kde.breezedark.desktop

# [Containments][1]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --key ItemGeometries-1707x960 "Applet-100:896,256,432,160,0;"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --key ItemGeometriesHorizontal "Applet-100:896,256,432,160,0;"

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
