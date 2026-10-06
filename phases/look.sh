#!/usr/bin/env bash
# Phase — the desktop's look, as chosen at the end of the install
# (lib/prompt.sh's choose_look), as root on the new system: from the
# installer through arch-chroot, or from a desktop phase run by hand through
# sudo. LOOK is archman or plain.
#
# Everything for both looks is installed by then; this only picks one. The
# system-wide part happens here: the login screen and the default
# wallpaper. The rest belongs to the user's first Plasma session, so the
# choice is left in $SETUP_DIR/look for plasma-tweaks to read.

phase_look() {
  require_root
  case ${LOOK:-} in
    archman|plain) ;;
    *) die "LOOK must be archman or plain" ;;
  esac

  local conf=/etc/sddm.conf.d/kde_settings.conf
  mkdir -p /etc/sddm.conf.d
  if [[ $LOOK == archman ]]; then
    # The login screen in the unlock screen's look (assets/sddm/archman),
    # and the wallpaper as the system-wide default, so the first Plasma
    # session starts with it.
    kwriteconfig6 --file "$conf" --group Theme --key Current "$SDDM_THEME"
    local xml=/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml
    sed -i "/<entry name=\"Image\" type=\"String\">/,/<\/entry>/ s|<default>.*</default>|<default>file://$WALLPAPER</default>|" "$xml"
  else
    # KDE's own login screen (from plasma-desktop); SDDM's built-in default
    # isn't it.
    kwriteconfig6 --file "$conf" --group Theme --key Current breeze
  fi

  echo "$LOOK" > "$SETUP_DIR/look"
  chown --reference="$SETUP_DIR" "$SETUP_DIR/look"
}
