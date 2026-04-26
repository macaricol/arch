#!/usr/bin/env bash
# utils.sh - Helper functions for Arch installer

# Default configuration (can be overridden before sourcing)
VERBOSE=${VERBOSE:-1}

run() { ((VERBOSE)) && "$@" || "$@" &>/dev/null; }
die() { printf '\e[91;1m[ Ω ] %b\e[0m\n' "$*" >&2; exit 1; }
info() { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m\n\n' "$*"; }
box() {
  local t=" $1 " w=${2:-70} c=${3:-Ω}
  local line=$(printf '%*s' "$w" '' | tr ' ' "$c")
  local pad=$(( (w - 2 - ${#t}) / 2 ))
  local side=$(printf '%*s' "$pad" '' | tr ' ' "$c")
  local rest=$(printf '%*s' "$((w - 2 - ${#t} - pad))" '' | tr ' ' "$c")

  printf '\n\e[35m%s\n%s\e[36m%s\e[35m%s\e[0m\n\e[35m%s\e[0m\n\n' \
    "$line" "$c$side" "$t" "$rest$c" "$line"
}

# ── INPUT & VALIDATION ────────────────────────────────────────────────
ask() { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m ' "$1"; }
valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && (( ${#1} <= 63 )); }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_password() { (( ${#1} >= 6 )); }

input() {
  local prompt=$1 var=$2 secure=${3:-no} validator=${4:-}
  while :; do
    ask "$prompt"
    if [[ $secure == yes ]]; then read -rs val; echo; else read -r val; fi
    val="${val##+([[:space:]])}"; val="${val%%+([[:space:]])}"
    [[ -n $validator && -z $val ]] && { echo -e '\e[93m[ Ω ] Cannot be empty\e[0m'; continue; }
    [[ -n $validator ]] && ! "$validator" "$val" && { echo -e '\e[93m[ Ω ] Invalid\e[0m'; continue; }
    printf -v "$var" '%s' "$val"
    return 0
  done
}
