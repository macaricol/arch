#!/usr/bin/env bash
# Simulated Wi-Fi networks, for trying the Wi-Fi screen in a VM: on the USB
# only when built with --wifi-test (tools/build-autoinstall-iso.sh), where
# the USB's start-up (tools/archauto.sh) sources this and calls
# wifi_test_setup, then wifi_test_wait_station. Functions only.
#
# Three simulated radios (mac80211_hwsim), two of them access points,
# "TestNet" (secret123) and "Neighbours WiFi" (whatever99), the third the
# one the Wi-Fi screen uses; and the screen is shown even with a cable,
# which is what then reaches the internet once "connected".
#
# The access points aren't iwd's: iwd as both the access point and the one
# connecting to it never completes the handshake (connect-timeout), and
# then loses the access points. So, as iwd's own tests do it, they're
# apart: their radios moved into a network namespace of their own, where
# iwd doesn't see them, run by wpa_supplicant (on the ISO) as access
# points. The simulated radios share one medium across namespaces, so the
# Wi-Fi screen's radio sees them like any network. What it did, and any
# error: /run/wifi-test.log.

# wifi_test_ap PHY INTERFACE SSID PASSPHRASE FREQUENCY — radio PHY, moved
# into the wifi-test namespace, as an access point for SSID.
wifi_test_ap() {
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

# wifi_test_setup — the three radios and the two access points.
wifi_test_setup() {
  local -a phys
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
}

# wifi_test_wait_station — iwd deletes and re-creates the interface of a
# radio it takes over: waits for the one left to it, or the start-up's
# check for Wi-Fi finds none at all.
wifi_test_wait_station() {
  for _ in {1..20}; do
    compgen -G '/sys/class/net/*/wireless' > /dev/null && break
    sleep 0.5
  done
  ls /sys/class/net >> /run/wifi-test.log 2>&1
}
