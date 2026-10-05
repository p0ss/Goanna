# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
# Real player scenes and menus, with networking disabled and a dummy renderer.
extends SceneTree

const Shell := preload("res://local_play.gd")
const Main := preload("res://main.tscn")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _run() -> void:
	OS.set_environment("GOANNA_NO_POINTER_CAPTURE", "1")
	OS.set_environment("GOANNA_NO_STORE", "1")
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "material_updates", false)
	cfg.save("user://goanna.cfg")
	var shell := Shell.new()
	shell.automatic_launch = false
	shell.capture_mouse = false
	shell.game_factory = func() -> Node:
		var game := Main.instantiate()
		game.connect_automatically = false
		return game
	root.add_child(shell)
	for i in 4:
		shell.add_player({"name": "scene_%d" % i, "device": i, "host": "127.0.0.1", "port": 39997})
	await process_frame
	await process_frame
	for i in 4:
		var slot: Node = shell.slots[i]
		check(slot.game.ui._main_node() == slot.game, "Real UI belongs to player %d" % i)
		check(slot.game.ui._gamepad() == slot.gamepad, "UI controls belong to player %d" % i)
		check(slot.game.cam.get_viewport() == slot.viewport, "Camera uses player viewport")
		check(slot.game.client.mesh_threads() == slot.mesh_threads, "Mesh budget applied to client")
		check(slot.game.cam.get_world_3d() == slot.viewport.find_world_3d(), "Camera uses private world")
	var first: Node = shell.slots[0].game
	var second: Node = shell.slots[1].game
	first.ui._open_pause_menu()
	check(first.ui.blocks_input(), "Player 1 opens a real pause menu")
	check(not first.gamepad_owns_play(), "Player 1 stops controlling the game")
	check(second.gamepad_owns_play(), "Player 2 keeps playing")
	second.ui._open_pause_menu()
	check(first.ui.window != second.ui.window, "Pause menus are separate nodes")
	for device in [0, 1]:
		_tap(shell, device, JOY_BUTTON_DPAD_DOWN)
	check(shell.slots[0].remembered_focus() != null, "Player 1 has local menu focus")
	check(shell.slots[1].remembered_focus() != null, "Player 2 has independent menu focus")
	_tap(shell, 0, JOY_BUTTON_A)
	check(first.gamepad_owns_play() and second.ui.blocks_input(), "Closing one menu leaves the other open")
	_tap(shell, 1, JOY_BUTTON_A)
	check(second.gamepad_owns_play(), "Player 2 activates their remembered selection")
	var old_client: Node = first.client
	shell.remove_player(shell.slots[0])
	await process_frame
	check(not is_instance_valid(old_client), "Leaving releases the player's native client")
	check(is_instance_valid(second.client), "Other native sessions survive")
	shell.free()
	await process_frame
	print("local play scenes: %d failures" % failures)
	quit(1 if failures else 0)

func _tap(shell: Node, device: int, which: int) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = device
		event.button_index = which
		event.pressed = pressed
		shell._input(event)
