#!/usr/bin/env bash
# Phase 4 — first Plasma session, as the user. Desktop look & layout, then
# self-cleanup. Autostarted by the post phase; runs once.

phase_kde_init() {
  require_user
  # Cleanup runs even if a tweak fails: better one missed setting (it's in
  # the log) than the autostart entry firing again on every login.
  trap cleanup EXIT
  configure_kwin
  configure_dolphin
  apply_dark_theme
  install_plasmoids
  configure_desktop_layout
  install_icon_theme
  systemctl --user restart plasma-plasmashell.service
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

# Installs each repo's package/ directory as a Plasma applet (into
# ~/.local/share/plasma/plasmoids); upgrades it if it's already there.
install_plasmoids() {
  local repo tmp
  for repo in "${PLASMOID_REPOS[@]}"; do
    tmp=$(mktemp -d)
    git_clone "$repo" "$tmp"
    run kpackagetool6 --type Plasma/Applet --install "$tmp/package" \
      || run kpackagetool6 --type Plasma/Applet --upgrade "$tmp/package"
    rm -rf "$tmp"
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
}

install_icon_theme() {
  local tmp; tmp=$(mktemp -d)
  git_clone "$ICON_THEME_REPO" "$tmp"
  mkdir -p "$HOME/.local/share/icons"
  cp -r "$tmp/$ICON_THEME" "$HOME/.local/share/icons/"
  rm -rf "$tmp"
  kwriteconfig6 --file kdeglobals --group Icons --key Theme "$ICON_THEME"
}

# Removes the autostart entry and, when running from the staged copy in the
# user's home, the installer itself — keeping only the log. A manual run from
# a git checkout is left alone.
cleanup() {
  rm -f "$HOME/.config/autostart/arch-kde-init.desktop"
  if [[ $SETUP_DIR == "$HOME/.arch-setup" ]]; then
    mv -f "$LOG_FILE" "$HOME/arch-setup.log" 2>/dev/null || true
    rm -rf "$SETUP_DIR"
  fi
}
