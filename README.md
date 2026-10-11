# Vibekey for Omarchy

A driver and control panel for the [Ulanzi Vibekey](https://www.ulanzi.com/products/au05-vibe-key-ai-voice-input-keypad-i018)
(AU05) on [Omarchy](https://omarchy.org). It adds a Vibekey icon to the bar; the
popup shows the keypad's status and battery and lets you assign any action to its
three keys and the knob.

```
  ┌───────────┐
  │  ◉ Voice  │     Voice key   → push-to-talk dictation
  │  ✓     ✕  │     ✓ Confirm   → Enter        ✕ Cancel → Escape
  │    (◎)    │     Knob press  → mute mic     turn → volume
  └───────────┘
```

Out of the box the Vibekey is a plain keyboard that types Enter, Escape,
PrintScreen and arrows, and its Voice key sends a code Linux throws away. This
plugin reads the keypad directly, keeps those factory keystrokes away from your
apps, and runs whatever you picked instead.

## Install

```bash
omarchy plugin add https://github.com/jimmibram/vibekey-driver.git --enable
```

Then click the Vibekey icon in the bar and press **Grant device access**. That
installs one udev rule (`/etc/udev/rules.d/70-ulanzi-vibekey.rules`) so your
login may read the keypad; it asks for your password once and needs no replug.

From a checkout, `./install.sh` does the same without git: it copies the plugin
into `~/.config/omarchy/plugins/`, enables it and installs the rule.

## Using it

- Open the panel from the bar icon. It draws the keypad with each control's
  assignment beside it. Press a key or turn the knob on the Vibekey and that
  control lights up in the drawing, so you always know which one you are editing.
- Click a control (on the drawing or its label) to pick an action: dictation (push-to-talk via voxtype), Omarchy
  menus and panels, volume and media, screenshots, workspaces, or a plain key
  press such as Enter and Escape. **Custom command** runs anything through bash;
  **Send key combo** types a shortcut such as `ctrl+shift+t`.
- Changes apply immediately. The daemon picks the config up within a second.
- **Block the factory keystrokes** is on by default. Turn it off if you also want
  the keypad's own Enter/Escape to reach your apps.

Push-to-talk works because the daemon sees key releases too: a preset may carry a
`release_command`, and the Voice key runs `voxtype record start` on press and
`voxtype record stop` on release.

## Flipping between agents in herdr

The presets **Next agent in herdr** and **Previous agent in herdr** run
`bin/vibekey-herdr-agent`. It finds the herdr TUI you have open (a local session,
`herdr --session`, `herdr --machine`, or `herdr --remote <host>`), asks that
session for its agents over the herdr socket API (through SSH for a remote
session), focuses the next or previous one, brings the herdr window to the
front and shows the agent's name in the OSD. With no agents running it flips
between herdr workspaces instead; with no herdr open it just says so.

## How it works

- `bin/vibekeyd` is a dependency-free Python daemon the panel starts and
  supervises. It finds the dongle (USB `fff1:00dd`), holds both of its raw HID
  channels open (the dongle reboots every four seconds otherwise), reads the
  keyboard, consumer and mouse reports straight from `hidraw`, and grabs the
  matching evdev nodes with `EVIOCGRAB` so the compositor never sees them.
  Battery level comes over the vendor channel (report `0x55`, TEA-encrypted),
  following the protocol documented by [MrCroxx/olanzi](https://github.com/MrCroxx/olanzi).
- The six controls are identified by what they send from the factory: Voice
  key = HID usage `0x01`, ✓ = Enter, ✕ = Escape, knob press = PrintScreen, knob
  turn = Right/Backspace or mouse wheel. A key remapped with Ulanzi Studio shows up
  as a new row with its raw id, which you can assign like any other.
- Assignments live in `~/.config/omarchy/vibekey/config.json`:

  ```json
  {
    "grab": true,
    "buttons": {
      "key1": { "preset": "dictation_ptt", "command": "voxtype record start", "release_command": "voxtype record stop" },
      "key2": { "keys": "Return" },
      "knob_right": { "command": "omarchy-audio-output-volume raise" }
    }
  }
  ```

  `bin/vibekey-config` edits it atomically (`show`, `set-button`, `set`), and the
  daemon reloads it on change. Live state for the panel is in
  `$XDG_RUNTIME_DIR/vibekey/state.json`.
- `bin/vibekeyd --probe` prints every decoded control event; handy to see what
  your keypad sends.

## Requirements

- Omarchy 4 (the Quickshell `omarchy-shell`), Python 3, `wtype` (ships with
  Omarchy) for the key-combo actions, `voxtype` for the dictation presets.
- The udev rule above, or membership of a group that may read `/dev/hidraw*`
  and `/dev/input/event*`.

## Uninstall

```bash
omarchy plugin remove jimmibram.vibekey
sudo rm /etc/udev/rules.d/70-ulanzi-vibekey.rules   # optional
```

## License

MIT. Not affiliated with Ulanzi. Protocol knowledge thanks to
[MrCroxx/olanzi](https://github.com/MrCroxx/olanzi) and
[kubja/ulanzi-vibekey](https://github.com/kubja/ulanzi-vibekey).
