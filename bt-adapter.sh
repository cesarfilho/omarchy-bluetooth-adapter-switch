#!/usr/bin/env bash
# Bluetooth adapter helper for the Omarchy "Bluetooth Adapter Switch" plugin.
#
#   bt-adapter.sh status        one line per adapter: hciN|ADDRESS|ALIAS|powered|blocked
#   bt-adapter.sh use <hciN>    make <hciN> the only powered adapter
#   bt-adapter.sh next          make the next adapter (in hciN order) the active one
#   bt-adapter.sh all-on        unblock and power on every adapter
#
# Runs as the logged-in user: rfkill is writable through the logind ACL on
# /dev/rfkill, and BlueZ accepts property writes from an active session.
# No sudo, pkexec or udev rule is involved.
set -u

BLUEZ=org.bluez

adapters() {
  rfkill -J -o DEVICE,TYPE 2>/dev/null |
    jq -r '.rfkilldevices[] | select(.type == "bluetooth") | .device' | sort -V
}

prop() { # <hci> <property> -> raw value
  busctl --system --json=short get-property "$BLUEZ" "/org/bluez/$1" org.bluez.Adapter1 "$2" 2>/dev/null |
    jq -r '.data'
}

is_blocked() { # <hci>
  rfkill -J -o DEVICE,SOFT 2>/dev/null |
    jq -e --arg d "$1" '.rfkilldevices[] | select(.device == $d and .soft == "blocked")' >/dev/null
}

set_powered() { # <hci> <true|false>
  busctl --system set-property "$BLUEZ" "/org/bluez/$1" org.bluez.Adapter1 Powered b "$2" 2>/dev/null
}

rf_id() { # <hci> -> numeric rfkill id (the rfkill CLI does not take device names)
  rfkill -J -o ID,DEVICE 2>/dev/null |
    jq -r --arg d "$1" '.rfkilldevices[] | select(.device == $d) | .id'
}

rf() { # <block|unblock> <hci>
  local id
  id=$(rf_id "$2")
  [[ -n $id ]] && rfkill "$1" "$id"
}

valid_adapter() { adapters | grep -qx -- "$1"; }

status() {
  local hci
  for hci in $(adapters); do
    printf '%s|%s|%s|%s|%s\n' "$hci" "$(prop "$hci" Address)" "$(prop "$hci" Alias)" \
      "$(prop "$hci" Powered)" "$(is_blocked "$hci" && echo true || echo false)"
  done
}

use() {
  local target=$1 hci
  valid_adapter "$target" || { echo "unknown adapter: $target" >&2; exit 2; }
  # Bring the target up first so there is never a moment with no adapter.
  rf unblock "$target"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -n $(prop "$target" Address) ]] && break
    sleep 0.2
  done
  set_powered "$target" true
  for hci in $(adapters); do
    [[ $hci == "$target" ]] && continue
    set_powered "$hci" false
    rf block "$hci"
  done
}

active() { # first powered, unblocked adapter
  local hci
  for hci in $(adapters); do
    is_blocked "$hci" && continue
    [[ $(prop "$hci" Powered) == true ]] && { echo "$hci"; return; }
  done
}

next() {
  local list current hci pick=""
  mapfile -t list < <(adapters)
  (( ${#list[@]} > 1 )) || { echo "only one adapter present" >&2; exit 3; }
  current=$(active)
  for i in "${!list[@]}"; do
    [[ ${list[i]} == "$current" ]] && { pick=${list[(i + 1) % ${#list[@]}]}; break; }
  done
  use "${pick:-${list[0]}}"
}

all_on() {
  local hci
  for hci in $(adapters); do
    rf unblock "$hci"
    set_powered "$hci" true
  done
}

case ${1:-status} in
  status) status ;;
  use) use "${2:?usage: bt-adapter.sh use <hciN>}" ;;
  next) next ;;
  all-on) all_on ;;
  *) echo "usage: bt-adapter.sh status|use <hciN>|next|all-on" >&2; exit 64 ;;
esac
