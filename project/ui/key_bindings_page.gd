# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Settings, Key bindings: the keyboard's game controls as a table of what
## each does and the key it is on, where a key is changed by choosing it
## and pressing the new one. The main menu (menu/menu.gd) and the in-game
## settings (ui/game_ui.gd) both put one of these on a page of its own. It
## reads and writes input/key_bindings.gd, which every key handler asks, so
## a change takes effect at once in a game and is saved for the next.
#
# A key another control already has is refused with the reason, rather than
# moved, so nothing is left without a key unnoticed. Controls that cannot
# be changed (digging and placing on the mouse, Escape, Ctrl+B) are listed
# greyed, and pressing one says why. A goanna.cfg edited by hand can still
# put two controls on one key; both are then marked and named at the top.
extends VBoxContainer

const KeyBindings := preload("res://input/key_bindings.gd")
const GlassStyle := preload("res://ui/glass_style.gd")
const PanelFit := preload("res://ui/panel_fit.gd")

const TARGET := 40.0
## The key column's width: the longest key name ("Right Control", "Keypad
## 0", "Press a key") at body size, so the column lines up as a table.
const KEY_WIDTH := 150.0
const QUIET := Color(1, 1, 1, 0.6)
const WARN := Color(1, 0.85, 0.4)
const GROUPS := ["Movement", "Items", "Hotbar", "Chat", "Camera"]
const FIXED_GROUPS := ["Digging and placing", "Menus"]
const CAPTURE_TEXT := "Press a key"

## The action whose key is being changed, or "".
var capturing := ""
## The note at the top: what was refused and why, or the clashes.
var status: Label
var reset_button: Button
var _buttons := {}		# action id -> its key Button
var _labels := {}		# action id -> its name Label

func _init() -> void:
	name = "KeyBindings"
	add_theme_constant_override("separation", 8)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var intro := Label.new()
	intro.text = "Choose a key, then press the new key for it. Escape cancels."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_font_size_override("font_size", 14)
	GlassStyle.tint_text(intro, QUIET)
	add_child(intro)
	status = Label.new()
	status.name = "Status"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", 14)
	GlassStyle.tint_text(status, WARN)
	status.visible = false
	add_child(status)
	_header_row()
	for group in GROUPS:
		PanelFit.heading(self, group)
		for a in KeyBindings.ACTIONS:
			if a[3] == group:
				_action_row(str(a[0]), str(a[2]))
	for group in FIXED_GROUPS:
		PanelFit.heading(self, group)
		for f in KeyBindings.FIXED:
			if f[1] == group:
				_fixed_row(str(f[0]), str(f[2]), str(f[3]))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 16)
	add_child(gap)
	reset_button = Button.new()
	reset_button.name = "Reset"
	reset_button.text = "Reset to defaults"
	reset_button.custom_minimum_size.y = TARGET
	reset_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset_button.pressed.connect(reset)
	add_child(reset_button)
	refresh()

# Column headings, quiet, over the two columns.
func _header_row() -> void:
	var row := _row()
	for text in ["Action", "Key"]:
		var l := Label.new()
		l.text = text
		l.add_theme_font_size_override("font_size", 14)
		GlassStyle.tint_text(l, QUIET)
		if text == "Action":
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			l.custom_minimum_size.x = KEY_WIDTH
		row.add_child(l)

func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(row)
	return row

func _name_label(row: HBoxContainer, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 17)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Wraps rather than squashing or running under the key at a narrow
	# window; a label needs some width to wrap into.
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 80
	row.add_child(l)
	return l

func _key_button(row: HBoxContainer) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(KEY_WIDTH, TARGET)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(b)
	return b

func _action_row(id: String, title: String) -> void:
	var row := _row()
	_labels[id] = _name_label(row, title)
	var b := _key_button(row)
	b.name = "Key_" + id
	b.pressed.connect(func() -> void: start_capture(id))
	_buttons[id] = b

func _fixed_row(title: String, key_text: String, reason: String) -> void:
	var row := _row()
	var l := _name_label(row, title)
	GlassStyle.tint_text(l, GlassStyle.TEXT_DISABLED)
	var b := _key_button(row)
	b.text = key_text
	b.tooltip_text = reason
	b.set_meta("fixed", true)
	b.add_theme_color_override("font_color", GlassStyle.TEXT_DISABLED)
	b.add_theme_color_override("font_hover_color", GlassStyle.TEXT_DISABLED)
	b.add_theme_color_override("font_focus_color", GlassStyle.TEXT_DISABLED)
	b.add_theme_color_override("font_pressed_color", GlassStyle.TEXT_DISABLED)
	b.flat = true
	# Greyed, not disabled: pressing it says why, in place, and does
	# nothing else (docs/systems/interface-layout.md, "Unavailable things").
	b.pressed.connect(func() -> void: _say(reason))

## Every key button's text and marking, from the bindings as they are now.
func refresh() -> void:
	var clashes := KeyBindings.clashes()
	for id in _buttons:
		var b: Button = _buttons[id]
		if id == capturing:
			b.text = CAPTURE_TEXT
		else:
			b.text = KeyBindings.name_of(id)
		if clashes.has(id):
			b.add_theme_color_override("font_color", WARN)
			b.tooltip_text = "%s is also %s." % [KeyBindings.name_of(id), clashes[id]]
		else:
			b.remove_theme_color_override("font_color")
			b.tooltip_text = ""
	if not clashes.is_empty() and capturing == "":
		var names: Array = clashes.keys().map(func(id: String) -> String: return KeyBindings.label_of(id))
		_say("These share a key, so one press does both: %s. Change one of each pair." % ", ".join(names))

func _say(text: String) -> void:
	status.text = text
	status.visible = text != ""

## Waits for the next key press to become this action's key.
func start_capture(id: String) -> void:
	if capturing != "" and capturing != id:
		cancel_capture()
	capturing = id
	_say("")
	refresh()

func cancel_capture() -> void:
	capturing = ""
	refresh()

## Takes `key` for the action being changed, or says why not.
func take_key(key: Key) -> void:
	var id := capturing
	capturing = ""
	if id == "":
		return
	var why := KeyBindings.set_key(id, key)
	_say(why)
	refresh()
	if why == "" and _buttons.has(id):
		(_buttons[id] as Button).grab_focus()

func reset() -> void:
	capturing = ""
	KeyBindings.reset()
	_say("Every key is back on its default.")
	refresh()

# Before the GUI and every game handler, so the key pressed to bind is
# taken here and does nothing else: not the game action it used to be, and
# Escape cancels rather than closing the settings.
func _input(event: InputEvent) -> void:
	if capturing == "" or not is_visible_in_tree():
		return
	if event is InputEventMouseButton and event.pressed:
		cancel_capture()
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	get_viewport().set_input_as_handled()
	if not k.pressed or k.echo:
		return
	var key := KeyBindings.event_key(k)
	if key == KEY_ESCAPE:
		var id := capturing
		cancel_capture()
		if _buttons.has(id):
			(_buttons[id] as Button).grab_focus()
		return
	take_key(key)
