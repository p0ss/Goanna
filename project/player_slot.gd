# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends Control

const Gamepad := preload("res://gamepad.gd")

var shell: Node
var slot_index := 0
var options: Dictionary
var viewport: SubViewport
var gamepad: Node
var game: Node
var device_id := -2 # -1 keyboard/mouse, -2 waiting for a controller
var keys := {}
var waiting: Label
var mesh_threads := 1
var poll_budget_ms := 1.5
var _focus: WeakRef
var _focus_overlay: Control
# Tests inject an empty player scene while exercising the real shell/input.
var game_factory := Callable()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	device_id = int(options.get("device", -2))
	viewport = SubViewport.new()
	viewport.name = "PlayerViewport"
	viewport.own_world_3d = true
	viewport.handle_input_locally = true
	viewport.audio_listener_enable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	viewport.gui_focus_changed.connect(_remember_focus)
	var display := TextureRect.new()
	display.texture = viewport.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.stretch_mode = TextureRect.STRETCH_SCALE
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(display)
	_focus_overlay = Control.new()
	_focus_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_focus_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_focus_overlay.draw.connect(_draw_focus)
	add_child(_focus_overlay)
	resized.connect(_resize_view)
	_resize_view()
	gamepad = Gamepad.new()
	gamepad.local_input = true
	gamepad.device_id = device_id
	viewport.add_child(gamepad)
	game = game_factory.call() if game_factory.is_valid() else preload("res://main.tscn").instantiate()
	game.player_slot = self
	game.connection_options = options.duplicate(true)
	viewport.add_child(game)
	waiting = Label.new()
	waiting.text = "%s\nPress Start on an unassigned controller" % str(options.get("name", "Player"))
	waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	waiting.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	waiting.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	waiting.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(waiting)
	set_device(device_id)

func _resize_view() -> void:
	if viewport != null:
		viewport.size = Vector2i(maxi(2, roundi(size.x)), maxi(2, roundi(size.y)))

func configure_client(client: Node) -> void:
	client.set_mesh_threads(mesh_threads)
	client.set_poll_budget_ms(poll_budget_ms)

func set_device(device: int) -> void:
	keys.clear()
	device_id = device
	options["device"] = device
	if gamepad != null:
		gamepad.reset_input()
		gamepad.device_id = device
	if game != null:
		game.dig_down = false
		game.place_down = false
		game.place_pressed = false
		game.set_pointer_captured(device != -2)
	if waiting != null:
		waiting.visible = device == -2

func key_pressed(key: Key) -> bool:
	return device_id == -1 and bool(keys.get(key, false))

func route_input(event: InputEvent) -> void:
	# Godot permits one GUI focus owner across a window's subviewports.
	# Restore this player's selection before handling their next event.
	var focus := remembered_focus()
	if focus != null and viewport.gui_get_focus_owner() != focus:
		focus.grab_focus()
	if event is InputEventKey:
		keys[event.physical_keycode if event.physical_keycode != 0 else event.keycode] = event.pressed
	viewport.push_input(event, true)

func _remember_focus(control: Control) -> void:
	if control != null:
		_focus = weakref(control)

func remembered_focus() -> Control:
	var control: Control = _focus.get_ref() if _focus != null else null
	if control == null or not control.is_visible_in_tree() or control.is_queued_for_deletion():
		return null
	return control

func _process(_delta: float) -> void:
	if _focus_overlay != null:
		_focus_overlay.queue_redraw()

func _draw_focus() -> void:
	var focus := remembered_focus()
	if focus == null or viewport.gui_get_focus_owner() == focus or device_id == -2:
		return
	if device_id != -1 and not gamepad._focus_nav:
		return
	# Keep the other players' menu selections visible while Godot temporarily
	# gives the active control to the player whose event is being delivered.
	_focus_overlay.draw_style_box(focus.get_theme_stylebox("focus"), focus.get_global_rect())

func update_pointer_capture() -> void:
	if is_instance_valid(shell):
		shell.update_pointer_capture()

func leave() -> void:
	shell.remove_player.call_deferred(self)

func release_controls() -> void:
	keys.clear()
	gamepad.reset_input()
	game.dig_down = false
	game.place_down = false
	game.place_pressed = false
