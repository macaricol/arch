// The first login's desktop layout (phases/plasma-tweaks.sh's
// configure_desktop_layout), run by Plasma's scripting interface
// (org.kde.PlasmaShell.evaluateScript; KDE's "desktop scripting" API).
// The shell script puts three values in front of it:
//   translucent  Panel Colorizer's Translucent preset (its settings.json), or null
//   launchers    the pinned apps, as the task manager's launcher URLs
//   vitals       KVitals' profile (assets/plasma/kvitals.json), or null
// It prints each panel's number and settings, a line each, for the log and
// plasmashellrc. Dry run: test/test-plasma-layout.sh.

// A panel's settings, as Panel Settings shows them, each on its own,
// so one this Plasma doesn't have can't stop the rest; and what
// the panel then says of each, for the log.
function configure(panel, settings) {
  Object.keys(settings).forEach(function (name) {
    try { panel[name] = settings[name]; } catch (e) {}
  });
  return Object.keys(settings).map(function (name) { return name + "=" + panel[name]; }).join(" ");
}

// Panel Colorizer (installed by install_plasmoids) in a panel, with the
// look of one of the presets it ships with, its own icon hidden: all
// its settings are one, globalSettings, the preset's as they are.
// (A widget that isn't there, its download failed, is left out, not
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
// opacity translucent, floating, height 30; where along the top, its own.
function top(alignment) {
  return { location: "top", alignment: alignment, lengthMode: "fit", hiding: "dodgewindows",
           opacity: "translucent", floating: true, height: 30 };
}

// The main panel: Plasma's first, on the right. Its task manager
// (icontasks, or the classic one) moves to a panel of its own, below.
var panel = panels()[0];
var said = configure(panel, top("right"));
var tasks = panel.widgets("org.kde.plasma.icontasks").concat(panel.widgets("org.kde.plasma.taskmanager"));
tasks.forEach(function (w) { w.remove(); });

// Its clock, in Noto Sans Medium at 26 points, not sized to the panel.
panel.widgets("org.kde.plasma.digitalclock").forEach(function (w) {
  w.currentConfigGroup = ["Appearance"];
  w.writeConfig("autoFontAndSize", false);
  w.writeConfig("fontFamily", "Noto Sans");
  w.writeConfig("fontStyleName", "Medium");
  w.writeConfig("fontWeight", 500);
  w.writeConfig("fontSize", 26);
});

// The app menu's button: the Arch logo, white like the tray's icons
// (written below this script, as archlinux-logo-white).
panel.widgets("org.kde.plasma.kickoff").forEach(function (w) {
  w.currentConfigGroup = ["General"];
  w.writeConfig("icon", "archlinux-logo-white");
});

colorize(panel, translucent);

// No Peek at Desktop (the default panel ends with one).
panel.widgets("org.kde.plasma.showdesktop").forEach(function (w) { w.remove(); });

// Apdatifier (installed by install_plasmoids), just before the tray:
// updates counted in a badge, the AUR's too, through paru
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
  var tray = panel.widgets("org.kde.plasma.systemtray");
  var before = tray.length ? order.indexOf(tray[0].id) : -1;
  order.splice(before >= 0 ? before : order.length, 0, apd.id);
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
// (vitals): it only keeps one it's told is set up (migrationDone),
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

// For the log and plasmashellrc: each panel's number, then what it
// now says of its settings, a line each.
print(panel.id + " " + said + "\n" + second.id + " " + saidSecond + "\n" + centre.id + " " + saidCentre);
