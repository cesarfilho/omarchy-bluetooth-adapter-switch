#!/usr/bin/env bash
# Bluetooth adapter helper for the Omarchy "Bluetooth Adapter Switch" plugin.
#
#   bt-adapter.sh status        one line per adapter: hciN|ADDRESS|ALIAS|powered|blocked
#   bt-adapter.sh json          JSON array with everything the widget shows: kind
#                               (onboard|usb|other), model, paired devices, ...
#   bt-adapter.sh use <hciN>    make <hciN> the only powered adapter
#   bt-adapter.sh next          make the next adapter (in hciN order) the active one
#   bt-adapter.sh auto [pref]   make the preferred adapter the only active one
#   bt-adapter.sh ensure [pref] like auto, but only when zero or several are active
#   bt-adapter.sh watch         print a line whenever a Bluetooth adapter is added,
#                               removed or changes state (plug/unplug detection)
#   bt-adapter.sh forget <hciN> <ADDRESS>
#                               unpair a device from the adapter it is paired to
#   bt-adapter.sh connect|disconnect <hciN> <ADDRESS>
#   bt-adapter.sh pair <hciN> <ADDRESS>   pair, trust and connect a new device
#   bt-adapter.sh audio <ADDRESS>         make that device the default audio output
#   bt-adapter.sh log [lines]   show the end of the plugin log (see "Logging" below)
#   bt-adapter.sh scan <hciN> [seconds] [bredr|le|auto]
#                               look for devices on one adapter until the process
#                               is stopped (default 45 s, classic BR/EDR only)
#
# Exactly one adapter is active at a time. [pref] is "usb" (default: a removable
# dongle wins over the onboard chip, and the onboard chip is used when the dongle
# is gone) or "onboard".
#
# Runs entirely with the logged-in user's own permissions: rfkill is writable
# through the logind ACL on /dev/rfkill, and BlueZ accepts property writes from
# an active session. Nothing here needs elevated rights.
set -u

BLUEZ=org.bluez

# Logging. Every action (switch, connect, pair, forget, scan, ...) is recorded
# with its outcome in $LOG, and a failure also writes a snapshot of the adapters,
# rfkill, the device involved and the latest bluetoothd messages, so a problem
# can be diagnosed after the error has left the screen. Polling (status/json) is
# not logged. The file rotates at 256 KB, keeping one previous copy.
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-bluetooth-adapter-switch
LOG=$STATE_DIR/plugin.log

log() { # <LEVEL> <message...>
  local level=$1; shift
  # The log holds device addresses and bluetoothd output: owner-only.
  (umask 077; mkdir -p "$STATE_DIR" 2>/dev/null) || return 0
  if [[ -f $LOG ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 262144 )); then
    mv -f "$LOG" "$LOG.1" 2>/dev/null
  fi
  (umask 077; printf '%s %-5s [%s] %s\n' "$(date '+%F %T')" "$level" "$$" "$*" >>"$LOG") 2>/dev/null
  return 0
}

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
adapter_key() { # <hci> -> "sysfs path|vendor:product"; changes when another adapter takes the name
  local dev usb ids=""
  dev=$(readlink -f "/sys/class/bluetooth/$1/device" 2>/dev/null) || return 0
  [[ -n $dev ]] || return 0
  usb=$dev
  while [[ -n $usb && $usb != / && ! -f $usb/idVendor ]]; do usb=$(dirname "$usb"); done
  [[ -f $usb/idVendor ]] && ids=$(cat "$usb/idVendor" "$usb/idProduct" 2>/dev/null | paste -sd:)
  printf '%s|%s\n' "$dev" "$ids"
}

# What an adapter is never changes while it stays plugged in, but working it out
# costs udevadm, sed and awk, and the widget polls every few seconds. The answer
# is cached per hciN, keyed by sysfs path plus USB vendor:product, so a replug into another port or
# a different dongle under the same name is looked up again.
adapter_info() { # <hci> -> kind<TAB>model
  local key cache=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-bluetooth-adapter-switch/info-$1 cached info
  key=$(adapter_key "$1")
  if [[ -n $key && -r $cache ]]; then
    { read -r cached; IFS= read -r info; } <"$cache"
    [[ $cached == "$key" && -n $info ]] && { printf '%s\n' "$info"; return 0; }
  fi
  info=$(adapter_info_read "$1")
  if [[ -n $key && -n $info ]]; then
    mkdir -p "${cache%/*}" 2>/dev/null && printf '%s\n%s\n' "$key" "$info" >"$cache" 2>/dev/null
  fi
  printf '%s\n' "$info"
}

adapter_info_read() { # <hci> -> kind<TAB>model, straight from sysfs/udev
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
                       | select(.value["org.bluez.Device1"] != null)
                       | .value as $v | $v["org.bluez.Device1"] as $d
                       | select($d.Adapter.data == "/org/bluez/" + $s.hci and $d.Paired.data == true)
                       | { address: $d.Address.data, name: ($d.Alias.data // $d.Address.data),
                           connected: ($d.Connected.data // false),
                           battery: ($v["org.bluez.Battery1"].Percentage.data // null),
                           hasProfile: ($d.Icon != null or $d.Class != null
                                        or ([$d.UUIDs.data[]? | select(test("^0000(110b|111e|110e|1124|1812)-"))] | length > 0)) } ],
            nearby: [ $o | to_entries[]
                      | .value["org.bluez.Device1"]? // empty
                      | select(.Adapter.data == "/org/bluez/" + $s.hci and (.Paired.data // false) == false and .RSSI != null)
                      | { address: .Address.data, name: (.Alias.data // .Address.data), rssi: .RSSI.data,
                          hasProfile: (.Icon != null or .Class != null) } ]
                    | sort_by([(if .hasProfile then 0 else 1 end), -.rssi])
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
  local list current hci i pick=""
  mapfile -t list < <(adapters)
  (( ${#list[@]} > 1 )) || { echo "only one adapter present" >&2; exit 3; }
  current=$(active)
  for i in "${!list[@]}"; do
    [[ ${list[i]} == "$current" ]] && { pick=${list[(i + 1) % ${#list[@]}]}; break; }
  done
  use "${pick:-${list[0]}}"
}

# The adapter that should be active: the preferred kind if present, otherwise
# the first adapter there is.
preferred() { # [usb|onboard] -> hciN
  local want=${1:-usb} hci first="" info
  for hci in $(adapters); do
    [[ -n $first ]] || first=$hci
    info=$(adapter_info "$hci")
    [[ ${info%%$'\t'*} == "$want" ]] && { echo "$hci"; return; }
  done
  echo "$first"
}

active_count() {
  local hci n=0
  for hci in $(adapters); do
    is_blocked "$hci" && continue
    [[ $(prop "$hci" Powered) == true ]] && n=$((n + 1))
  done
  echo "$n"
}

auto() {
  local pick
  pick=$(preferred "${1:-usb}")
  [[ -n $pick ]] || return 0
  use "$pick"
}

ensure() {
  [[ $(active_count) == 1 ]] || auto "${1:-usb}"
}

# One line per Bluetooth rfkill event (add/remove/change). rfkill runs as a
# coprocess that is killed with us: in a plain pipeline it would outlive a
# killed shell until the next event made it hit a closed pipe.
watch() {
  local line
  coproc RF { exec rfkill event 2>/dev/null 3>&-; }
  trap 'kill "$RF_PID" 2>/dev/null; exit 0' TERM INT
  while read -r line <&"${RF[0]}"; do
    [[ $line == *" type 2 "* ]] && echo event
  done
}

# Unpair a device on the adapter that owns it. `bluetoothctl remove` only acts
# on the default controller, so a device paired to the other adapter could not
# be forgotten that way; BlueZ's own RemoveDevice takes the adapter explicitly.
forget() { # <hci> <address>
  local hci=$1 addr=${2^^} path err
  valid_adapter "$hci" || { echo "unknown adapter: $hci" >&2; exit 2; }
  [[ $addr =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || { echo "invalid address: $2" >&2; exit 2; }
  path="/org/bluez/$hci/dev_${addr//:/_}"
  # Drop the link first; a device that is not connected just refuses, which is fine.
  timeout 10 busctl --system call "$BLUEZ" "$path" org.bluez.Device1 Disconnect >/dev/null 2>&1 || true
  if ! err=$(busctl --system call "$BLUEZ" "/org/bluez/$hci" org.bluez.Adapter1 RemoveDevice o "$path" 2>&1); then
    echo "could not forget $addr on $hci: ${err#Call failed: }" >&2
    exit 1
  fi
}

dev_path() { # <hci> <address> -> BlueZ object path, validating both
  valid_adapter "$1" || { echo "unknown adapter: $1" >&2; exit 2; }
  local addr=${2^^}
  [[ $addr =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || { echo "invalid address: $2" >&2; exit 2; }
  printf '/org/bluez/%s/dev_%s' "$1" "${addr//:/_}"
}

dev_call() { # <path> <method> <timeout> -> runs the call, prints a readable reason on failure
  local err
  if ! err=$(timeout "$3" busctl --system call "$BLUEZ" "$1" org.bluez.Device1 "$2" 2>&1); then
    err=${err#Call failed: }
    case $err in
      "")                                   err="no response from the device. Turn it on, bring it close and make sure no other device is connected to it" ;;
      *"doesn't exist"*|*"Does Not Exist"*) err="device not found on this adapter (scan and pair it first)" ;;
      *InProgress*|*"In Progress"*)         err="another attempt is still running; wait a few seconds and try again" ;;
      *"Page Timeout"*|*"Host is down"*|*"host is down"*) err="the device is out of range or switched off" ;;
      *AlreadyConnected*)                   return 0 ;;
    esac
    echo "$err" >&2
    return 1
  fi
}

adapter_on() { # <hci>
  [[ $(prop "$1" Powered) == true ]] || { echo "$1 is off; switch to it first" >&2; exit 1; }
}

# A pairing made over Low Energy has only generic GATT services. For a headset
# that means no audio profile, so connecting cannot work: say so.
le_only_hint() { # <path>
  local uuids
  uuids=$(busctl --system get-property "$BLUEZ" "$1" org.bluez.Device1 UUIDs 2>/dev/null) || return 0
  [[ -n $uuids ]] || return 0
  case $uuids in
    *0000110b-*|*0000111e-*|*0000110e-*|*00001124-*|*00001812-*) ;;
    *) echo "This pairing only has Bluetooth Low Energy services (no audio or input profile). Forget it and pair again with a classic scan." >&2 ;;
  esac
}

# Make a connected device the default audio output and move what is playing to
# it. Connecting alone leaves the sound on the speakers: the Bluetooth sink only
# shows up a moment after the link, and nothing selects it.
audio_output() { # <address>
  local addr=${1^^} want name id i
  want="bluez_output.${addr//:/_}"
  for i in {1..20}; do
    name=$(pactl list short sinks 2>/dev/null | awk -v w="$want" 'index($2, w) == 1 { print $2; exit }')
    [[ -n $name ]] && break
    sleep 0.4
  done
  if [[ -z $name ]]; then
    log WARN "audio: no sink appeared for $addr (is the headset on the audio profile?)"
    return 1
  fi
  id=$(pactl list sinks 2>/dev/null | awk -v n="$name" '$1 == "Name:" { cur = $2 } /object.id =/ { if (cur == n) { gsub(/"/, "", $3); print $3; exit } }')
  if command -v omarchy-audio-output-set-default >/dev/null && [[ -n $id ]]; then
    omarchy-audio-output-set-default "$id" "$name"
  else
    pactl set-default-sink "$name" 2>/dev/null
    pactl list short sink-inputs 2>/dev/null | awk '{ print $1 }' |
      while read -r i; do pactl move-sink-input "$i" "$name" 2>/dev/null || true; done
  fi
  log INFO "audio: default output -> $name"
}

connect() { # <hci> <address>
  local p; p=$(dev_path "$1" "$2") || exit $?
  adapter_on "$1"
  if ! dev_call "$p" Connect 15; then
    # A Connect that never answered keeps running inside BlueZ and makes the
    # next attempt fail with InProgress; Disconnect cancels it.
    timeout 5 busctl --system call "$BLUEZ" "$p" org.bluez.Device1 Disconnect >/dev/null 2>&1 || true
    le_only_hint "$p"
    exit 1
  fi
  audio_output "$2" || true
}

disconnect() { # <hci> <address>
  local p; p=$(dev_path "$1" "$2") || exit $?
  dev_call "$p" Disconnect 10 || exit 1
}

pair() { # <hci> <address>   exit 4 = paired, but the first connect failed
  local p cerr; p=$(dev_path "$1" "$2") || exit $?
  adapter_on "$1"
  if ! busctl --system get-property "$BLUEZ" "$p" org.bluez.Device1 Address >/dev/null 2>&1; then
    echo "the device is no longer visible. Put it in pairing mode (headsets: hold the button until the light flashes) and scan again" >&2
    exit 1
  fi
  dev_call "$p" Pair 40 || exit 1
  # Trusted lets the device reconnect by itself next time.
  busctl --system set-property "$BLUEZ" "$p" org.bluez.Device1 Trusted b true >/dev/null 2>&1 || true
  if ! cerr=$(dev_call "$p" Connect 15 2>&1); then
    echo "Paired, but could not connect: $cerr" >&2
    exit 4
  fi
  audio_output "$2" || true
}

# Device discovery only lasts while the process that asked for it is alive, so
# this keeps a bluetoothctl session open on the chosen adapter and closes it
# when told to stop (or after <seconds>).
# Transport matters: earbuds and speakers that advertise over Low Energy get
# paired as LE-only entries with no audio profile, which can never carry sound.
# Searching over classic BR/EDR finds the audio identity of the same device.
scan() { # <hci> [seconds] [bredr|le|auto]
  local hci=$1 secs=${2:-45} transport=${3:-bredr} addr
  valid_adapter "$hci" || { echo "unknown adapter: $hci" >&2; exit 2; }
  adapter_on "$hci"
  addr=$(prop "$hci" Address)
  coproc BT { exec bluetoothctl >/dev/null 2>&1 3>&-; }
  local fd=${BT[1]}
  # Never `kill 0`: with no sleeper yet that signals the whole process group,
  # which is the shell that launched us.
  stop() { { printf 'scan off\nquit\n' 1>&"$fd"; } 2>/dev/null; [[ -n ${sleeper:-} ]] && kill "$sleeper" 2>/dev/null; return 0; }
  trap 'stop; wait "$BT_PID" 2>/dev/null; exit 0' TERM INT
  case $transport in bredr|le|auto) ;; *) transport=bredr ;; esac
  printf 'select %s\nmenu scan\ntransport %s\nback\nscan on\n' "$addr" "$transport" >&"$fd"
  sleep "$secs" & sleeper=$!
  wait "$sleeper"
  stop
  wait "$BT_PID" 2>/dev/null
}

# Snapshot written to the log when an action fails.
diagnose() { # <the failed command line...>
  local p addr pr l
  log DIAG "rfkill: $(rfkill -J -o ID,DEVICE,SOFT,HARD 2>/dev/null | jq -c '.rfkilldevices' 2>/dev/null)"
  log DIAG "adapters: $(json 2>/dev/null | jq -c '[.[] | {hci, kind, powered, blocked, paired: (.devices | length)}]' 2>/dev/null)"
  if [[ ${2:-} =~ ^hci[0-9]+$ && ${3:-} =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    addr=${3^^}
    p=/org/bluez/$2/dev_${addr//:/_}
    if ! busctl --system get-property "$BLUEZ" "$p" org.bluez.Device1 Address >/dev/null 2>&1; then
      log DIAG "device $addr is not known to BlueZ on ${2} (not paired and not seen recently)"
    else
      for pr in Paired Bonded Trusted Connected Blocked ServicesResolved AddressType Icon Class RSSI UUIDs; do
        log DIAG "device $addr $pr: $(busctl --system get-property "$BLUEZ" "$p" org.bluez.Device1 "$pr" 2>&1 | cut -c1-240)"
      done
    fi
  fi
  journalctl -u bluetooth --since "-2min" --no-pager -q 2>/dev/null | grep -v adv_monitor | tail -12 |
    while IFS= read -r l; do log DIAG "bluetoothd: $l"; done
}

on_action_exit() {
  local rc=$? ms err
  trap - EXIT
  ms=$(( ($(date +%s%N) - ACTION_START_NS) / 1000000 ))
  err=$(tr '\n' ' ' <"$ACTION_ERRFILE" 2>/dev/null)
  cat "$ACTION_ERRFILE" >&3 2>/dev/null # hand the collected stderr to the caller
  rm -f "$ACTION_ERRFILE"
  if (( rc == 0 )); then
    log INFO "ok: $ACTION_ARGS (${ms}ms)${err:+ stderr: $err}"
  else
    log ERROR "failed rc=$rc after ${ms}ms: $ACTION_ARGS :: $err"
    diagnose "${ACTION_ARR[@]}" 2>/dev/null
  fi
}

# Sourced (by tests/test.sh) only to get the functions above.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

case ${1:-} in
  use|next|auto|ensure|forget|connect|disconnect|pair|scan|audio)
    ACTION_ARGS=$*
    ACTION_ARR=("$@")
    ACTION_START_NS=$(date +%s%N)
    ACTION_ERRFILE=$(mktemp)
    log INFO "run: $ACTION_ARGS"
    # stderr goes to a file while the action runs and is replayed to the real
    # stderr (fd 3) on exit, once the file is complete. Long-lived children
    # close fd 3 so they cannot hold the caller's pipe open. A SIGKILL skips the
    # EXIT trap, so the text is lost then; the log still has the "run:" line.
    exec 3>&2 2>>"$ACTION_ERRFILE"
    trap on_action_exit EXIT
    ;;
esac

case ${1:-status} in
  status) status ;;
  json) json ;;
  log) [[ -f $LOG ]] && tail -n "${2:-60}" "$LOG" || echo "no log yet: $LOG" ;;
  log-path) echo "$LOG" ;;
  use) use "${2:?usage: bt-adapter.sh use <hciN>}" ;;
  next) next ;;
  auto) auto "${2:-usb}" ;;
  ensure) ensure "${2:-usb}" ;;
  watch) watch ;;
  connect) connect "${2:?usage: bt-adapter.sh connect <hciN> <ADDRESS>}" "${3:?usage}" ;;
  disconnect) disconnect "${2:?usage: bt-adapter.sh disconnect <hciN> <ADDRESS>}" "${3:?usage}" ;;
  pair) pair "${2:?usage: bt-adapter.sh pair <hciN> <ADDRESS>}" "${3:?usage}" ;;
  audio) audio_output "${2:?usage: bt-adapter.sh audio <ADDRESS>}" || exit 1 ;;
  scan) scan "${2:?usage: bt-adapter.sh scan <hciN> [seconds] [bredr|le|auto]}" "${3:-45}" "${4:-bredr}" ;;
  forget) forget "${2:?usage: bt-adapter.sh forget <hciN> <ADDRESS>}" "${3:?usage: bt-adapter.sh forget <hciN> <ADDRESS>}" ;;
  *) echo "usage: bt-adapter.sh status|json|log|use <hciN>|next|auto|ensure|watch|forget|connect|disconnect|pair <hciN> <ADDRESS>|scan <hciN> [secs]|audio <ADDRESS>" >&2; exit 64 ;;
esac
