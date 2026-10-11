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
  if (entry.command) return String(entry.command)
  if (entry.keys) return "Keys " + entry.keys
  return "Not assigned"
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
  var extras = []
  for (var id in seenControls) {
    var info = seenControls[id]
    if (!isObject(info) || covered[id]) continue
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

function tooltip(state, daemonRunning, rows) {
  var lines = ["Vibekey · " + statusText(state, daemonRunning)]
  if (isObject(state) && isObject(state.last) && state.last.label) {
    lines.push("Last: " + state.last.label + (state.last.action ? " → " + state.last.action : ""))
  }
  var assigned = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].entry) assigned++
  lines.push(assigned + " of " + rows.length + " controls assigned")
  return lines.join("\n")
}
