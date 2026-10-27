# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Tests the footfall detector (game/effects/footfalls.gd) and how
## climate_particles.gd reads the climate field, without drawing a frame.
## Headless, no server or GPU:
## godot --headless --path project --script res://tests/footfalls.gd
#
# Checked:
#   - a body walking on the ground steps about once a STRIDE, none while it
#     stands, none along a teleport, none in the air, and one landing when
#     it comes down from a fall;
#   - dust rises from dry ground and not from damp, spatter only from
#     soaked, breath only in the cold, and none of it where the field is
#     unknown;
#   - grit blows only over dry ground in a wind;
#   - the dust takes the colour of the ground, paled;
#   - the climate particles node builds with a fake client and reports its
#     state;
#   - the heat shimmer finds heat round the eye, keeps its answer while the
#     field is unknown, and its shader and the droplet shader compile.
# How any of it looks is not tested here.
extends SceneTree

const Footfalls := preload("res://game/effects/footfalls.gd")
const ClimateParticles := preload("res://game/effects/climate_particles.gd")
const HeatShimmer := preload("res://game/effects/heat_shimmer.gd")
const PlayerContext := preload("res://game/player_context.gd")

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


class FakeMain extends Node3D:
	var cam := Camera3D.new()
	var last_move := {"pos": Vector3.ZERO}
	var fly_mode := false
	var grass_wind := Vector2(0.3, 0.0)

	func _init() -> void:
		add_to_group("goanna_main")
		add_child(cam)


class FakeWake extends Node:
	var main: Node

	func gather_sources(m: Node, _eye: Vector3) -> Array:
		return [{"key": "local", "pos": m.last_move["pos"]}]


# The node itself, as a game frame drives it: a player walking across dry
# sand at four nodes a second for two seconds must kick up dust.
func _test_walking_node() -> void:
	var m := FakeMain.new()
	root.add_child(m)
	var n := ClimateParticles.new()
	n.client = FakeClient.new()
	n.wake = FakeWake.new()
	root.add_child(n)
	await process_frame
	var x := 0.0
	for i in 40:
		x += 4.0 * 0.05
		m.last_move = {"pos": Vector3(x, 0.0, 0.0)}
		m.cam.position = Vector3(x, 1.6, 0.0)
		n._process(0.05)
	var s: Dictionary = n.debug_state()
	check(int(s["steps"]) >= 7, "walking 8 nodes through the node gave %s" % [s])
	check(int(s["dust"]) >= 1, "walking on dry sand raised no dust: %s" % [s])
	var red := ClimateParticles.dust_tint(Color(0.7, 0.35, 0.15))
	check(n.dust_colour.b < ClimateParticles.DUST_COLOUR.b and n.dust_colour.r > n.dust_colour.b,
			"the dust did not turn toward the red sand: %s" % [n.dust_colour])
	check(red.r > red.g and red.g > red.b and red.b > 0.15,
			"dust_tint lost the ground's hue or did not pale it: %s" % [red])
	n.queue_free()
	m.queue_free()
	await process_frame


func _initialize() -> void:
	_test_walk()
	_test_field()
	_test_node()
	await _test_walking_node()
	_test_shimmer()
	print("footfalls: %d failures" % failures)
	quit(1 if failures else 0)


func _walk(f, path: Array, ground: Callable, dt := 0.1) -> Array:
	var out := []
	var t := 0.0
	for p in path:
		t += dt
		out.append_array(f.step([{"key": "a", "pos": p}], dt, t, ground))
	return out


func _test_walk() -> void:
	var flat := func(p: Vector3) -> bool: return p.y <= 0.01
	# Four nodes a second for two seconds: 8 nodes, about 10 steps.
	var path := []
	for i in 21:
		path.append(Vector3(i * 0.4, 0.0, 0.0))
	var steps := _walk(Footfalls.new(), path, flat)
	check(steps.size() >= 9 and steps.size() <= 10, "walking 8 nodes: %d steps" % steps.size())
	check(steps.all(func(s): return not s["landing"]), "a walk has no landings")
	# Standing still.
	path = []
	for i in 20:
		path.append(Vector3(1.0, 0.0, 1.0))
	check(_walk(Footfalls.new(), path, flat).is_empty(), "standing still steps")
	# A teleport of 50 nodes in one sample.
	check(_walk(Footfalls.new(), [Vector3.ZERO, Vector3(50, 0, 0), Vector3(50, 0, 0)], flat).is_empty(),
			"a teleport left steps")
	# Running through the air.
	path = []
	for i in 20:
		path.append(Vector3(i * 0.4, 5.0, 0.0))
	check(_walk(Footfalls.new(), path, flat).is_empty(), "steps in the air")
	# Falling three nodes and landing.
	path = [Vector3(0, 3, 0), Vector3(0, 2, 0), Vector3(0, 1, 0), Vector3(0, 0, 0), Vector3(0, 0, 0)]
	var land := _walk(Footfalls.new(), path, flat)
	check(land.size() == 1 and land[0]["landing"], "a fall gave %s" % [land])


func _test_field() -> void:
	var dry := {"temp": 20.0, "wet": 0.05, "hum": 0.2, "known": 1.0}
	var damp := {"temp": 12.0, "wet": 0.6, "hum": 0.7, "known": 1.0}
	var soaked := {"temp": 12.0, "wet": 0.98, "hum": 0.95, "known": 1.0}
	var cold := {"temp": -10.0, "wet": 0.6, "hum": 0.6, "known": 1.0}
	check(ClimateParticles.dust_for(dry) > 0.9, "dry ground gives dust")
	check(ClimateParticles.dust_for(damp) == 0.0, "damp ground gives dust")
	check(ClimateParticles.spatter_for(soaked) > 0.9, "soaked ground spatters")
	check(ClimateParticles.spatter_for(damp) == 0.0, "damp ground spatters")
	check(ClimateParticles.breath_for(cold) > 0.5, "no breath at -10 C")
	check(ClimateParticles.breath_for(dry) == 0.0, "breath at 20 C")
	var half := dry.duplicate()
	half["known"] = 0.5
	check(absf(ClimateParticles.dust_for(half) - 0.5 * ClimateParticles.dust_for(dry)) < 1e-4,
			"dust is not scaled by how much is known")
	check(ClimateParticles.grit_for(dry, 1.0) > 0.9, "no grit over dry ground in a gale")
	check(ClimateParticles.grit_for(dry, 0.25) == 0.0, "grit in still air")
	check(ClimateParticles.grit_for(damp, 1.0) == 0.0, "grit over damp ground")
	check(ClimateParticles.dust_for({}) == 0.0 and ClimateParticles.breath_for({}) == 0.0,
			"an unknown field gives something")


class FakeClient extends Node:
	func climate_at(_p: Vector3) -> Dictionary:
		return {"temp": 20.0, "wet": 0.05, "hum": 0.2, "known": 1.0}

	func node_name_at(p: Vector3) -> String:
		return "mcl_core:sand" if p.y < 0.0 else "air"

	# Red sand under the walk.
	func ground_dust(_p: Vector3, _wide: bool) -> Color:
		return Color(0.7, 0.35, 0.15, 1.0)


func _test_node() -> void:
	var n := ClimateParticles.new()
	n.client = FakeClient.new()
	root.add_child(n)
	check(n.field(Vector3.ZERO).get("wet", -1.0) == 0.05, "field() did not pass the client's value")
	check(n._footing(Vector3(0, 0, 0)), "sand under the feet is not footing")
	check(not n._footing(Vector3(0, 2, 0)), "air under the feet is footing")
	var s: Dictionary = n.debug_state()
	check(s.has("steps") and s.has("motes"), "debug_state lacks counts: %s" % [s])
	n.client.free()
	n.queue_free()


class HotClient extends Node:
	var temp := 20.0
	var known := 1.0

	func climate_at(p: Vector3) -> Dictionary:
		# Hot only far out to the east, as lava past the edge of a view.
		if known <= 0.0:
			return {}
		return {"temp": temp if p.x > 50.0 else 15.0, "wet": 0.1, "hum": 0.2, "known": known}

	func load_view_shader(path: String) -> Shader:
		return load(path)


func _test_shimmer() -> void:
	for path in ["res://shaders/heat_shimmer.gdshader", "res://shaders/droplet.gdshader"]:
		var sh: Shader = load(path)
		check(sh != null and not sh.get_shader_uniform_list().is_empty(), path + " did not compile")
	var cam := Camera3D.new()
	root.add_child(cam)
	var c := HotClient.new()
	var h := HeatShimmer.new(cam, c)
	check(h.quad.get_parent() == cam, "the shimmer quad is not on the camera")
	h.update(1.0, c, Vector3.ZERO, true)
	check(not h.quad.visible, "shimmer shown with nothing hot")
	c.temp = 40.0
	h.update(1.0, c, Vector3.ZERO, true)
	check(h.quad.visible, "shimmer hidden with hot ground 64 nodes off")
	c.known = 0.0
	h.update(1.0, c, Vector3.ZERO, true)
	check(h.quad.visible, "shimmer dropped while the field was unknown")
	h.update(1.0, c, Vector3.ZERO, false)
	check(not h.quad.visible, "shimmer shown with the switch off")
	c.free()
	cam.queue_free()
