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
  local -a tweaks=(configure_kwin configure_dolphin set_brightness)
  [[ $look == archman ]] && tweaks+=(apply_dark_theme set_lock_screen_wallpaper install_plasmoids
                                     configure_desktop_layout set_up_wallpaper_picker install_icon_theme)
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

# set_brightness — every screen Plasma can dim to BRIGHTNESS percent: its
# power management's displays (org.kde.ScreenBrightness), a laptop's panel
# or a monitor through DDC/CI, which it finds a few seconds into the
# session; up to 15 s for them (a VM has none). Without the brightness
# popup (flag 1).
set_brightness() {
  local service=org.kde.ScreenBrightness iface=org.kde.ScreenBrightness.Display display max
  local -a displays=()
  for _ in {1..15}; do
    mapfile -t displays < <(busctl --user tree --list "$service" 2>/dev/null | grep '/display[0-9]*$')
    (( ${#displays[@]} )) && break
    sleep 1
  done
  (( ${#displays[@]} )) || { note "No screen whose brightness can be set"; return 0; }
  for display in "${displays[@]}"; do
    max=$(busctl --user get-property "$service" "$display" "$iface" MaxBrightness | awk '{ print $2 }')
    busctl --user call "$service" "$display" "$iface" SetBrightness iu $(( max * BRIGHTNESS / 100 )) 1
    note "Brightness of $display: $BRIGHTNESS%"
  done
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

# The desktop's layout: the clock on the desktop; at the top, three
# panels: the main one on the right (the app menu, Apdatifier, the tray,
# the clock), the pinned apps in the centre, and KVitals on the left; each
# with Panel Colorizer's Translucent preset. Through Plasma's scripting interface, not
# its layout file's numbers (which containment is the panel, which applet
# the task manager): those are Plasma's to choose. The panel's own settings
# too, by the interface's documented properties; and, in case a Plasma
# lacks or renames one, written into plasmashellrc as well, its internal
# keys under the panel's number (which the script reports), read when
# plasmashell restarts at the end of this phase.
configure_desktop_layout() {
  # For the script below ("null" when missing): Panel Colorizer's
  # Translucent preset, as the installed widget ships it, and KVitals'
  # profile (which readings it shows: assets/plasma/kvitals.json). And the
  # pinned apps, in order: the browser, the file manager, VS Code, Steam
  # (installed only with a gaming graphics card) and System Settings, the
  # installed ones.
  local presets=$HOME/.local/share/plasma/plasmoids/luisbocanegra.panel.colorizer/contents/ui/presets
  local translucent=null vitals=null out app launchers='"preferred://browser", "preferred://filemanager"'
  [[ -f $presets/Translucent/settings.json ]] && translucent=$(< "$presets/Translucent/settings.json")
  for app in code-oss steam systemsettings; do
    [[ -f /usr/share/applications/$app.desktop ]] && launchers+=", \"applications:$app.desktop\""
  done
  [[ -f $SETUP_DIR/assets/plasma/kvitals.json ]] && vitals=$(< "$SETUP_DIR/assets/plasma/kvitals.json")
  # The app menu button's icon: the Arch logo (the filesystem package's, in
  # Arch blue) in white, not the icon theme's take on it (Breeze Chameleon's
  # is a round badge); with a small margin (it fills its
  # 256 square edge to edge): drawn at 96% of the canvas. In
  # the user's hicolor, which every icon theme falls back to.
  local logo=$HOME/.local/share/icons/hicolor/scalable/apps/archlinux-logo-white.svg
  mkdir -p "${logo%/*}"
  sed 's|fill="#1793d1"|fill="#ffffff"|; s|viewBox="0 0 256 256"|viewBox="-5.33 -5.33 266.67 266.67"|' \
    /usr/share/pixmaps/archlinux-logo.svg > "$logo"
  out=$(plasma_script '
    var translucent = '"$translucent"';
    var launchers = ['"$launchers"'];
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

    // Each panel: at the top, width fit content, visibility dodge windows,
    // opacity translucent, floating, height 28; where along the top, its own.
    function top(alignment) {
      return { location: "top", alignment: alignment, lengthMode: "fit", hiding: "dodgewindows",
               opacity: "translucent", floating: true, height: 28 };
    }

    // The main panel: Plasma'"'"'s first, on the right. Its task manager
    // (icontasks, or the classic one) moves to a panel of its own, below;
    // where it was, Apdatifier goes.
    var panel = panels()[0];
    var said = configure(panel, top("right"));
    var tasks = panel.widgets("org.kde.plasma.icontasks").concat(panel.widgets("org.kde.plasma.taskmanager"));
    var order = panel.widgets().map(function (w) { return w.id; });
    var tasksAt = tasks.length ? order.indexOf(tasks[0].id) : -1;
    tasks.forEach(function (w) { w.remove(); });

    // Its clock, in Noto Sans at 28 points, not sized to the panel.
    panel.widgets("org.kde.plasma.digitalclock").forEach(function (w) {
      w.currentConfigGroup = ["Appearance"];
      w.writeConfig("autoFontAndSize", false);
      w.writeConfig("fontFamily", "Noto Sans");
      w.writeConfig("fontStyleName", "Regular");
      w.writeConfig("fontWeight", 400);
      w.writeConfig("fontSize", 28);
    });

    // The app menu'"'"'s button: the Arch logo, white like the tray'"'"'s icons
    // (written below this script, as archlinux-logo-white).
    panel.widgets("org.kde.plasma.kickoff").forEach(function (w) {
      w.currentConfigGroup = ["General"];
      w.writeConfig("icon", "archlinux-logo-white");
    });

    colorize(panel, translucent);

    // No Peek at Desktop (the default panel ends with one).
    panel.widgets("org.kde.plasma.showdesktop").forEach(function (w) { w.remove(); });

    // Apdatifier (installed by install_plasmoids), where the task manager
    // was: updates counted in a badge, the AUR'"'"'s too, through paru
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
    order = panel.widgets().map(function (w) { return w.id; }).filter(function (id) { return id != apd.id; });
    order.splice(tasksAt >= 0 ? Math.min(tasksAt, order.length) : order.length, 0, apd.id);
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

    // The second panel: new, on the left. KVitals in it, with its profile
    // (vitals): it only keeps one it'"'"'s told is set up (migrationDone),
    // else it makes its own; its shortcut, Meta+Shift+V, it sets itself.
    var second = new Panel;
    var saidSecond = configure(second, top("left"));
    var kvitals = second.addWidget("org.kde.plasma.kvitals");
    if (kvitals && vitals) {
      kvitals.currentConfigGroup = ["General"];
      kvitals.writeConfig("profileList", JSON.stringify(vitals.profileList));
      kvitals.writeConfig("activeProfileId", vitals.activeProfileId);
      kvitals.writeConfig("profileListVersion", 1);
      kvitals.writeConfig("migrationDone", true);
    }
    colorize(second, translucent);

    // The third panel: new, in the centre: the task manager, with the
    // pinned apps (launchers), and a margins separator after it.
    var centre = new Panel;
    var saidCentre = configure(centre, top("center"));
    var pinned = centre.addWidget("org.kde.plasma.icontasks");
    if (pinned) {
      pinned.currentConfigGroup = ["General"];
      pinned.writeConfig("launchers", launchers);
    }
    centre.addWidget("org.kde.plasma.marginsseparator");
    colorize(centre, translucent);

    // For the log and plasmashellrc: each panel'"'"'s number, then what it
    // now says of its settings, a line each.
    print(panel.id + " " + said + "\n" + second.id + " " + saidSecond + "\n" + centre.id + " " + saidCentre);
  ') || return 1
  local main second centre
  { read -r main; read -r second; read -r centre; } <<< "$out"
  [[ ${main%% *} =~ ^[0-9]+$ && ${second%% *} =~ ^[0-9]+$ && ${centre%% *} =~ ^[0-9]+$ ]] \
    || { note "Plasma's script gave no panels: $out"; return 1; }
  note "Main panel: containment $main"
  note "Second panel: containment $second"
  note "Centre panel: containment $centre"

  # The same settings by plasmashellrc's keys, for a Plasma whose script
  # interface lacks one: under each panel's number, alignment (2 right,
  # 1 left, 132 centre), and the rest panel_view's.
  panel_view "${main%% *}" alignment 2
  panel_view "${second%% *}" alignment 1
  panel_view "${centre%% *}" alignment 132
}

# panel_view PANEL KEY VALUE... — plasmashellrc's view settings for panel
# number PANEL: fit content, dodge windows, opacity translucent, floating,
# height 28, and KEY=VALUE for each pair given (thickness goes under
# Defaults, where Plasma keeps it).
panel_view() {
  local view=(--file plasmashellrc --group PlasmaViews --group "Panel $1"); shift
  kwriteconfig6 "${view[@]}" --key panelLengthMode 1
  kwriteconfig6 "${view[@]}" --key panelVisibility 2
  kwriteconfig6 "${view[@]}" --key panelOpacity 2
  kwriteconfig6 "${view[@]}" --key floating 1
  kwriteconfig6 "${view[@]}" --key floatingApplets 0
  kwriteconfig6 "${view[@]}" --group Defaults --key thickness 28
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
# skwd-wall, the wallpaper picker (installed by the desktop phase), set up
# as on the machine ARCHMAN is made on: its settings (assets/skwd-wall/
# config.json: the ARCHMAN preset of its "slices" picker, matugen for its
# colours, and the rest), its
# service, the desktop's wallpaper drawn by its Plasma plugin, and the
# default wallpaper (WALLPAPER; in its folder, ~/Pictures/Wallpapers, with
# the others, since the desktop phase) applied through it: the plugin keeps a wallpaper per screen, by a name
# not known before now, which skwd-helm works out. Without skwd-wall (a
# build failed), nothing: the desktop keeps Plasma's own wallpaper.
set_up_wallpaper_picker() {
  command -v skwd-helm &>/dev/null && [[ -d /usr/share/plasma/wallpapers/org.skwd.wall.plasma ]] \
    || { note "No skwd-wall, the desktop keeps Plasma's wallpaper"; return 0; }
  local config=$HOME/.config/skwd-wall-v2/config.json wallpapers=$HOME/Pictures/Wallpapers
  if [[ ! -f $config ]]; then
    mkdir -p "${config%/*}"
    cp "$SETUP_DIR/assets/skwd-wall/config.json" "$config"
  fi
  mkdir -p "$wallpapers"
  [[ -f $wallpapers/${WALLPAPER##*/} ]] || cp "$WALLPAPER" "$wallpapers/"
  systemctl --user enable --now skwd-walld.service
  plasma_script 'desktops().forEach(function (d) { d.wallpaperPlugin = "org.skwd.wall.plasma"; });' > /dev/null
  # The service takes a moment to answer: a few tries.
  local try applied=0
  for try in {1..10}; do
    skwd-helm apply "$wallpapers/${WALLPAPER##*/}" &>/dev/null && { applied=1; break; }
    sleep 1
  done
  (( applied )) || { note "skwd-wall didn't take the default wallpaper"; return 0; }
  connect_skwd_colours
}

# Plasma's colours from the wallpaper, by skwd-wall: with the wallpaper its
# Plasma plugin draws, Plasma's own accent-from-wallpaper has no picture to
# take a colour from, so skwd-wall works the colours out (matugen) and
# makes them Plasma's colour scheme, SkwdManaged, accent and all (the icon
# theme follows the accent). It's connected to Plasma once, by its picker
# (Settings, App themes, KDE Plasma: On), which there's no command for; and
# not by writing the state that leaves (~/.local/state/skwd-wall-v2/
# app-themes/kde.json): one skwd-wall didn't make itself, it won't take
# ("An existing Skwd setup needs review"), nor turn on. So the colours are
# only regenerated (skwd-helm retheme), in case it connects by itself; the
# log says whether it did.
connect_skwd_colours() {
  command -v matugen &>/dev/null || { note "No matugen, Plasma keeps its own colours"; return 0; }
  skwd-helm retheme &>/dev/null || true
  sleep 2
  if [[ $(kreadconfig6 --file kdeglobals --group General --key ColorScheme) == SkwdManaged* ]]; then
    note "skwd-wall's colours: connected by itself"
  else
    note "skwd-wall's colours: not connected; turn them on in its settings (App themes, KDE Plasma)"
  fi
}

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
