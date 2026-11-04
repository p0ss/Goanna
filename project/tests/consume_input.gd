# SPDX-License-Identifier: LGPL-2.1-or-later
## Ordinary consumable controls through the game input handler. Headless
## fixture only, no server, inventory consumption or rendered animation.
extends SceneTree
const Use := preload("res://game/consume_use.gd")
class Game extends "res://game/main.gd":
	func _ready() -> void:
		pass
	func _process(_delta: float) -> void:
		pass
	func pointer_captured(_event: InputEvent = null) -> bool:
		return true
var failures := 0
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func button(which: MouseButton, down: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = which
	event.pressed = down
	return event
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var game := Game.new()
	root.add_child(game)
	game.client = GoannaClient.new()
	game.add_child(game.client)
	game._unhandled_input(button(MOUSE_BUTTON_LEFT, true))
	var food := {"kind": "eat"}
	var meal := game._consume_controls(0, game.dig_down, false, false, food)
	check(meal.dig and not meal.active, "Left click alone retains vanilla punch and does not eat")
	game._unhandled_input(button(MOUSE_BUTTON_RIGHT, true))
	meal = game._consume_controls(0, game.dig_down, game.place_down, game.place_pressed, food)
	check(not meal.dig and meal.active and meal.started, "Ordinary right use suppresses simultaneous primary")
	game.place_pressed = false
	game._update_wield(0.1)
	check(game.swing_t == 1, "Eating does not start a generic punching swing")
	for frame in 120:
		meal = game._consume_controls(1.0 / 60, true, true, false, food)
	check(not meal.dig and meal.active and not meal.started,
			"Held secondary remains safe without restarting finite gesture")
	game._unhandled_input(button(MOUSE_BUTTON_RIGHT, false))
	meal = game._consume_controls(2, true, false, false, {})
	check(not meal.dig and not meal.active, "Stuck primary stays blocked after meal and final item replacement")
	meal = game._consume_controls(0.1, false, false, false, {})
	meal = game._consume_controls(0.1, true, false, false, {})
	check(meal.dig, "A released then pressed primary resumes ordinary combat")
	var drink := Use.new()
	var sip := drink.step(0, "drink", false, true, true)
	check(sip.kind == "drink" and sip.phase == 0 and sip.started, "Drink begins its own finite gesture")
	sip = drink.step(0.5, "", true, false, false)
	check(sip.active and not sip.dig and is_equal_approx(sip.phase, 0.5), "Short tap retains gesture and safety after item replacement")
	sip = drink.step(0.6, "", false, false, false)
	check(not sip.active and sip.phase == 1, "Use gesture terminates rather than looping")
	game.cam = Camera3D.new()
	game.add_child(game.cam)
	for mode in [game.CAMERA_BEHIND, game.CAMERA_FRONT]:
		game._set_camera_mode(mode)
		game.orbit_distance = 0.1
		game._third_drawn = false
		game._place_third_person(Vector3.ZERO)
		check(game._third_drawn, "Close-wall camera retains third-person presentation in mode %d" % mode)
	game.free()
	print("consume input: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
