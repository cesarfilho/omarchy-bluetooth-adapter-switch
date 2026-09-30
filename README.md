# Bluetooth Adapter Switch

An [Omarchy](https://omarchy.org/) bar widget for machines with more than one
Bluetooth adapter, typically the onboard chip plus a USB dongle. It shows which
adapter is active and switches between them from a small panel.

![Bluetooth Adapter Switch panel](preview.png)

The bar label says what is active: `USB`, `Onboard`, `all` when several adapters
are on, or `off` when none is. Left click opens a panel that lists every adapter
with what it is (onboard chip or USB dongle), its model, which one is active and
what is paired to it.

| Action | Result |
|---|---|
| Left click | Open the panel (or switch straight to the next adapter, see settings) |
| Scroll / middle click | Switch to the next adapter |
| Right click | Turn every adapter on |
| Hover | Tooltip with every adapter and its state |

In the panel: Up/Down or `j`/`k` move, Enter selects, `1`-`9` pick an adapter,
`A` turns everything on, `R` refreshes, Esc closes. Hovering a row that would
turn off an adapter with connected devices is the moment to check what will
disconnect.

With a single adapter the widget is dimmed and there is nothing to switch.

## How it works

Switching to an adapter powers it on and soft-blocks every other Bluetooth
adapter with `rfkill`. Everything runs with your own user's permissions:
`/dev/rfkill` is writable by the logged-in user through the logind ACL, and BlueZ
accepts `Powered` changes from an active session. The plugin needs no elevated
rights, installs no system files and does not touch anything outside its own
directory.

Because the block is an rfkill soft block, `systemd-rfkill` restores it at boot,
so your choice survives a reboot. The target adapter is powered on first and the
others are only turned off once it is up, so a failed switch never leaves you
with no adapter.

Adapter type comes from sysfs: a USB device flagged `fixed` is reported as
onboard, a `removable` one as a USB dongle.

The logic lives in [`bt-adapter.sh`](bt-adapter.sh) (`status`, `json`,
`use <hciN>`, `next`, `all-on`), which you can also run by hand.

## Install

```bash
omarchy plugin add https://github.com/cesarfilho/omarchy-bluetooth-adapter-switch.git --enable
```

Or by hand: clone this repository into
`~/.config/omarchy/plugins/io.github.cesarfilho.bluetooth-adapter-switch/`,
then run `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable io.github.cesarfilho.bluetooth-adapter-switch`.

Move it with
`omarchy bar move io.github.cesarfilho.bluetooth-adapter-switch --section left`.
After updating the plugin's code, run `omarchy restart shell` if the bar still
shows the old behaviour, since a running bar widget is not always replaced by the
hot reload.

## Remove

```bash
omarchy plugin remove io.github.cesarfilho.bluetooth-adapter-switch
```

If an adapter is still blocked, turn everything back on first (right-click the
widget, or `rfkill unblock bluetooth`).

## Settings

Set in the widget's entry in `~/.config/omarchy/shell.json`, or from the
Omarchy settings panel:

| Key | Default | Meaning |
|---|---|---|
| `showLabel` | `true` | Show the adapter name next to the icon |
| `labelMode` | `Type` | `Type` shows USB or Onboard, `Adapter id` shows hci0, hci1 |
| `clickAction` | `Open panel` | `Open panel` or `Switch to next` on left click |
| `notify` | `true` | Desktop notification after switching |
| `refreshIntervalSec` | `10` | How often the state is re-read (2 to 120) |

## Things to know

- **Paired devices belong to one adapter.** Each adapter keeps its own pairings,
  so pair your devices again after switching. Switching away from an adapter
  disconnects whatever is connected to it.
- **The stock Bluetooth widget can lag behind.** Quickshell's
  `Bluetooth.defaultAdapter`, which `omarchy.bluetooth` uses, does not follow this
  switch. If the onboard adapter is the one you blocked, the stock widget may
  show "Turned off" while your dongle works fine. This widget always shows the
  real state.
- If the onboard adapter should never come back, de-authorizing its USB port
  with a udev rule is the permanent option. That needs administrator rights and
  is deliberately not automated here.

## Dependencies

All are present on a standard Omarchy install: `bluez` (BlueZ over D-Bus),
`util-linux` (`rfkill`), `systemd` (`busctl`, `udevadm`), `jq`, `libnotify`
(`notify-send`, only for the optional notification) and `bash`.

## License

[MIT](LICENSE)
