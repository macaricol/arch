# Set Portuguese (pt) as the only keyboard layout
kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "pt"
kwriteconfig6 --file kxkbrc --group Layout --key Use "true"

### Modern Clock
git clone https://github.com/prayag2/kde_modernclock && cd kde_modernclock/

kpackagetool6 -i package

kpackagetool6 --type Plasma/Applet -i

kpackagetool6 --type Plasma/Applet -l | grep modernclock

# [Containments][1]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --key ItemGeometries-1707x960 "Applet-25:896,256,432,160,0;"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --key ItemGeometriesHorizontal "Applet-25:896,256,432,160,0;"

# [Containments][1][Applets][25]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --key immutability "1"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --key plugin "com.github.prayag2.modernclock"

# [Containments][1][Applets][25][Configuration][Appearance]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --group Configuration --group Appearance --key date_font_color "205,227,251"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --group Configuration --group Appearance --key day_font_color "242,116,223"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --group Configuration --group Appearance --key day_font_size "40"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --group Configuration --group Appearance --key time_font_color "205,227,251"

# [Containments][1][Applets][25][Configuration][ConfigDialog]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --group Configuration --group ConfigDialog --key DialogHeight "540"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 1 --group Applets --group 25 --group Configuration --group ConfigDialog --key DialogWidth "720"

kquitapp6 plasmashell && kstart6 plasmashell
