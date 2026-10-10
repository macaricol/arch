#!/usr/bin/env bash
# Phase 4 — first Plasma session, as the user. Desktop look & layout, then
# self-cleanup. Autostarted by the desktop phase; runs once. The look's tweaks
# only with the ARCHMAN look (phases/look.sh leaves the choice in
# $SETUP_DIR/look; without it, ARCHMAN).

phase_plasma_tweaks() {
  # Cleanup runs even if a tweak fails: better one missed setting (it's in
  # the log) than the autostart entry firing again on every login.
  trap cleanup EXIT
  wait_for_plasma
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

# wait_for_plasma — until Plasma is ready for its files to be changed: its
# shell on the session bus (org.kde.plasmashell), and the desktop layout it
# writes on a first start (the appletsrc file the tweaks edit) there and
# left alone for 3 s. Plasma saves its settings a moment after changing
# them, and a tweak made before that would be written over. Up to a minute;
# then on anyway.
wait_for_plasma() {
  local file=$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc until=$(( SECONDS + 60 )) mtime last='' still=0
  while (( SECONDS < until )); do
    if busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
         NameHasOwner s org.kde.plasmashell 2>/dev/null | grep -q true && [[ -f $file ]]; then
      mtime=$(stat -c %Y "$file")
      if [[ $mtime == "$last" ]]; then
        (( ++still < 3 )) || { note "Plasma ready after $(( 60 - until + SECONDS )) s"; return 0; }
      else
        last=$mtime still=0
      fi
    fi
    sleep 1
  done
  note "Plasma not settled after a minute, tweaking anyway"
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

# Installs each repo's widget as a Plasma applet (into
# ~/.local/share/plasma/plasmoids); upgrades it if it's already there. The
# copy the USB brought (extras/plasmoids/<repo name>/package) when there is
# one, so no internet is needed; otherwise downloaded: the repo's package/
# directory, or the repo itself when its metadata.json is at the top.
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
      [[ -d $package ]] || package=$tmp
    fi
    run kpackagetool6 --type Plasma/Applet --install "$package" \
      || run kpackagetool6 --type Plasma/Applet --upgrade "$package"
    [[ -z $tmp ]] || rm -rf "$tmp"
  done
}

# plasma_script JAVASCRIPT — runs it in the Plasma session's shell, through
# its scripting interface (org.kde.PlasmaShell.evaluateScript, KDE's way to
# script desktop layouts): it finds the panels and widgets itself, changes
# them as they're shown, and saves them as its own. Prints what the script
# print()s; fails if the script throws.
plasma_script() {
  local reply
  reply=$(busctl --user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s "$1") || return 1
  reply=${reply#s \"} reply=${reply%\"}
  printf '%b' "$reply"
}

# The desktop's layout: the clock on the desktop; at the top, the main
# panel on the right with the pinned apps and Apdatifier, and a second one
# on the left with KVitals; each with a Panel Colorizer preset, Fake
# Floating and Translucent. Through Plasma's scripting interface, not
# its layout file's numbers (which containment is the panel, which applet
# the task manager): those are Plasma's to choose. The panel's own settings
# too, by the interface's documented properties; and, in case a Plasma
# lacks or renames one, written into plasmashellrc as well, its internal
# keys under the panel's number (which the script reports), read when
# plasmashell restarts at the end of this phase.
configure_desktop_layout() {
  # For the script below ("null" when missing): two of Panel Colorizer's
  # presets, as the installed widget ships them, and KVitals' profile
  # (which readings it shows: assets/plasma/kvitals.json).
  local presets=$HOME/.local/share/plasma/plasmoids/luisbocanegra.panel.colorizer/contents/ui/presets
  local fake_floating=null translucent=null vitals=null out
  [[ -f "$presets/Fake Floating/settings.json" ]] && fake_floating=$(< "$presets/Fake Floating/settings.json")
  [[ -f $presets/Translucent/settings.json ]] && translucent=$(< "$presets/Translucent/settings.json")
  [[ -f $SETUP_DIR/assets/plasma/kvitals.json ]] && vitals=$(< "$SETUP_DIR/assets/plasma/kvitals.json")
  out=$(plasma_script '
    var fakeFloating = '"$fake_floating"';
    var translucent = '"$translucent"';
    var vitals = '"$vitals"';

    // A panel'"'"'s settings, as Panel Settings shows them, each on its own,
    // so one this Plasma doesn'"'"'t have can'"'"'t stop the rest; and what
    // the panel then says of each, for the log.
    function configure(panel, settings) {
      Object.keys(settings).forEach(function (name) {
        try { panel[name] = settings[name]; } catch (e) {}
      });
      return Object.keys(settings).map(function (name) { return name + "=" + panel[name]; }).join(" ");
    }

    // Panel Colorizer (installed by install_plasmoids) in a panel, with the
    // look of one of the presets it ships with, its own icon hidden: all
    // its settings are one, globalSettings, the preset'"'"'s as they are.
    // (A widget that isn'"'"'t there, its download failed, is left out, not
    // the rest of the layout with it; so are the others below.)
    function colorize(panel, preset) {
      if (!preset) return;
      var colorizer = panel.addWidget("luisbocanegra.panel.colorizer");
      if (!colorizer) return;
      colorizer.currentConfigGroup = ["General"];
      colorizer.writeConfig("globalSettings", JSON.stringify(preset.globalSettings));
      colorizer.writeConfig("hideWidget", true);
    }

    // The main panel: Plasma'"'"'s first, at the top, on the right: width
    // fit content, visibility dodge windows, opacity translucent, floating
    // disabled, height 42.
    var panel = panels()[0];
    var said = configure(panel, { location: "top", alignment: "right", lengthMode: "fit", hiding: "dodgewindows",
                                  opacity: "translucent", floating: false, height: 42 });

    // Pinned apps in the task manager (icontasks, or the classic one).
    var tasks = panel.widgets("org.kde.plasma.icontasks").concat(panel.widgets("org.kde.plasma.taskmanager"));
    tasks.forEach(function (w) {
      w.currentConfigGroup = ["General"];
      w.writeConfig("launchers", ["applications:systemsettings.desktop", "preferred://filemanager", "preferred://browser"]);
    });

    colorize(panel, fakeFloating);

    // No Peek at Desktop (the default panel ends with one).
    panel.widgets("org.kde.plasma.showdesktop").forEach(function (w) { w.remove(); });

    // Apdatifier (installed by install_plasmoids), right after the task
    // manager: updates counted in a badge, the AUR'"'"'s too, through paru
    // (installed by the desktop phase), upgrades run in Konsole.
    var apd = panel.addWidget("com.github.exequtic.apdatifier");
    if (apd) {
    apd.currentConfigGroup = [];
    apd.writeConfig("popupWidth", 560);
    apd.writeConfig("popupHeight", 400);
    apd.currentConfigGroup = ["General"];
    apd.writeConfig("aur", true);
    apd.currentConfigGroup = ["Upgrade"];
    apd.writeConfig("wrapper", "paru");
    apd.writeConfig("terminal", "/usr/bin/konsole");
    apd.currentConfigGroup = ["Appearance"];
    apd.writeConfig("counterMode", "badge");
    apd.writeConfig("counterBadgePosition", "bottomRight");
    apd.writeConfig("selectedIcon", "apdatifier-package");
    apd.writeConfig("hideIconPolicy", 10);
    var order = panel.widgets().map(function (w) { return w.id; }).filter(function (id) { return id != apd.id; });
    var after = tasks.length ? order.indexOf(tasks[0].id) : -1;
    order.splice(after >= 0 ? after + 1 : order.length, 0, apd.id);
    panel.currentConfigGroup = ["General"];
    panel.writeConfig("AppletOrder", order.join(";"));
    }

    // The Modern Clock on the desktop, left of centre, a third of the way
    // down, whatever the screen size.
    var desk = desktops()[0];
    var screen = screenGeometry(desk.screen);
    var clock = desk.addWidget("com.github.prayag2.modernclock",
                               Math.round(screen.width * 0.19), Math.round(screen.height * 0.32), 400, 160);
    if (clock) {
    clock.currentConfigGroup = ["Appearance"];
    clock.writeConfig("date_font_color", "205,227,251");
    clock.writeConfig("day_font_color", "242,116,223");
    clock.writeConfig("day_font_size", 40);
    clock.writeConfig("time_font_color", "205,227,251");
    clock.writeConfig("use_24_hour_format", true);
    }

    // The second panel: new, at the top, on the left: width fit content,
    // visibility dodge windows, opacity Plasma'"'"'s own (adaptive),
    // floating disabled, height 36. KVitals in it, with its profile
    // (vitals): it only keeps one it'"'"'s told is set up (migrationDone),
    // else it makes its own; its shortcut, Meta+Shift+V, it sets itself.
    var second = new Panel;
    var saidSecond = configure(second, { location: "top", alignment: "left", lengthMode: "fit",
                                         hiding: "dodgewindows", floating: false, height: 36 });
    var kvitals = second.addWidget("org.kde.plasma.kvitals");
    if (kvitals && vitals) {
      kvitals.currentConfigGroup = ["General"];
      kvitals.writeConfig("profileList", JSON.stringify(vitals.profileList));
      kvitals.writeConfig("activeProfileId", vitals.activeProfileId);
      kvitals.writeConfig("profileListVersion", 1);
      kvitals.writeConfig("migrationDone", true);
    }
    colorize(second, translucent);

    // For the log and plasmashellrc: each panel'"'"'s number, then what it
    // now says of its settings, a line each.
    print(panel.id + " " + said + "\n" + second.id + " " + saidSecond);
  ') || return 1
  local main=${out%%$'\n'*} second=${out#*$'\n'}
  [[ ${main%% *} =~ ^[0-9]+$ && ${second%% *} =~ ^[0-9]+$ ]] || { note "Plasma's script gave no panels: $out"; return 1; }
  note "Main panel: containment $main"
  note "Second panel: containment $second"

  # The same settings by plasmashellrc's keys, for a Plasma whose script
  # interface lacks one: under each panel's number, alignment (2 right,
  # 1 left), width fit content, visibility dodge windows, opacity
  # translucent (the main one's), floating disabled, height.
  panel_view "${main%% *}" alignment 2 panelOpacity 2 thickness 42
  panel_view "${second%% *}" alignment 1 thickness 36
}

# panel_view PANEL KEY VALUE... — plasmashellrc's view settings for panel
# number PANEL: fit content, dodge windows, not floating, and KEY=VALUE for
# each pair given (thickness goes under Defaults, where Plasma keeps it).
panel_view() {
  local view=(--file plasmashellrc --group PlasmaViews --group "Panel $1"); shift
  kwriteconfig6 "${view[@]}" --key panelLengthMode 1
  kwriteconfig6 "${view[@]}" --key panelVisibility 2
  kwriteconfig6 "${view[@]}" --key floating 0
  kwriteconfig6 "${view[@]}" --key floatingApplets 0
  while (( $# >= 2 )); do
    if [[ $1 == thickness ]]; then
      kwriteconfig6 "${view[@]}" --group Defaults --key thickness "$2"
    else
      kwriteconfig6 "${view[@]}" --key "$1" "$2"
    fi
    shift 2
  done
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

# Removes the autostart entry and the installer itself, keeping only the
# log. Only ever the copy the install left in the user's home: the check is
# a safety net, so this can never delete anything else.
cleanup() {
  rm -f "$HOME/.config/autostart/arch-plasma-tweaks.desktop"
  if [[ $SETUP_DIR == "$HOME/.arch-setup" ]]; then
    mv -f "$LOG_FILE" "$HOME/arch-setup.log" 2>/dev/null || true
    rm -rf "$SETUP_DIR"
  fi
}
