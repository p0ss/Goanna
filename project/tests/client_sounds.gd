# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The sounds the client makes for the local player (ui/audio.gd), against
# upstream's SoundMaker and Camera::step, and what the player agent hears of
# every sound played. Offline, with a fake client; the session's own sounds
# (place, use, damage, other objects' footsteps) need a server and are not
# covered here.
#
#   godot --headless --path project -s tests/client_sounds.gd
extends SceneTree

const Audio := preload("res://ui/audio.gd")
const Channel := preload("res://player_agent_channel.gd")

var failures := 0
var checks := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", what)

class FakeClient extends Node:
	var under := "default:stone"
	var at_feet := "default:water_source"
	func media_names() -> Array:
		return ["stone_step.ogg", "water_step.ogg", "player_jump.ogg", "mob_growl.ogg"]
	func node_name_at(p: Vector3) -> String:
		return at_feet if fposmod(p.y, 1.0) < 0.001 or p.y == floorf(p.y) else under
	func node_sound(node: String, kind: String) -> Dictionary:
		if kind != "footstep":
			return {}
		return {"name": "water_step" if node == at_feet else "stone_step", "gain": 0.5}
	func take_sounds() -> Array: return []
	func take_stopped_sounds() -> Array: return []
	func status() -> Dictionary: return {"state": "ready"}

class FakeUi extends Node:
	var audio: Node
	var chat_lines: Array = []

class FakeMain extends Node:
	var client
	var ui: FakeUi
	var cam := Camera3D.new()
	var agent_dig := false
	var agent_place := false
	var agent_place_pressed := false

var audio: Node
var heard: Array = []

func _initialize() -> void:
	OS.set_environment("GOANNA_PLAYER_AGENT", str(43000 + randi() % 2000))
	audio = Audio.new()
	audio.client = FakeClient.new()
	audio.muted = true      # nothing to hear in a test; played still fires
	root.add_child(audio)
	for file in ["stone_step.ogg", "water_step.ogg", "player_jump.ogg", "mob_growl.ogg"]:
		audio._stream_cache[file] = AudioStreamOggVorbis.new()
	audio.played.connect(func(info: Dictionary) -> void: heard.append(info))
	_run.call_deferred()

# Runs the movement step for `seconds` at 60 frames a second.
func walk(seconds: float, move: Dictionary) -> Array:
	heard.clear()
	for i in roundi(seconds * 60.0):
		audio.step_local(1.0 / 60.0, move)
	return heard.duplicate()

func named(list: Array, name: String) -> Array:
	return list.filter(func(h: Dictionary) -> bool: return h.name == name)

func _run() -> void:
	var ground := {"pos": Vector3(0, 1, 0), "on_ground": true, "speed": Vector3(4, 0, 0)}
	walk(0.5, ground.merged({"speed": Vector3.ZERO}, true))
	# Camera::step: a step at the start and at every half cycle, the cycle
	# running at speed * 10 * 0.03 a second: 4 nodes a second is 1.2 cycles,
	# so 2 seconds is one step to start and 4.8 more.
	var steps := named(walk(2.0, ground), "stone_step")
	check(steps.size() >= 5 and steps.size() <= 6, "walking: %d steps in 2 s, upstream 5 or 6" % steps.size())
	check(steps.all(func(h: Dictionary) -> bool: return h.kind == "step" and h.position == null),
		"own footsteps are local and of kind step")
	walk(0.5, ground.merged({"speed": Vector3.ZERO}, true))
	var fast := named(walk(2.0, ground.merged({"speed": Vector3(20, 0, 0)}, true)), "stone_step")
	check(fast.size() >= 9 and fast.size() <= 10, "sprinting: %d steps in 2 s, upstream 9 or 10 (capped at 70)" % fast.size())
	check(walk(2.0, ground.merged({"speed": Vector3.ZERO}, true)).is_empty(), "standing still is silent")
	check(walk(2.0, ground.merged({"free_move": true}, true)).is_empty(), "flying is silent")
	# Landing: one step, of the node half a node under the feet in the air.
	walk(0.2, {"pos": Vector3(0, 3.3, 0), "on_ground": false, "speed": Vector3(0, -5, 0)})
	var landed := walk(1.0 / 60.0, {"pos": Vector3(0, 1.0, 0), "on_ground": true, "speed": Vector3.ZERO})
	check(named(landed, "stone_step").size() == 1, "landing makes one step: %s" % [landed])
	# Jumping: leaving the ground upwards, at most once in 0.2 s.
	heard.clear()
	audio.step_local(1.0 / 60.0, {"pos": Vector3(0, 1, 0), "on_ground": true, "speed": Vector3.ZERO})
	audio.step_local(1.0 / 60.0, {"pos": Vector3(0, 1.1, 0), "on_ground": false, "speed": Vector3(0, 6.5, 0)})
	audio.step_local(1.0 / 60.0, {"pos": Vector3(0, 1, 0), "on_ground": true, "speed": Vector3.ZERO})
	audio.step_local(1.0 / 60.0, {"pos": Vector3(0, 1.1, 0), "on_ground": false, "speed": Vector3(0, 6.5, 0)})
	var jumps := named(heard, "player_jump")
	check(jumps.size() == 1 and jumps[0].kind == "jump" and is_equal_approx(float(jumps[0].gain), 0.5),
		"one jump sound at half gain, the second within 0.2 s held back: %d" % jumps.size())
	# Swimming: steps of the node at the feet.
	walk(0.5, ground.merged({"speed": Vector3.ZERO}, true))
	var swim := walk(1.0, {"pos": Vector3(0, 0, 0), "on_ground": false, "in_liquid": true,
		"speed": Vector3(2, 0, 0)})
	check(named(swim, "water_step").size() >= 1 and named(swim, "stone_step").is_empty(),
		"swimming steps are the water's: %s" % [swim.map(func(h: Dictionary) -> String: return h.name)])

	# What the player agent hears.
	var main := FakeMain.new()
	main.client = audio.client
	main.ui = FakeUi.new()
	main.ui.audio = audio
	root.add_child(main)
	main.add_child(main.cam)
	main.add_child(main.ui)
	var channel: Node = Channel.new()
	channel.main = main
	root.add_child(channel)
	await process_frame
	await process_frame
	var before: int = channel._event_cursor
	audio.play("mob_growl", 0.8, 1.0, false, Vector3(-10, 0, 0), 5, "", 0)
	audio.play("stone_step", 0.5, 1.0, false, null, 0, "step")
	audio.play("water_step", 0.3, 1.0, false, Vector3(0, 0, -3), 0, "footstep", 0)
	audio.play("player_jump", 0.5, 1.0, false, null, 0, "damage")
	var events: Array = channel._events.filter(func(e: Dictionary) -> bool:
		return int(e.cursor) > before and e.kind == "sound")
	check(events.size() == 3, "own footsteps are not reported, the rest are: %s" % [events])
	if events.size() == 3:
		var growl: Dictionary = events[0]
		check(growl.sound == "mob_growl" and growl.source == "server" and growl.distance == 10 \
			and absf(float(growl.look.yaw) - 90.0) < 0.5 and not growl.has("position"),
			"a sound in the world comes with the look to face it and its distance, not its place: %s" % [growl])
		check(events[1].source == "footstep" and events[1].distance == 3,
			"another object's footstep, three nodes ahead")
		check(events[2].get("local", false) and events[2].source == "damage",
			"a sound local to the player says so")
	print("client sounds: %d checks, %s" % [checks, "PASS" if failures == 0 else "FAIL (%d)" % failures])
	quit(0 if failures == 0 else 1)
