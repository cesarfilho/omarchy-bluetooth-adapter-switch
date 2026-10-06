#!/usr/bin/env bash
# Tests for the pure logic in bt-adapter.sh: the JSON the widget reads and the
# way BlueZ errors are turned into messages. rfkill, busctl and sysfs are
# replaced by stubs, so it runs anywhere with bash and jq:
#
#   tests/test.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
XDG_STATE_HOME=$(mktemp -d)
XDG_CACHE_HOME=$(mktemp -d)
export XDG_STATE_HOME XDG_CACHE_HOME
trap 'rm -rf "$XDG_STATE_HOME" "$XDG_CACHE_HOME"' EXIT

# shellcheck source=bt-adapter.sh disable=SC1091
source ./bt-adapter.sh
set +e

pass=0 failed=0
check() { # <name> <expected> <actual>
  if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else
    failed=$((failed + 1)); echo "FAIL: $1"$'\n'"  expected: $2"$'\n'"  actual:   $3"
  fi
}

# ---- stubs --------------------------------------------------------------

BUSCTL_OUT="" BUSCTL_RC=0
rfkill() {
  case $* in
    *DEVICE,TYPE,SOFT*) echo '{"rfkilldevices":[{"device":"hci0","type":"bluetooth","soft":"unblocked"},{"device":"hci1","type":"bluetooth","soft":"blocked"},{"device":"phy0","type":"wlan","soft":"unblocked"}]}' ;;
    *DEVICE,TYPE*)      echo '{"rfkilldevices":[{"device":"hci1","type":"bluetooth"},{"device":"hci0","type":"bluetooth"},{"device":"phy0","type":"wlan"}]}' ;;
  esac
}
INFO_COUNT=$XDG_CACHE_HOME/reads
adapter_key() { echo "/sys/fake/$1"; }
adapter_info_read() { echo x >>"$INFO_COUNT"; case $1 in hci0) printf 'onboard\tIntel AX200\n' ;; *) printf 'usb\tASUS USB-BT500\n' ;; esac; }
busctl() { printf '%s\n' "$BUSCTL_OUT"; return "$BUSCTL_RC"; }
timeout() { shift; "$@"; }
pactl() { echo '[{"name":"bluez_card.11_22_33_44_55_66","active_profile":"a2dp-sink","profiles":{"a2dp-sink":{},"headset-head-unit":{},"off":{}}}]'; }

# ---- json ---------------------------------------------------------------

BUSCTL_OUT='{"type":"a{oa{sa{sv}}}","data":[{
 "/org/bluez/hci0":{"org.bluez.Adapter1":{"Address":{"type":"s","data":"AA:AA:AA:AA:AA:01"},"Alias":{"type":"s","data":"laptop"},"Powered":{"type":"b","data":true}}},
 "/org/bluez/hci1":{"org.bluez.Adapter1":{"Address":{"type":"s","data":"BB:BB:BB:BB:BB:02"},"Alias":{"type":"s","data":"dongle"},"Powered":{"type":"b","data":false}}},
 "/org/bluez/hci0/dev_11_22_33_44_55_66":{"org.bluez.Device1":{"Address":{"type":"s","data":"11:22:33:44:55:66"},"Alias":{"type":"s","data":"Headset"},"Adapter":{"type":"o","data":"/org/bluez/hci0"},"Paired":{"type":"b","data":true},"Connected":{"type":"b","data":true},"Icon":{"type":"s","data":"audio-headset"},"UUIDs":{"type":"as","data":[]}},"org.bluez.Battery1":{"Percentage":{"type":"y","data":80}}},
 "/org/bluez/hci0/dev_AA_00_00_00_00_01":{"org.bluez.Device1":{"Address":{"type":"s","data":"AA:00:00:00:00:01"},"Alias":{"type":"s","data":"Speaker"},"Adapter":{"type":"o","data":"/org/bluez/hci0"},"Paired":{"type":"b","data":false},"RSSI":{"type":"n","data":-50},"Class":{"type":"u","data":1}}},
 "/org/bluez/hci0/dev_AA_00_00_00_00_02":{"org.bluez.Device1":{"Address":{"type":"s","data":"AA:00:00:00:00:02"},"Alias":{"type":"s","data":"Beacon"},"Adapter":{"type":"o","data":"/org/bluez/hci0"},"Paired":{"type":"b","data":false},"RSSI":{"type":"n","data":-40}}}
}]}'
out=$(json)

check "adapters in hciN order"   'hci0 hci1'        "$(jq -r '[.[].hci] | join(" ")' <<<"$out")"
check "kind and model"           'onboard|Intel AX200|usb' "$(jq -r '"\(.[0].kind)|\(.[0].model)|\(.[1].kind)"' <<<"$out")"
check "powered and blocked"      'true false|false true'   "$(jq -r '"\(.[0].powered) \(.[0].blocked)|\(.[1].powered) \(.[1].blocked)"' <<<"$out")"
check "paired device + battery"  'Headset true 80 true'    "$(jq -r '.[0].devices[0] | "\(.name) \(.connected) \(.battery) \(.hasProfile)"' <<<"$out")"
check "headset profile from the audio card" 'a2dp true' "$(jq -r '.[0].devices[0] | "\(.profile) \(.canProfile)"' <<<"$out")"
check "no devices on hci1"       '0'                       "$(jq -r '.[1].devices | length' <<<"$out")"
check "nearby sorted, profile first" 'Speaker Beacon'      "$(jq -r '[.[0].nearby[].name] | join(" ")' <<<"$out")"
check "wlan device is ignored"   '2'                       "$(jq -r 'length' <<<"$out")"

BUSCTL_OUT='' BUSCTL_RC=1
check "BlueZ down: still valid JSON" '2 false' "$(json | jq -r '"\(length) \(.[0].powered)"')"

# ---- adapter_info cache -------------------------------------------------

rm -rf "$XDG_CACHE_HOME"/omarchy-bluetooth-adapter-switch "$INFO_COUNT"
reads() { wc -l <"$INFO_COUNT" | tr -d ' '; }
adapter_info hci0 >/dev/null; adapter_info hci0 >/dev/null
check "info is read once, then cached"  '1'      "$(reads)"
check "cached value is intact"          $'onboard\tIntel AX200' "$(adapter_info hci0)"
adapter_key() { echo "/sys/fake/other-port/$1"; }
adapter_info hci0 >/dev/null
check "a different sysfs path re-reads" '2'      "$(reads)"

# ---- log ---------------------------------------------------------------

log INFO "test entry"
check "log file is owner-only"  '600 700' "$(stat -c %a "$LOG") $(stat -c %a "$STATE_DIR")"

# ---- dev_call: BlueZ error -> readable message --------------------------

reason() { # <busctl error text> -> message dev_call prints
  BUSCTL_OUT=$1 BUSCTL_RC=1
  dev_call /org/bluez/hci0/dev_X Connect 5 2>&1
}
check "in progress"  "another attempt is still running; wait a few seconds and try again" "$(reason 'Call failed: In Progress')"
check "page timeout" "the device is out of range or switched off"                         "$(reason 'Call failed: Page Timeout')"
check "not found"    "device not found on this adapter (scan and pair it first)"         "$(reason "Call failed: Method \"Connect\" doesn't exist")"
check "silent failure explains itself" "no response from the device. Turn it on, bring it close and make sure no other device is connected to it" "$(reason '')"
check "unknown text passes through" "Something odd" "$(reason 'Call failed: Something odd')"

# ---- remembered devices -------------------------------------------------

BUSCTL_OUT='{"type":"s","data":"AA:AA:AA:AA:AA:01"}' BUSCTL_RC=0
remember_connected hci0 11:22:33:44:55:66
remember_connected hci0 aa:bb:cc:dd:ee:ff
remember_connected hci0 11:22:33:44:55:66
check "last lists each device once, newest last" '11:22:33:44:55:66' "$(state_get | jq -r '.last[-1]')"
check "last has two devices"                     '2'                 "$(state_get | jq -r '.last | length')"
check "adapter is remembered by address"         'AA:AA:AA:AA:AA:01' "$(state_get | jq -r '.lastAdapter')"
forget_wanted 11:22:33:44:55:66
check "disconnect stops the reconnect"           'AA:BB:CC:DD:EE:FF' "$(state_get | jq -r '.last | join(",")')"
forget_wanted AA:BB:CC:DD:EE:FF drop
check "forget drops the device entry"            'null'              "$(state_get | jq -c '.devices["AA:BB:CC:DD:EE:FF"]')"
check "profiles file is owner-only"              '600'               "$(stat -c %a "$PROFILES")"
rm -f "$PROFILES"
check "no state yet is an empty object"          '{}'                "$(state_get)"

adapters() { printf 'hci0\nhci1\n'; }
prop() { [[ $2 == Address ]] && { [[ $1 == hci0 ]] && echo AA:AA:AA:AA:AA:01 || echo BB:BB:BB:BB:BB:02; }; }
check "last, nothing remembered: falls back to usb" 'hci1' "$(preferred last)"
state_set '.lastAdapter = "AA:AA:AA:AA:AA:01"'
check "last follows the remembered adapter"        'hci0' "$(preferred last)"
state_set '.lastAdapter = "CC:CC:CC:CC:CC:09"'
check "last, adapter gone: falls back to usb"      'hci1' "$(preferred last)"

# ---- diagnostics privacy ------------------------------------------------

check "addresses are masked" 'device F4:9D:8A:XX:XX:XX / dev_F4_9D_8A_XX:XX:XX' \
  "$(echo 'device F4:9D:8A:98:E3:B2 / dev_F4_9D_8A_98_E3_B2' | mask_addresses)"

echo "$pass passed, $failed failed"
(( failed == 0 ))
