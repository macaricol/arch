#!/bin/bash
# The ARCHMAN USB's start-up, run by archauto.service on tty1 (both added to
# the official ISO by tools/build-autoinstall-iso.sh, as
# /usr/local/bin/archauto): the splash, the network (the Wi-Fi screen when
# there's no cable), then the installer, fetched from GitHub
# (bootstrap.sh). The values it needs from the build (REPO, BRANCH,
# BOOTSTRAP_URL, TAGLINE, CONSOLE_PALETTE, WIFI_TEST, and the logo as
# coloured lines: LOGO, LOGO_WIDTH) are in archauto.conf beside its files.

source /usr/local/share/archauto/archauto.conf

# Font first, as lib/ui.sh's scale_console_font picks it (nearest ~48 rows
# with 80+ columns) and from the same patched files, so the installer keeps
# it and nothing jumps.
# The quiet boot leaves the framebuffer console's takeover deferred until
# something is printed, and until then setfont fails: print, then wait for
# the takeover (asynchronous) to accept a font. A visible character, as the
# placeholder console ignores escape sequences and spaces: a dot, erased.
printf '\e[H.\r\e[K'
for _ in {1..20}; do
  setfont -C /dev/tty1 default8x16 2>/dev/null && break
  sleep 0.5
done
best='' best_diff=99999
for font in default8x16 sun12x22 latarcyrheb-sun32; do
  font=/usr/local/share/archauto/$font.psfu.gz
  setfont -C /dev/tty1 "$font" 2>/dev/null || continue
  read -r rows cols < <(stty size < /dev/tty)
  (( cols >= 80 )) || continue
  diff=$(( rows > 48 ? rows - 48 : 48 - rows ))
  (( diff < best_diff )) && { best=$font; best_diff=$diff; }
done
setfont -C /dev/tty1 "${best:-default8x16}" 2>/dev/null

for i in "${!CONSOLE_PALETTE[@]}"; do printf '\e]P%X%s' "$i" "${CONSOLE_PALETTE[i]}"; done
printf '\e[0m\e[?25l'

# center TEXT COLOUR [WIDTH] — as lib/ui.sh's center, in one SGR colour (or
# none, for text already coloured: then WIDTH is its width without escapes)
center() {
  local LC_ALL=C.UTF-8 pad=$(( ($(stty size < /dev/tty | cut -d' ' -f2) - ${3:-${#1}}) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%*s\e[%sm%s\e[0m\n' "$pad" '' "${2:-0}" "$1"
}

# splash "Status" — logo, tagline and status where the installer puts its
# logo, tagline and step title
splash() {
  local line
  printf '\e[2J\e[H\n\n'
  while IFS= read -r line; do center "$line" '' "$LOGO_WIDTH"; done <<< "$LOGO"
  echo; center "$TAGLINE" 95; echo; echo; echo
  center "$1" '1;97'
}

# give_up [--keep] "Title" "Line"... — something went wrong: say so in plain
# words, what to do about it, and restart on Enter. No shell and no commands
# on screen: whoever is installing shouldn't need either. (To dig in, the
# ISO's other consoles are still there: Alt+F2, root, no password.) With
# --keep, below what's on screen: the installer's own error, which a
# cleared screen would lose.
give_up() {
  if [[ $1 == --keep ]]; then shift; printf '\e[0m\n'; center "$1" '1;97'; else splash "$1"; fi
  shift
  echo
  local line
  for line; do center "$line" 97; done
  echo; center "Press Enter to restart" 90
  printf '\e[?25l'
  read -r _ || true
  systemctl reboot
}
NO_INTERNET=("No internet connection"
  "Plug in a network cable, or make sure you're near a Wi-Fi network,"
  "then restart your computer.")

# under_logo "Text" — a line just under the big logo: two text rows below
# its bottom edge, which fb-logo.py reports in pixels. With the text splash
# instead, its own status line. Placed without a newline: scrolling the
# console would smear the logo.
under_logo() {
  local LC_ALL=C.UTF-8 rows cols row
  (( LOGO_BOTTOM )) || { splash "$1"; return; }
  read -r rows cols < <(stty size < /dev/tty)
  row=$(( LOGO_BOTTOM * rows / SCREEN_HEIGHT + 3 ))
  printf '\e[%d;1H\e[2K\e[%d;%dH\e[1;97m%s\e[0m' "$row" "$row" $(( (cols - ${#1}) / 2 + 1 )) "$1"
}

# The logo, two thirds of the screen wide (the text splash if there's no
# 32-bit framebuffer), up from here until the installer's first question:
# it checks the network, then the installer (told by SPLASH_SINCE) checks
# the rest, draws nothing meanwhile, and keeps the splash up for at least
# 4 seconds in all. 2 seconds in, one line under the logo says what's
# going on.
share=/usr/local/share/archauto
# show_splash — the screen cleared and the big logo drawn (fb-logo.py, which
# reports where it ends: LOGO_BOTTOM, SCREEN_HEIGHT), or the text splash;
# SPLASH_SINCE is when.
show_splash() {
  local geometry
  printf '\e[2J\e[H'
  LOGO_BOTTOM=0 SCREEN_HEIGHT=0
  if geometry=$(python3 "$share/fb-logo.py" "$share/logo-hd.txt" "$share/logo-hd.colors" \
                  "${CONSOLE_PALETTE[0]}" "${CONSOLE_PALETTE[6]}" "${CONSOLE_PALETTE[2]}" 2>/dev/null); then
    read -r LOGO_BOTTOM SCREEN_HEIGHT <<< "$geometry"
  else
    splash ""
  fi
  SPLASH_SINCE=$EPOCHSECONDS
}
show_splash
( sleep 2; under_logo "Checking if this computer is ready..." ) &
checking=$!

# The network. A cable is usually up within a few seconds; without one, on
# a machine with Wi-Fi, the Wi-Fi screen (phases/wifi.sh, from the copy of
# the installer above) asks for the keyboard layout and lists the networks
# to pick from, then goes on to the installer. Without Wi-Fi either, it
# waits for a cable, up to 30 s.
#
# The waits go by the clock, and each try is capped at 3 s: ping's -W only
# covers waiting for the reply, not looking up the name first, which on a
# network with no way out (a cable, an address, no internet) can hang for
# many seconds a try.
online() { timeout 3 ping -c1 -W2 archlinux.org &>/dev/null; }
wait_online() {   # wait_online SECONDS
  local until=$(( SECONDS + $1 ))
  until online; do
    (( SECONDS < until )) || return 1
    sleep 1
  done
}
# --wifi-test (a build for testing in a VM): three simulated Wi-Fi radios
# (mac80211_hwsim), two of them access points, "TestNet" (secret123) and
# "Neighbours WiFi" (whatever99), the third the one the Wi-Fi screen uses;
# and the screen is shown even with a cable, which is what then reaches the
# internet once "connected". Off in a normal build.
#
# The access points aren't iwd's: iwd as both the access point and the one
# connecting to it never completes the handshake (connect-timeout), and
# then loses the access points. So, as iwd's own tests do it, they're
# apart: their radios moved into a network namespace of their own, where
# iwd doesn't see them, run by wpa_supplicant (on the ISO) as access
# points. The simulated radios share one medium across namespaces, so the
# Wi-Fi screen's radio sees them like any network. What it did, and any
# error: /run/wifi-test.log.
if (( WIFI_TEST )); then
  export WIFI_TEST
  wifi_test_ap() {   # wifi_test_ap PHY INTERFACE SSID PASSPHRASE FREQUENCY
    local ns=(ip netns exec wifi-test) dev
    iw phy "$1" set netns name wifi-test || return 1
    # The interface iwd made on that radio came along: replace it with one
    # wpa_supplicant runs.
    for dev in $("${ns[@]}" iw dev | awk -v p="${1#phy}" '/^phy#/ { on = (substr($1, 5) == p) } on && $1 == "Interface" { print $2 }'); do
      "${ns[@]}" iw dev "$dev" del
    done
    "${ns[@]}" iw phy "$1" interface add "$2" type managed
    "${ns[@]}" ip link set "$2" up
    printf 'network={\n  ssid="%s"\n  mode=2\n  frequency=%s\n  key_mgmt=WPA-PSK\n  proto=RSN\n  pairwise=CCMP\n  group=CCMP\n  psk="%s"\n}\n' \
      "$3" "$5" "$4" > "/run/wifi-test-$2.conf"
    "${ns[@]}" wpa_supplicant -B -i "$2" -c "/run/wifi-test-$2.conf"
  }
  {
    modprobe mac80211_hwsim radios=3
    for _ in {1..20}; do
      (( $(ls /sys/class/ieee80211 2>/dev/null | wc -l) >= 3 )) && break
      sleep 0.5
    done
    sleep 1   # iwd taking the new radios
    mapfile -t phys < <(ls /sys/class/ieee80211 | sort -V | tail -3)
    echo "radios: ${phys[*]} (the first stays with iwd)"
    ip netns add wifi-test
    wifi_test_ap "${phys[1]}" ap1 "TestNet" "secret123" 2437
    wifi_test_ap "${phys[2]}" ap2 "Neighbours WiFi" "whatever99" 2462
    sleep 2
    ip netns exec wifi-test iw dev
  } >> /run/wifi-test.log 2>&1
fi

started=$SECONDS network=0
(( WIFI_TEST )) || { wait_online 8 && network=1; }   # (--wifi-test: straight to the Wi-Fi screen)
if (( WIFI_TEST )); then
  # iwd deletes and re-creates the interface of a radio it takes over: wait
  # for the one left to it, or the check below finds no Wi-Fi at all.
  for _ in {1..20}; do
    compgen -G '/sys/class/net/*/wireless' > /dev/null && break
    sleep 0.5
  done
  ls /sys/class/net >> /run/wifi-test.log 2>&1
fi
if (( ! network )) && compgen -G '/sys/class/net/*/wireless' > /dev/null; then
  kill "$checking" 2>/dev/null; wait "$checking" 2>/dev/null
  # The Wi-Fi screen stays up, saying it's connected, until the installer's
  # first screen replaces it: not the splash again, which would show for
  # only as long as the download takes, a blink.
  bash "$share/installer/setup.sh" wifi || give_up "${NO_INTERNET[@]}"
  network=1   # the Wi-Fi screen only returns online
fi
(( network )) || wait_online $(( 30 - (SECONDS - started) )) \
  || { kill "$checking" 2>/dev/null
       give_up "${NO_INTERNET[@]}"; }

# The installer ends by restarting the computer: if it comes back here at
# all, failed or not, it stopped early. Never a black screen: say so, and
# restart on Enter.
curl -fsSL "$BOOTSTRAP_URL" | SPLASH_SINCE=$SPLASH_SINCE REPO=$REPO BRANCH=$BRANCH bash
kill "$checking" 2>/dev/null
give_up --keep "The installation stopped" "Restart to try again."
