# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/node_array_shaders.gd
#
# The two node array shaders, which GoannaClient::materialFor picks between
# per tile (arrayTileKey in goanna_client.cpp): nodes_array.gdshader for a
# tile whose own layer is opaque, nodes_array_scissor.gdshader for one with
# alpha. Both are handed the same uniforms by the same code, so a uniform
# missing from either is set into nothing and silently does nothing. The
# headless renderer runs Godot's shader front end in full (a type error
# fails the compile and leaves no uniforms), so this checks that both
# compile and declare everything the client sets, and that the opaque one
# has the parallax march the Lowest profile's mat_parallax channel switches.
# It renders nothing: how either looks is not tested here.
extends SceneTree

const GraphicsProfiles := preload("res://graphics_profiles.gd")

const NODES := "res://shaders/nodes_array.gdshader"
const SCISSOR := "res://shaders/nodes_array_scissor.gdshader"
# What materialFor sets by name on an array material, of either shader.
const SET_BY_CLIENT := ["albedo_array", "normal_array", "spec_array", "has_normal",
		"has_spec", "layer_class", "layer_anim", "layer_depth", "layer_coarse",
		"layer_roughness_floor", "pack_normal_gain", "block_light_emission",
		"lod_flatten", "lod_avg_colour", "lod_coverage", "lod_avg_rough",
		"lod_avg_metal", "lod_avg_spec", "lod_normal_variance"]
# kMatStrengthDefaults in goanna_client.cpp: each is set as <channel>_strength
# on every material, and the settings sliders move them through
# set_material_strength.
const CHANNELS := ["normal", "ao", "roughness", "specular", "emission", "sss",
		"sky_light", "vertex_ao", "vertex_ao_light", "sky_fill", "stale",
		"debug_nodelight", "detail", "parallax", "parallax_short", "micro_shadow"]
# The march's own knobs, besides parallax_strength.
const PARALLAX := ["parallax_depth", "parallax_range", "parallax_shadow_strength",
		"parallax_silhouette", "layer_depth"]

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func uniforms(path: String) -> Dictionary:
	var shader: Shader = load(path)
	check(shader != null, "cannot load " + path)
	var names := {}
	if shader:
		for u in shader.get_shader_uniform_list(true):
			names[u["name"]] = true
	check(not names.is_empty(), path + " did not compile")
	return names


func _initialize() -> void:
	var sets := SET_BY_CLIENT.duplicate()
	for c in CHANNELS:
		sets.append(c + "_strength")
	for path in [NODES, SCISSOR]:
		var names := uniforms(path)
		for n in sets + PARALLAX:
			check(names.has(n), path + " has no uniform " + n)

	# The uniforms live in the shared include, so both declare them; what
	# matters is which one uses them. The opaque shader marches and shadows,
	# reads the layer's own depth, and never enters the alpha scissor
	# pipeline (godotengine/godot#60388); the scissor one alpha tests.
	var nodes := FileAccess.get_file_as_string(NODES)
	var scissor := FileAccess.get_file_as_string(SCISSOR)
	for text in ["if (has_normal && parallax_strength > 0.001 && flatten < 0.999) {",
			"(layer_depth[layer] > 0.0 ? layer_depth[layer] : goanna_class_depth(cls))",
			"* parallax_depth * pom;",
			"if (parallax_shadow_strength > 0.001 && goanna_sun_dir.y > 0.02 && sn > 0.05) {",
			"tile = textureGrad(albedo_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);"]:
		check(nodes.contains(text), NODES + " lost part of its parallax march: " + text)
	# A write, not a mention: the header comment names it to say why not.
	var write := RegEx.create_from_string("ALPHA_SCISSOR_THRESHOLD\\s*=")
	check(write.search(nodes) == null,
			NODES + " writes ALPHA_SCISSOR_THRESHOLD, which moves every opaque tile into the scissor pipeline")
	check(write.search(scissor) != null, SCISSOR + " no longer alpha tests")

	# The Lowest profile's mat_parallax reaches the shader as
	# parallax_strength (game_ui.gd strips mat_ and calls
	# set_material_strength), and 0 skips the march outright rather than
	# running it at no depth. Low runs the short march, the others the
	# full one; every tier takes the micro shadow
	# (docs/materials.md, "Micro shadows and the short march").
	check(float(GraphicsProfiles.PROFILES["lowest"].get("mat_parallax", -1.0)) == 0.0,
			"the Lowest profile no longer turns parallax off")
	check(float(GraphicsProfiles.PROFILES["low"].get("mat_parallax", -1.0)) == 1.0
			and float(GraphicsProfiles.PROFILES["low"].get("mat_parallax_short", -1.0)) == 1.0,
			"the Low profile no longer runs the short march")
	for tier in ["medium", "high", "ultra"]:
		check(float(GraphicsProfiles.PROFILES[tier].get("mat_parallax", -1.0)) == 1.0
				and float(GraphicsProfiles.PROFILES[tier].get("mat_parallax_short", -1.0)) == 0.0,
				"the %s profile does not run the full march" % tier)
	for tier in GraphicsProfiles.ORDER:
		check(float(GraphicsProfiles.PROFILES[tier].get("mat_micro_shadow", -1.0)) == 1.0,
				"the %s profile does not take the micro shadow" % tier)
	check(uniforms(NODES).has("parallax_short_strength")
			and uniforms(NODES).has("micro_shadow_strength"),
			"mat_parallax_short or mat_micro_shadow has no uniform to reach")
	check(CHANNELS.has("parallax") and uniforms(NODES).has("parallax_strength"),
			"mat_parallax has no uniform to reach")
	print("node_array_shaders: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)
