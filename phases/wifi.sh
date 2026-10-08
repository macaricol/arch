#!/usr/bin/env bash
# Phase — Wi-Fi, on the live ISO, as root: the networks in range as a list,
# strongest first; pick one, type its password, connected. Run by the USB's
# start-up (tools/build-autoinstall-iso.sh) when there's no wired
# connection, before the installer can be downloaded: so from the copy of
# this installer the USB carries. Returns once the internet is reachable.
#
# Every call to iwd has a time limit (busctl --timeout, timeout for iwctl):
# should iwd stop answering, the screen moves on, to an empty list that
# offers to look again, rather than waiting forever.
#
# The live ISO's Wi-Fi is iwd. The list comes from it over D-Bus (busctl,
# read with python3, both on the ISO), which gives each network's name,
# kind and signal as data rather than iwctl's coloured table; connecting
# goes through iwctl. iwd remembers the network, and the install phase
# hands it on to the new system's NetworkManager (carry_wifi_networks).

phase_wifi() {
  setup_console
  # The keyboard first, so the Wi-Fi password is typed with it; no location
  # yet, so English (US) leads. The installer keeps this choice.
  choose_keyboard
  save_keyboard_choice
  rfkill unblock wifi 2>/dev/null || true

  local station device
  read -r station device < <(wifi_station) || true
  [[ -n ${station:-} ]] || die "No Wi-Fi adapter found. Plug in a network cable, then restart."

  local -a names kinds bars items
  local scan_again='── scan again ──' i pick name password
  while :; do
    # (In a USB built --wifi-test, the cable is online all along: the
    # screen stays until a network is connected.)
    (( ${WIFI_TEST:-0} )) || { online && return 0; }
    header "Choose your Wi-Fi network"
    info "Looking for Wi-Fi networks..."
    wifi_scan "$station"
    if (( ${#names[@]} == 0 )); then
      buttons "No Wi-Fi networks found" 0 \
        "Look again" "Move closer to your router, or check it's switched on, then look again."
      continue
    fi
    items=()
    for i in "${!names[@]}"; do items+=("$(wifi_item "${names[i]}" "${bars[i]}" "${kinds[i]}")"); done
    menu "Choose your Wi-Fi network" "${items[@]}" "$scan_again" || continue   # Esc: scan again
    [[ $MENU_CHOICE != "$scan_again" ]] || continue
    pick=-1
    for i in "${!items[@]}"; do
      if [[ ${items[i]} == "$MENU_CHOICE" ]]; then pick=$i; fi
    done
    (( pick >= 0 )) || continue
    name=${names[pick]}

    if [[ ${kinds[pick]} != psk && ${kinds[pick]} != open ]]; then
      buttons "$name can't be used here" 0 \
        "Other network" "It needs a company login (802.1X), which this installer doesn't support."
      continue
    fi

    # The network picked: its password (when it has one), connecting, and
    # on failure, what went wrong and the choice of trying again (straight
    # back to the password) or another network (back to the list).
    while :; do
      password=''
      if [[ ${kinds[pick]} == psk ]]; then
        header "Connect to $name"
        wifi_password password || break   # Esc: back to the list
      fi
      header "Connecting to $name"
      info "This can take up to half a minute."
      WIFI_PASSWORD=$password
      # run()'s report of a failure (iwctl's own words) goes nowhere: the
      # screens below say it plainly. It's in the log either way.
      if ! run wifi_connect "$device" "$name" 2>/dev/null; then
        if [[ -n $password ]]; then
          buttons "Couldn't connect to $name" 0 \
            "Try again" "The password may be wrong. Type it again." \
            "Other network" "Go back to the list of Wi-Fi networks."
        else
          buttons "Couldn't connect to $name" 0 \
            "Try again" "The network didn't answer. Try connecting again." \
            "Other network" "Go back to the list of Wi-Fi networks."
        fi
      elif ! run wait_online 2>/dev/null; then
        buttons "$name doesn't reach the internet" 1 \
          "Try again" "It connected, but the internet didn't answer. Try connecting again." \
          "Other network" "Go back to the list of Wi-Fi networks."
      else
        # Left on screen until the installer's first one replaces it.
        info "Connected. Getting the installer ready..."
        return 0
      fi
      (( PICKED == 0 )) || break
    done
  done
}

# Each try capped at 3 s: ping's -W doesn't cover the name lookup, which can
# hang far longer on a network with no way out.
online() { timeout 3 ping -c1 -W2 archlinux.org &>/dev/null; }

# wifi_password VAR — the network's password, into VAR. Its own field, not
# lib/prompt.sh's: gum's password field can't be shown, and here Tab shows
# and hides what's typed. Wi-Fi passwords are 8 to 63 characters: anything
# else is refused at once, rather than after a failed connection. Esc
# returns 1 (back to the list).
wifi_password() {
  local LC_ALL=C.UTF-8 __var=$1 __pw='' __shown=0 __key __rest __mask __note=''   # ${#} in characters
  __mask=$(mask_char)
  ask "Password >"
  # The field starts here: the one cursor position saved (\e7), and never
  # saved over, as each frame is redrawn from it (\e8, then \e[J to clear
  # below). After the hints under the field, back to its start and the
  # field once more, which leaves the cursor at its end, where typing goes.
  printf '\e7'
  local __field
  cursor on
  while :; do
    if (( __shown )); then __field=$__pw; else __field=$(repeat "$__mask" "${#__pw}"); fi
    printf '\e8\e[J%s\n\n' "$__field"
    if [[ -n $__note ]]; then
      printf '%s%s%s%s\n' "$MARGIN" "$C_YELLOW" "$__note" "$C_RESET"
    fi
    printf '%s%sTab %s the password · Esc goes back to the list%s' "$MARGIN" "$C_GREY" \
      "$( (( __shown )) && echo hides || echo shows )" "$C_RESET"
    printf '\e8%s' "$__field"
    IFS= read -rsn1 __key || die "Input closed"
    __note=''
    case $__key in
      '')
        if (( ${#__pw} >= 8 && ${#__pw} <= 63 )); then break; fi
        __note="Wi-Fi passwords are 8 to 63 characters; this one has ${#__pw}." ;;
      $'\t')         __shown=$(( 1 - __shown )) ;;
      $'\x7f'|$'\b') __pw=${__pw%?} ;;
      $'\x15')       __pw='' ;;                                       # Ctrl+U
      $'\e')
        # Esc alone, or the start of a key's code (arrows: Esc [ A...),
        # which is read to its end (a letter or ~) and ignored.
        __rest=''; read -rsn1 -t 0.05 __rest || true
        [[ -n $__rest ]] || { cursor off; printf '\e[J\n'; return 1; }
        while [[ $__rest != [A-Za-z~] ]] && read -rsn1 -t 0.05 __rest; do :; done ;;
      *)             __pw+=$__key ;;
    esac
  done
  cursor off
  printf '\e8\e[J\n'
  printf -v "$__var" '%s' "$__pw"
}

# wifi_station — prints the iwd station's D-Bus path and its device name
# (wlan0...), the first Wi-Fi adapter's; nothing without one.
wifi_station() {
  busctl --timeout=5 --json=short call net.connman.iwd / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null \
    | python3 -c '
import json, sys
for path, ifaces in json.load(sys.stdin)["data"][0].items():
    if "net.connman.iwd.Station" in ifaces:
        print(path, ifaces["net.connman.iwd.Device"]["Name"]["data"])
        break'
}

# wifi_scan STATION — scans (a few seconds), then fills names, kinds (psk,
# open, 8021x...) and bars (signal, 1 to 4), strongest first.
wifi_scan() {
  local name kind bar i
  # At most some 15 s in all, even with iwd not answering: the scan asked
  # for (3 s), its end waited for by the clock (6 s), the list (2 x 3 s).
  busctl --timeout=3 call net.connman.iwd "$1" net.connman.iwd.Station Scan &>/dev/null || true
  local until=$(( SECONDS + 6 ))
  while (( SECONDS < until )); do
    [[ $(busctl --timeout=1 get-property net.connman.iwd "$1" net.connman.iwd.Station Scanning 2>/dev/null) == 'b false' ]] && break
    sleep 0.2
  done
  names=() kinds=() bars=()
  while IFS=$'\t' read -r bar kind name; do
    names+=("$name") kinds+=("$kind") bars+=("$bar")
  done < <(python3 - "$1" <<'PY'
import json, subprocess, sys
def busctl(*args):
    out = subprocess.run(["busctl", "--timeout=3", "--json=short", "call", "net.connman.iwd", *args],
                         capture_output=True, text=True, check=True, timeout=5).stdout
    return json.loads(out)["data"][0]
try:
    objects = busctl("/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
    ordered = busctl(sys.argv[1], "net.connman.iwd.Station", "GetOrderedNetworks")
except Exception:      # iwd not answering, or no networks yet: an empty list
    sys.exit(0)
for path, signal in ordered:              # strongest first; signal in 100 * dBm
    net = objects.get(path, {}).get("net.connman.iwd.Network")
    if not net:
        continue
    dbm = signal / 100
    bars = 4 if dbm >= -60 else 3 if dbm >= -67 else 2 if dbm >= -75 else 1
    name = net["Name"]["data"].replace("\t", " ").replace("\n", " ")
    print(f'{bars}\t{net["Type"]["data"]}\t{name}')
PY
)
}

# wifi_item NAME BARS KIND — a line of the list: the name, then the signal
# as four dots (the console fonts have no signal bars), then its security.
wifi_item() {
  local LC_ALL=C.UTF-8 name=$1 meter security   # ${#} counts characters, not bytes
  (( ${#name} <= 44 )) || name="${name:0:41}..."   # (no … in the console fonts)
  printf -v meter '%*s' "$2" ''; meter=${meter// /•}
  while (( ${#meter} < 4 )); do meter+='·'; done
  case $3 in psk) security=secured ;; open) security=open ;; *) security=enterprise ;; esac
  printf '%s%*s  %s  %s' "$name" $(( 44 - ${#name} )) '' "$meter" "$security"   # (printf pads by bytes)
}

# wifi_connect DEVICE NAME — connects, with the password in WIFI_PASSWORD
# (empty for an open network): through a variable, not an argument, as
# run() writes its command line into the log. iwctl waits for the
# association, and fails on a wrong password.
wifi_connect() {
  local -a args=()
  [[ -z $WIFI_PASSWORD ]] || args=(--passphrase "$WIFI_PASSWORD")
  timeout 45 iwctl "${args[@]}" station "$1" connect "$2" < /dev/null
}

# wait_online — up to 20 s, by the clock, for an address and the internet.
wait_online() {
  local until=$(( SECONDS + 20 ))
  until online; do
    (( SECONDS < until )) || return 1
    sleep 1
  done
}
