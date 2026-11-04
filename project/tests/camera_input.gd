# SPDX-License-Identifier: LGPL-2.1-or-later
## Camera input regression with the real game input handler and client.
## Headless fixture only, no server, desktop input or rendered view:
## godot --headless --path project --script res://tests/camera_input.gd
extends SceneTree

class TestMain extends "res://game/main.gd":
	func _ready() -> void:
		pass
	func _process(_delta: float) -> void:
		pass
	func pointer_captured(_event: InputEvent = null) -> bool:
		return true

class StatusUI extends CanvasLayer:
	var statuses: Array[String] = []
	func show_status_text(text: String) -> void:
		statuses.append(text)

var failures := 0
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		push_error(message)
		failures += 1

func key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	return event

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var game := TestMain.new()
	root.add_child(game)
	game.client = GoannaClient.new()
	game.add_child(game.client)
	var status := StatusUI.new()
	game.ui = status
	game.add_child(status)
	var initial_yaw := game.yaw
	var initial_pitch := game.pitch
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(12, 8)
	motion.alt_pressed = true
	game._unhandled_input(motion)
	check(game.camera_mode == game.CAMERA_FIRST, "Alt motion cannot enter third person")
	check(game.yaw == initial_yaw and game.pitch == initial_pitch,
			"Alt motion while switching windows does not turn the player")
	var tab := key(KEY_TAB)
	tab.alt_pressed = true
	game._unhandled_input(tab)
	check(game.camera_mode == game.CAMERA_FIRST and status.statuses.is_empty(),
			"Alt Tab does not change camera or show a camera hint")
	for modifier in ["alt_pressed", "ctrl_pressed", "meta_pressed", "shift_pressed"]:
		var modified := key(KEY_F7)
		modified.set(modifier, true)
		game._unhandled_input(modified)
		check(game.camera_mode == game.CAMERA_FIRST, "Modified F7 is ignored: " + modifier)
	game._unhandled_input(key(KEY_F7))
	check(game.camera_mode == game.CAMERA_BEHIND, "Unmodified F7 selects behind view")
	check(status.statuses.back().contains("F7 twice"), "Behind view explains return to first person")
	game._unhandled_input(motion)
	check(game.orbit_yaw != 0 and game.orbit_pitch != 0, "Alt motion still orbits in third person")
	check(game.yaw == initial_yaw and game.pitch == initial_pitch, "Orbit does not turn the player")
	game._unhandled_input(key(KEY_F7))
	check(game.camera_mode == game.CAMERA_FRONT and game.crosshair_hidden,
			"Second F7 selects front view and hides crosshair")
	check(status.statuses.back().contains("Press F7 for first person"), "Front view explains return")
	game._unhandled_input(key(KEY_F7))
	check(game.camera_mode == game.CAMERA_FIRST and not game.crosshair_hidden,
			"Third F7 restores first person and crosshair")
	check(game.orbit_yaw == 0 and game.orbit_pitch == 0, "Camera changes reset orbit")
	check(status.statuses.back().begins_with("First person"), "First person confirms restored view")
	motion.alt_pressed = false
	game._unhandled_input(motion)
	check(game.yaw != initial_yaw and game.pitch != initial_pitch, "Ordinary mouse look remains available")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.alt_pressed = true
	game._unhandled_input(wheel)
	check(game.camera_mode == game.CAMERA_BEHIND, "Deliberate Alt wheel can still enter third person")
	check(game.orbit_distance == game.THIRD_PERSON_MIN, "Alt wheel enters at closest distance")
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	game._unhandled_input(wheel)
	check(game.camera_mode == game.CAMERA_FIRST, "Alt wheel inward restores first person")
	var held := key(KEY_F7)
	held.echo = true
	game._unhandled_input(held)
	check(game.camera_mode == game.CAMERA_FIRST, "Held F7 does not repeatedly cycle views")
	game.cam = Camera3D.new()
	game.add_child(game.cam)
	for mode in [game.CAMERA_BEHIND, game.CAMERA_FRONT]:
		game._set_camera_mode(mode)
		game.yaw = 0
		game.pitch = 0
		game._place_third_person(Vector3.ZERO)
		var before := game.cam.position
		var right := game.cam.basis.x
		var up := game.cam.basis.y
		motion.alt_pressed = true
		game._unhandled_input(motion)
		game._place_third_person(Vector3.ZERO)
		var travel := game.cam.position - before
		check(travel.dot(right) < 0, "Right orbit drag moves camera screen-left in mode %d" % mode)
		check(travel.dot(up) > 0, "Down orbit drag moves camera screen-up in mode %d" % mode)
		check(game.yaw == 0 and game.pitch == 0, "Orbit preserves player facing in mode %d" % mode)
		game._set_camera_mode(mode)
		motion.alt_pressed = false
		game._unhandled_input(motion)
		game._place_third_person(Vector3.ZERO)
		check(game.cam.rotation_degrees.x < 0, "Down mouse looks down in mode %d" % mode)
		check(game.yaw < 0, "Ordinary look preserves player yaw turning in mode %d" % mode)
	game.free()
	print("camera input: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
