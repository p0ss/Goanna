# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Game controller input, loaded as the Gamepad autoload so the main menu, the
# game and every form get the same handling.
#
# In play, main.gd asks this for the stick and button state each frame and
# folds it into the same keys dictionary, look angles and dig and place flags
# the keyboard and mouse already drive. The controller reaches the server
# through nothing else, so it can do only what a keyboard and mouse can.
#
# Outside play (a form, the inventory, the pause menu, settings, the main
# menu) the left stick moves a cursor of its own and the face buttons click
# with it. Luanti's forms are laid out for a pointer and have no focus order
# worth the name, so a pointer is the one thing that reaches every part of
# every form. Each click is an ordinary mouse event pushed through
# Input.parse_input_event, the path control_ui.gd already uses, so a form
# cannot tell it from a mouse. Goanna's own menus are Controls that take
# focus, so the D-pad moves focus through them as well, and A presses what
# has focus.
#
# The layout follows upstream Luanti 5.17's SDL gamepad defaults
# (luanti/src/defaultsettings.cpp), which number buttons and axes the way
# Godot does. docs/controller.md has the table.
extends CanvasLayer

const CFG_PATH := "user://goanna.cfg"

# Mouse events pushed for the cursor carry this device, so one coming back
# through _input can be told from a real mouse. main.gd's CONTROL_DEVICE,
# for the control channel, is 0x60A7.
const POINTER_DEVICE := 0x60A8

# Upstream's joystick_frustum_sensitivity: degrees a second at full
# deflection, before the field of view scale.
const DEFAULT_LOOK_SPEED := 170.0
# Upstream's joystick_inner_deadzone is 0.25. Lower here because Steam Input,
# which is how a Steam Deck's controls reach Goanna, can apply a deadzone of
# its own before Godot sees the stick. Untested on a Deck; the setting is
# there for that reason.
const DEFAULT_DEADZONE := 0.15
# A trigger is a dig or place button, so a light brush should not count.
const TRIGGER_THRESHOLD := 0.4
# Upstream's repeat_joystick_button_time: a held hotbar button steps again
# this often, since controller buttons do not repeat the way keys do.
const REPEAT_SECONDS := 0.17

# Cursor speed in pixels a second at full deflection on a 900 pixel tall
# window, and how much faster it gets when the stick is held over: slow
# enough to land on a slot, fast enough to cross the screen.
const CURSOR_SPEED := 650.0
const CURSOR_ACCEL := 2.0
const CURSOR_RAMP_SECONDS := 0.8
# Wheel steps a second with the right stick fully over, for scrolling lists.
const SCROLL_STEPS := 12.0
const DOUBLE_CLICK_SECONDS := 0.4

# Every binding, by action name. An int is a button; [axis, sign] is one
# direction of an axis. Movement, look, triggers and the play buttons follow
# upstream. The goanna_ui_ ones are the same buttons read outside play.
const ACTIONS := {
	"goanna_move_forward": [JOY_AXIS_LEFT_Y, -1.0],
	"goanna_move_backward": [JOY_AXIS_LEFT_Y, 1.0],
	"goanna_move_left": [JOY_AXIS_LEFT_X, -1.0],
	"goanna_move_right": [JOY_AXIS_LEFT_X, 1.0],
	"goanna_look_left": [JOY_AXIS_RIGHT_X, -1.0],
	"goanna_look_right": [JOY_AXIS_RIGHT_X, 1.0],
	"goanna_look_up": [JOY_AXIS_RIGHT_Y, -1.0],
	"goanna_look_down": [JOY_AXIS_RIGHT_Y, 1.0],
	"goanna_dig": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"goanna_place": [JOY_AXIS_TRIGGER_LEFT, 1.0],
	"goanna_jump": JOY_BUTTON_A,
	"goanna_sneak": JOY_BUTTON_B,
	"goanna_aux1": JOY_BUTTON_X,
	"goanna_inventory": JOY_BUTTON_Y,
	"goanna_pause": JOY_BUTTON_START,
	"goanna_hotbar_previous": JOY_BUTTON_LEFT_SHOULDER,
	"goanna_hotbar_next": JOY_BUTTON_RIGHT_SHOULDER,
	"goanna_drop": JOY_BUTTON_DPAD_DOWN,
	"goanna_ui_click": JOY_BUTTON_A,
	"goanna_ui_secondary": JOY_BUTTON_X,
	"goanna_ui_back": JOY_BUTTON_B,
	"goanna_ui_shift": JOY_BUTTON_LEFT_SHOULDER,
}
const TRIGGERS := ["goanna_dig", "goanna_place"]

# Buttons that stand in for a key, because the key's handler is already the
# right behaviour: Escape opens the pause menu or closes a window, I opens
# the inventory or closes it (ui/game_ui.gd). Upstream's keymap_pause and
# keymap_inventory do the same jobs.
const PLAY_KEYS := {"goanna_pause": KEY_ESCAPE, "goanna_inventory": KEY_I}
const UI_KEYS := {"goanna_pause": KEY_ESCAPE, "goanna_ui_back": KEY_ESCAPE,
	"goanna_inventory": KEY_I}

# Settings, from goanna.cfg and the settings panel.
# A local player consumes only events forwarded into their viewport. Global
# Input state still serves the single-player game and the main menu.
var local_input := false
var device_id := -1
var _strengths := {}

func reset_input() -> void:
	_leave_pointer()
	_strengths.clear()
	_prev.clear()
	_repeat.clear()
	_stale.clear()
	_pending = {"hotbar": 0, "drop": 0, "place": 0}
	move = Vector2.ZERO
	look = Vector2.ZERO
	_was_play = false

func _strength(action: String) -> float:
	return float(_strengths.get(action, 0.0)) if local_input else Input.get_action_raw_strength(action)

func _pressed(action: String) -> bool:
	if not local_input:
		return Input.is_action_pressed(action)
	var threshold := TRIGGER_THRESHOLD if action in TRIGGERS else 0.5
	return _strength(action) > threshold

func _push_event(event: InputEvent) -> void:
	if local_input:
		get_viewport().push_input(event, true)
	else:
		Input.parse_input_event(event)

var enabled := true
var look_speed := DEFAULT_LOOK_SPEED
var invert_y := false
var deadzone := DEFAULT_DEADZONE

# Returns true while the game, rather than a menu, has the controls. main.gd
# sets it; with no game running (the main menu) the controller is a cursor.
var play_owner := Callable()

# Sticks after the deadzone, x right and y down, from -1 to 1.
var move := Vector2.ZERO
var look := Vector2.ZERO

var pointer_pos := Vector2(-1.0, -1.0)
var pointer_shown := false
var _pointer_held := 0.0
var _mask := 0
var _scroll := 0.0
var _focus_nav := false
var _hid_os_pointer := false
var _last_click_time := -10.0
var _last_click_pos := Vector2.ZERO
var _clock := 0.0
var _cursor: Control

# Play edges, taken by main.gd once each.
var _was_play := false
var _prev := {}
var _repeat := {}
var _pending := {"hotbar": 0, "drop": 0, "place": 0}
# Buttons already down when play resumed: A pressing Continue must not jump.
# Each is ignored until it is let go.
var _stale := {}
const HELD_IN_PLAY := ["goanna_jump", "goanna_sneak", "goanna_aux1", "goanna_dig", "goanna_place"]

func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cursor = Control.new()
	_cursor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.draw.connect(_draw_cursor)
	add_child(_cursor)
	load_settings()
	ensure_actions()

# Read at startup, and again by the main menu when its settings screen saves,
# since the menu has no game panel to apply them live.
func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	look_speed = float(cfg.get_value("settings", "pad_look_speed", look_speed))
	invert_y = float(cfg.get_value("settings", "pad_invert_y", 1.0 if invert_y else 0.0)) > 0.5
	set_deadzone(float(cfg.get_value("settings", "pad_deadzone", deadzone)))
	set_enabled(float(cfg.get_value("settings", "pad_enabled", 1.0 if enabled else 0.0)) > 0.5)

# Declare the actions at startup rather than in project.godot, because the
# deadzone is a setting and the keyboard is not in InputMap at all.
func ensure_actions() -> void:
	for action in ACTIONS:
		var dz := TRIGGER_THRESHOLD if action in TRIGGERS else deadzone
		if InputMap.has_action(action):
			InputMap.action_set_deadzone(action, dz)
			continue
		InputMap.add_action(action, dz)
		var binding: Variant = ACTIONS[action]
		var ev: InputEvent
		if binding is Array:
			var m := InputEventJoypadMotion.new()
			m.axis = binding[0]
			m.axis_value = binding[1]
			ev = m
		else:
			var b := InputEventJoypadButton.new()
			b.button_index = binding
			ev = b
		ev.device = -1  # any controller
		InputMap.action_add_event(action, ev)
	# Godot's built-in direction bindings default to controller 0. Events
	# have already been assigned to a player before reaching a local viewport.
	for action in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		for event in InputMap.action_get_events(action):
			if (event is InputEventJoypadButton or event is InputEventJoypadMotion) and event.device != -1:
				InputMap.action_erase_event(action, event)
				var any_pad := event.duplicate() as InputEvent
				any_pad.device = -1
				InputMap.action_add_event(action, any_pad)
	# Godot's ui_accept has no controller button, so A would move focus with
	# the D-pad and then press nothing.
	var has_a := false
	for ev in InputMap.action_get_events("ui_accept"):
		if ev is InputEventJoypadButton and ev.button_index == JOY_BUTTON_A:
			has_a = true
	if not has_a:
		var a := InputEventJoypadButton.new()
		a.button_index = JOY_BUTTON_A
		a.device = -1
		InputMap.action_add_event("ui_accept", a)

func set_deadzone(value: float) -> void:
	deadzone = clampf(value, 0.0, 0.9)
	ensure_actions()

func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		_leave_pointer()
		move = Vector2.ZERO
		look = Vector2.ZERO

func in_play() -> bool:
	return play_owner.is_valid() and bool(play_owner.call())

# --- pure helpers, tested in tests/gamepad.gd --------------------------------

# A radial deadzone, rescaled so the stick still reaches 1 at the rim: a
# small push past the deadzone is a small amount, not a jump to its edge.
# Upstream rescales each axis the same way (keycode.cpp).
static func apply_deadzone(v: Vector2, dz: float) -> Vector2:
	var length := v.length()
	if length <= dz or length == 0.0:
		return Vector2.ZERO
	return v / length * minf(1.0, (length - dz) / maxf(1.0 - dz, 0.0001))

# Degrees to add to yaw and pitch for one frame of right stick. Scaled by
# the field of view as upstream's getSensitivityScaleFactor does, so the
# stick feels the same at any zoom. Pitch is positive looking up, as
# main.gd keeps it.
static func look_delta(v: Vector2, speed: float, delta: float, invert: bool,
		fov_deg: float) -> Vector2:
	var scale := tan(deg_to_rad(fov_deg) * 0.5) * 1.3763819
	var rate := speed * delta * scale
	return Vector2(-v.x * rate, (v.y if invert else -v.y) * rate)

# How far the cursor moves in one frame. Squared deflection for fine control
# near the centre, and faster the longer the stick has been held over.
static func cursor_step(v: Vector2, held: float, delta: float, px_per_sec: float) -> Vector2:
	var mag := minf(v.length(), 1.0)
	if mag == 0.0:
		return Vector2.ZERO
	var accel := 1.0 + CURSOR_ACCEL * clampf(held / CURSOR_RAMP_SECONDS, 0.0, 1.0)
	return v.normalized() * px_per_sec * mag * mag * accel * delta

func _raw(neg: String, pos: String) -> float:
	return _strength(pos) - _strength(neg)

func held(action: String) -> bool:
	return enabled and _pressed(action) and not _stale.has(action)

# --- what main.gd reads in play ----------------------------------------------

# Fold the controller into main.gd's keys dictionary. A key held on the
# keyboard stays a full press; a stick adds its analogue amount only where
# no key is down, which is upstream's rule that keys take priority
# (PlayerControl::setMovementFromKeys).
func merge_keys(keys: Dictionary) -> void:
	if not enabled:
		return
	var amounts := {"up": maxf(0.0, -move.y), "down": maxf(0.0, move.y),
		"left": maxf(0.0, -move.x), "right": maxf(0.0, move.x)}
	for k in amounts:
		if not bool(keys.get(k, false)) and amounts[k] > 0.0:
			keys[k] = amounts[k]
	for pair in [["jump", "goanna_jump"], ["sneak", "goanna_sneak"], ["aux1", "goanna_aux1"]]:
		if held(pair[1]):
			keys[pair[0]] = true

func look_step(delta: float, fov_deg: float) -> Vector2:
	if not enabled:
		return Vector2.ZERO
	return look_delta(look, look_speed, delta, invert_y, fov_deg)

func dig_held() -> bool:
	return held("goanna_dig")

func place_held() -> bool:
	return held("goanna_place")

# How many of an edge happened since the last take: "hotbar" is a signed
# step count, "drop" and "place" are presses.
func take(what: String) -> int:
	var n: int = _pending.get(what, 0)
	_pending[what] = 0
	return n

# --- per frame ---------------------------------------------------------------

func _process(delta: float) -> void:
	step(delta)

func step(delta: float) -> void:
	_clock += delta
	if not enabled:
		return
	move = apply_deadzone(Vector2(_raw("goanna_move_left", "goanna_move_right"),
		_raw("goanna_move_forward", "goanna_move_backward")), deadzone)
	look = apply_deadzone(Vector2(_raw("goanna_look_left", "goanna_look_right"),
		_raw("goanna_look_up", "goanna_look_down")), deadzone)
	var play := in_play()
	if play and not _was_play:
		for action in HELD_IN_PLAY:
			if _pressed(action):
				_stale[action] = true
	for action in _stale.keys():
		if not _pressed(action):
			_stale.erase(action)
	if play:
		_leave_pointer()
		_play_edges(delta, not _was_play)
	else:
		_pointer_step(delta)
	_was_play = play

func _play_edges(delta: float, entering: bool) -> void:
	for action in ["goanna_place", "goanna_drop", "goanna_hotbar_next", "goanna_hotbar_previous"]:
		var down := held(action)
		# A button still down from a menu (A pressing Continue, say) is not
		# a press in the game.
		var pressed: bool = down and not entering and not _prev.get(action, false)
		_prev[action] = down
		var fire := pressed
		if action.begins_with("goanna_hotbar"):
			if pressed:
				_repeat[action] = 0.0
			elif down:
				_repeat[action] = float(_repeat.get(action, 0.0)) + delta
				if _repeat[action] >= REPEAT_SECONDS:
					_repeat[action] -= REPEAT_SECONDS
					fire = true
		if not fire:
			continue
		match action:
			"goanna_place": _pending["place"] += 1
			"goanna_drop": _pending["drop"] += 1
			"goanna_hotbar_next": _pending["hotbar"] += 1
			"goanna_hotbar_previous": _pending["hotbar"] -= 1

# --- the cursor --------------------------------------------------------------

func _screen() -> Vector2:
	return get_viewport().get_visible_rect().size

func _pointer_step(delta: float) -> void:
	if move != Vector2.ZERO:
		_show_pointer()
		_pointer_held += delta
		var px := CURSOR_SPEED * _screen().y / 900.0
		var d := cursor_step(move, _pointer_held, delta, px)
		var to := (pointer_pos + d).clamp(Vector2.ZERO, _screen() - Vector2.ONE)
		if to != pointer_pos:
			pointer_pos = to
			_push_motion()
	else:
		_pointer_held = 0.0
	# Right stick up and down turns the wheel under the cursor.
	if absf(look.y) > 0.0:
		_scroll += -look.y * SCROLL_STEPS * delta
		while absf(_scroll) >= 1.0:
			_show_pointer()
			var up := _scroll > 0.0
			_push_button(MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN, true)
			_push_button(MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN, false)
			_scroll -= 1.0 if up else -1.0
	else:
		_scroll = 0.0

func _show_pointer() -> void:
	_focus_nav = false
	if pointer_shown:
		return
	pointer_shown = true
	if pointer_pos.x < 0.0:
		pointer_pos = _screen() * 0.5
	if not local_input and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		_hid_os_pointer = true
	_cursor.queue_redraw()

func _hide_pointer() -> void:
	if not pointer_shown:
		return
	pointer_shown = false
	if _hid_os_pointer and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_hid_os_pointer = false
	_cursor.queue_redraw()

# Leaving the cursor behind (play resumed, or the controller turned off)
# must not leave a pushed button down: the GUI would go on thinking a drag
# was in progress.
func _leave_pointer() -> void:
	for bit in [[MOUSE_BUTTON_MASK_LEFT, MOUSE_BUTTON_LEFT], [MOUSE_BUTTON_MASK_RIGHT, MOUSE_BUTTON_RIGHT]]:
		if _mask & bit[0]:
			_push_button(bit[1], false)
	_hide_pointer()

func _push_motion() -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = POINTER_DEVICE
	ev.position = pointer_pos
	ev.global_position = pointer_pos
	ev.button_mask = _mask
	ev.shift_pressed = held("goanna_ui_shift")
	_push_event(ev)
	_cursor.queue_redraw()

func _push_button(button: int, pressed: bool) -> void:
	var bit := 0
	match button:
		MOUSE_BUTTON_LEFT: bit = MOUSE_BUTTON_MASK_LEFT
		MOUSE_BUTTON_RIGHT: bit = MOUSE_BUTTON_MASK_RIGHT
	if bit != 0:
		_mask = (_mask | bit) if pressed else (_mask & ~bit)
	var ev := InputEventMouseButton.new()
	ev.device = POINTER_DEVICE
	ev.position = pointer_pos
	ev.global_position = pointer_pos
	ev.button_index = button
	ev.pressed = pressed
	ev.factor = 1.0
	ev.button_mask = _mask
	# LB is Shift, for a shift click that moves a whole stack across.
	ev.shift_pressed = held("goanna_ui_shift")
	# Godot flags a double click on the event itself, and only for events
	# from the OS, so a pushed one has to work it out.
	if pressed and button == MOUSE_BUTTON_LEFT:
		ev.double_click = _clock - _last_click_time < DOUBLE_CLICK_SECONDS \
				and pointer_pos.distance_to(_last_click_pos) < 6.0
		_last_click_time = -10.0 if ev.double_click else _clock
		_last_click_pos = pointer_pos
	_push_event(ev)

func _tap_key(keycode: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.key_label = keycode
		ev.pressed = pressed
		_push_event(ev)

func _draw_cursor() -> void:
	if not pointer_shown:
		return
	var s := clampf(_screen().y / 900.0, 0.75, 2.0) * 18.0
	var p := pointer_pos
	var arrow := PackedVector2Array([p, p + Vector2(0, s), p + Vector2(s * 0.28, s * 0.74),
		p + Vector2(s * 0.7, s * 0.7)])
	_cursor.draw_colored_polygon(arrow, Color.WHITE)
	arrow.append(p)
	_cursor.draw_polyline(arrow, Color.BLACK, 1.5, true)

# --- events ------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.device != POINTER_DEVICE:
			# A real mouse took over; the cursor starts from it next time.
			pointer_pos = (event as InputEventMouseMotion).position
			_hide_pointer()
		return
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	if local_input:
		if event.device != device_id:
			get_viewport().set_input_as_handled()
			return
		for action in ACTIONS:
			var binding: Variant = ACTIONS[action]
			if event is InputEventJoypadButton and binding is int and event.button_index == binding:
				_strengths[action] = 1.0 if event.pressed else 0.0
			elif event is InputEventJoypadMotion and binding is Array and event.axis == binding[0]:
				_strengths[action] = maxf(0.0, event.axis_value * binding[1])
	if not enabled:
		get_viewport().set_input_as_handled()
		return
	# Everything the controller does in play is read from Input's action
	# state in step(), which Godot updated before this event arrived, so the
	# event itself is spent here and never reaches the GUI.
	if in_play():
		_tap_mapped(event, PLAY_KEYS)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and _menu_button(event):
		return
	get_viewport().set_input_as_handled()

# Outside play. Returns true when the event should go on to the GUI.
func _menu_button(event: InputEventJoypadButton) -> bool:
	for dir in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		if event.is_action(dir):
			if not event.pressed:
				return true
			_hide_pointer()
			_focus_nav = true
			if get_viewport().gui_get_focus_owner() == null:
				var first := _first_focusable(get_viewport() if local_input else get_tree().root)
				if first != null:
					first.grab_focus()
					return false
			return true
	if event.is_action("goanna_ui_click"):
		if _focus_nav and get_viewport().gui_get_focus_owner() != null:
			return true  # ui_accept presses what has focus
		_show_pointer()
		_push_button(MOUSE_BUTTON_LEFT, event.pressed)
		return false
	if event.is_action("goanna_ui_secondary"):
		_show_pointer()
		_push_button(MOUSE_BUTTON_RIGHT, event.pressed)
		return false
	_tap_mapped(event, UI_KEYS)
	return false

func _tap_mapped(event: InputEvent, table: Dictionary) -> void:
	if not (event is InputEventJoypadButton and event.pressed):
		return
	for action in table:
		if event.is_action(action):
			_tap_key(table[action])
			return

func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if child == self:
			continue
		if child is Control:
			var c := child as Control
			if not c.is_visible_in_tree():
				continue
			if c.focus_mode != Control.FOCUS_NONE \
					and not (c is BaseButton and (c as BaseButton).disabled):
				return c
		elif child is CanvasItem and not (child as CanvasItem).is_visible_in_tree():
			continue
		elif child is CanvasLayer and not (child as CanvasLayer).visible:
			continue
		var found := _first_focusable(child)
		if found != null:
			return found
	return null
