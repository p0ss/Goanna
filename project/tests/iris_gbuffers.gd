# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Checks a real shader pack's geometry programs translate into Godot
## shaders that Godot's own front end accepts. Headless (the dummy renderer
## still compiles shaders), no server or GPU:
## godot --headless --path project --script res://tests/iris_gbuffers.gd
## GOANNA_IRIS_PACK=/path/to/pack checks another pack instead of the
## bundled Base-Shader.
#
# GoannaIrisGbuffers (src/iris/goanna_iris_gbuffers.cpp) translates the
# pack's gbuffers_terrain, gbuffers_terrain_cutout and gbuffers_water, each
# with Iris's fallbacks, and registers the global parameters they read. A
# shader that fails to compile in Godot leaves no uniforms, which is what
# this looks for, as tests/node_array_shaders.gd does for Goanna's own. It
# also checks what the client sets on such a material is declared, and the
# block.properties mapping. How the result looks is not tested here; that
# needs a frame (docs/design/iris-compat.md, rung 5).
extends SceneTree

const BASE := "res://tests/shaderpacks/base-shader"
# What GoannaClient::materialFor and applyIrisGbuffers set on a pack
# material for the array tiles; the water, the foliage (leaves and
# plants) and the other single texture tiles take albedo_tex instead.
# Surface 6 is that last: emissive nodes and textures no array holds.
const ARRAY_UNIFORMS := ["albedo_array", "layer_anim", "goanna_iris_block_ids"]
const SINGLE_UNIFORMS := {2: ["albedo_tex", "goanna_iris_entity_override"],
		3: ["albedo_tex", "goanna_iris_block_ids"],
		6: ["albedo_tex", "goanna_iris_block_ids", "single_sided"]}

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func uniform_names(shader: Shader) -> Dictionary:
	var names := {}
	for u in shader.get_shader_uniform_list(true):
		names[u["name"]] = true
	return names


func _initialize() -> void:
	_test_pack.call_deferred()


func _test_pack() -> void:
	var bodies := {"sun_direction": Vector3.UP, "moon_direction": Vector3.DOWN}
	var tilted: Dictionary = preload("res://game/effects/iris_sky.gd").celestial_state(bodies, -40.0)
	check(tilted["sun_direction"].is_equal_approx(Vector3(0, cos(deg_to_rad(40.0)), -sin(deg_to_rad(40.0)))),
		"negative sun path rotation tilts midday towards negative Godot Z")
	check(tilted["moon_direction"].is_equal_approx(-tilted["sun_direction"]), "moon follows the same orbit")
	check(bodies["sun_direction"] == Vector3.UP, "pack orbit does not change the server state")
	check(preload("res://game/effects/iris_sky.gd").celestial_state(bodies, 0.0) == bodies,
		"zero rotation preserves the server orbit")
	var path := OS.get_environment("GOANNA_IRIS_PACK")
	var bundled := path == ""
	if bundled:
		path = ProjectSettings.globalize_path(BASE)
	var g := GoannaIrisGbuffers.new()
	check(g.load_pack(path), "the pack did not load: %s" % g.report())
	var camera := Camera3D.new()
	root.add_child(camera)
	g.update(camera, {"time_of_day": 0.75})
	var lighting := g.lighting_state()
	check(is_equal_approx(lighting["sunAngle"], 0.4636752137),
		"sunAngle follows the dusk orbit rather than the clock")
	check(lighting["worldTime"] == 12000, "worldTime retains the dusk clock")
	g.update(camera, {"time_of_day": 0.0})
	check(is_equal_approx(g.lighting_state()["sunAngle"], 0.75), "midnight sunAngle wraps")
	check(g.lighting_state()["worldTime"] == 18000, "midnight worldTime wraps")
	camera.free()
	var report: Dictionary = g.report()
	print("iris_gbuffers: ", report)
	for surface in [0, 1, 2, 3, 6]:
		var shader: Shader = g.shader(surface)
		var name: String = ["terrain", "cutout", "water", "foliage", "", "", "single"][surface]
		check(shader != null, name + " was not translated: %s" % report.get(name))
		if shader == null:
			continue
		var names := uniform_names(shader)
		check(not names.is_empty(), name + " does not compile in Godot")
		for u in (ARRAY_UNIFORMS if surface < 2 else SINGLE_UNIFORMS[surface]):
			check(names.has(u), name + " has no uniform " + u)
	for surface in [4, 5]:
		var shader: Shader = g.shader(surface)
		if shader != null:
			check(not uniform_names(shader).is_empty(), "sky program does not compile in Godot")
	# second_targets() is every surface's second outputs together, the
	# colortex numbers game/effects/iris_targets.gd may draw.
	var union := {}
	for name in ["terrain", "cutout", "water", "foliage", "sky", "sky_textured", "single"]:
		if report[name]["translated"]:
			for ct in report[name]["second_colortex"]:
				check(ct >= 1 and ct <= 15, name + " has a second output outside colortex1 to 15")
				union[ct] = true
	var keys := union.keys()
	keys.sort()
	check(Array(g.second_targets()) == keys, "second_targets() is not the surfaces' union")
	# translucent_targets() is the water's second outputs no other surface
	# writes.
	var opaque := {}
	for name in ["terrain", "cutout", "foliage", "sky", "sky_textured", "single"]:
		if report[name]["translated"]:
			for ct in report[name]["second_colortex"]:
				opaque[ct] = true
	var water_only := []
	if report["water"]["translated"]:
		for ct in report["water"]["second_colortex"]:
			if not opaque.has(ct):
				water_only.push_back(ct)
	water_only.sort()
	check(Array(g.translucent_targets()) == water_only, "translucent_targets() is not the water's own outputs")
	# The chain half says which of them it reads; only those get a camera.
	# Base-Shader has no chain.
	var effect := GoannaIrisEffect.new()
	if not bundled and effect.load_pack(path):
		var read := []
		for ct in g.second_targets():
			if effect.reads_colortex(ct):
				read.push_back(ct)
		print("iris_gbuffers: second outputs ", g.second_targets(), ", read by the chain ", read)
	check(not effect.reads_colortex(16), "colortex16 is out of range")
	if bundled:
		# Base-Shader's three programs, as the plan reads them: terrain and its
		# cutout have their own, water falls back to terrain, and none writes
		# a second target.
		check(g.second_targets().is_empty(), "Base-Shader has a second output")
		check(String(report["terrain"]["program"]) == "gbuffers_terrain", "terrain program")
		check(String(report["cutout"]["program"]) == "gbuffers_terrain_cutout", "cutout program")
		check(String(report["water"]["program"]) == "gbuffers_terrain", "water falls back to terrain")
		check(String(report["single"]["program"]) == "gbuffers_terrain", "single tiles use terrain")
		for s in ["terrain", "cutout", "water"]:
			check((report[s]["dropped_colortex"] as PackedInt32Array).is_empty(), s + " drops a target")
			check(not report[s]["moves_vertices"], s + " moves vertices")
		# block.10000 lists grass_block and the leaves tag.
		check(g.block_id("grass_block") == 10000, "grass_block is not 10000")
		check(g.block_id("grass_block_top") == 10000, "a texture name does not find its block")
		check(g.block_id("oak_leaves") == 10000, "the leaves tag does not match oak_leaves")
		check(g.block_id("stone") == -1, "an unlisted block is not -1")
		var ids: PackedInt32Array = g.block_ids(PackedStringArray(["", "stone", "oak_leaves"]))
		check(ids.size() == 512 and ids[1] == -1 and ids[2] == 10000, "block_ids table")
	# The shadow program (rung 7), translated for the opaque and cut-out
	# array tiles and the foliage; Base-Shader has none.
	if bundled:
		check(not g.has_shadow(), "Base-Shader has no shadow program")
	elif g.has_shadow():
		for surface in [0, 1, 3, 6]:
			var shadow: Shader = g.shadow_shader(surface)
			var sname: String = "shadow " + ["terrain", "cutout", "", "foliage", "", "", "single"][surface]
			check(shadow != null, sname + " was not translated: %s" % report.get("shadow"))
			if shadow == null:
				continue
			var snames := uniform_names(shadow)
			check(not snames.is_empty(), sname + " does not compile in Godot")
			for u in (ARRAY_UNIFORMS if surface < 2 else ["albedo_tex"]):
				check(snames.has(u), sname + " has no uniform " + u)
	print("iris_gbuffers: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)
