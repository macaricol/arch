#!/usr/bin/env bash
# Phase — Wi-Fi, on the live ISO, as root: the networks in range as a list,
# strongest first; pick one, type its password, connected. Run by the USB's
# start-up (tools/build-autoinstall-iso.sh) when there's no wired
# connection, before the installer can be downloaded: so from the copy of
# this installer the USB carries. Returns once the internet is reachable.
#
# The live ISO's Wi-Fi is iwd. The list comes from it over D-Bus (busctl,
# read with python3, both on the ISO), which gives each network's name,
# kind and signal as data rather than iwctl's coloured table; connecting
# goes through iwctl. iwd remembers the network, and the install phase
# hands it on to the new system's NetworkManager (carry_wifi_networks).

phase_wifi() {
  setup_console
  rfkill unblock wifi 2>/dev/null || true

  local station device
  read -r station device < <(wifi_station) || true
  [[ -n ${station:-} ]] || die "No Wi-Fi adapter found. Plug in a network cable, then restart."

  local -a names kinds bars items
  local scan_again='── scan again ──' i pick password
  while :; do
    (( ${WIFI_TEST:-0} )) || { online && return 0; }   # TEMPORARY (Wi-Fi test): was "online && return 0"
    wifi_scan "$station"
    if (( ${#names[@]} == 0 )); then
      header "No Wi-Fi networks found"
      info "Looking again..."
      sleep 2
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

    password=''
    case ${kinds[pick]} in
      psk)  echo; input password "Password for ${names[pick]}" '' --secret ;;
      open) ;;
      *)    echo; warn "${names[pick]} needs a company login (802.1X), which isn't supported here. Pick another network."
            sleep 3; continue ;;
    esac
    header "Connecting to ${names[pick]}"
    WIFI_PASSWORD=$password
    # run()'s report of a failure (iwctl's own words) goes nowhere: the
    # message below says it plainly. It's in the log either way.
    if run wifi_connect "$device" "${names[pick]}" 2>/dev/null && run wait_online 2>/dev/null; then
      info "Connected."
      sleep 1
      return 0
    fi
    warn "Couldn't connect to ${names[pick]}.$([[ -n $password ]] && echo " Check the password and try again.")"
    sleep 3
  done
}

# Each try capped at 3 s: ping's -W doesn't cover the name lookup, which can
# hang far longer on a network with no way out.
online() { timeout 3 ping -c1 -W2 archlinux.org &>/dev/null; }

# wifi_station — prints the iwd station's D-Bus path and its device name
# (wlan0...), the first Wi-Fi adapter's; nothing without one.
wifi_station() {
  busctl --json=short call net.connman.iwd / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null \
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
  busctl call net.connman.iwd "$1" net.connman.iwd.Station Scan &>/dev/null || true
  for (( i = 0; i < 25; i++ )); do
    [[ $(busctl get-property net.connman.iwd "$1" net.connman.iwd.Station Scanning 2>/dev/null) == 'b false' ]] && break
    sleep 0.2
  done
  names=() kinds=() bars=()
  while IFS=$'\t' read -r bar kind name; do
    names+=("$name") kinds+=("$kind") bars+=("$bar")
  done < <(python3 - "$1" <<'PY'
import json, subprocess, sys
def busctl(*args):
    out = subprocess.run(["busctl", "--json=short", "call", "net.connman.iwd", *args],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)["data"][0]
objects = busctl("/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects")
ordered = busctl(sys.argv[1], "net.connman.iwd.Station", "GetOrderedNetworks")
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
  iwctl "${args[@]}" station "$1" connect "$2"
}

# wait_online — up to 20 s, by the clock, for an address and the internet.
wait_online() {
  local until=$(( SECONDS + 20 ))
  until online; do
    (( SECONDS < until )) || return 1
    sleep 1
  done
}
