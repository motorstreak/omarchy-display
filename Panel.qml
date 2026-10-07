import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "display"
  ipcTarget: "io.github.motorstreak.display"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  //   "target"     - which monitor LOOKS LIKE applies to; one row of pills,
  //                  only with more than one display on.
  //   "scale"      - LOOKS LIKE options, a grid scaleColumns wide: j/k move
  //                  by rows, h/l along a row.
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")

  // hyprctl monitors -j, by connector name.
  property var monitorInfo: ({})
  // The monitor LOOKS LIKE applies to; the focused one when the panel opens.
  property string targetMonitor: ""
  readonly property var targetInfo: monitorInfo[targetMonitor] || null
  readonly property var enabledNames: {
    var names = []
    for (var i = 0; i < displays.length; i++)
      if (displays[i] && displays[i].enabled && monitorInfo[displays[i].name]) names.push(displays[i].name)
    return names
  }
  readonly property var scaleValues: targetInfo ? Model.looksLikeOptions(targetInfo.width, targetInfo.height) : []
  readonly property int scaleColumns: 2
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("rendering")
    if (enabledNames.length > 1) list.push("target")
    list.push("scale")
    if (refreshOptions.length > 1) list.push("refresh")
    if (arrangeVisible) list.push("arrange")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "rendering") return textModes.length
    if (section === "scale") return scaleValues.length
    if (section === "target") return enabledNames.length
    if (section === "arrange") return arrangeOptions.length
    if (section === "refresh") return refreshOptions.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; monitor pills sit horizontally.
    return section === "brightness" || section === "textsize" || section === "rendering" || section === "target"
      || section === "arrange" || section === "refresh"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (focusSection === "scale") {
      var next = selectedIndex + delta * scaleColumns
      if (next >= 0 && next <= max) { selectedIndex = next; return }
      if (delta > 0 && Math.floor(selectedIndex / scaleColumns) < Math.floor(max / scaleColumns)) {
        selectedIndex = max
        return
      }
    }

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: walks the monitor pills, or along a row of LOOKS LIKE options;
  // everywhere else, no-op because adjustBrightness handles horizontal motion
  // on the brightness slider.
  function moveCursorH(delta) {
    if (focusSection === "refresh") {
      selectedIndex = Math.max(0, Math.min(refreshOptions.length - 1, selectedIndex + delta))
      return
    }
    if (focusSection === "arrange") {
      selectedIndex = Math.max(0, Math.min(arrangeOptions.length - 1, selectedIndex + delta))
      return
    }
    if (focusSection === "rendering") {
      selectedIndex = Math.max(0, Math.min(textModes.length - 1, selectedIndex + delta))
      return
    }
    if (focusSection === "target") {
      var t = selectedIndex + delta
      if (t < 0) t = 0
      if (t > enabledNames.length - 1) t = enabledNames.length - 1
      selectedIndex = t
      targetMonitor = enabledNames[t]
      return
    }
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    var row = Math.floor(selectedIndex / scaleColumns)
    if (next < 0 || next > scaleValues.length - 1 || Math.floor(next / scaleColumns) !== row) return
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "rendering" && selectedIndex >= 0 && selectedIndex < textModes.length) {
      setTextMode(textModes[selectedIndex].id)
      return
    }
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex].exact)
      return
    }
    if (focusSection === "refresh" && selectedIndex >= 0 && selectedIndex < refreshOptions.length) {
      setRefresh(refreshOptions[selectedIndex])
      return
    }
    if (focusSection === "arrange" && selectedIndex >= 0 && selectedIndex < arrangeOptions.length) {
      arrange(arrangeOptions[selectedIndex].id)
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      targetMonitor: root.targetMonitor,
      textMode: root.textMode,
      opened: root.opened,
      panelHeight: panelColumn.implicitHeight,
      scale: root.monitorScale,
      looksLike: root.scaleValues,
      displays: root.displays
    })
  }

  IpcHandler {
    target: root.ipcTarget

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    // Sets the scale of the monitor the panel targets (for testing).
    function scale(value: string): string { root.setScale(Number(value)); return "ok" }
    // Sets text rendering: "crisp", "soft", "smooth" or "heavy".
    function text(mode: string): string { root.setTextMode(mode); return "ok" }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!textModeProc.running) textModeProc.running = true
    if (!monitorsProc.running) monitorsProc.running = true
    if (!arrangementProc.running) arrangementProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    return targetInfo ? Model.matchingOptionIndex(scaleValues, targetInfo.scale) : -1
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Refresh rate: the rates the targeted monitor offers at its current
  // resolution (hyprctl's availableModes), fastest first, one per rate.
  readonly property var refreshOptions: {
    if (!targetInfo || !targetInfo.availableModes) return []
    var prefix = targetInfo.width + "x" + targetInfo.height + "@"
    var seen = {}
    var list = []
    for (var i = 0; i < targetInfo.availableModes.length; i++) {
      var mode = String(targetInfo.availableModes[i])
      if (mode.indexOf(prefix) !== 0) continue
      var rate = parseFloat(mode.slice(prefix.length))
      if (!isFinite(rate)) continue
      var key = rate.toFixed(2)
      if (seen[key]) continue
      seen[key] = true
      list.push({ rate: rate, key: key, label: Number(key) % 1 === 0 ? String(Number(key)) : key })
    }
    list.sort(function(a, b) { return b.rate - a.rate })
    return list
  }
  readonly property int refreshColumns: refreshOptions.length <= 4 ? Math.max(1, refreshOptions.length) : (refreshOptions.length <= 6 ? 3 : 4)

  function refreshIsCurrent(option) {
    return !!targetInfo && Math.abs(Number(targetInfo.refreshRate) - option.rate) < 0.006
  }

  function setRefresh(option) {
    if (!targetInfo || !/^[A-Za-z0-9._-]+$/.test(targetMonitor)) return
    var mode = targetInfo.width + "x" + targetInfo.height + "@" + option.key
    actionProc.command = ["hyprctl", "eval",
      "if display_scaling and display_scaling.set_mode then display_scaling.set_mode(\"" + targetMonitor + "\", \"" + mode + "\") end"]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Arrangement (hypr/display.lua): each monitor's side of the anchor, the
  // laptop panel when it's on (else the first monitor without a side). From
  // ~/.local/state/omarchy-display/arrangement, by monitor description.
  readonly property var arrangeOptions: [
    { id: "left", label: "Left" },
    { id: "right", label: "Right" },
    { id: "above", label: "Above" },
    { id: "below", label: "Below" }
  ]
  property var arrangement: ({})
  readonly property string anchorMonitor: {
    var names = enabledNames.slice().sort()
    for (var i = 0; i < names.length; i++)
      if (/^(eDP|LVDS|DSI)-/.test(names[i])) return names[i]
    for (var j = 0; j < names.length; j++) {
      var info = monitorInfo[names[j]]
      if (info && !arrangement[info.description]) return names[j]
    }
    return names.length ? names[0] : ""
  }
  readonly property bool arrangeVisible: enabledNames.length > 1 && targetMonitor !== "" && targetMonitor !== anchorMonitor
  readonly property string targetSide: (targetInfo && arrangement[targetInfo.description]) || "right"

  // ---- The map: each monitor on, as a rectangle its "looks like" size, where
  // it is (hyprctl's layout positions). Drag one and let go: it snaps flush
  // against the nearest edge of another (sharing at least mapMinShared of it,
  // so the pointer can cross), lining up edges or centres when close, never
  // overlapping. The places are saved as offsets from the anchor.
  property var mapOverride: null
  property bool mapDragging: false
  readonly property real mapMinShared: 100

  readonly property var mapRects: {
    if (mapOverride) return mapOverride
    var list = []
    for (var i = 0; i < enabledNames.length; i++) {
      var info = monitorInfo[enabledNames[i]]
      if (!info || (info.mirrorOf && info.mirrorOf !== "none") || !(info.scale > 0)) continue
      var w = info.width / info.scale
      var h = info.height / info.scale
      if ((info.transform || 0) % 2 === 1) { var t = w; w = h; h = t }
      list.push({
        name: info.name,
        label: /^(eDP|LVDS|DSI)-/.test(info.name) ? "Laptop" : (info.model || info.name),
        x: info.x, y: info.y, w: w, h: h
      })
    }
    return list
  }

  readonly property var mapBounds: {
    if (mapRects.length === 0) return { x: 0, y: 0, w: 1, h: 1 }
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    for (var i = 0; i < mapRects.length; i++) {
      var r = mapRects[i]
      x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y)
      x1 = Math.max(x1, r.x + r.w); y1 = Math.max(y1, r.y + r.h)
    }
    return { x: x0, y: y0, w: Math.max(1, x1 - x0), h: Math.max(1, y1 - y0) }
  }

  function overlapsAny(x, y, w, h, others) {
    for (var i = 0; i < others.length; i++) {
      var o = others[i]
      if (x < o.x + o.w - 0.5 && x + w > o.x + 0.5 && y < o.y + o.h - 0.5 && y + h > o.y + 0.5) return true
    }
    return false
  }

  // A value pulled to the nearest of `targets` within `reach`.
  function snapTo(v, targets, reach) {
    var best = v, dist = reach
    for (var i = 0; i < targets.length; i++) {
      var d = Math.abs(v - targets[i])
      if (d <= dist) { dist = d; best = targets[i] }
    }
    return best
  }

  // A rectangle let go at layout position (lx, ly): snapped, saved, applied.
  function mapDrop(name, lx, ly, reach) {
    var rects = mapRects
    var me = null
    var others = []
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].name === name) me = rects[i]
      else others.push(rects[i])
    }
    if (!me || others.length === 0) { mapOverride = rects.slice(); return }
    var best = null, bestDist = Infinity
    for (var j = 0; j < others.length; j++) {
      var o = others[j]
      var shared = Math.min(mapMinShared, me.h, o.h)
      var y = Math.max(o.y - me.h + shared, Math.min(o.y + o.h - shared, ly))
      y = snapTo(y, [o.y, o.y + o.h - me.h, o.y + (o.h - me.h) / 2], reach)
      shared = Math.min(mapMinShared, me.w, o.w)
      var x = Math.max(o.x - me.w + shared, Math.min(o.x + o.w - shared, lx))
      x = snapTo(x, [o.x, o.x + o.w - me.w, o.x + (o.w - me.w) / 2], reach)
      var candidates = [
        { x: o.x - me.w, y: y }, { x: o.x + o.w, y: y },
        { x: x, y: o.y - me.h }, { x: x, y: o.y + o.h }
      ]
      for (var c = 0; c < candidates.length; c++) {
        var cand = candidates[c]
        if (overlapsAny(cand.x, cand.y, me.w, me.h, others)) continue
        var d = Math.hypot(cand.x - lx, cand.y - ly)
        if (d < bestDist) { bestDist = d; best = cand }
      }
    }
    if (!best) { mapOverride = rects.slice(); return }

    var placed = []
    for (var k = 0; k < rects.length; k++) {
      var r = rects[k]
      placed.push(r.name === name
        ? { name: r.name, label: r.label, x: Math.round(best.x), y: Math.round(best.y), w: r.w, h: r.h }
        : r)
    }
    mapOverride = placed

    // Saved as offsets from the anchor (which may itself have been dragged).
    var anchor = null
    for (var a = 0; a < placed.length; a++) if (placed[a].name === anchorMonitor) anchor = placed[a]
    if (!anchor) return
    var items = []
    for (var n = 0; n < placed.length; n++) {
      var p = placed[n]
      if (p.name === anchor.name || !/^[A-Za-z0-9._-]+$/.test(p.name)) continue
      items.push("{ \"" + p.name + "\", " + Math.round(p.x - anchor.x) + ", " + Math.round(p.y - anchor.y) + " }")
    }
    actionProc.command = ["hyprctl", "eval",
      "if display_scaling and display_scaling.place then display_scaling.place({ " + items.join(", ") + " }) end"]
    if (!actionProc.running) actionProc.running = true
  }

  function anchorLabel() {
    if (/^(eDP|LVDS|DSI)-/.test(anchorMonitor)) return "of the laptop"
    var info = monitorInfo[anchorMonitor]
    return "of " + (info && info.model ? info.model : anchorMonitor)
  }

  function arrange(side) {
    if (!/^[A-Za-z0-9._-]+$/.test(targetMonitor) || !/^(left|right|above|below)$/.test(side)) return
    actionProc.command = ["hyprctl", "eval",
      "if display_scaling and display_scaling.arrange then display_scaling.arrange(\"" + targetMonitor + "\", \"" + side + "\") end"]
    if (!actionProc.running) actionProc.running = true
  }

  Process {
    id: arrangementProc
    command: ["sh", "-c", "cat \"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-display/arrangement\" 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var tab = lines[i].lastIndexOf("\t")
          if (tab > 0) map[lines[i].slice(0, tab)] = lines[i].slice(tab + 1).trim()
        }
        root.arrangement = map
      }
    }
  }

  // Text inset inside a highlighted row: at least `min` (Omarchy's margin, for
  // its small rounding), more as the rounding grows, so the text stays clear
  // of the curve (three quarters of the end's radius).
  function insetFor(item, min) {
    var floor = min === undefined ? Style.space(8) : min
    var r = Math.min(Number(item.radius) || 0, (Number(item.height) || 0) / 2)
    return Math.max(floor, Math.round(r * 0.75))
  }

  // hypr/display.lua applies the scale to the monitor and remembers it.
  // Monitor names come from Hyprland but go into Lua source, so only plain
  // connector names pass.
  function setScale(scale) {
    var value = Number(scale)
    if (!/^[A-Za-z0-9._-]+$/.test(targetMonitor) || !isFinite(value) || value <= 0) return
    // Not set up (see setupNeeded): applied directly, for now only.
    var name = "\"" + targetMonitor + "\""
    var v = value.toPrecision(8)
    actionProc.command = ["hyprctl", "eval",
      "if display_scaling then display_scaling.set(" + name + ", " + v + ") else " +
      "for _, m in ipairs(hl.get_monitors()) do if m.name == " + name + " then " +
      "hl.monitor({ output = m.name, mode = string.format('%dx%d@%.2f', m.width, m.height, m.refresh_rate), " +
      "position = 'auto', scale = " + v + ", transform = m.transform or 0 }) end end end"]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text rendering (bin/display-text): crisp, then three Mac-like steps ----
  readonly property var textModes: [
    { id: "crisp", label: "Crisp", hint: "sharpest" },
    { id: "soft", label: "Soft", hint: "like macOS, lighter" },
    { id: "smooth", label: "Smooth", hint: "like macOS" },
    { id: "heavy", label: "Heavy", hint: "like macOS, heavier" }
  ]
  function textModeHint(mode) {
    for (var i = 0; i < textModes.length; i++)
      if (textModes[i].id === mode) return textModes[i].hint
    return ""
  }
  property string textMode: ""

  // A switch made while the last one is still being applied waits for it.
  property string pendingTextMode: ""

  function setTextMode(mode) {
    if (mode === textMode && !textModeSetProc.running) return
    textMode = mode
    if (textModeSetProc.running) {
      pendingTextMode = mode
      return
    }
    textModeSetProc.command = [root.pluginDir + "/bin/display-text", mode]
    textModeSetProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Remembering scales: hypr/display.lua, loaded from a block at the end
  // of ~/.config/hypr/monitors.lua. That file is yours, so the block is added
  // only once you allow it here (asked until then; "Not now" until the shell
  // restarts). Without it, "looks like" still applies a scale, unremembered.
  property bool setupNeeded: false
  property bool setupDismissed: false

  function allowSetup() {
    setupNeeded = false
    setupInstallProc.running = true
  }

  Process {
    id: setupStatusProc
    command: [root.pluginDir + "/bin/display-setup", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.setupNeeded = String(text || "").trim() === "missing"
    }
  }

  Process {
    id: setupInstallProc
    command: [root.pluginDir + "/bin/display-setup", "install"]
    onRunningChanged: if (!running) setupStatusProc.running = true
  }

  Component.onCompleted: {
    setupStatusProc.running = true
    refresh()
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      targetMonitor = ""
      refresh()
      if (!setupStatusProc.running) setupStatusProc.running = true
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  // Entering the monitor pills puts the cursor on the targeted monitor.
  onFocusSectionChanged: if (focusSection === "target") {
    var t = enabledNames.indexOf(targetMonitor)
    if (t >= 0) selectedIndex = t
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: textModeProc
    command: [root.pluginDir + "/bin/display-text", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.textMode = String(text || "").trim()
    }
  }

  Process {
    id: textModeSetProc
    onRunningChanged: {
      if (running) return
      if (root.pendingTextMode !== "") {
        var next = root.pendingTextMode
        root.pendingTextMode = ""
        textModeSetProc.command = [root.pluginDir + "/bin/display-text", next]
        textModeSetProc.running = true
        return
      }
      root.refresh()
    }
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var info = {}
        try {
          var list = JSON.parse(String(text || "[]"))
          for (var i = 0; i < list.length; i++) info[list[i].name] = list[i]
        } catch (e) {}
        // Not under a rectangle being dragged; a fresh layout replaces the
        // places shown since the last drop.
        if (root.mapDragging) return
        root.mapOverride = null
        root.monitorInfo = info
        if (!info[root.targetMonitor]) {
          root.targetMonitor = ""
          for (var name in info) if (info[name].focused) root.targetMonitor = name
        }
      }
    }
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // As tall as its content (it grows while the setup question shows); it only
    // scrolls if that won't fit on the screen.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Asked once: may it edit monitors.lua? ----------
          PanelSeparator {
            visible: root.setupNeeded && !root.setupDismissed
            foreground: root.bar.foreground
          }

          Column {
            visible: root.setupNeeded && !root.setupDismissed
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "REMEMBER EACH MONITOR'S SCALE?"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Adds a few lines to the end of ~/.config/hypr/monitors.lua, so each monitor keeps the scale you pick, and keeps Omarchy's laptop scale there in step. Until then, a scale you pick lasts until you log out."
              color: Qt.darker(root.bar.foreground, 1.2)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              id: setupRow
              width: parent.width
              spacing: Style.spacing.xs

              Button {
                text: "Allow"
                width: (setupRow.width - setupRow.spacing) / 2
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: true
                onClicked: root.allowSetup()
              }

              Button {
                text: "Not now"
                width: (setupRow.width - setupRow.spacing) / 2
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.setupDismissed = true
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                textFormat: Text.PlainText
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text rendering ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(renderingHeader.implicitHeight, renderingHint.implicitHeight)

              PanelSectionHeader {
                id: renderingHeader
                text: "TEXT RENDERING"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: renderingHint
                textFormat: Text.PlainText
                text: root.textModeHint(root.textMode)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: renderingRow
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.textModes

                TextModePill {
                  required property var modelData
                  required property int index

                  mode: modelData
                  pillIndex: index
                  width: (renderingRow.width - renderingRow.spacing * (root.textModes.length - 1)) / root.textModes.length
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "LOOKS LIKE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // The panel's real resolution and current scale.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.targetInfo
                  ? root.targetInfo.width + " × " + root.targetInfo.height + " · " + root.normalizeScale(root.targetInfo.scale) + "×"
                  : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Which monitor the options apply to, with more than one on.
            Row {
              id: targetRow
              visible: root.enabledNames.length > 1
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.enabledNames

                TargetPill {
                  required property string modelData
                  required property int index

                  monitorName: modelData
                  pillIndex: index
                  width: (targetRow.width - targetRow.spacing * (root.enabledNames.length - 1)) / root.enabledNames.length
                }
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleColumns
              spacing: Style.spacing.xs

              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: root.scaleValues

                ScaleOption {
                  required property var modelData
                  required property int index

                  option: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }

            // Refresh rates at this resolution, when there's a choice.
            Item {
              visible: root.refreshOptions.length > 1
              width: parent.width
              implicitHeight: refreshHeader.implicitHeight + Style.space(4)

              PanelSectionHeader {
                id: refreshHeader
                text: "REFRESH RATE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.bottom: parent.bottom
              }

              Text {
                textFormat: Text.PlainText
                text: "Hz"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.bottom: parent.bottom
              }
            }

            Grid {
              id: refreshRow
              visible: root.refreshOptions.length > 1
              width: parent.width
              columns: root.refreshColumns
              spacing: Style.spacing.xs

              Repeater {
                model: root.refreshOptions

                RefreshPill {
                  required property var modelData
                  required property int index

                  option: modelData
                  pillIndex: index
                  width: (refreshRow.width - refreshRow.spacing * (refreshRow.columns - 1)) / refreshRow.columns
                }
              }
            }

            // Where the monitors sit, with more than one on: drag them on the
            // map, or pick a side for the chosen one below it.
            Item {
              visible: root.enabledNames.length > 1
              width: parent.width
              implicitHeight: Math.max(arrangeHeader.implicitHeight, arrangeHint.implicitHeight) + Style.space(4)

              PanelSectionHeader {
                id: arrangeHeader
                text: "ARRANGE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.bottom: parent.bottom
              }

              Text {
                id: arrangeHint
                textFormat: Text.PlainText
                text: root.arrangeVisible ? root.anchorLabel() : "drag to arrange"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.bottom: parent.bottom
              }
            }

            Item {
              id: arrangeMap
              visible: root.enabledNames.length > 1 && root.mapRects.length > 1
              width: parent.width
              readonly property real pad: Style.space(8)
              readonly property real maxHeight: Style.space(170)
              readonly property real k: Math.min((width - 2 * pad) / root.mapBounds.w, (maxHeight - 2 * pad) / root.mapBounds.h)
              readonly property real ox: (width - root.mapBounds.w * k) / 2
              implicitHeight: root.mapBounds.h * k + 2 * pad

              Rectangle {
                anchors.fill: parent
                radius: Style.space(10)
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.05)
              }

              Repeater {
                model: root.mapRects

                Rectangle {
                  id: screenBox
                  required property var modelData
                  readonly property bool isTarget: modelData.name === root.targetMonitor

                  x: arrangeMap.ox + (modelData.x - root.mapBounds.x) * arrangeMap.k
                  y: arrangeMap.pad + (modelData.y - root.mapBounds.y) * arrangeMap.k
                  width: Math.max(8, modelData.w * arrangeMap.k)
                  height: Math.max(8, modelData.h * arrangeMap.k)
                  radius: Style.space(4)
                  z: dragArea.drag.active ? 10 : 1
                  color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, isTarget ? 0.22 : 0.10)
                  border.width: isTarget ? 2 : 1
                  border.color: isTarget ? Color.accent
                    : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.45)

                  Text {
                    anchors.centerIn: parent
                    width: parent.width - Style.space(6)
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: screenBox.modelData.label
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: screenBox.isTarget
                  }

                  MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    drag.target: screenBox
                    drag.threshold: 2
                    drag.minimumX: 0
                    drag.minimumY: 0
                    drag.maximumX: arrangeMap.width - screenBox.width
                    drag.maximumY: arrangeMap.height - screenBox.height
                    onPressed: {
                      root.targetMonitor = screenBox.modelData.name
                      root.mapDragging = true
                    }
                    onReleased: {
                      root.mapDragging = false
                      if (screenBox.x === arrangeMap.ox + (screenBox.modelData.x - root.mapBounds.x) * arrangeMap.k
                          && screenBox.y === arrangeMap.pad + (screenBox.modelData.y - root.mapBounds.y) * arrangeMap.k) return
                      root.mapDrop(screenBox.modelData.name,
                        root.mapBounds.x + (screenBox.x - arrangeMap.ox) / arrangeMap.k,
                        root.mapBounds.y + (screenBox.y - arrangeMap.pad) / arrangeMap.k,
                        Style.space(10) / arrangeMap.k)
                    }
                    onCanceled: {
                      root.mapDragging = false
                      root.mapOverride = root.mapRects.slice()
                    }
                  }
                }
              }
            }

            Row {
              id: arrangeRow
              visible: root.arrangeVisible
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.arrangeOptions

                ArrangePill {
                  required property var modelData
                  required property int index

                  side: modelData
                  pillIndex: index
                  width: (arrangeRow.width - arrangeRow.spacing * (root.arrangeOptions.length - 1)) / root.arrangeOptions.length
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component TextModePill: Button {
    id: modePill
    required property var mode
    required property int pillIndex

    text: mode.label
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.textMode === mode.id
    hasCursor: root.cursorActive && root.focusSection === "rendering" && root.selectedIndex === pillIndex

    onClicked: root.setTextMode(mode.id)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "rendering"
      root.selectedIndex = modePill.pillIndex
    }
  }

  component RefreshPill: Button {
    id: refreshPill
    required property var option
    required property int pillIndex

    text: option.label
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.refreshIsCurrent(option)
    hasCursor: root.cursorActive && root.focusSection === "refresh" && root.selectedIndex === pillIndex

    onClicked: root.setRefresh(option)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "refresh"
      root.selectedIndex = refreshPill.pillIndex
    }
  }

  component ArrangePill: Button {
    id: arrangePill
    required property var side
    required property int pillIndex

    text: side.label
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.targetSide === side.id
    hasCursor: root.cursorActive && root.focusSection === "arrange" && root.selectedIndex === pillIndex

    onClicked: root.arrange(side.id)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "arrange"
      root.selectedIndex = arrangePill.pillIndex
    }
  }

  component TargetPill: Button {
    id: targetPill
    required property string monitorName
    required property int pillIndex

    text: monitorName
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.targetMonitor === monitorName
    hasCursor: root.cursorActive && root.focusSection === "target" && root.selectedIndex === pillIndex

    onClicked: root.targetMonitor = monitorName
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "target"
      root.selectedIndex = targetPill.pillIndex
    }
  }

  // One "looks like" desktop size: the size, then its scale.
  component ScaleOption: CursorSurface {
    id: scaleOption
    required property var option
    required property int scaleIndex

    readonly property bool isActive: root.activeScaleIndex() === scaleIndex

    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(scaleOption)
    current: isActive
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    outline: true
    implicitHeight: optionLabels.implicitHeight + Style.spacing.lg

    // One line: the size on the left, its scale on the right (with "native"
    // or "sharpest" in front where it applies), so a long list stays short.
    Item {
      id: optionLabels
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      // Clear of the highlight's rounded ends: its radius follows Hyprland's
      // window rounding, which can make it a full pill.
      anchors.leftMargin: root.insetFor(scaleOption)
      anchors.rightMargin: root.insetFor(scaleOption)
      implicitHeight: Math.max(sizeText.implicitHeight, factorText.implicitHeight)

      Text {
        id: sizeText
        textFormat: Text.PlainText
        text: scaleOption.option.width + " × " + scaleOption.option.height
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: scaleOption.isActive
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: factorText.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: factorText
        textFormat: Text.PlainText
        text: (scaleOption.option.exact === 1 ? "native " : "")
          + (scaleOption.option.exact === 2 ? "sharpest " : "")
          + scaleOption.option.scale + "×"
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "scale"
        root.selectedIndex = scaleOption.scaleIndex
      }
      onClicked: root.setScale(scaleOption.option.exact)
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.insetFor(monitorRow, Style.space(6))
      anchors.rightMargin: root.insetFor(monitorRow, Style.space(6))
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
