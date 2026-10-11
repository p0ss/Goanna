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
# material for the array tiles; the water takes albedo_tex instead.
const ARRAY_UNIFORMS := ["albedo_array", "layer_anim", "goanna_iris_block_ids"]
const WATER_UNIFORMS := ["albedo_tex", "goanna_iris_entity_override"]

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
	var path := OS.get_environment("GOANNA_IRIS_PACK")
	var bundled := path == ""
	if bundled:
		path = ProjectSettings.globalize_path(BASE)
	var g := GoannaIrisGbuffers.new()
	check(g.load_pack(path), "the pack did not load: %s" % g.report())
	var report: Dictionary = g.report()
	print("iris_gbuffers: ", report)
	for surface in [0, 1, 2]:
		var shader: Shader = g.shader(surface)
		var name: String = ["terrain", "cutout", "water"][surface]
		check(shader != null, name + " was not translated: %s" % report.get(name))
		if shader == null:
			continue
		var names := uniform_names(shader)
		check(not names.is_empty(), name + " does not compile in Godot")
		for u in (WATER_UNIFORMS if surface == 2 else ARRAY_UNIFORMS):
			check(names.has(u), name + " has no uniform " + u)
	if bundled:
		# Base-Shader's three programs, as the plan reads them: terrain and its
		# cutout have their own, water falls back to terrain, and none writes
		# a second target.
		check(String(report["terrain"]["program"]) == "gbuffers_terrain", "terrain program")
		check(String(report["cutout"]["program"]) == "gbuffers_terrain_cutout", "cutout program")
		check(String(report["water"]["program"]) == "gbuffers_terrain", "water falls back to terrain")
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
	print("iris_gbuffers: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)
