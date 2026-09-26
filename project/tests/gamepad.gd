# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Controller input (gamepad.gd) without a controller or a GPU: synthetic
# InputEventJoypadButton and InputEventJoypadMotion events go in through
# Input.parse_input_event, the path a real controller's events take, and the
# test checks what comes out: the keys dictionary main.gd hands the client,
# look angles, hotbar and drop edges, the deadzone, and the cursor's pushed
# mouse and key events outside play.
#
#   godot --headless --path project --script res://tests/gamepad.gd
#
# Exits 1 on any failure. Nothing here has been near a real controller.
extends SceneTree

const Pad := preload("res://gamepad.gd")

class Recorder extends Node:
	var events: Array = []
	func _input(event: InputEvent) -> void:
		if event is InputEventMouse or event is InputEventKey:
			events.append(event)

var pad: Node
var rec: Recorder
var play := false
var failures := 0

func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", what)

func near(a: float, b: float, eps := 0.001) -> bool:
	return absf(a - b) <= eps

func _initialize() -> void:
	_run.call_deferred()

func axis(a: int, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.device = 0
	ev.axis = a
	ev.axis_value = value
	Input.parse_input_event(ev)
	Input.flush_buffered_events()

func button(b: int, pressed: bool) -> void:
	var ev := InputEventJoypadButton.new()
	ev.device = 0
	ev.button_index = b
	ev.pressed = pressed
	ev.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)
	Input.flush_buffered_events()

func tap(b: int) -> void:
	button(b, true)
	button(b, false)

func step(delta := 1.0 / 60.0) -> void:
	pad.step(delta)
	Input.flush_buffered_events()

func centre_sticks() -> void:
	for a in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y,
			JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		axis(a, 0.0)

func fresh_keys() -> Dictionary:
	return {"up": false, "down": false, "left": false, "right": false,
		"jump": false, "sneak": false, "aux1": false}

func _run() -> void:
	# The autoload when the project loads it, otherwise one of our own. Its
	# settings are pinned here, so the owner's goanna.cfg does not matter.
	pad = root.get_node_or_null("Gamepad")
	if pad == null:
		pad = Pad.new()
		pad.name = "Gamepad"
		root.add_child(pad)
	# A headless window is tiny; give it the project's own size, so the
	# cursor positions below are inside it.
	root.size = Vector2i(1600, 900)
	await process_frame
	pad.set_enabled(true)
	pad.look_speed = 170.0
	pad.invert_y = false
	pad.set_deadzone(0.15)
	pad.play_owner = func() -> bool: return play
	rec = Recorder.new()
	root.add_child(rec)

	_test_actions()
	_test_deadzone()
	_test_play()
	_test_edges()
	_test_disabled()
	_test_cursor()
	_test_menu_buttons()

	if failures == 0:
		print("gamepad: actions, deadzone, play keys, look, edges, off switch, cursor and menu buttons passed")
	quit(1 if failures > 0 else 0)

func _bound(action: String, want: int) -> bool:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and ev.button_index == want:
			return true
		if ev is InputEventJoypadMotion and ev.axis == want:
			return true
	return false

func _test_actions() -> void:
	for action in Pad.ACTIONS:
		check(InputMap.has_action(action), "action %s exists" % action)
	# Upstream Luanti 5.17's layout.
	check(_bound("goanna_jump", JOY_BUTTON_A), "A jumps")
	check(_bound("goanna_sneak", JOY_BUTTON_B), "B sneaks")
	check(_bound("goanna_aux1", JOY_BUTTON_X), "X is aux1")
	check(_bound("goanna_inventory", JOY_BUTTON_Y), "Y is the inventory")
	check(_bound("goanna_pause", JOY_BUTTON_START), "Start pauses")
	check(_bound("goanna_hotbar_next", JOY_BUTTON_RIGHT_SHOULDER), "RB is hotbar next")
	check(_bound("goanna_hotbar_previous", JOY_BUTTON_LEFT_SHOULDER), "LB is hotbar previous")
	check(_bound("goanna_drop", JOY_BUTTON_DPAD_DOWN), "D-pad down drops")
	check(_bound("goanna_dig", JOY_AXIS_TRIGGER_RIGHT), "RT digs")
	check(_bound("goanna_place", JOY_AXIS_TRIGGER_LEFT), "LT places")
	check(_bound("ui_accept", JOY_BUTTON_A), "A accepts focused controls")
	# ensure_actions twice must not bind anything twice.
	pad.ensure_actions()
	check(InputMap.action_get_events("goanna_jump").size() == 1, "no duplicate bindings")

func _test_deadzone() -> void:
	check(Pad.apply_deadzone(Vector2(0.1, 0.0), 0.15) == Vector2.ZERO, "inside the deadzone is nothing")
	check(Pad.apply_deadzone(Vector2(0.1, 0.1), 0.15) == Vector2.ZERO, "radial: a diagonal inside is nothing")
	check(near(Pad.apply_deadzone(Vector2(1.0, 0.0), 0.15).x, 1.0), "the rim is still 1")
	check(near(Pad.apply_deadzone(Vector2(0.575, 0.0), 0.15).x, 0.5), "rescaled past the deadzone")
	check(near(Pad.apply_deadzone(Vector2(0.0, -0.5), 0.5).length(), 0.0), "exactly at the deadzone is nothing")

func _test_play() -> void:
	play = true
	centre_sticks()
	# Full forward is a full key.
	axis(JOY_AXIS_LEFT_Y, -1.0)
	step()
	var keys := fresh_keys()
	pad.merge_keys(keys)
	check(near(float(keys["up"]), 1.0), "stick forward is up 1, got %s" % keys["up"])
	check(not bool(keys["down"]), "and not down")
	# Drift inside the deadzone moves nothing.
	axis(JOY_AXIS_LEFT_Y, -0.1)
	step()
	keys = fresh_keys()
	pad.merge_keys(keys)
	check(keys["up"] is bool and not keys["up"], "drift is not movement")
	# Part way is part speed, which the client now reads as analogue.
	axis(JOY_AXIS_LEFT_Y, -0.575)
	axis(JOY_AXIS_LEFT_X, 0.0)
	step()
	keys = fresh_keys()
	pad.merge_keys(keys)
	check(near(float(keys["up"]), 0.5, 0.01), "half way past the deadzone is half, got %s" % keys["up"])
	# A key held on the keyboard stays a full press.
	keys = fresh_keys()
	keys["up"] = true
	pad.merge_keys(keys)
	check(keys["up"] is bool and keys["up"], "keyboard keeps priority")
	axis(JOY_AXIS_LEFT_Y, 0.0)
	# Buttons.
	button(JOY_BUTTON_A, true)
	button(JOY_BUTTON_B, true)
	button(JOY_BUTTON_X, true)
	step()
	keys = fresh_keys()
	pad.merge_keys(keys)
	check(keys["jump"] and keys["sneak"] and keys["aux1"], "A, B and X are jump, sneak and aux1")
	button(JOY_BUTTON_A, false)
	button(JOY_BUTTON_B, false)
	button(JOY_BUTTON_X, false)
	step()
	keys = fresh_keys()
	pad.merge_keys(keys)
	check(not keys["jump"] and not keys["sneak"] and not keys["aux1"], "released buttons let go")
	# Look: at 72 degrees the field of view scale is 1, as upstream's is.
	axis(JOY_AXIS_RIGHT_X, 1.0)
	step()
	var d: Vector2 = pad.look_step(0.5, 72.0)
	check(near(d.x, -85.0, 0.05), "right stick right turns right at 170 a second, got %s" % d.x)
	axis(JOY_AXIS_RIGHT_X, 0.0)
	axis(JOY_AXIS_RIGHT_Y, -1.0)
	step()
	d = pad.look_step(0.5, 72.0)
	check(d.y > 84.9, "stick forward looks up")
	pad.invert_y = true
	d = pad.look_step(0.5, 72.0)
	check(d.y < -84.9, "inverted, stick forward looks down")
	pad.invert_y = false
	axis(JOY_AXIS_RIGHT_Y, 0.1)
	step()
	check(pad.look_step(0.5, 72.0) == Vector2.ZERO, "look drift inside the deadzone")
	axis(JOY_AXIS_RIGHT_Y, 0.0)
	# Triggers need a firm pull.
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.2)
	step()
	check(not pad.dig_held(), "a brushed trigger does not dig")
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.9)
	axis(JOY_AXIS_TRIGGER_LEFT, 0.9)
	step()
	check(pad.dig_held() and pad.place_held(), "pulled triggers dig and place")
	check(pad.take("place") == 1, "a place pull is one press")
	step()
	check(pad.take("place") == 0, "held, it is not pressed again")
	centre_sticks()
	step()
	# Start and Y stand in for Escape and I, whose handlers already open the
	# pause menu and the inventory.
	rec.events.clear()
	tap(JOY_BUTTON_START)
	tap(JOY_BUTTON_Y)
	var keys_seen := rec.events.filter(func(e: InputEvent) -> bool:
		return e is InputEventKey and e.pressed).map(func(e: InputEvent) -> int:
		return (e as InputEventKey).keycode)
	check(keys_seen == [KEY_ESCAPE, KEY_I], "Start and Y press Escape and I, got %s" % [keys_seen])

func _test_edges() -> void:
	play = true
	step()
	pad.take("hotbar")
	pad.take("drop")
	button(JOY_BUTTON_RIGHT_SHOULDER, true)
	step()
	check(pad.take("hotbar") == 1, "RB steps the hotbar forward")
	step(0.1)
	check(pad.take("hotbar") == 0, "not again before the repeat time")
	step(0.1)
	check(pad.take("hotbar") == 1, "held, it repeats as upstream's does")
	button(JOY_BUTTON_RIGHT_SHOULDER, false)
	button(JOY_BUTTON_LEFT_SHOULDER, true)
	step()
	check(pad.take("hotbar") == -1, "LB steps back")
	button(JOY_BUTTON_LEFT_SHOULDER, false)
	button(JOY_BUTTON_DPAD_DOWN, true)
	step()
	check(pad.take("drop") == 1, "D-pad down drops")
	button(JOY_BUTTON_DPAD_DOWN, false)
	# A button already down when play resumes is not a press.
	play = false
	step()
	button(JOY_BUTTON_RIGHT_SHOULDER, true)
	step()
	play = true
	step()
	check(pad.take("hotbar") == 0, "a button held into play is not a press")
	button(JOY_BUTTON_RIGHT_SHOULDER, false)
	step()
	# Nor is A, still down from pressing a menu button, a jump until it is
	# let go and pressed again.
	play = false
	step()
	button(JOY_BUTTON_A, true)
	play = true
	step()
	var keys := fresh_keys()
	pad.merge_keys(keys)
	check(not keys["jump"], "A held from a menu does not jump")
	button(JOY_BUTTON_A, false)
	step()
	button(JOY_BUTTON_A, true)
	step()
	keys = fresh_keys()
	pad.merge_keys(keys)
	check(keys["jump"], "pressed again, it jumps")
	button(JOY_BUTTON_A, false)
	step()

func _test_disabled() -> void:
	play = true
	pad.set_enabled(false)
	axis(JOY_AXIS_LEFT_Y, -1.0)
	axis(JOY_AXIS_RIGHT_X, 1.0)
	button(JOY_BUTTON_A, true)
	step()
	var keys := fresh_keys()
	pad.merge_keys(keys)
	check(keys == fresh_keys(), "switched off, the controller adds nothing")
	check(pad.look_step(0.5, 72.0) == Vector2.ZERO, "switched off, no look")
	rec.events.clear()
	tap(JOY_BUTTON_START)
	check(rec.events.is_empty(), "switched off, Start presses nothing")
	button(JOY_BUTTON_A, false)
	centre_sticks()
	pad.set_enabled(true)
	step()

func _test_cursor() -> void:
	# The pure step: speed is squared deflection, ramping up while held.
	check(near(Pad.cursor_step(Vector2(1, 0), 0.0, 0.1, 650.0).x, 65.0), "full deflection, not yet held")
	check(near(Pad.cursor_step(Vector2(1, 0), 0.8, 0.1, 650.0).x, 195.0), "held, three times as fast")
	check(near(Pad.cursor_step(Vector2(0.5, 0), 0.0, 0.1, 650.0).x, 16.25), "half deflection, a quarter")
	check(Pad.cursor_step(Vector2.ZERO, 1.0, 0.1, 650.0) == Vector2.ZERO, "still")

	play = false
	pad.pointer_pos = Vector2(-1, -1)
	pad.pointer_shown = false
	var screen: Vector2 = root.get_visible_rect().size
	rec.events.clear()
	axis(JOY_AXIS_LEFT_X, 1.0)
	step(0.1)
	var first: Vector2 = pad.pointer_pos
	check(pad.pointer_shown, "the stick shows the cursor")
	# Held for its first 0.1 seconds already, so a little past base speed.
	var want := screen * 0.5 + Pad.cursor_step(Vector2(1, 0), 0.1, 0.1, Pad.CURSOR_SPEED * screen.y / 900.0)
	check(first.distance_to(want) < 0.5, "starts at the centre and moves right, got %s want %s" % [first, want])
	var motions := rec.events.filter(func(e: InputEvent) -> bool: return e is InputEventMouseMotion)
	check(motions.size() == 1 and motions[0].device == Pad.POINTER_DEVICE \
			and motions[0].position == first, "a pushed mouse motion at the cursor")
	step(0.1)
	var second: Vector2 = pad.pointer_pos
	check(second.x - first.x > first.x - screen.x * 0.5, "it accelerates while held")
	for i in 100:
		step(0.1)
	check(near(pad.pointer_pos.x, screen.x - 1.0), "and stops at the edge of the window")
	axis(JOY_AXIS_LEFT_X, 0.0)
	axis(JOY_AXIS_LEFT_Y, 0.0)
	pad.pointer_pos = Vector2(400, 300)
	step()

	# A is the left button, held for a drag; X is the right; LB is Shift.
	rec.events.clear()
	button(JOY_BUTTON_A, true)
	axis(JOY_AXIS_LEFT_Y, 1.0)
	step(0.1)
	axis(JOY_AXIS_LEFT_Y, 0.0)
	button(JOY_BUTTON_A, false)
	var presses := rec.events.filter(func(e: InputEvent) -> bool: return e is InputEventMouseButton)
	check(presses.size() == 2, "A is one press and one release, got %d" % presses.size())
	if presses.size() == 2:
		check(presses[0].pressed and presses[0].button_index == MOUSE_BUTTON_LEFT \
				and presses[0].position == Vector2(400, 300), "left press where the cursor was")
		check(not presses[1].pressed and presses[1].position.y > 300.0, "released where it was dragged to, got %s %s" % [presses[1].pressed, presses[1].position])
	var drag := rec.events.filter(func(e: InputEvent) -> bool: return e is InputEventMouseMotion)
	check(drag.size() == 1 and drag[0].button_mask == MOUSE_BUTTON_MASK_LEFT, "the drag carries the held button")
	rec.events.clear()
	button(JOY_BUTTON_LEFT_SHOULDER, true)
	tap(JOY_BUTTON_X)
	button(JOY_BUTTON_LEFT_SHOULDER, false)
	presses = rec.events.filter(func(e: InputEvent) -> bool: return e is InputEventMouseButton)
	check(presses.size() == 2 and presses[0].button_index == MOUSE_BUTTON_RIGHT \
			and presses[0].shift_pressed, "X is a right click, LB holds Shift")
	# Two quick presses in place are a double click, which Godot only marks
	# on events from the OS.
	rec.events.clear()
	tap(JOY_BUTTON_A)
	tap(JOY_BUTTON_A)
	presses = rec.events.filter(func(e: InputEvent) -> bool:
		return e is InputEventMouseButton and e.pressed)
	check(presses.size() == 2 and not presses[0].double_click and presses[1].double_click,
		"a second quick A is a double click")
	# Right stick turns the wheel.
	rec.events.clear()
	axis(JOY_AXIS_RIGHT_Y, 1.0)
	step(0.54)
	axis(JOY_AXIS_RIGHT_Y, 0.0)
	var wheel := rec.events.filter(func(e: InputEvent) -> bool:
		return e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN)
	check(wheel.size() == 6, "just over half a second fully down is six wheel steps, got %d" % wheel.size())
	# Play resuming with A still down releases it, or the GUI would think a
	# drag was still going.
	rec.events.clear()
	button(JOY_BUTTON_A, true)
	play = true
	step()
	var ups := rec.events.filter(func(e: InputEvent) -> bool:
		return e is InputEventMouseButton and not e.pressed)
	check(ups.size() == 1 and not pad.pointer_shown, "leaving the cursor lets go of A and hides it")
	button(JOY_BUTTON_A, false)
	play = false
	step()
	# A real mouse takes over from the cursor.
	pad.pointer_pos = Vector2(100, 100)
	pad._show_pointer()
	var real := InputEventMouseMotion.new()
	real.position = Vector2(700, 500)
	Input.parse_input_event(real)
	Input.flush_buffered_events()
	check(not pad.pointer_shown and pad.pointer_pos == Vector2(700, 500), "a real mouse hides the cursor")

func _test_menu_buttons() -> void:
	play = false
	rec.events.clear()
	tap(JOY_BUTTON_B)
	tap(JOY_BUTTON_START)
	var keys_seen := rec.events.filter(func(e: InputEvent) -> bool:
		return e is InputEventKey and e.pressed).map(func(e: InputEvent) -> int:
		return (e as InputEventKey).keycode)
	check(keys_seen == [KEY_ESCAPE, KEY_ESCAPE], "B and Start close windows as Escape, got %s" % [keys_seen])
	# The D-pad hands the controller to focus: the first focusable control
	# takes focus, and A is then left to ui_accept rather than clicking.
	var box := VBoxContainer.new()
	var one := Button.new()
	one.text = "one"
	var two := Button.new()
	two.text = "two"
	box.add_child(one)
	box.add_child(two)
	root.add_child(box)
	var pressed := [0]
	one.pressed.connect(func() -> void: pressed[0] += 1)
	pad._show_pointer()
	tap(JOY_BUTTON_DPAD_DOWN)
	check(root.gui_get_focus_owner() == one and not pad.pointer_shown, "D-pad focuses the first control")
	rec.events.clear()
	tap(JOY_BUTTON_A)
	check(pressed[0] == 1, "A presses the focused button")
	check(rec.events.filter(func(e: InputEvent) -> bool: return e is InputEventMouseButton).is_empty(),
		"and pushes no click")
	box.queue_free()
