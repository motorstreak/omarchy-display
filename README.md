# Omarchy Display

Omarchy's Display panel (the monitor button in the bar), upgraded the way
BetterDisplay upgrades the Mac's display settings:

- **Looks like.** Instead of six fixed scale buttons, the panel lists every
  desktop size your monitor can show sharply — e.g. on a 3440×1440 monitor:
  3440×1440, 3225×1350, 2752×1152, 2580×1080, 2150×900, 2064×864, 1720×720.
  These are the scales Hyprland accepts without rounding (the mode must divide
  into whole pixels in 1/120 steps), down to a 720 px tall desktop.
- **Pick the monitor.** With more than one display on, pills choose which
  monitor the sizes apply to (it starts on the focused one).
- **Remembered per monitor.** Each monitor keeps its own scale across reboots,
  matched by make, model and serial, so it follows the monitor to another port
  or dock. Omarchy's own `Super + /` and `Super + Alt + /` changes are
  remembered too. (Omarchy saves one scale for every monitor, so a laptop
  panel and an external monitor couldn't keep different scales.)

- **Smooth text.** A Crisp / Smooth switch under Text size. Smooth renders
  text the way macOS does: no snapping of letter shapes to the pixel grid
  (only light vertical hinting), grayscale antialiasing, and stems darkened
  (slightly emboldened) by FreeType. Apps pick it up when they next start.
  Crisp is Omarchy's default.

Everything else is Omarchy's Display panel: brightness, text size, turning
displays on and off. `Super + Ctrl + D` opens this panel instead of Omarchy's.

Wayland apps draw straight at the monitor's real pixels for any of these
scales, so unlike a Mac there's no need to render at 2× and shrink.

## Install

```bash
omarchy plugin add https://github.com/motorstreak/omarchy-display.git --enable
```

Then swap Omarchy's Display button for this one in `~/.config/omarchy/shell.json`:
replace `{"id": "omarchy.monitor"}` in `bar.layout` with `{"id": "display"}`.

The first time the panel loads it adds a short block to the end of
`~/.config/hypr/monitors.lua` (between `-- omarchy-display-start` and
`-- omarchy-display-end`) that loads `hypr/display.lua`. Keep it last so the
saved scales win over the rules above it.

## How it works

`hypr/display.lua` runs inside Hyprland's config. On every monitor change it
saves each monitor's mode, scale and rotation to
`~/.local/state/omarchy-display/monitors`, and on every config load it turns
that file into `hl.monitor({ output = "desc:…" })` rules. Omarchy's toggles
(laptop display off, mirroring) load after `monitors.lua`, so they still win.

Smooth text (`bin/display-text crisp|smooth|status`) writes
`~/.config/fontconfig/conf.d/60-smooth-text.conf` (autohinter, light hinting,
grayscale) and sets `FREETYPE_PROPERTIES` to turn on FreeType's stem
darkening; `hypr/display.lua` sets it again at every login. Ghostty has its own
FreeType settings, so the plugin adds `config-file = ?smooth-text` to the
Ghostty config and writes `~/.config/ghostty/smooth-text` only while text is
smooth. Ghostty runs one process for all its windows: quit it fully to see the
change. Crisp removes both files.

A saved rule replaces any rule you wrote for the same monitor above it. If you
keep your own rule for a monitor (to set a position or VRR, say), delete that
monitor's line from the state file, or put your rule after the block.

## Remove

```bash
~/.config/omarchy/plugins/display/bin/display-text crisp
~/.config/omarchy/plugins/display/bin/display-setup remove
omarchy plugin remove display
```

then put `{"id": "omarchy.monitor"}` back in the bar layout, and delete the
`config-file = ?smooth-text` line from the Ghostty config.

## Credits

The panel is a copy of Omarchy's `omarchy.monitor` panel (MIT), so it doesn't
receive Omarchy's later changes to that panel.
