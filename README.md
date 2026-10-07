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

- **Smooth text.** Four steps under Text size: **Crisp** (Omarchy's
  default), then three Mac-like ones. They render text the way macOS does: no
  snapping of letter shapes to the pixel grid (only light vertical hinting),
  grayscale antialiasing, and stems darkened (slightly emboldened) by FreeType
  — at half strength for **Soft**, at FreeType's maximum for **Smooth**.
  **Heavy** also draws regular text one weight heavier (Medium) in fonts that
  have it, such as Omarchy's Adwaita Sans. Apps pick it up when they next
  start.

Everything else is Omarchy's Display panel: brightness, text size, turning
displays on and off. `Super + Ctrl + D` opens this panel instead of Omarchy's.

Wayland apps draw straight at the monitor's real pixels for any of these
scales, so unlike a Mac there's no need to render at 2× and shrink.

## Install

```bash
omarchy plugin add https://github.com/motorstreak/omarchy-display.git --enable
```

Then swap Omarchy's Display button for this one in `~/.config/omarchy/shell.json`:
replace `{"id": "omarchy.monitor"}` in `bar.layout` with `{"id": "io.github.motorstreak.display"}`.

To remember a scale per monitor, the plugin needs a short block at the end of
`~/.config/hypr/monitors.lua` (between `-- omarchy-display-start` and
`-- omarchy-display-end`) that loads `hypr/display.lua`. It never adds it on
its own: the panel asks first ("Remember each monitor's scale?"), or run
`~/.config/omarchy/plugins/io.github.motorstreak.display/bin/display-setup install`. Keep the block
last so the saved scales win over the rules above it. Without it, "looks like"
still sets a scale, until you log out.

Upgrading from a version before 0.5.0 (plugin id `display`): remove it first
(see Remove, with `display` in place of the new id), then add it again as above.

## What it changes, and what it needs

Outside its own folder the plugin writes only:

- `~/.config/hypr/monitors.lua`: the block above, and the
  `omarchy_monitor_scale` / `omarchy_gdk_scale` values in it, only after you
  allow it in the panel (or run `display-setup install`).
- `~/.local/state/omarchy-display/`: the saved scales and text setting.
- Text rendering, only when you pick Soft, Smooth or Heavy:
  `~/.config/fontconfig/conf.d/60-smooth-text.conf`, `~/.config/ghostty/smooth-text`
  and a `config-file = ?smooth-text` line in the Ghostty config. Crisp removes
  the files.
- Once set up, `Super + Ctrl + D` opens this panel instead of Omarchy's Display panel.

It needs nothing beyond a standard Omarchy install: Hyprland, the Omarchy
shell and its `omarchy-*` commands (brightness, text size), plus `flock`
(util-linux) and `fontconfig`. No root access, services or downloads.

## How it works

`hypr/display.lua` runs inside Hyprland's config. On every monitor change it
saves each monitor's mode, scale and rotation to
`~/.local/state/omarchy-display/monitors`, and on every config load it turns
that file into `hl.monitor({ output = "desc:…" })` rules. Omarchy's toggles
(laptop display off, mirroring) load after `monitors.lua`, so they still win.
REFRESH RATE lists the rates the chosen monitor offers at its resolution and
saves the one you pick with its mode, like the scale.

With more than one display on, ARRANGE shows the displays as rectangles, each
the size it looks like. Drag one and let go: it snaps flush against the
nearest edge of another (never overlapping, always sharing enough edge for the
pointer to cross), lining up edges or centres when it's close. The buttons
below put the chosen monitor left, right, above or below the laptop panel (or,
without one, the first monitor) instead: beside the laptop the bottoms line
up, above or below the centres do. Either is saved per monitor in
`~/.local/state/omarchy-display/arrangement` (a side, or `@x,y` from the laptop
panel's corner). They're applied again when
a monitor is plugged in or out or its scale changes.
The laptop panel's scale is also written to `omarchy_monitor_scale` (and
`omarchy_gdk_scale`) in `monitors.lua`, as Omarchy's own scale keys do:
Omarchy's lid script turns the panel back on at that scale.

Text rendering (`bin/display-text crisp|soft|smooth|heavy|status`) writes
`~/.config/fontconfig/conf.d/60-smooth-text.conf` (autohinter, light hinting,
grayscale; Regular → Medium for Heavy) and sets `FREETYPE_PROPERTIES` to turn on
FreeType's stem darkening; `hypr/display.lua` sets it again at every login. Ghostty has its own
FreeType settings, so the plugin adds `config-file = ?smooth-text` to the
Ghostty config and writes `~/.config/ghostty/smooth-text` only while text is
not crisp; on Heavy it switches Ghostty to Medium too if its font has a Medium
style.
Omarchy's JetBrains Mono package has no Medium: take
`JetBrainsMonoNerdFont-Medium*.ttf` from the full `ttf-jetbrains-mono-nerd`
package into `~/.local/share/fonts` (the full package conflicts with the
basic one Omarchy depends on). Ghostty runs one process for all its windows: quit it fully to see the
change. Crisp removes both files.

A saved rule (mode, scale, rotation and position) replaces any rule you wrote
for the same monitor above it. If you
keep your own rule for a monitor (to set a position or VRR, say), delete that
monitor's line from the state file, or put your rule after the block.

## Remove

```bash
~/.config/omarchy/plugins/io.github.motorstreak.display/bin/display-text crisp
~/.config/omarchy/plugins/io.github.motorstreak.display/bin/display-setup remove
omarchy plugin remove io.github.motorstreak.display
```

then put `{"id": "omarchy.monitor"}` back in the bar layout, and delete the
`config-file = ?smooth-text` line from the Ghostty config.

## Credits

The panel is a copy of Omarchy's `omarchy.monitor` panel (MIT), so it doesn't
receive Omarchy's later changes to that panel.
