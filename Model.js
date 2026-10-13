// Pure helpers for the Vibekey panel. No QML here, so they can be reasoned
// about (and tested) on their own.
.pragma library

// The six physical controls, in the order the panel lists them. The ids match
// the slot names bin/vibekeyd resolves factory key codes to.
var SLOTS = [
  { key: "key1", label: "Voice key", hint: "Top key with the microphone" },
  { key: "key2", label: "Confirm key", hint: "The ✓ key" },
  { key: "key3", label: "Cancel key", hint: "The ✕ key" },
  { key: "knob", label: "Knob press", hint: "Push the knob" },
  { key: "knob_right", label: "Knob right", hint: "Turn clockwise, one notch" },
  { key: "knob_left", label: "Knob left", hint: "Turn counter-clockwise, one notch" }
]

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function parseJson(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return isObject(parsed) ? parsed : fallback
  } catch (e) {
    return fallback
  }
}

function buttons(config) {
  return isObject(config) && isObject(config.buttons) ? config.buttons : {}
}

function presetById(presets, id) {
  if (!Array.isArray(presets) || !id) return null
  for (var i = 0; i < presets.length; i++) {
    if (presets[i] && presets[i].id === id) return presets[i]
  }
  return null
}

// What an assignment does, in a few words.
function summary(entry, presets) {
  if (!isObject(entry)) return "Not assigned"
  var preset = presetById(presets, entry.preset)
  if (preset && preset.label) return preset.label
  if (entry.label) return String(entry.label)
  if (entry.scroll) return "Scroll " + entry.scroll
  if (entry.command) return String(entry.command)
  if (entry.keys) return "Keys " + entry.keys
  return "Not assigned"
}

// ---- The knob turn is one setting: a mode that assigns both directions. ----

function knobTurnOptions(knobPresets) {
  var options = [{ value: "none", label: "Nothing", description: "Turning the knob does nothing" }]
  if (Array.isArray(knobPresets)) {
    for (var i = 0; i < knobPresets.length; i++) {
      var preset = knobPresets[i]
      if (!preset || !preset.id) continue
      options.push({ value: String(preset.id), label: String(preset.label || preset.id), description: String(preset.description || "") })
    }
  }
  return options
}

// The mode id the current knob_right/knob_left entries came from, "none" when
// both are empty, or "custom" when they were set some other way.
function knobTurnMode(config, knobPresets) {
  var assigned = buttons(config)
  var right = assigned.knob_right, left = assigned.knob_left
  if (!isObject(right) && !isObject(left)) return "none"
  var tag = isObject(right) && right.preset ? String(right.preset) : (isObject(left) && left.preset ? String(left.preset) : "")
  if (tag.indexOf("knob:") === 0 && presetById(knobPresets, tag.slice(5))) return tag.slice(5)
  return "custom"
}

function knobTurnSummary(config, knobPresets, presets) {
  var mode = knobTurnMode(config, knobPresets)
  if (mode === "none") return "Not assigned"
  var preset = presetById(knobPresets, mode)
  if (preset) return String(preset.label)
  var assigned = buttons(config)
  return "\u2192 " + summary(assigned.knob_right, presets) + "  \u2190 " + summary(assigned.knob_left, presets)
}

// The two config entries a knob mode stands for, fields copied so the daemon
// never needs the catalogue.
function entriesForKnobPreset(preset) {
  if (!isObject(preset)) return null
  function entry(side) {
    var out = { preset: "knob:" + String(preset.id || ""), label: String(preset.label || "") }
    var fields = ["command", "keys", "scroll", "release_command", "release_keys"]
    var source = isObject(preset[side]) ? preset[side] : {}
    for (var i = 0; i < fields.length; i++) if (source[fields[i]]) out[fields[i]] = String(source[fields[i]])
    return out
  }
  return { right: entry("right"), left: entry("left") }
}

// The editor's dropdown value for an assignment.
function editorMode(entry, presets) {
  if (!isObject(entry)) return "none"
  if (presetById(presets, entry.preset)) return entry.preset
  if (entry.command) return "custom"
  if (entry.keys) return "keys"
  return "none"
}

// Rows for the panel: the six physical controls first, then anything else the
// device has sent (a key remapped in firmware shows up as a raw id).
function controls(config, seen, presets) {
  var rows = []
  var assigned = buttons(config)
  var seenControls = isObject(seen) && isObject(seen.controls) ? seen.controls : {}
  var covered = {}
  for (var i = 0; i < SLOTS.length; i++) {
    var slot = SLOTS[i]
    covered[slot.key] = true
    rows.push({
      key: slot.key,
      label: slot.label,
      hint: slot.hint,
      entry: isObject(assigned[slot.key]) ? assigned[slot.key] : null,
      summary: summary(assigned[slot.key], presets),
      extra: false
    })
  }
  var aliases = isObject(config) && isObject(config.aliases) ? config.aliases : {}
  var extras = []
  for (var id in seenControls) {
    var info = seenControls[id]
    if (!isObject(info) || covered[id]) continue
    if (aliases[id] && covered[aliases[id]]) continue
    if (info.slot && covered[info.slot]) continue
    extras.push({ key: id, label: String(info.label || id), last: Number(info.last || 0) })
  }
  for (var key in assigned) {
    if (covered[key]) continue
    var known = false
    for (var j = 0; j < extras.length; j++) if (extras[j].key === key) known = true
    if (!known) extras.push({ key: key, label: key, last: 0 })
  }
  extras.sort(function(a, b) { return b.last - a.last })
  for (var k = 0; k < extras.length; k++) {
    var raw = extras[k]
    covered[raw.key] = true
    rows.push({
      key: raw.key,
      label: raw.label,
      hint: raw.key,
      entry: isObject(assigned[raw.key]) ? assigned[raw.key] : null,
      summary: summary(assigned[raw.key], presets),
      extra: true
    })
  }
  return rows
}

// Build the config entry a preset stands for, copying the fields so the
// daemon never needs the preset catalogue.
function entryForPreset(preset) {
  if (!isObject(preset)) return null
  var entry = { preset: String(preset.id || ""), label: String(preset.label || "") }
  var fields = ["command", "keys", "release_command", "release_keys"]
  for (var i = 0; i < fields.length; i++) {
    if (preset[fields[i]]) entry[fields[i]] = String(preset[fields[i]])
  }
  return entry
}

function entryForCommand(command) {
  var text = String(command || "").trim()
  return text === "" ? null : { command: text }
}

function entryForKeys(keys) {
  var text = String(keys || "").replace(/\s+/g, "")
  return text === "" ? null : { keys: text, label: "Keys " + text }
}

// Dropdown options: nothing, every preset grouped as the catalogue lists them,
// then the two free-form choices.
function editorOptions(presets) {
  var options = [{ value: "none", label: "Nothing", description: "Leave this control unassigned" }]
  if (Array.isArray(presets)) {
    for (var i = 0; i < presets.length; i++) {
      var preset = presets[i]
      if (!preset || !preset.id) continue
      options.push({
        value: String(preset.id),
        label: String(preset.label || preset.id),
        description: String(preset.description || preset.command || preset.keys || "")
      })
    }
  }
  options.push({ value: "custom", label: "Custom command…", description: "Run any shell command" })
  options.push({ value: "keys", label: "Send key combo…", description: "Type a shortcut such as ctrl+shift+t" })
  return options
}

// Which physical control a raw id stands for, for the "Also seen" editor.
function slotOptions() {
  var options = [{ value: "none", label: "Not one of the six", description: "Keep it as its own control" }]
  for (var i = 0; i < SLOTS.length; i++) {
    options.push({ value: SLOTS[i].key, label: SLOTS[i].label, description: SLOTS[i].hint })
  }
  return options
}

function aliasOf(config, rawId) {
  var aliases = isObject(config) && isObject(config.aliases) ? config.aliases : {}
  return aliases[rawId] ? String(aliases[rawId]) : "none"
}

// Presets by group, in catalogue order: [{ name, presets: [...] }].
function groupedPresets(presets) {
  var groups = [], index = {}
  if (!Array.isArray(presets)) return groups
  for (var i = 0; i < presets.length; i++) {
    var preset = presets[i]
    if (!preset || !preset.id) continue
    var name = String(preset.group || "Other")
    if (index[name] === undefined) {
      index[name] = groups.length
      groups.push({ name: name, presets: [] })
    }
    groups[index[name]].presets.push(preset)
  }
  return groups
}

// Deterministic pseudo-random in [0, 1) for the scribble lines, so the fake
// text looks the same every time the panel opens.
function noise(seed) {
  var x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453
  return x - Math.floor(x)
}

function statusText(state, daemonRunning) {
  if (!isObject(state)) return daemonRunning ? "Starting driver…" : "Driver not running"
  if (state.access === "denied") return "Needs device access"
  if (!daemonRunning && state.access === "stopped") return "Driver not running"
  if (state.connected !== true) return "Looking for the dongle…"
  var text = "Connected"
  var battery = state.battery
  if (isObject(battery) && isFinite(Number(battery.percent))) {
    text += " · Battery " + Math.round(Number(battery.percent)) + "%"
    if (battery.charging === true) text += ", charging"
  }
  return text
}

function batteryGlyph(battery) {
  if (!isObject(battery) || !isFinite(Number(battery.percent))) return ""
  var percent = Number(battery.percent)
  if (battery.charging === true) return "󰂄"  // nf-md-battery_charging
  var steps = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(10, Math.round(percent / 10)))
  return steps[index]
}

function tooltip(state, daemonRunning, assigned, total) {
  var lines = ["Vibekey · " + statusText(state, daemonRunning)]
  if (isObject(state) && isObject(state.last) && state.last.label) {
    lines.push("Last: " + state.last.label + (state.last.action ? " → " + state.last.action : ""))
  }
  lines.push(assigned + " of " + total + " controls assigned")
  return lines.join("\n")
}
