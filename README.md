# Bluetooth Adapter Switch

An [Omarchy](https://omarchy.org/) bar widget for machines with more than one
Bluetooth adapter, typically the onboard chip plus a USB dongle. It shows which
adapter is active and switches between them with one click.

![Bluetooth Adapter Switch in the bar](preview.png)

| Action | Result |
|---|---|
| Left click / scroll | Make the next adapter (in `hciN` order) the only powered one |
| Right click | Unblock and power on every adapter |
| Middle click | Refresh |
| Hover | Lists every adapter with its name, address and state |

The label shows the active adapter (`hci1`), `all` when several are on, or
`off` when none is. With a single adapter the widget is dimmed and does
nothing.

## How it works

Switching to an adapter powers it on and soft-blocks every other Bluetooth
adapter with `rfkill`. Nothing runs as root: `/dev/rfkill` is writable by the
logged-in user through the logind ACL, and BlueZ accepts `Powered` changes from
an active session. The plugin never uses `sudo`, `pkexec`, udev rules or systemd
units, and it does not touch any file outside its own directory.

Because the block is an rfkill soft block, `systemd-rfkill` restores it at boot,
so your choice survives a reboot.

The logic lives in [`bt-adapter.sh`](bt-adapter.sh) (`status`, `use <hciN>`,
`next`, `all-on`), which you can also run by hand.

## Install

```bash
omarchy plugin add https://github.com/cesarfilho/omarchy-bluetooth-adapter-switch.git --enable
```

Or by hand: clone this repository into
`~/.config/omarchy/plugins/io.github.cesarfilho.bluetooth-adapter-switch/`,
then run `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable io.github.cesarfilho.bluetooth-adapter-switch`.

Move it with `omarchy bar move io.github.cesarfilho.bluetooth-adapter-switch --section left`.

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
- If the onboard adapter should never come back, a udev rule that
  de-authorizes its USB port is the permanent option. That needs root and is
  deliberately not automated here.

## Dependencies

All are present on a standard Omarchy install: `bluez` (BlueZ over D-Bus),
`util-linux` (`rfkill`), `systemd` (`busctl`), `jq` and `bash`.

## License

[MIT](LICENSE)
