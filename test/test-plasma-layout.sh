#!/usr/bin/env bash
# Dry run of the first login's desktop layout (phases/plasma-tweaks.sh's
# configure_desktop_layout), without a Plasma session to change: the
# script it would send to Plasma, run in Qt's JavaScript engine (the qml
# tool, from qt6-declarative) against a stand-in for Plasma's scripting
# interface, with a default panel like a fresh session's. Prints each
# panel's settings and widgets, and what's written to plasmashellrc.
#
#   test/test-plasma-layout.sh
#
# Panel Colorizer's preset is missing from the stand-in's home (no widgets
# installed), so the colorizers are left out, as on a session where its
# download failed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
qml=/usr/lib/qt6/bin/qml
[[ -x $qml ]] || { echo "Needs Qt's qml tool: sudo pacman -S qt6-declarative" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The layout's script, as configure_desktop_layout builds it; and the
# plasmashellrc writes it makes after.
(
  source config.sh
  SETUP_DIR=$PWD HOME=$work/home
  note() { :; }
  plasma_script() { printf '%s' "$1" > "$work/layout.js"; printf '2 main\n26 left\n30 centre\n'; }
  kwriteconfig6() { echo "  $*" >> "$work/plasmashellrc.txt"; }
  eval "$(sed -n '/^configure_desktop_layout() {/,/^}/p; /^panel_view() {/,/^}/p' phases/plasma-tweaks.sh)"
  configure_desktop_layout
)

# Plasma's scripting interface, as much of it as the script uses.
cat > "$work/plasma.js" <<'EOF'
var out = [], nextId = 40, allPanels = [];
function print(s) { out.push("print: " + String(s).split("\n").join("\nprint: ")); }
function Widget(type, id) { this.type = type; this.id = id; this.cfg = {}; this.currentConfigGroup = []; this.removed = false; }
Widget.prototype.writeConfig = function (k, v) { this.cfg[this.currentConfigGroup.join("/") + ":" + k] = v; };
Widget.prototype.remove = function () { this.removed = true; };
function Panel() { this.id = nextId++; this.list = []; this.cfg = {}; this.currentConfigGroup = []; allPanels.push(this); }
Panel.prototype.widgets = function (t) { return this.list.filter(function (w) { return !w.removed && (!t || w.type == t); }); };
Panel.prototype.addWidget = function (t) { var w = new Widget(t, nextId++); this.list.push(w); return w; };
Panel.prototype.writeConfig = function (k, v) { this.cfg[this.currentConfigGroup.join("/") + ":" + k] = v; };
// A fresh session's panel.
var main = new Panel(); main.id = 2;
["org.kde.plasma.kickoff", "org.kde.plasma.pager", "org.kde.plasma.icontasks", "org.kde.plasma.marginsseparator",
 "org.kde.plasma.systemtray", "org.kde.plasma.digitalclock", "org.kde.plasma.showdesktop"].forEach(function (t, i) {
  main.list.push(new Widget(t, 3 + i));
});
function panels() { return [main]; }
function desktops() { return [{ screen: 0, addWidget: function (t) { return new Widget(t, nextId++); } }]; }
function screenGeometry() { return { width: 3840, height: 2160 }; }
EOF
cat > "$work/report.js" <<'EOF'
allPanels.forEach(function (p) {
  out.push("panel " + p.id + ": " + ["location", "alignment", "lengthMode", "hiding", "opacity", "floating", "height"]
    .map(function (k) { return k + "=" + p[k]; }).join(" "));
  if (p.cfg["General:AppletOrder"]) out.push("  order " + p.cfg["General:AppletOrder"]);
  p.widgets().forEach(function (w) {
    var cfg = JSON.stringify(w.cfg);
    out.push("  " + w.id + " " + w.type + (cfg == "{}" ? "" : " " + (cfg.length > 200 ? cfg.slice(0, 200) + "…" : cfg)));
  });
});
EOF
{
  printf 'import QtQuick\nItem { Component.onCompleted: { var log; try { log = (function () {\n'
  cat "$work/plasma.js" "$work/layout.js" "$work/report.js"
  printf '\nreturn out; })(); } catch (e) { log = ["ERROR: " + e + " (line " + e.lineNumber + ")"]; }\n'
  printf 'console.warn(log.join("\\n")); Qt.quit(); } }\n'
} > "$work/test.qml"
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen timeout 30 "$qml" "$work/test.qml" 2>&1 | sed 's/^qml: //'
echo "plasmashellrc:"
sed 's/--file plasmashellrc --group PlasmaViews //' "$work/plasmashellrc.txt"
