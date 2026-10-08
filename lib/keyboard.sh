#!/usr/bin/env bash
# The keyboard layout question: on the USB's Wi-Fi screen (phases/wifi.sh)
# when there's no cable, so the Wi-Fi password is typed with it, else in the
# install phase. The choice made on the Wi-Fi screen is kept in
# KEYBOARD_CHOICE_FILE for the installer, which then doesn't ask again.

KEYBOARD_CHOICE_FILE=/run/archman-keyboard

# The keyboard layouts offered, as "label|console keymap|X11 layout|X11
# variant": Omarchy's list (basecamp/omarchy, install/provisioning/
# setup-form.sh), less its Lao and Azerbaijani, whose keymaps there are
# other layouts' (la-latin1 is Latin American Spanish, azerty French). The
# X11 side is systemd's (kbd-model-map, what localectl uses), filled in by
# hand where it has no line. Layouts without Latin letters come with US as
# a second one, so a Latin password can still be typed at the login screen.
KEYBOARD_LAYOUTS=(
  "English (US)|us|us|" "English (UK)|uk|gb|" "English (US, Dvorak)|dvorak|us|dvorak"
  "English (US, Colemak)|colemak|us|colemak" "Belarusian|by|by,us|" "Belgian|be-latin1|be|"
  "Bulgarian|bg-cp1251|bg,us|" "Croatian|croat|hr|" "Czech|cz|cz|" "Danish|dk-latin1|dk|"
  "Dutch|nl|nl|" "Estonian|et|ee|" "Finnish|fi|fi|" "French|fr|fr|" "French (Canada)|cf|ca|"
  "French (Switzerland)|fr_CH|ch|fr" "Georgian|ge|ge,us|" "German|de|de|"
  "German (Switzerland)|de_CH-latin1|ch|" "Greek|gr|gr,us|" "Hebrew|il|il|" "Hungarian|hu|hu|"
  "Icelandic|is-latin1|is|" "Irish|ie|ie|" "Italian|it|it|" "Japanese|jp106|jp|"
  "Kazakh|kazakh|kz,us|" "Kyrgyz|kyrgyz|kg,us|" "Latvian|lv|lv|apostrophe" "Lithuanian|lt|lt|"
  "Macedonian|mk-utf|mk,us|" "Norwegian|no-latin1|no|" "Polish|pl|pl|" "Portuguese|pt-latin1|pt|"
  "Portuguese (Brazil)|br-abnt2|br|" "Romanian|ro|ro|" "Russian|ru|ru,us|"
  "Serbian|sr-latin|rs|latin" "Slovak|sk-qwertz|sk|" "Slovenian|slovene|si|" "Spanish|es|es|"
  "Spanish (Latin American)|la-latin1|latam|" "Swedish|sv-latin1|se|" "Tajik|tj_alt-UTF8|tj|"
  "Turkish|trq|tr|" "Ukrainian|ua|ua,us|"
)
# The layout people type on, by country (geolocate's); any other country,
# and those typing on US keyboards (US, Canada, Australia, India, the
# Netherlands...), English (US).
declare -A COUNTRY_KEYBOARD=(
  [GB]="English (UK)" [IE]="English (UK)" [PT]="Portuguese" [BR]="Portuguese (Brazil)"
  [ES]="Spanish" [FR]="French" [BE]="Belgian" [CH]="German (Switzerland)"
  [DE]="German" [AT]="German" [LI]="German" [IT]="Italian" [SM]="Italian"
  [DK]="Danish" [NO]="Norwegian" [SE]="Swedish" [FI]="Finnish" [IS]="Icelandic"
  [EE]="Estonian" [LV]="Latvian" [LT]="Lithuanian" [PL]="Polish" [CZ]="Czech"
  [SK]="Slovak" [SI]="Slovenian" [HR]="Croatian" [RS]="Serbian" [HU]="Hungarian"
  [RO]="Romanian" [BG]="Bulgarian" [GR]="Greek" [CY]="Greek" [TR]="Turkish"
  [RU]="Russian" [UA]="Ukrainian" [BY]="Belarusian" [KZ]="Kazakh" [KG]="Kyrgyz"
  [TJ]="Tajik" [GE]="Georgian" [MK]="Macedonian" [IL]="Hebrew" [JP]="Japanese"
)
for _country in MX AR CO CL PE VE EC GT CU BO DO HN PY SV NI CR PA UY PR; do
  COUNTRY_KEYBOARD[$_country]="Spanish (Latin American)"
done
unset _country

# choose_keyboard — asks for the keyboard layout: the one of where this
# machine is (geolocate's GEO_COUNTRY) first, then English (US), then the
# rest by name; without a location (on the Wi-Fi screen, before there's a
# network), English (US) first.
# Loads it on the console at once, so the password that follows is typed
# with it, and sets KEYBOARD_LABEL, KEYMAP and the X11_* that the later
# phases use. Esc shows the list again.
choose_keyboard() {
  local detected=${COUNTRY_KEYBOARD[${GEO_COUNTRY:-none}]:-English (US)} entry label   # (an empty key is an error)
  local -a labels=("$detected") rest=()
  [[ $detected == "English (US)" ]] || labels+=("English (US)")
  for entry in "${KEYBOARD_LAYOUTS[@]}"; do
    label=${entry%%|*}
    [[ $label == "$detected" || $label == "English (US)" ]] || rest+=("$label")
  done
  mapfile -t rest < <(printf '%s\n' "${rest[@]}" | LC_ALL=C sort)
  labels+=("${rest[@]}")
  until menu "Select your keyboard layout" "${labels[@]}"; do :; done
  KEYBOARD_LABEL=$MENU_CHOICE
  for entry in "${KEYBOARD_LAYOUTS[@]}"; do
    if [[ ${entry%%|*} == "$KEYBOARD_LABEL" ]]; then IFS='|' read -r _ KEYMAP X11_LAYOUT X11_VARIANT <<< "$entry"; fi
  done
  # Two layouts: both Shift keys switch between them.
  X11_OPTIONS=''
  [[ $X11_LAYOUT != *,* ]] || X11_OPTIONS=grp:shifts_toggle
  loadkeys "$KEYMAP" 2>/dev/null || true
  printf 'Keyboard: %s (%s; X11 %s %s %s)\n' "$KEYBOARD_LABEL" "$KEYMAP" "$X11_LAYOUT" "$X11_VARIANT" "$X11_OPTIONS" >> "$LOG_FILE"
}

# save_keyboard_choice / read_keyboard_choice — the layout picked, kept for
# the installer (a separate run, downloaded afterwards). read_keyboard_choice
# sets it up as choose_keyboard would, loaded on the console; it fails when
# nothing was picked, or the label isn't in the list any more.
save_keyboard_choice() { printf '%s\n' "$KEYBOARD_LABEL" > "$KEYBOARD_CHOICE_FILE"; }
read_keyboard_choice() {
  local label entry
  [[ -r $KEYBOARD_CHOICE_FILE ]] || return 1
  IFS= read -r label < "$KEYBOARD_CHOICE_FILE" || return 1
  for entry in "${KEYBOARD_LAYOUTS[@]}"; do
    if [[ ${entry%%|*} == "$label" ]]; then
      KEYBOARD_LABEL=$label
      IFS='|' read -r _ KEYMAP X11_LAYOUT X11_VARIANT <<< "$entry"
      X11_OPTIONS=''
      [[ $X11_LAYOUT != *,* ]] || X11_OPTIONS=grp:shifts_toggle
      loadkeys "$KEYMAP" 2>/dev/null || true
      printf 'Keyboard (picked on the Wi-Fi screen): %s\n' "$KEYBOARD_LABEL" >> "$LOG_FILE"
      return 0
    fi
  done
  return 1
}
