git clone https://github.com/prayag2/kde_modernclock && cd kde_modernclock/

kpackagetool6 -i package

# [Containments][44]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key ItemGeometries-1707x960 "Applet-75:896,256,432,160,0;"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key ItemGeometriesHorizontal "Applet-75:896,256,432,160,0;"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key activityId "958bf108-304e-45db-89e1-2510541bdd4c"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key formfactor "0"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key immutability "1"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key lastScreen "0"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key location "0"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key plugin "org.kde.plasma.folder"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --key wallpaperplugin "org.kde.image"

# [Containments][44][Applets][75]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --key immutability "1"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --key plugin "com.github.prayag2.modernclock"

# [Containments][44][Applets][75][Configuration]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --key UserBackgroundHints ""

# [Containments][44][Applets][75][Configuration][Appearance]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --group Appearance --key date_font_color "205,227,251"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --group Appearance --key day_font_color "242,116,223"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --group Appearance --key day_font_size "40"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --group Appearance --key time_font_color "205,227,251"

# [Containments][44][Applets][75][Configuration][ConfigDialog]
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --group ConfigDialog --key DialogHeight "540"
kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group Containments --group 44 --group Applets --group 75 --group Configuration --group ConfigDialog --key DialogWidth "720"

kquitapp6 plasmashell && kstart6 plasmashell


 
-[Containments][2][Applets][24]
-immutability=1
-plugin=com.github.prayag2.modernclock
-
 [Containments][2][General]
-AppletOrder=3;4;5;6;7;16;17;24
+AppletOrder=3;4;5;6;7;16;17
