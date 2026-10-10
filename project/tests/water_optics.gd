# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/water_optics.gd
#
# The water round the eye (docs/systems/water-optics.md), everything that can be
# checked without drawing a frame:
#   - the water shader compiles with the shared optics and the globals it
#     reads are registered, at the beach's values by default; the underwater
#     murk is deep water's colour as the shader makes it (the same body
#     gain, the water tile's colour from the client) and the underside no
#     longer reflects the sky above it;
#   - beds, lily pads and river water read as the regions a player would
#     read them as, and a lily pad is not water;
#   - the murk is clear at the surface (clearer than the one fixed fog that
#     was too murky there), keeps that old fog for a beach's depths, and
#     reaches a swamp's murk far sooner than a beach's;
#   - the eye's depth under the surface is measured;
#   - with the head in water, camera in it or out of it (third person), the
#     game's one-colour water sky gives way to the last ordinary sky; with
#     the head out, the game's sky stands;
#   - the size of the water sets the background waves: a small pond lies
#     nearly flat under short ripples, the open sea runs longer and higher;
#   - wading from a beach into a swamp finds the swamp and eases the optics
#     there over a couple of seconds rather than switching, and the water
#     shader is handed them.
# It renders nothing: how any of it looks is not tested here.
extends SceneTree

const Optics := preload("res://water_optics.gd")
const WATER := "res://shaders/water.gdshader"

var failures := 0
var finished := 0


# Stands in for GoannaClient where the shader's globals are set.
class Globals:
	extends RefCounted
	var values := {}

	func set_view_shader_parameter(key: StringName, value: Variant) -> void:
		values[key] = value


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _initialize() -> void:
	_test_shader()
	_test_regions()
	_test_murk()
	_test_wading()
	_test_sea()
	_test_dry_sky()
	check(finished == 6, "%d of 6 tests ran to their end" % finished)
	print("water optics: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)


# A sea with its surface at y 0.5 (water in every node at or under y 0) down
# to a bed at y -6. The bed is sand for x under 20, mud past it, where lily
# pads float on the water.
func _world(p: Vector3) -> String:
	var ny := roundi(p.y)
	if ny <= -6:
		return "mcl_core:sand" if p.x < 20.0 else "mcl_mud:mud"
	if ny <= 0:
		return "mcl_core:water_source"
	if ny == 1 and p.x >= 20.0:
		return "mcl_flowers:waterlily"
	return "air"


func _test_shader() -> void:
	var shader: Shader = load(WATER)
	check(shader != null and shader.get_shader_uniform_list().size() > 0, "the water shader does not compile")
	var src := FileAccess.get_file_as_string(WATER)
	check(not src.contains("uniform vec3 absorption"), "the water shader keeps an absorption of its own")
	var globals := RenderingServer.global_shader_parameter_get_list()
	for name in ["goanna_water_absorption", "goanna_water_tint", "goanna_water_fog", "goanna_water_sea"]:
		check(src.contains(name), "the water shader does not read " + name)
		check(globals.has(StringName(name)), name + " is not registered in project.godot")
	var registered: Dictionary = ProjectSettings.get_setting("shader_globals/goanna_water_absorption")
	check(registered["value"] == Optics.REGIONS["clear"]["absorption"],
			"the water shader does not start at a beach's absorption")
	# The murk's colour is daylight through the water, by the region: a
	# beach's the old cyan the owner found right, a swamp's a dark green;
	# main.gd lights it by the light on the water. The underside mirrors
	# the water below past the critical angle, fading into the murk.
	var beach: Color = Optics.murk_hue(Optics.REGIONS["clear"])
	check(beach.is_equal_approx(Color(0.217, 0.609, 0.739)) or
			Vector3(beach.r - 0.217, beach.g - 0.609, beach.b - 0.739).length() < 0.02,
			"a beach's murk is not the cyan the owner liked: %s" % beach)
	var swamp_hue: Color = Optics.murk_hue(Optics.REGIONS["swamp"])
	check(swamp_hue.g > swamp_hue.r and swamp_hue.g > swamp_hue.b and swamp_hue.g < 0.3,
			"a swamp's murk is not a dark green: %s" % swamp_hue)
	var main_src := FileAccess.get_file_as_string("res://main.gd")
	check(main_src.contains("WaterOptics.murk_hue(o)") and main_src.contains("WATER_NOON_LIGHT"),
			"main.gd does not light the murk's hue")
	check(src.contains("vec3 rdir = reflect(normalize(VERTEX), NORMAL);"),
			"the underside does not mirror the water below")
	check(src.contains("!FRONT_FACING && face_up > 0.7") and src.contains("vec3 last = goanna_water_fog.rgb;"),
			"the underside's mirror is not the top's only, or falls back to flat murk")
	# Every opaque surface seen from under the water loses its light to the
	# water per colour, as the bed seen from above does.
	for f in ["nodes_array.gdshader", "nodes_array_scissor.gdshader", "waving_plants.gdshader",
			"waving_leaves.gdshader", "entity_common.gdshaderinc", "grass_volume.gdshader"]:
		var text := FileAccess.get_file_as_string("res://shaders/" + f)
		check(text.contains("underwater.gdshaderinc") and text.contains("ALBEDO *= goanna_uw;"),
				f + " is not absorbed under the water")
	check(globals.has(&"goanna_water_surface"), "goanna_water_surface is not registered")
	check(src.contains("SPECULAR = FRONT_FACING ?"), "the underside still reflects the sky above it")
	# The per view globals take float, vec3, vec4 and samplers only.
	for key in ProjectSettings.get_property_list():
		var name: String = key["name"]
		if name.begins_with("shader_globals/goanna_water") or name.begins_with("shader_globals/goanna_ripple"):
			var type: String = ProjectSettings.get_setting(name)["type"]
			check(type in ["float", "vec3", "vec4", "sampler2D", "sampler3D"],
					"%s is a %s, which a view's globals cannot hold" % [name, type])
	finished += 1


func _test_regions() -> void:
	check(Optics.bed_region("mcl_core:sand") == "clear" and Optics.bed_region("mcl_core:gravel") == "clear"
			and Optics.bed_region("mcl_core:stone") == "clear", "sand, gravel and stone are not a beach's")
	check(Optics.bed_region("mcl_core:clay") == "lake" and Optics.bed_region("mcl_core:dirt") == "lake",
			"clay and dirt are not a lake's")
	check(Optics.bed_region("mcl_mud:mud") == "swamp", "mud is not a swamp's")
	check(Optics.bed_region("mcl_flowers:tulip") == "", "a flower has an opinion about the water")
	check(Optics.column_region("mcl_core:water_source", "air", "mcl_core:sand") == "clear", "a sandy column")
	check(Optics.column_region("mcl_core:water_source", "mcl_flowers:waterlily", "mcl_core:sand") == "swamp",
			"lily pads do not make a swamp")
	check(Optics.column_region("mclx_core:river_water_source", "air", "mcl_core:gravel") == "river",
			"river water is not a river's")
	check(Optics.column_region("mclx_core:river_water_source", "air", "mcl_mud:mud") == "swamp",
			"a muddy river is not a swamp's")
	check(not Optics.is_water_name("mcl_flowers:waterlily"), "a lily pad is water")
	check(Optics.is_water_name("mcl_core:water_flowing"), "flowing water is not water")
	var half := Optics.blend({"clear": 1, "swamp": 1})
	var a: Vector3 = half["absorption"]
	var want: Vector3 = (Optics.REGIONS["clear"]["absorption"] + Optics.REGIONS["swamp"]["absorption"]) * 0.5
	check(a.is_equal_approx(want), "an even mix is not half of each: %s" % a)
	finished += 1


func _test_murk() -> void:
	var clear: Dictionary = Optics.REGIONS["clear"]
	var swamp: Dictionary = Optics.REGIONS["swamp"]
	var at_top: Dictionary = Optics.murk(clear, 0.0)
	var deep: Dictionary = Optics.murk(clear, 200.0)
	print("water optics: beach murk %.3f at the surface, %.3f 4 nodes down, %.3f 16 down, %.3f deep"
			% [at_top["density"], Optics.murk(clear, 4.0)["density"], Optics.murk(clear, 16.0)["density"],
			deep["density"]])
	print("water optics: swamp murk %.3f at the surface, %.3f 4 nodes down, %.3f deep"
			% [Optics.murk(swamp, 0.0)["density"], Optics.murk(swamp, 4.0)["density"],
			Optics.murk(swamp, 200.0)["density"]])
	check(at_top["density"] < 0.05 * 0.5, "the water is as murky at the surface as the old fixed fog")
	check(is_equal_approx(deep["density"], 0.05), "a beach's depths lost the old fog's murk")
	check(at_top["light"] > deep["light"], "the depths are no darker than the surface")
	var last := -1.0
	for d in range(0, 40, 2):
		var m: float = Optics.murk(clear, d)["density"]
		check(m >= last, "the murk thins going deeper, at %d" % d)
		last = m
	var way := func(o: Dictionary, d: float) -> float:
		return (Optics.murk(o, d)["density"] - o["shallow"]) / (o["deep"] - o["shallow"])
	check(way.call(swamp, 3.0) > 2.0 * way.call(clear, 3.0),
			"a swamp does not reach its murk much sooner than a beach")
	check(swamp["shallow"] > clear["deep"], "a swamp's shallows are clearer than a beach's depths")
	finished += 1


func _test_wading() -> void:
	var o: Node = Optics.new()
	o.node_at = _world
	o.client = Globals.new()
	# In the sea over sand, eye three nodes under the surface.
	var eye := Vector3(5.0, -2.5, 5.0)
	for i in 60:
		o.step(eye, 1.0 / 60.0)
	check(is_equal_approx(o.eye_depth, 3.0), "the eye is %.2f under the surface, not 3" % o.eye_depth)
	check(o.found.has("clear") and not o.found.has("swamp"), "the sandy sea is not a beach's: %s" % o.found)
	check(o.water_name == "mcl_core:water_source", "the murk's water is %s" % o.water_name)
	# Out over the mud under the lily pads. A sweep finds it within a
	# second, and the optics ease there over a couple more, not at once.
	eye = Vector3(40.0, -2.5, 5.0)
	var clear_a: Vector3 = Optics.REGIONS["clear"]["absorption"]
	var swamp_a: Vector3 = Optics.REGIONS["swamp"]["absorption"]
	var seconds := 0.0
	var at_half := -1.0
	while seconds < 10.0:
		o.step(eye, 1.0 / 60.0)
		seconds += 1.0 / 60.0
		var a: Vector3 = o.current["absorption"]
		if at_half < 0.0 and (a - clear_a).length() > 0.5 * (swamp_a - clear_a).length():
			at_half = seconds
	print("water optics: halfway to a swamp's optics %.1f s after wading in" % at_half)
	check(o.found.has("swamp"), "the muddy water under the lily pads is not a swamp's: %s" % o.found)
	check(at_half > 0.5 and at_half < 4.0, "the optics switch at once or never: halfway at %.1f s" % at_half)
	check((o.current["absorption"] as Vector3).is_equal_approx(swamp_a) or
			((o.current["absorption"] as Vector3) - swamp_a).length() < 0.02,
			"the optics do not settle on a swamp's")
	var shader: Dictionary = o.client.values
	check((shader.get(&"goanna_water_absorption", Vector3.ZERO) as Vector3).distance_to(o.current["absorption"]) < 1e-4,
			"the water shader is not handed the optics")
	check(shader.has(&"goanna_water_tint"), "the water shader is not handed the tint")
	# Out of the water: depth 0.
	o.step(Vector3(5.0, 3.0, 5.0), 1.0 / 60.0)
	check(o.eye_depth == 0.0, "the eye in the air is under the water")
	o.free()
	finished += 1


# A pond 6 nodes across, surface at y 0.5, two deep, in grass.
func _pond(p: Vector3) -> String:
	var ny := roundi(p.y)
	var inside := absf(p.x) <= 3.0 and absf(p.z) <= 3.0
	if ny <= -2:
		return "mcl_core:dirt"
	if ny <= 0:
		return "mcl_core:water_source" if inside else "mcl_core:dirt"
	return "air"


func _test_sea() -> void:
	check(is_equal_approx(Optics.sea_for(2.0), Optics.SEA_POND), "a puddle is not a pond's calm")
	check(is_equal_approx(Optics.sea_for(200.0), Optics.SEA_OPEN), "the open sea is not the open sea's")
	var last := 0.0
	for r in range(0, 70, 4):
		var v := Optics.sea_for(r)
		check(v >= last, "the waves shrink as the water grows, at %d" % r)
		last = v
	check(Optics.SEA_POND < 0.5 and Optics.SEA_OPEN > 1.0, "a pond is not calmer and the sea not bigger than a lake")
	# The size of the water scales the waves' strength only. Scaling their
	# length or speed multiplies the world position and TIME in the shader,
	# and near a shore, where the measured size wavers, the sea strobed.
	var shader_src := FileAccess.get_file_as_string(WATER)
	check(shader_src.contains("TIME * wave_speed, octaves") and shader_src.contains("TAU / max(wave_length, 0.5)"),
			"the size of the water scales the waves' length or speed")
	for world in [[_world, "sea"], [_pond, "pond"]]:
		var o: Node = Optics.new()
		o.node_at = world[0]
		o.client = Globals.new()
		var eye := Vector3(0.0, 1.6, 0.0)
		for i in 600:
			o.step(eye, 1.0 / 60.0)
		print("water optics: the %s reaches %.1f nodes, waves %.2f as strong as a lake's"
				% [world[1], o.fetch, o.sea])
		if world[1] == "sea":
			check(o.fetch >= Optics.FETCH_REACH - 0.01, "the open sea is %.1f nodes across" % o.fetch)
			check(o.sea > 1.2, "the open sea's waves are not bigger than a lake's")
		else:
			check(o.fetch < 8.0, "a 6 node pond reaches %.1f nodes" % o.fetch)
			check(o.sea < 0.4, "the pond's waves are not calm: %.2f" % o.sea)
		var published: Vector4 = o.client.values.get(&"goanna_water_sea", Vector4.ZERO)
		check(is_equal_approx(published.x, o.sea), "the water shader is not handed the waves")
		o.free()
	finished += 1


func _test_dry_sky() -> void:
	var main_script: GDScript = load("res://main.gd")
	var colours := ["day_sky", "day_horizon", "dawn_sky", "dawn_horizon", "night_sky", "night_horizon"]
	var make := func(base: Color, top: Color, clouds: bool) -> Dictionary:
		var sky := {"type": "regular", "clouds": clouds}
		for k in colours:
			sky[k] = top if k.ends_with("sky") else base
		return {"sky": sky, "clouds": {"density": 0.4}}
	var ordinary: Dictionary = make.call(Color(0.6, 0.7, 0.9), Color(0.3, 0.5, 0.9), true)
	var wet: Dictionary = make.call(Color(0.25, 0.46, 0.89), Color(0.25, 0.46, 0.89), false)
	var kept := {}
	main_script.dry_sky(ordinary, kept, false, false)
	var seen: Dictionary = main_script.dry_sky(wet, kept, true, false)
	check(seen["sky"]["day_horizon"] == ordinary["sky"]["day_horizon"] and bool(seen["sky"]["clouds"]),
			"a camera above the water draws the water sky the head is in")
	check(main_script.dry_sky(wet, kept, true, true)["sky"]["day_horizon"] == ordinary["sky"]["day_horizon"],
			"a camera in the water draws the game's water sky through the surface")
	check(main_script.dry_sky(wet, kept, false, false)["sky"]["day_horizon"] == wet["sky"]["day_horizon"],
			"a one-colour sky with the head dry was replaced")
	finished += 1
