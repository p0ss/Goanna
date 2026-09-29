# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Offline gem fixture: every gem kind the shaders know (diamond, emerald,
# amethyst, mese, quartz) as ore, block and item, drawn by the production
# array and item shaders from the games' own art, under a fixed camera and
# lamp. Needs a display, like the other fixtures:
#
#   GOANNA_SHOT=/tmp/gems godot --path project gem_study.tscn
#
# Writes gems_off.png (treatment off), gems_on.png and gems_side.png (lamp
# moved), then quits. GOANNA_GAMES is the Luanti games directory (default
# the flatpak's). GOANNA_GEM_SHADERS renders with another copy of the
# shaders instead of res://shaders/, for a before and after of the same
# scene. The codes below are mode | kind << 2, as gemTextureCode in
# src/goanna_materials.cpp returns them for these textures.
extends Node3D

const ROWS := [
	["Diamond", [
		["mineclonia/mods/ITEMS/mcl_core/textures/mcl_core_diamond_ore.png", "", 1, true],
		["mineclonia/mods/ITEMS/mcl_core/textures/default_diamond_block.png", "", 2, true],
		["mineclonia/mods/ITEMS/mcl_tools/textures/default_tool_diamondpick.png", "", 1, false]]],
	["Emerald", [
		["mineclonia/mods/ITEMS/mcl_core/textures/mcl_core_emerald_ore.png", "", 5, true],
		["mineclonia/mods/ITEMS/mcl_core/textures/mcl_core_emerald_block.png", "", 6, true],
		["mineclonia/mods/ITEMS/mcl_core/textures/mcl_core_emerald.png", "", 5, false]]],
	["Amethyst", [
		["mineclonia/mods/ITEMS/mcl_amethyst/textures/mcl_amethyst_budding_amethyst.png", "", 10, true],
		["mineclonia/mods/ITEMS/mcl_amethyst/textures/mcl_amethyst_amethyst_block.png", "", 10, true],
		["mineclonia/mods/ITEMS/mcl_amethyst/textures/mcl_amethyst_amethyst_shard.png", "", 9, false]]],
	["Mese", [
		["minetest_game/mods/default/textures/default_stone.png",
			"minetest_game/mods/default/textures/default_mineral_mese.png", 13, true],
		["minetest_game/mods/default/textures/default_mese_block.png", "", 14, true],
		["minetest_game/mods/default/textures/default_mese_crystal.png", "", 13, false],
		["minetest_game/mods/default/textures/default_tool_mesepick.png", "", 13, false]]],
	["Quartz", [
		["mineclonia/mods/ITEMS/mcl_nether/textures/mcl_nether_quartz_ore.png", "", 17, true],
		["mineclonia/mods/ITEMS/mcl_nether/textures/mcl_nether_quartz.png", "", 17, false]]],
]

var viewport: SubViewport
var lamp: OmniLight3D
var materials: Array[ShaderMaterial] = []
var games := OS.get_environment("GOANNA_GAMES")
var shaders := OS.get_environment("GOANNA_GEM_SHADERS")


func _image(path: String, overlay: String) -> Image:
	var img := Image.load_from_file(games.path_join(path))
	assert(img != null, path)
	img.convert(Image.FORMAT_RGBA8)
	if not overlay.is_empty():
		# Minetest Game's ore is stone with the mineral composited over it,
		# as the tile string default_stone.png^default_mineral_mese.png asks.
		var top := Image.load_from_file(games.path_join(overlay))
		top.convert(Image.FORMAT_RGBA8)
		img.blend_rect(top, Rect2i(Vector2i.ZERO, top.get_size()), Vector2i.ZERO)
	img.generate_mipmaps()
	return img


func _material(entry: Array) -> ShaderMaterial:
	var img := _image(entry[0], entry[1])
	var code: int = entry[2]
	var array: bool = entry[3]
	var mat := ShaderMaterial.new()
	if array:
		var cutout := img.detect_alpha() != Image.ALPHA_NONE
		mat.shader = load(shaders.path_join("nodes_array" + ("_scissor" if cutout else "") + ".gdshader"))
		var tex := Texture2DArray.new()
		tex.create_from_images([img])
		mat.set_shader_parameter("albedo_array", tex)
		var codes := PackedInt32Array()
		codes.resize(256)
		codes[0] = code
		mat.set_shader_parameter("layer_diamond", codes)
	else:
		mat.shader = load(shaders.path_join("entity_diamond.gdshader"))
		mat.set_shader_parameter("albedo", ImageTexture.create_from_image(img))
		mat.set_shader_parameter("diamond_mode", code)
		mat.set_shader_parameter("class_smoothness", 0.92)
		mat.set_shader_parameter("class_f0", 0.04)
		mat.set_shader_parameter("block_fill", 0.0)
	materials.append(mat)
	return mat


func _mesh(box: bool) -> ArrayMesh:
	var primitive: PrimitiveMesh = BoxMesh.new() if box else QuadMesh.new()
	if box:
		primitive.size = Vector3.ONE
	else:
		primitive.size = Vector2.ONE * 1.2
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA8_UNORM)
	var arrays := primitive.surface_get_arrays(0)
	for index: int in arrays[Mesh.ARRAY_INDEX]:
		var normal: Vector3 = arrays[Mesh.ARRAY_NORMAL][index]
		var vertex: Vector3 = arrays[Mesh.ARRAY_VERTEX][index]
		var uv: Vector2 = arrays[Mesh.ARRAY_TEX_UV][index]
		if box:
			uv = Vector2(vertex.x, -vertex.y)
			if absf(normal.x) > 0.5:
				uv = Vector2(vertex.z, -vertex.y)
			elif absf(normal.y) > 0.5:
				uv = Vector2(vertex.x, vertex.z)
			uv += Vector2.ONE * 0.5
		st.set_normal(normal)
		st.set_uv(uv)
		st.set_uv2(Vector2.ZERO)
		st.set_color(Color.WHITE)
		st.set_custom(0, Color(0, 0, 1, 1))
		st.add_vertex(vertex)
	st.generate_tangents()
	return st.commit()


func _ready() -> void:
	if games.is_empty():
		games = OS.get_environment("HOME").path_join(".var/app/org.luanti.luanti/.minetest/games")
	if shaders.is_empty():
		shaders = "res://shaders/"
	viewport = SubViewport.new()
	viewport.size = Vector2i(1200, 1300)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.025, 0.032, 0.045)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.8, 1.0)
	env.ambient_light_energy = 0.1
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	var world := WorldEnvironment.new()
	world.environment = env
	viewport.add_child(world)
	var camera := Camera3D.new()
	camera.fov = 40
	viewport.add_child(camera)
	camera.position = Vector3(0.5, 0, 14.5)
	camera.current = true
	lamp = OmniLight3D.new()
	lamp.omni_range = 18.0
	lamp.light_energy = 7.0
	lamp.light_color = Color(1.0, 0.88, 0.72)
	viewport.add_child(lamp)
	lamp.position = Vector3(-2.0, 3.0, 5.0)
	for r in ROWS.size():
		var row: Array = ROWS[r]
		var y := 3.6 - r * 1.8
		var name_label := Label3D.new()
		name_label.text = row[0]
		name_label.font_size = 36
		name_label.pixel_size = 0.006
		name_label.no_depth_test = true
		viewport.add_child(name_label)
		name_label.position = Vector3(-3.7, y, 0.4)
		var entries: Array = row[1]
		for c in entries.size():
			var entry: Array = entries[c]
			var mesh := MeshInstance3D.new()
			mesh.mesh = _mesh(entry[3])
			mesh.material_override = _material(entry)
			viewport.add_child(mesh)
			mesh.position = Vector3(-1.6 + c * 1.9, y, 0)
			mesh.set_instance_shader_parameter("node_light", Vector2.ZERO)
			if entry[3]:
				mesh.rotation_degrees = Vector3(14, -20, 0)
	await _capture(OS.get_environment("GOANNA_SHOT"))
	get_tree().quit()


func _shot(path: String) -> void:
	for frame in 4:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(path)


func _capture(directory: String) -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	for mat in materials:
		mat.set_shader_parameter("diamond_strength", 0.0)
	await _shot(directory.path_join("gems_off.png"))
	for mat in materials:
		mat.set_shader_parameter("diamond_strength", 1.0)
	await _shot(directory.path_join("gems_on.png"))
	lamp.position = Vector3(2.5, 0.5, 5.0)
	await _shot(directory.path_join("gems_side.png"))
