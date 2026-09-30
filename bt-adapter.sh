#!/usr/bin/env bash
# Bluetooth adapter helper for the Omarchy "Bluetooth Adapter Switch" plugin.
#
#   bt-adapter.sh status        one line per adapter: hciN|ADDRESS|ALIAS|powered|blocked
#   bt-adapter.sh json          JSON array with everything the widget shows: kind
#                               (onboard|usb|other), model, paired devices, ...
#   bt-adapter.sh use <hciN>    make <hciN> the only powered adapter
#   bt-adapter.sh next          make the next adapter (in hciN order) the active one
#   bt-adapter.sh all-on        unblock and power on every adapter
#
# Runs entirely with the logged-in user's own permissions: rfkill is writable
# through the logind ACL on /dev/rfkill, and BlueZ accepts property writes from
# an active session. Nothing here needs elevated rights.
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

# Where the adapter is attached: "onboard" (soldered USB/PCIe chip), "usb" (a
# removable dongle) or "other". Read from sysfs, so it needs no privileges.
adapter_info() { # <hci> -> kind<TAB>model
  local dev usb kind=other removable vendor model props
  dev=$(readlink -f "/sys/class/bluetooth/$1/device" 2>/dev/null) || return 0
  usb=$dev
  while [[ -n $usb && $usb != / && ! -f $usb/idVendor ]]; do usb=$(dirname "$usb"); done
  if [[ -f $usb/idVendor ]]; then
    read -r removable < "$usb/removable" 2>/dev/null || removable=unknown
    case $removable in
      fixed) kind=onboard ;;
      removable) kind=usb ;;
    esac
    props=$(udevadm info -q property -p "$usb" 2>/dev/null)
    vendor=$(sed -n 's/^ID_VENDOR_FROM_DATABASE=//p' <<<"$props" | awk '{print $1}')
    model=$(sed -n 's/^ID_MODEL_FROM_DATABASE=//p' <<<"$props")
    [[ -n $model ]] || model=$(sed -n 's/^ID_MODEL=//p' <<<"$props" | tr '_' ' ')
    [[ -n $vendor && $model != "$vendor"* ]] && model="$vendor $model"
  elif [[ $dev == */platform/* || $dev == */serial* ]]; then
    kind=onboard
  fi
  printf '%s\t%s\n' "$kind" "$model"
}

json() {
  local managed rf hci info kind model rows=""
  managed=$(busctl --system --json=short call "$BLUEZ" / org.freedesktop.DBus.ObjectManager GetManagedObjects 2>/dev/null) ||
    managed='{"data":[{}]}'
  rf=$(rfkill -J -o DEVICE,TYPE,SOFT 2>/dev/null) || rf='{}'
  for hci in $(adapters); do
    info=$(adapter_info "$hci")
    kind=${info%%$'\t'*}
    model=${info#*$'\t'}
    rows+="$hci"$'\t'"$kind"$'\t'"$model"$'\n'
  done
  jq -n --argjson bz "$managed" --argjson rf "$rf" --arg rows "$rows" '
    ($bz.data[0] // {}) as $o
    | [ $rows | split("\n")[] | select(length > 0) | split("\t")
        | { hci: .[0], kind: .[1], model: (.[2] // "") } as $s
        | ($o["/org/bluez/" + $s.hci]["org.bluez.Adapter1"] // {}) as $a
        | $s + {
            address: ($a.Address.data // ""),
            alias:   ($a.Alias.data // $s.hci),
            powered: ($a.Powered.data // false),
            blocked: ([$rf.rfkilldevices[]? | select(.device == $s.hci and .soft == "blocked")] | length > 0),
            devices: [ $o | to_entries[]
                       | .value["org.bluez.Device1"]? // empty
                       | select(.Adapter.data == "/org/bluez/" + $s.hci and .Paired.data == true)
                       | { name: (.Alias.data // .Address.data), connected: (.Connected.data // false) } ]
          } ]'
}

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
  # After an rfkill unblock BlueZ needs a moment before it accepts Powered, so
  # retry instead of trusting a single attempt.
  rf unblock "$target"
  local up=0
  for _ in {1..25}; do
    if [[ -n $(prop "$target" Address) ]] && set_powered "$target" true; then up=1; break; fi
    sleep 0.2
  done
  # Never turn the others off if the target did not come up.
  if (( ! up )); then
    echo "could not power on $target" >&2
    exit 1
  fi
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
  local hci failed=0
  for hci in $(adapters); do
    rf unblock "$hci"
    set_powered "$hci" true || { echo "could not power on $hci" >&2; failed=1; }
  done
  return $failed
}

case ${1:-status} in
  status) status ;;
  json) json ;;
  use) use "${2:?usage: bt-adapter.sh use <hciN>}" ;;
  next) next ;;
  all-on) all_on ;;
  *) echo "usage: bt-adapter.sh status|json|use <hciN>|next|all-on" >&2; exit 64 ;;
esac
