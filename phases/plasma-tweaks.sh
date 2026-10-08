#!/usr/bin/env bash
# Phase 4 — first Plasma session, as the user. Desktop look & layout, then
# self-cleanup. Autostarted by the desktop phase; runs once. The look's tweaks
# only with the ARCHMAN look (phases/look.sh leaves the choice in
# $SETUP_DIR/look; without it, ARCHMAN).

phase_plasma_tweaks() {
  # Cleanup runs even if a tweak fails: better one missed setting (it's in
  # the log) than the autostart entry firing again on every login.
  trap cleanup EXIT
  local look tweak
  look=$(cat "$SETUP_DIR/look" 2>/dev/null) || look=archman
  local -a tweaks=(configure_kwin configure_dolphin)
  [[ $look == archman ]] && tweaks+=(apply_dark_theme set_lock_screen_wallpaper install_plasmoids
                                     configure_desktop_layout install_icon_theme)
  for tweak in "${tweaks[@]}"; do
    tweak "$tweak"
  done
  systemctl --user restart plasma-plasmashell.service
}

# tweak FUNCTION — runs one of the tweaks below; if it fails, the rest still
# run. In a subshell with set -e of its own: inside an `if` or `||`, bash
# ignores set -e, and a failed command would go unnoticed.
tweak() {
  local status
  set +e
  ( set -e; "$1" )
  status=$?
  set -e
  (( status == 0 )) || warn "Skipped $1, it failed (status $status)"
}

# kwriteconfig6 shorthand for the desktop layout file
applets() { kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc "$@"; }

configure_kwin() {
  kwriteconfig6 --file kwinrc --group ElectricBorders --key BottomLeft  ShowDesktop
  kwriteconfig6 --file kwinrc --group ElectricBorders --key BottomRight ShowDesktop
  kwriteconfig6 --file kwinrc --group TabBox --key BorderAlternativeActivate 6
  kwriteconfig6 --file kwinrc --group ScreenEdges --key RemainActiveOnFullscreen true
}

configure_dolphin() {
  kwriteconfig6 --file dolphinrc  --group IconsMode       --key PreviewSize 96
  kwriteconfig6 --file kdeglobals --group PreviewSettings --key EnableRemoteFolderThumbnail false
  kwriteconfig6 --file kdeglobals --group PreviewSettings --key MaximumRemoteSize 10000000000
}

apply_dark_theme() {
  plasma-apply-colorscheme BreezeDark
  plasma-apply-desktoptheme breeze-dark
  plasma-apply-lookandfeel -a org.kde.breezedark.desktop
  kwriteconfig6 --file kdeglobals --group General --key accentColorFromWallpaper true
}

# The desktop's wallpaper comes from the system-wide default (phases/look.sh).
set_lock_screen_wallpaper() {
  kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper \
    --group org.kde.image --group General --key Image "file://$WALLPAPER"
}

# Installs each repo's package/ directory as a Plasma applet (into
# ~/.local/share/plasma/plasmoids); upgrades it if it's already there. The
# copy the USB brought (extras/plasmoids/<repo name>) when there is one, so
# no internet is needed; otherwise downloaded.
install_plasmoids() {
  local repo name tmp package
  for repo in "${PLASMOID_REPOS[@]}"; do
    name=${repo##*/} name=${name%.git}
    tmp=''
    package=$SETUP_DIR/extras/plasmoids/$name/package
    if [[ ! -d $package ]]; then
      tmp=$(mktemp -d)
      git_clone "$repo" "$tmp"
      package=$tmp/package
    fi
    run kpackagetool6 --type Plasma/Applet --install "$package" \
      || run kpackagetool6 --type Plasma/Applet --upgrade "$package"
    [[ -z $tmp ]] || rm -rf "$tmp"
  done
}

# Containment/applet IDs and the geometry key below come from Plasma's
# default first-session layout at 1707x960; they are what the stock layout
# produces, not something this script controls.
configure_desktop_layout() {
  # Modern clock widget on the desktop (containment 1)
  applets --group Containments --group 1 --key ItemGeometries-1707x960  "Applet-100:320,304,400,160,0"
  applets --group Containments --group 1 --key ItemGeometriesHorizontal "Applet-100:320,304,400,160,0"
  local clock=(--group Containments --group 1 --group Applets --group 100)
  applets "${clock[@]}" --key immutability 1
  applets "${clock[@]}" --key plugin com.github.prayag2.modernclock
  local look=("${clock[@]}" --group Configuration --group Appearance)
  applets "${look[@]}" --key date_font_color "205,227,251"
  applets "${look[@]}" --key day_font_color  "242,116,223"
  applets "${look[@]}" --key day_font_size   40
  applets "${look[@]}" --key time_font_color "205,227,251"
  applets "${look[@]}" --key use_24_hour_format true
  applets "${clock[@]}" --group Configuration --group ConfigDialog --key DialogHeight 540
  applets "${clock[@]}" --group Configuration --group ConfigDialog --key DialogWidth  720

  # Panel (containment 2): horizontal, top, right-aligned, floating, auto-hide
  applets --group Containments --group 2 --key formfactor 2
  applets --group Containments --group 2 --key location 3
  local panel=(--file plasmashellrc --group PlasmaViews --group "Panel 2")
  kwriteconfig6 "${panel[@]}" --key alignment 2
  kwriteconfig6 "${panel[@]}" --key floating 1
  kwriteconfig6 "${panel[@]}" --key floatingApplets 0
  kwriteconfig6 "${panel[@]}" --key panelLengthMode 1
  kwriteconfig6 "${panel[@]}" --key panelOpacity 2
  kwriteconfig6 "${panel[@]}" --key panelVisibility 2
  kwriteconfig6 --file plasmashellrc --group PlasmaViews --group "Panel 94" --key panelVisibility 2

  # Pinned apps in the task manager (applet 5)
  applets --group Containments --group 2 --group Applets --group 5 \
    --group Configuration --group General \
    --key launchers "applications:systemsettings.desktop,preferred://filemanager,preferred://browser"

  # Apdatifier (installed by install_plasmoids) in the panel, right after the
  # task manager: updates counted in a badge, the AUR's too, through paru
  # (installed by the desktop phase), upgrades run in Konsole.
  local apdatifier=(--group Containments --group 2 --group Applets --group 101)
  local settings=("${apdatifier[@]}" --group Configuration)
  applets "${apdatifier[@]}" --key immutability 1
  applets "${apdatifier[@]}" --key plugin com.github.exequtic.apdatifier
  applets "${settings[@]}" --key popupWidth 560
  applets "${settings[@]}" --key popupHeight 400
  applets "${settings[@]}" --group General --key aur true
  applets "${settings[@]}" --group Upgrade --key wrapper paru
  applets "${settings[@]}" --group Upgrade --key terminal /usr/bin/konsole
  applets "${settings[@]}" --group Appearance --key counterMode badge
  applets "${settings[@]}" --group Appearance --key counterBadgePosition bottomRight
  applets "${settings[@]}" --group Appearance --key selectedIcon apdatifier-package
  applets "${settings[@]}" --group Appearance --key hideIconPolicy 10
  panel_insert 101 5
}

# panel_insert ID AFTER — puts applet ID in the panel's (containment 2)
# order right after applet AFTER, or last without it. The order is Plasma's
# AppletOrder; when it hasn't written one, the panel's applets by ID, which
# is the order it shows them in then.
panel_insert() {
  local file=$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc order
  order=$(kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
            --group Containments --group 2 --group General --key AppletOrder)
  if [[ -z $order ]]; then
    order=$(sed -nE 's/^\[Containments\]\[2\]\[Applets\]\[([0-9]+)\]$/\1/p' "$file" | sort -nu | paste -sd';')
  fi
  order=";$order;"
  order=${order//;$1;/;}                               # once only, wherever it was
  if [[ $order == *";$2;"* ]]; then order=${order/;$2;/;$2;$1;}; else order+="$1;"; fi
  order=${order#;} order=${order%;}
  applets --group Containments --group 2 --group General --key AppletOrder "$order"
}

# The icon theme: the copy the USB brought (extras/icons) when there is
# one, so no internet is needed; otherwise downloaded.
install_icon_theme() {
  mkdir -p "$HOME/.local/share/icons"
  if [[ -d $SETUP_DIR/extras/icons/$ICON_THEME ]]; then
    cp -r "$SETUP_DIR/extras/icons/$ICON_THEME" "$HOME/.local/share/icons/"
  else
    local tmp; tmp=$(mktemp -d)
    git_clone "$ICON_THEME_REPO" "$tmp"
    cp -r "$tmp/$ICON_THEME" "$HOME/.local/share/icons/"
    rm -rf "$tmp"
  fi
  kwriteconfig6 --file kdeglobals --group Icons --key Theme "$ICON_THEME"
}

# Removes the autostart entry and, when running from the staged copy in the
# user's home, the installer itself — keeping only the log. A manual run from
# a git checkout is left alone.
cleanup() {
  rm -f "$HOME/.config/autostart/arch-plasma-tweaks.desktop"
  if [[ $SETUP_DIR == "$HOME/.arch-setup" ]]; then
    mv -f "$LOG_FILE" "$HOME/arch-setup.log" 2>/dev/null || true
    rm -rf "$SETUP_DIR"
  fi
}
