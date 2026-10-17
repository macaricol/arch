#!/usr/bin/env bash
# Where this machine is, by its public IP, and what follows from it: the
# timezone, the date formats and the mirrors' countries (the install
# phase), and the keyboard offered first (lib/keyboard.sh).

# Where this machine is, by its public IP (ipinfo.io), in GEO_COUNTRY (a
# two-letter code) and GEO_TIMEZONE (e.g. Europe/Lisbon); each empty when
# the lookup fails or doesn't say. One lookup for all of them.
geolocate() {
  local json country='"country": *"([A-Z]{2})"' zone='"timezone": *"([A-Za-z0-9_+/-]+)"'
  GEO_COUNTRY='' GEO_TIMEZONE=''
  json=$(curl -fsS --max-time 5 https://ipinfo.io/json 2>/dev/null) || true
  [[ $json =~ $country ]] && GEO_COUNTRY=${BASH_REMATCH[1]}
  [[ $json =~ $zone ]] && GEO_TIMEZONE=${BASH_REMATCH[1]}
  printf 'Location: country %s, timezone %s\n' "${GEO_COUNTRY:-unknown}" "${GEO_TIMEZONE:-unknown}" >> "$LOG_FILE"
  return 0
}

# TIMEZONE, settled: with auto (config.sh), the one geolocate found, if it's
# one the system knows (a file in /usr/share/zoneinfo); UTC otherwise. A
# fixed one is kept as it is.
resolve_timezone() {
  [[ $TIMEZONE == auto ]] || return 0
  if [[ -n $GEO_TIMEZONE && -f /usr/share/zoneinfo/$GEO_TIMEZONE ]]; then
    TIMEZONE=$GEO_TIMEZONE
  else
    TIMEZONE=UTC
  fi
}

# TIME_LOCALE, settled: with auto (config.sh), the locale whose dates and
# times are the country's geolocate found, one glibc has (its list,
# /usr/share/i18n/SUPPORTED): in the country's main language (pt_PT,
# es_ES, de_DE), else in English (en_GB, en_IN, en_CA), else the first
# there is. For countries whose first isn't their main language, the
# language is given (MAIN_LANGUAGE). LOCALE's when there's no country, or
# no locale for it. A fixed one is kept as it is.
declare -A MAIN_LANGUAGE=(
  [BR]=pt [CN]=zh [TW]=zh [UA]=uk [IR]=fa [PE]=es [PK]=ur [NP]=ne [MM]=my
  [ET]=am [ER]=ti [KE]=sw [BE]=nl [CH]=de [LU]=fr [NO]=nb [AW]=nl [SN]=wo
)
resolve_time_locale() {
  [[ $TIME_LOCALE == auto ]] || return 0
  TIME_LOCALE=$LOCALE
  [[ -n $GEO_COUNTRY ]] || return 0
  local cc=$GEO_COUNTRY lang name
  local -a candidates=()
  mapfile -t candidates < <(sed -nE "s/^([a-z]{2,3}_${cc}(\.UTF-8)?) UTF-8\$/\1/p" /usr/share/i18n/SUPPORTED 2>/dev/null)
  (( ${#candidates[@]} )) || return 0
  for lang in ${MAIN_LANGUAGE[$cc]:-} "${cc,,}" en; do
    for name in "${candidates[@]}"; do
      [[ $name == "${lang}_${cc}" || $name == "${lang}_${cc}.UTF-8" ]] && { TIME_LOCALE=$name; return 0; }
    done
  done
  TIME_LOCALE=${candidates[0]}
}

# Prints the countries to rank mirrors in: MIRROR_COUNTRIES, or with auto
# the one geolocate found, or nothing if it found none.
mirror_countries() {
  if [[ $MIRROR_COUNTRIES != auto ]]; then
    echo "$MIRROR_COUNTRIES"
  elif [[ -n $GEO_COUNTRY ]]; then
    echo "$GEO_COUNTRY"
  fi
  return 0
}
