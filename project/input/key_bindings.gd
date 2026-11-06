# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The keyboard's game controls: which key does what, in one table every
## handler asks (game/main.gd, ui/game_ui.gd, input/gamepad.gd's stand in
## keys, agents/control_ui.gd's action names), so a key changed in Settings,
## Key bindings changes everywhere at once. All static, never instanced;
## preloaded as KeyBindings.
#
# Stored as Luanti stores them. The section is [keymap] in goanna.cfg, each
# key named as Luanti's own setting (keymap_forward, keymap_drop) and its
# value in Luanti's key format: SYSTEM_SCANCODE_<USB HID usage> as Luanti
# 5.12 and later write it, with the Irrlicht names older minetest.conf files
# hold (KEY_KEY_Q, KEY_LSHIFT) read as well, so a line copied from a Luanti
# config means the same key here. Luanti joins a key and a controller button
# with "|"; the first keyboard part is taken and the rest left to the
# controller, which has its own fixed layout (input/gamepad.gd). Only keys
# changed from Goanna's defaults are written, as Luanti writes only what
# differs from its own; "" is a key deliberately left unset. Goanna does not
# read Luanti's minetest.conf itself.
#
# Keys are matched by position, as Luanti's scancodes are: Godot's physical
# keycode, which is the key's name on a US layout, falling back to the
# keycode for an event that has no physical one (some pushed by tests).
extends RefCounted

const CFG_PATH := "user://goanna.cfg"
const SECTION := "keymap"

## [id, Luanti setting, label shown, group, default key]. Defaults are
## Luanti's (src/defaultsettings.cpp) except camera_mode, which Goanna
## keeps on F7 where Luanti moved it to C.
const ACTIONS := [
	["forward", "keymap_forward", "Move forward", "Movement", KEY_W],
	["backward", "keymap_backward", "Move back", "Movement", KEY_S],
	["left", "keymap_left", "Move left", "Movement", KEY_A],
	["right", "keymap_right", "Move right", "Movement", KEY_D],
	["jump", "keymap_jump", "Jump", "Movement", KEY_SPACE],
	["sneak", "keymap_sneak", "Sneak", "Movement", KEY_SHIFT],
	["aux1", "keymap_aux1", "Aux1, and use what you point at", "Movement", KEY_E],
	["freemove", "keymap_freemove", "Fly", "Movement", KEY_K],
	["inventory", "keymap_inventory", "Inventory", "Items", KEY_I],
	["drop", "keymap_drop", "Drop item", "Items", KEY_Q],
	["slot1", "keymap_slot1", "Hotbar slot 1", "Hotbar", KEY_1],
	["slot2", "keymap_slot2", "Hotbar slot 2", "Hotbar", KEY_2],
	["slot3", "keymap_slot3", "Hotbar slot 3", "Hotbar", KEY_3],
	["slot4", "keymap_slot4", "Hotbar slot 4", "Hotbar", KEY_4],
	["slot5", "keymap_slot5", "Hotbar slot 5", "Hotbar", KEY_5],
	["slot6", "keymap_slot6", "Hotbar slot 6", "Hotbar", KEY_6],
	["slot7", "keymap_slot7", "Hotbar slot 7", "Hotbar", KEY_7],
	["slot8", "keymap_slot8", "Hotbar slot 8", "Hotbar", KEY_8],
	["slot9", "keymap_slot9", "Hotbar slot 9", "Hotbar", KEY_9],
	["slot10", "keymap_slot10", "Hotbar slot 10", "Hotbar", KEY_0],
	["chat", "keymap_chat", "Chat, or hold to speak", "Chat", KEY_T],
	["cmd", "keymap_cmd", "Chat command", "Chat", KEY_SLASH],
	["camera_mode", "keymap_camera_mode", "Change camera", "Camera", KEY_F7],
]

## Controls listed beside the keys that cannot be changed here: [label,
## group, what does it, why it is fixed].
const FIXED := [
	["Dig", "Digging and placing", "Left Click",
		"Digging stays on the left mouse button. Goanna cannot move it to a key yet."],
	["Place or use", "Digging and placing", "Right Click",
		"Placing stays on the right mouse button. Goanna cannot move it to a key yet."],
	["Pause menu", "Menus", "Escape",
		"Escape always opens the pause menu and closes windows, so it can never be lost."],
	["Read aloud", "Menus", "Ctrl+B",
		"Ctrl+B turns Read aloud on and off everywhere, menus included, so it stays fixed."],
]

## Keys no action may take, with the reason.
const RESERVED := {KEY_ESCAPE: "Escape always opens the pause menu and closes windows."}

static var _keys := {}		# id -> Key, KEY_NONE for unset
static var _loaded := false

static func _row(id: String) -> Array:
	for a in ACTIONS:
		if a[0] == id:
			return a
	return []

static func ids() -> Array:
	return ACTIONS.map(func(a: Array) -> String: return a[0])

static func label_of(id: String) -> String:
	var r := _row(id)
	return str(r[2]) if not r.is_empty() else ""

static func setting_of(id: String) -> String:
	var r := _row(id)
	return str(r[1]) if not r.is_empty() else ""

static func default_of(id: String) -> Key:
	var r := _row(id)
	return r[4] if not r.is_empty() else KEY_NONE

## The key an action is on now, KEY_NONE if it is unset or not an action.
static func key_of(id: String) -> Key:
	_ensure()
	return _keys.get(id, KEY_NONE)

## The key a pushed event for this action should carry: the bound key, or
## the default when the player has left it unset, so a test's action name
## always presses something.
static func key_or_default(id: String) -> Key:
	var k := key_of(id)
	return k if k != KEY_NONE else default_of(id)

## The key an event is, by position (see the head of this file).
static func event_key(event: InputEventKey) -> Key:
	return event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode

## Whether a key event, pressed or released, is this action's key.
static func matches(id: String, event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var k := key_of(id)
	return k != KEY_NONE and event_key(event as InputEventKey) == k

## A fresh press of the action's key: down, and not the keyboard's repeat.
static func pressed(id: String, event: InputEvent) -> bool:
	return matches(id, event) and event.is_pressed() and not event.is_echo()

## The action that has this key, or "".
static func action_on(key: Key, except := "") -> String:
	_ensure()
	if key == KEY_NONE:
		return ""
	for id in ids():
		if id != except and _keys.get(id, KEY_NONE) == key:
			return id
	return ""

## Actions sharing a key with another, which a hand edited goanna.cfg can
## produce: id -> the label of the first other action on the same key.
static func clashes() -> Dictionary:
	_ensure()
	var out := {}
	for id in ids():
		var other := action_on(_keys.get(id, KEY_NONE), id)
		if other != "":
			out[id] = label_of(other)
	return out

## Puts an action on a key and saves it. Refuses a reserved key or one
## another action has, returning why; "" when it is done.
static func set_key(id: String, key: Key) -> String:
	_ensure()
	if _row(id).is_empty():
		return "There is no such control."
	if RESERVED.has(key):
		return str(RESERVED[key])
	var other := action_on(key, id)
	if other != "":
		return "%s is already %s. Change %s first." % [key_name(key), label_of(other), label_of(other)]
	_keys[id] = key
	_save()
	return ""

## Leaves an action with no key.
static func clear(id: String) -> void:
	_ensure()
	if _row(id).is_empty():
		return
	_keys[id] = KEY_NONE
	_save()

## Every action back on its default key; the saved section is removed.
static func reset() -> void:
	_keys.clear()
	for a in ACTIONS:
		_keys[a[0]] = a[4]
	_loaded = true
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	if cfg.has_section(SECTION):
		cfg.erase_section(SECTION)
	cfg.save(CFG_PATH)

## Reads goanna.cfg again; the menu and the game read the same table.
static func reload() -> void:
	_loaded = false
	_ensure()

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_keys.clear()
	var cfg := ConfigFile.new()
	var ok := cfg.load(CFG_PATH) == OK
	for a in ACTIONS:
		var k: Key = a[4]
		if ok and cfg.has_section_key(SECTION, a[1]):
			var parsed := parse_setting(str(cfg.get_value(SECTION, a[1])))
			# A value naming only a mouse or controller button leaves the
			# keyboard on its default rather than on nothing.
			if parsed != -1:
				k = parsed as Key
		_keys[a[0]] = k

static func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	for a in ACTIONS:
		var k: Key = _keys.get(a[0], a[4])
		if k == a[4]:
			if cfg.has_section_key(SECTION, a[1]):
				cfg.erase_section_key(SECTION, a[1])
		else:
			cfg.set_value(SECTION, a[1], to_setting(k))
	cfg.save(CFG_PATH)

# --- Luanti's key format ----------------------------------------------------

## Keys as Luanti 5.17 knows them: [Godot physical key, SDL scancode (the
## USB HID usage), Irrlicht key name as older settings wrote it, key name
## shown]. ui/formspec.gd's key_event buttons use the same table.
static func key_table() -> Array:
	var t: Array = []
	for i in 26:
		var ch := char(65 + i)
		t.append([KEY_A + i, 4 + i, "KEY_KEY_" + ch, ch])
	for i in 9:
		t.append([KEY_1 + i, 30 + i, "KEY_KEY_%d" % (i + 1), str(i + 1)])
	t.append([KEY_0, 39, "KEY_KEY_0", "0"])
	t.append_array([[KEY_ENTER, 40, "KEY_RETURN", "Return"], [KEY_ESCAPE, 41, "KEY_ESCAPE", "Escape"],
		[KEY_BACKSPACE, 42, "KEY_BACK", "Backspace"], [KEY_TAB, 43, "KEY_TAB", "Tab"],
		[KEY_SPACE, 44, "KEY_SPACE", "Space"], [KEY_MINUS, 45, "KEY_MINUS", "-"],
		[KEY_EQUAL, 46, "KEY_PLUS", "="], [KEY_BRACKETLEFT, 47, "KEY_OEM_4", "["],
		[KEY_BRACKETRIGHT, 48, "KEY_OEM_6", "]"], [KEY_BACKSLASH, 49, "KEY_OEM_5", "\\"],
		[KEY_SEMICOLON, 51, "KEY_OEM_1", ";"], [KEY_APOSTROPHE, 52, "KEY_OEM_7", "'"],
		[KEY_QUOTELEFT, 53, "KEY_OEM_3", "`"], [KEY_COMMA, 54, "KEY_COMMA", ","],
		[KEY_PERIOD, 55, "KEY_PERIOD", "."], [KEY_SLASH, 56, "KEY_OEM_2", "/"],
		[KEY_CAPSLOCK, 57, "KEY_CAPITAL", "Caps Lock"]])
	for i in 12:
		t.append([KEY_F1 + i, 58 + i, "KEY_F%d" % (i + 1), "F%d" % (i + 1)])
	t.append_array([[KEY_INSERT, 73, "KEY_INSERT", "Insert"], [KEY_HOME, 74, "KEY_HOME", "Home"],
		[KEY_PAGEUP, 75, "KEY_PRIOR", "Page Up"], [KEY_DELETE, 76, "KEY_DELETE", "Delete"],
		[KEY_END, 77, "KEY_END", "End"], [KEY_PAGEDOWN, 78, "KEY_NEXT", "Page Down"],
		[KEY_RIGHT, 79, "KEY_RIGHT", "Right"], [KEY_LEFT, 80, "KEY_LEFT", "Left"],
		[KEY_DOWN, 81, "KEY_DOWN", "Down"], [KEY_UP, 82, "KEY_UP", "Up"]])
	for i in 9:
		t.append([KEY_KP_1 + i, 89 + i, "KEY_NUMPAD%d" % (i + 1), "Keypad %d" % (i + 1)])
	t.append([KEY_KP_0, 98, "KEY_NUMPAD0", "Keypad 0"])
	# Modifiers: the right hand ones are told apart by location below.
	t.append_array([[KEY_CTRL, 224, "KEY_LCONTROL", "Left Control"],
		[KEY_SHIFT, 225, "KEY_LSHIFT", "Left Shift"], [KEY_ALT, 226, "KEY_LMENU", "Left Alt"],
		[-1, 228, "KEY_RCONTROL", "Right Control"], [-1, 229, "KEY_RSHIFT", "Right Shift"],
		[-1, 230, "KEY_RMENU", "Right Alt"]])
	return t

# Godot has one keycode for each modifier and tells left from right by the
# event's location, so a right hand modifier in a setting is the same key.
const _RIGHT_MODIFIERS := {228: KEY_CTRL, 229: KEY_SHIFT, 230: KEY_ALT,
	"KEY_RCONTROL": KEY_CTRL, "KEY_RSHIFT": KEY_SHIFT, "KEY_RMENU": KEY_ALT,
	"KEY_SHIFT": KEY_SHIFT, "KEY_CONTROL": KEY_CTRL, "KEY_MENU": KEY_ALT}

## A Luanti key setting as a Godot key: KEY_NONE for "", -1 when it names
## no keyboard key (a mouse or controller button only, or nothing known).
static func parse_setting(value: String) -> int:
	var v := value.strip_edges()
	if v == "":
		return KEY_NONE
	for part in v.split("|", false):
		var p := part.strip_edges()
		if p.begins_with("SYSTEM_SCANCODE_"):
			var code := p.substr(16).to_int()
			if _RIGHT_MODIFIERS.has(code):
				return _RIGHT_MODIFIERS[code]
			for row in key_table():
				if int(row[1]) == code and int(row[0]) != -1:
					return int(row[0])
		elif p.begins_with("KEY_"):
			if _RIGHT_MODIFIERS.has(p):
				return _RIGHT_MODIFIERS[p]
			for row in key_table():
				if row[2] == p and int(row[0]) != -1:
					return int(row[0])
		elif not (p.begins_with("MOUSE_") or p.begins_with("GAMEPAD_")):
			# A Godot key name, which is what to_setting writes for a key
			# Luanti's table has no scancode for.
			var k := OS.find_keycode_from_string(p)
			if k != KEY_NONE:
				return k
	return -1

## A key in Luanti's format, or its Godot name for a key Luanti's table
## lacks (Luanti will not read that one, but Goanna will).
static func to_setting(key: Key) -> String:
	if key == KEY_NONE:
		return ""
	for row in key_table():
		if int(row[0]) == int(key):
			return "SYSTEM_SCANCODE_%d" % int(row[1])
	return OS.get_keycode_string(key)

## A key's name for the player: "Q", "Space", "Shift", "F7", "Not set". A
## letter or symbol key is named as the player's layout prints it at that
## place, since keys are matched by place (on AZERTY, Luanti's Q is "A").
static func key_name(key: Key) -> String:
	if key != KEY_NONE and DisplayServer.get_name() != "headless":
		var printed := DisplayServer.keyboard_get_label_from_physical(key)
		if printed != KEY_NONE and printed != key and printed < KEY_SPECIAL:
			return OS.get_keycode_string(printed)
	match key:
		KEY_NONE: return "Not set"
		KEY_SHIFT: return "Shift"
		KEY_CTRL: return "Ctrl"
		KEY_ALT: return "Alt"
		KEY_ENTER: return "Enter"
	for row in key_table():
		if int(row[0]) == int(key):
			return str(row[3])
	return OS.get_keycode_string(key)

## The name of the key an action is on, for hints ("Press F7 ...").
static func name_of(id: String) -> String:
	return key_name(key_of(id))
