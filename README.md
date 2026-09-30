# Bluetooth Adapter Switch

An [Omarchy](https://omarchy.org/) bar widget for machines with two Bluetooth
adapters, typically the onboard chip plus a USB dongle. **Exactly one adapter is
active at a time**, and the plugin switches on its own:

- plug the dongle in and it becomes the active adapter (the onboard one is turned off);
- unplug it and the onboard adapter comes back on;
- at login, if zero or several adapters are on, it settles on one.

Prefer the onboard chip instead? Set `preferred` to `Onboard` (see Settings). A
manual pick from the panel is kept until the adapters change again.

![Bluetooth Adapter Switch panel](preview.png)

Click the widget to open a panel that lists every adapter: what it is
(**Onboard** chip or **USB dongle**), its model, whether it is active, and what
is paired to it. Each adapter has a switch: turning one on makes it the only adapter in use, and turning the active one off hands over to the other. Pick with the mouse or the keyboard. Hovering an adapter
warns you which connected devices the switch would drop.

| Action | Result |
|---|---|
| Left click | Open the panel (or switch to the next adapter, see `clickAction`) |
| Scroll / middle click | Make the next adapter the only powered one |
| Right click | Go back to the automatic choice (the preferred adapter) |
| Hover | Lists every adapter with its type and state |

Every paired device is listed under its adapter, with its battery level when
the device reports one (low levels turn red, and connected devices' batteries
also show in the bar tooltip). Flip the device's switch (or click the line)
to connect or disconnect, and use the trash button, which appears when you point at the line, to forget
it: click once,
then again to confirm. All of these act on **that adapter**, which is why this
works for a device paired to both adapters or only to the dongle. The stock
Bluetooth widget talks to the default adapter only, so it cannot see or forget
what lives on the other one.

To add a new device, press the magnifier on the active adapter (or `S`). Named
devices in range show up under **Nearby**; the `+` button pairs, trusts and
connects. Scanning looks over classic Bluetooth by default (see `scanTransport`) and stops after 45 seconds, when you press it again, when you
switch adapter or when the panel closes.

Panel keys: `↑`/`↓` or `j`/`k` move, `Enter` selects, `1`-`9` pick an adapter
directly, `S` scans for new devices, `R` refreshes, `Esc` closes.

The bar label shows the active adapter (`USB`, `Onboard`) or `off` when none is. After a switch you get a desktop notification,
and a failed switch is shown in the panel instead of failing silently. With a
single adapter the widget is dimmed and does nothing.

## How it works

Switching to an adapter powers it on and soft-blocks every other Bluetooth
adapter with `rfkill`. Plug and unplug are noticed through `rfkill event`, which
the plugin reads as your own user. Everything runs with your own user's
permissions: `/dev/rfkill` is writable by the logged-in user through the logind
ACL, and BlueZ accepts `Powered` changes from an active session. The plugin needs
no elevated rights, installs no system files and does not touch anything outside
its own directory (apart from its log, see Logs).

Because the block is an rfkill soft block, `systemd-rfkill` restores it at boot,
so your choice survives a reboot. The target adapter is powered on first and the
others are only turned off once it is up, so a failed switch never leaves you
with no adapter, and unplugging the active dongle turns the onboard adapter back
on.

Adapter type comes from sysfs: a USB device flagged `fixed` is reported as
onboard, a `removable` one as a USB dongle.

The logic lives in [`bt-adapter.sh`](bt-adapter.sh) (`status`, `use <hciN>`,
`next`, `auto`, `ensure`, `watch`, `forget|connect|disconnect|pair <hciN> <ADDRESS>`,
`scan <hciN>`, `audio <ADDRESS>`, `log`, and `json` for the full state), which
you can also run by hand.

## Keybinding

The panel answers to Omarchy's shell IPC, so you can open it from a Hyprland
binding:

```bash
omarchy-shell io.github.cesarfilho.bluetooth-adapter-switch toggle
```

## Logs

Every action (switch, connect, disconnect, pair, forget, scan) is written to
`~/.local/state/omarchy-bluetooth-adapter-switch/plugin.log` with its outcome and
duration. When an action fails the log also gets a snapshot to diagnose it: the
rfkill state, the adapters, every BlueZ property of the device involved and the
latest `bluetoothd` messages. Polling is not logged, and the file rotates at
256 KB.

```bash
bash ~/.config/omarchy/plugins/io.github.cesarfilho.bluetooth-adapter-switch/bt-adapter.sh log 80
```

A failure banner in the panel also points to this file. The widget itself logs
to the shell journal (`journalctl -b | grep bt-adapter-switch`).

## Install

```bash
omarchy plugin add https://github.com/cesarfilho/omarchy-bluetooth-adapter-switch.git --enable
```

Or by hand: clone this repository into
`~/.config/omarchy/plugins/io.github.cesarfilho.bluetooth-adapter-switch/`,
then run `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable io.github.cesarfilho.bluetooth-adapter-switch`.

After updating the plugin, run `omarchy restart shell`: the running shell keeps
the old widget in memory until it restarts.

Move it with `omarchy bar move io.github.cesarfilho.bluetooth-adapter-switch --section left`.

## Remove

```bash
omarchy plugin remove io.github.cesarfilho.bluetooth-adapter-switch
```

If an adapter is still blocked, unblock it first with `rfkill unblock bluetooth`.

## Settings

Set in the widget's entry in `~/.config/omarchy/shell.json`, or from the
Omarchy settings panel:

| Key | Default | Meaning |
|---|---|---|
| `showLabel` | `true` | Show the adapter name next to the icon |
| `preferred` | `USB dongle` | Which adapter is active when several are present: `USB dongle` or `Onboard` |
| `labelMode` | `Type` | `Type` shows USB / Onboard, `Adapter id` shows hci0 / hci1 |
| `clickAction` | `Open panel` | `Open panel` or `Switch to next` on left click |
| `scanTransport` | `Classic (headsets, speakers)` | What a scan looks for: `Classic`, `Low Energy` or `Both` |
| `notify` | `true` | Desktop notification after switching |
| `refreshIntervalSec` | `10` | How often the state is re-read (2 to 120); 2 s while the panel is open |

## Things to know

- **Pair headsets and speakers with a classic scan.** The default scan looks
  over classic BR/EDR, which is what carries audio. A device found over Low
  Energy can be paired as an LE-only entry with no audio profile; it then lists
  as paired but never connects ("no response from the device"). If you have one,
  forget it and pair again from a classic scan. Some earbuds (QCY, for example)
  even show up twice: an audio identity and a separate "app" identity that only
  speaks Low Energy. The panel tags entries without an audio or input profile as
  **BLE only** (paired) or **BLE** (nearby), and lists audio devices first, so you
  can pair the right one. Use the `Low Energy` or `Both`
  scan setting for BLE-only gear such as some keyboards and mice.
- **Sound moves to the headset on connect.** After a connect or pair, the
  plugin waits for the Bluetooth audio sink to appear, makes it the default
  output and moves what is playing to it (`bt-adapter.sh audio <ADDRESS>` does
  the same by hand). When the headset disconnects, PipeWire falls back to the
  previous output.
- **Battery only shows when the device reports it.** It comes from BlueZ's
  `Battery1` interface. Many earbuds and headsets do not publish a level over
  Bluetooth to Linux, in which case nothing is shown rather than a made-up value.
- **Paired devices belong to one adapter.** Each adapter keeps its own pairings,
  so pair your devices again after switching (the same device can be paired to
  both, and each copy is forgotten separately). Switching away from an adapter
  disconnects whatever is connected to it.
- **The stock Bluetooth widget can lag behind.** Quickshell's
  `Bluetooth.defaultAdapter`, which `omarchy.bluetooth` uses, does not follow this
  switch. If the onboard adapter is the one you blocked, the stock widget may
  show "Turned off" while your dongle works fine. This widget always shows the
  real state.
- If the onboard adapter should never come back, a udev rule that
  de-authorizes its USB port is the permanent option. That needs root and is
  deliberately not automated here.

## Dependencies

All are present on a standard Omarchy install: `bluez` (BlueZ over D-Bus),
`bluez-utils` (`bluetoothctl`, used for scanning), `util-linux` (`rfkill`),
`systemd` (`busctl`, `udevadm`), `libnotify` (`notify-send`), `jq` and
`bash`.

## License

[MIT](LICENSE)
