# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
# CPU-only checks for slot ownership, routing, layout and shader isolation.
extends SceneTree

const Shell := preload("res://local_play.gd")
const Launch := preload("res://local_launch.gd")
const Context := preload("res://player_context.gd")
var failures := 0

class Game extends Node3D:
	var player_slot: Node
	var connection_options: Dictionary
	var client: Node
	var ui: Node
	var captured := true
	var dig_down := false
	var place_down := false
	var place_pressed := false
	var inventory_open := false
	var keys_received: Array = []
	func _ready() -> void:
		add_to_group("goanna_main")
		player_slot.gamepad.play_owner = func() -> bool: return captured
	func pointer_captured() -> bool:
		return captured
	func set_pointer_captured(on: bool) -> void:
		captured = on
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed:
			keys_received.append(event.keycode)
			if event.keycode == KEY_I:
				inventory_open = not inventory_open
				captured = not inventory_open
				get_viewport().set_input_as_handled()

class Server extends RefCounted:
	var stops := 0
	func stop() -> void:
		stops += 1

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	_run.call_deferred()

func button(shell: Node, device: int, which: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = which
	event.pressed = pressed
	shell._input(event)

func axis(shell: Node, device: int, which: int, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = which
	event.axis_value = value
	shell._input(event)

func _run() -> void:
	check(Launch.validate([{"name": "a", "device": 0}, {"name": "b", "device": 0}]) != "", "Reject duplicate devices")
	check(Launch.validate([{"name": "a"}, {"name": "a"}]) != "", "Reject duplicate identities")
	check(Launch.validate([{"name": "a"}, {"name": "b"}]) == "", "Multiple unassigned slots are valid")
	for count in [1, 2, 3, 4, 6, 9]:
		var rectangles := Shell.rectangles(count, Vector2(1601, 901))
		check(rectangles.size() == count, "Layout supports %d slots" % count)
		for i in count:
			check(rectangles[i].has_area(), "Positive slot size")
			check(Rect2(0, 0, 1601, 901).encloses(rectangles[i]), "Slot fits window")
			for j in range(i):
				check(not rectangles[i].intersects(rectangles[j]), "Slots do not overlap")
	check(Shell.rectangles(2, Vector2(1600, 900), "horizontal")[1] == Rect2(0, 450, 1600, 450), "Horizontal split")
	var shell := Shell.new()
	shell.automatic_launch = false
	shell.capture_mouse = false
	shell.game_factory = func() -> Node: return Game.new()
	root.add_child(shell)
	var server := Server.new()
	shell.owned_server = server
	for i in 4:
		shell.add_player({"name": "player_%d" % i, "device": i})
	await process_frame
	for slot in shell.slots:
		slot.gamepad.set_process(false)
		slot.gamepad.step(0.016)
		check(slot.viewport.world_3d != root.world_3d, "Private player world")
		check(Context.find(slot.game, "goanna_main") == slot.game, "Context resolves the owning player")
		for other in shell.slots:
			if other != slot:
				check(slot.viewport.find_world_3d() != other.viewport.find_world_3d(), "Worlds are distinct")
	axis(shell, 0, JOY_AXIS_LEFT_Y, -1.0)
	axis(shell, 1, JOY_AXIS_LEFT_Y, 0.6)
	for slot in shell.slots: slot.gamepad.step(0.016)
	check(shell.slots[0].gamepad.move.y < -0.9, "Player 1 moves forward")
	check(shell.slots[1].gamepad.move.y > 0.4, "Player 2 independently moves backwards")
	check(shell.slots[2].gamepad.move == Vector2.ZERO, "Other players stay still")
	button(shell, 0, JOY_BUTTON_Y, true)
	button(shell, 0, JOY_BUTTON_Y, false)
	check(shell.slots[0].game.inventory_open, "Controller opens its own inventory")
	check(not shell.slots[1].game.inventory_open, "Another inventory stays closed")
	check(shell.slots[1].gamepad.in_play(), "Other players keep playing through a menu")
	var first_cursor: Node = shell.slots[0].gamepad
	first_cursor.step(0.1)
	check(first_cursor.pointer_shown, "Menu has a local cursor")
	check(not shell.slots[1].gamepad.pointer_shown, "Cursor stays in its own view")
	shell._controller_changed(1, false)
	check(shell.slots[1].gamepad.move == Vector2.ZERO, "Unplug clears held movement")
	check(shell.slots[1].device_id == -2, "Disconnected slot waits for reassignment")
	button(shell, 7, JOY_BUTTON_START, true)
	check(shell.slots[1].device_id == 7, "An unassigned controller can reclaim a slot")
	check(shell.slots[1].game.keys_received.is_empty(), "Join press does not open a pause menu")
	shell.slots[2].set_device(-1)
	var key := InputEventKey.new()
	key.keycode = KEY_W
	key.physical_keycode = KEY_W
	key.pressed = true
	shell._input(key)
	check(shell.slots[2].key_pressed(KEY_W), "Keyboard reaches its assigned slot")
	check(not shell.slots[0].key_pressed(KEY_W), "Keyboard cannot move another player")
	shell._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(not shell.slots[2].key_pressed(KEY_W), "Focus loss releases keyboard state")
	shell.remove_player(shell.slots[3])
	check(server.stops == 0, "Leaving one slot keeps the shared server running")
	check(shell.slots.size() == 3, "Leaving removes only one player")
	shell.free()
	check(server.stops == 1, "Shell teardown stops its owned server once")
	await process_frame
	_test_shaders()
	print("local play: %d failures" % failures)
	quit(1 if failures else 0)

func _test_shaders() -> void:
	var a := GoannaClient.new()
	var b := GoannaClient.new()
	a.enable_render_scope()
	b.enable_render_scope()
	var first: String = a.view_shader_parameter_name("goanna_eye_underwater")
	var second: String = b.view_shader_parameter_name("goanna_eye_underwater")
	check(first != second, "Each player has separate underwater state")
	for path in ["water", "ice", "nodes_array", "nodes_array_scissor", "entity", "entity_scissor", "sky", "precipitation", "light_shafts", "waving_leaves", "grass_volume"]:
		var shader: Shader = a.load_view_shader("res://shaders/%s.gdshader" % path)
		check(shader != null, "Load scoped shader " + path)
		if shader != null:
			check(not shader.get_shader_uniform_list(true).is_empty(), "Scoped shader parses " + path)
			check(not shader.code.contains("#include \""), "Expand scoped includes " + path)
			check(not shader.code.contains("global uniform float goanna_") and not shader.code.contains("global uniform vec3 goanna_"), "No unscoped globals in " + path)
	var water: Shader = a.load_view_shader("res://shaders/water.gdshader")
	check(water.code.contains(first), "Shader uses the player's own underwater binding")
	check(a.load_view_shader("res://shaders/water.gdshader") == water, "Shaders are cached within a player")
	check(b.load_view_shader("res://shaders/water.gdshader") != water, "Shaders are not shared across players")
	a.free()
	check(RenderingServer.global_shader_parameter_get_list().has(second), "Removing one player preserves the other's shader state")
	b.free()
