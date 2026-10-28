# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## The split screen shell: one player_slot.gd per local player, laid out in a
## grid, with window input routed to the slot that owns each device. The root
## of local_play.tscn, which menu/menu.gd changes to when more than one local
## player is set up; it takes the roster and any server it started from
## game/local_launch.gd, and stops that server when the last player leaves.
## docs/systems/local-multiplayer.md has the whole picture.
extends Control

const Launch := preload("res://game/local_launch.gd")
const Slot := preload("res://game/player_slot.gd")

var slots: Array = []
var layout := "grid"
var graphics_profile := "low"
var owned_server: RefCounted
var _next_slot := 0
var _menu_gamepad: Node
var _closing := false
# Tests set these before _ready: a stand-in game scene for every slot, and
# no roster read from local_launch.gd, so they can add players themselves.
var game_factory := Callable()
var automatic_launch := true
var _pointer_capture: Node
var capture_mouse := true

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	capture_mouse = capture_mouse and DisplayServer.get_name() != "headless" \
		and OS.get_environment("GOANNA_NO_POINTER_CAPTURE") in ["", "0"] \
		and OS.get_environment("GOANNA_CONTROL").is_empty()
	if capture_mouse:
		_pointer_capture = preload("res://input/pointer_capture.gd").new()
		_pointer_capture.blocked = _pointer_blocked
		add_child(_pointer_capture)
	# Each slot has its own gamepad.gd reading only its device; the autoload
	# would read every controller at once, so it sleeps until the menu returns.
	_menu_gamepad = get_node_or_null("/root/Gamepad")
	if _menu_gamepad != null:
		_menu_gamepad.reset_input()
		_menu_gamepad.process_mode = Node.PROCESS_MODE_DISABLED
	resized.connect(_layout_players)
	Input.joy_connection_changed.connect(_controller_changed)
	if not automatic_launch:
		return
	var roster: Array = Launch.players if not Launch.players.is_empty() else Launch.from_environment()
	owned_server = Launch.server
	Launch.server = null
	Launch.players = []
	var error := Launch.validate(roster)
	if error != "":
		push_error(error)
		return_to_menu.call_deferred()
		return
	layout = Launch.layout
	graphics_profile = Launch.graphics_profile
	for player in roster:
		var options: Dictionary = player.duplicate(true)
		var device := int(options.get("device", -2))
		if device >= 0 and not Input.get_connected_joypads().has(device):
			options["device"] = -2
		add_player(options)

## Adds a slot for options ({name, device, password?}) and lays the screen
## out again. Returns the slot, or null if the roster would no longer pass
## local_launch.gd's validate.
func add_player(options: Dictionary) -> Node:
	var roster := slots.map(func(slot: Node) -> Dictionary: return slot.options)
	roster.append(options)
	if Launch.validate(roster) != "":
		return null
	var slot := Slot.new()
	slot.shell = self
	slot.slot_index = _next_slot
	_next_slot += 1
	slot.options = options.duplicate(true)
	slot.options["name"] = str(slot.options["name"]).strip_edges()
	slot.game_factory = game_factory
	slots.append(slot)
	# Allocate before _ready connects; no slot starts an automatic CPU-sized pool.
	_budget_players()
	add_child(slot)
	_budget_players()
	_layout_players()
	return slot

## Disconnects that player and frees their slot; the last one out returns
## to the menu. Reached from the game's Disconnect through player_slot.leave.
func remove_player(slot: Node) -> void:
	if not slots.has(slot):
		return
	slot.release_controls()
	if slot.game.client != null:
		slot.game.client.disconnect_from_server()
	slots.erase(slot)
	remove_child(slot)
	slot.queue_free()
	if slots.is_empty():
		return_to_menu()
	else:
		_budget_players()
		_layout_players()
		update_pointer_capture()

## The screen rectangle of each of count players in area. Two players split
## side by side, or one above the other with split "horizontal"; more fill the
## smallest square grid that holds them.
static func rectangles(count: int, area: Vector2, split := "grid") -> Array[Rect2]:
	var result: Array[Rect2] = []
	if count <= 0:
		return result
	var columns := ceili(sqrt(float(count)))
	if count == 2:
		columns = 1 if split == "horizontal" else 2
	var rows := ceili(float(count) / columns)
	for i in count:
		var x := i % columns
		var y := i / columns
		# Rounded boundaries avoid gaps or overlap at odd window dimensions.
		var start := Vector2(roundf(area.x * x / columns), roundf(area.y * y / rows))
		var end := Vector2(roundf(area.x * (x + 1) / columns), roundf(area.y * (y + 1) / rows))
		result.append(Rect2(start, end - start))
	return result

func _layout_players() -> void:
	var rects := rectangles(slots.size(), size, layout)
	for i in slots.size():
		slots[i].position = rects[i].position
		slots[i].size = rects[i].size

# The players share the machine: mesh workers and the per frame block upload
# budget are divided between them, and each player's own sounds are turned
# down so several at once are no louder than one.
func _budget_players() -> void:
	var count := maxi(1, slots.size())
	var workers := maxi(1, mini(8, OS.get_processor_count() - 2) / count)
	for slot in slots:
		slot.mesh_threads = workers
		slot.poll_budget_ms = 6.0 / count
		if slot.game != null and slot.game.client != null:
			slot.configure_client(slot.game.client)
			if slot.game.ui != null and slot.game.ui.audio != null:
				slot.game.ui.audio.local_mix_gain = 1.0 / sqrt(float(count))

# Every event lands on the window first. A controller event goes to the slot
# holding that device, and Start on an unclaimed controller claims the first
# waiting slot. Keyboard and mouse go to the slot on device -1, with the mouse
# position moved into that slot's own coordinates.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		for slot in slots:
			if slot.device_id == event.device:
				slot.route_input(event)
				get_viewport().set_input_as_handled()
				return
		if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START:
			for slot in slots:
				if slot.device_id == -2:
					slot.set_device(event.device)
					break
		get_viewport().set_input_as_handled()
	elif event is InputEventKey or event is InputEventMouse:
		for slot in slots:
			if slot.device_id != -1:
				continue
			var local := event.duplicate() as InputEvent
			if local is InputEventMouse:
				local.position -= slot.position
				local.global_position = local.position
				if not slot.game.pointer_captured() and not Rect2(Vector2.ZERO, slot.size).has_point(local.position):
					# Releases still reach a drag that left this player's rectangle.
					if not (local is InputEventMouseButton and not local.pressed):
						return
			slot.route_input(local)
			get_viewport().set_input_as_handled()
			return

func _controller_changed(device: int, connected: bool) -> void:
	if connected:
		return # Press Start to claim a waiting slot; IDs can change on reconnect.
	for slot in slots:
		if slot.device_id == device:
			slot.set_device(-2)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		for slot in slots:
			slot.release_controls()

## Loading and modal state can change without a new capture request.
func _pointer_blocked() -> bool:
	for slot in slots:
		if slot.device_id == -1 and slot.game != null:
			return slot.game.connect_overlay != null \
				or (slot.game.ui != null and slot.game.ui.blocks_input()) \
				or (slot.game.overseer != null and slot.game.overseer.active)
	return false

## Captures the OS pointer only while the keyboard player's game wants it.
func update_pointer_capture() -> void:
	if not capture_mouse:
		return
	var captured := false
	for slot in slots:
		if slot.device_id == -1 and slot.game != null:
			captured = slot.game.pointer_captured()
	if _pointer_capture != null:
		_pointer_capture.want_capture(captured)

func return_to_menu() -> void:
	if _closing:
		return
	_closing = true
	OS.set_environment("GOANNA_MENU", "1")
	get_tree().change_scene_to_file.call_deferred("res://menu/menu.tscn")

func _exit_tree() -> void:
	if owned_server != null:
		owned_server.stop()
		owned_server = null
		OS.set_environment("GOANNA_SP_PID", "")
		OS.set_environment("GOANNA_SP_MATCH", "")
	if is_instance_valid(_menu_gamepad):
		_menu_gamepad.play_owner = Callable()
		_menu_gamepad.reset_input()
		_menu_gamepad.process_mode = Node.PROCESS_MODE_ALWAYS
	if capture_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
