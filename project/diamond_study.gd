# SPDX-License-Identifier: LGPL-2.1-or-later
# Offline material study using the production shaders and local game art.
# Add through the developer control channel, then await capture(directory).
extends Node

var viewport: SubViewport
var camera: Camera3D
var lamp: OmniLight3D
var environment: Environment
var materials: Array[ShaderMaterial] = []
var pack := "res://../pbr_packs/mineclonia/textures/"
var armour_dir := ""


func _image(path: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	assert(img != null, path)
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	return img


func _texture(img: Image, array: bool) -> Texture:
	if array:
		var tex := Texture2DArray.new()
		tex.create_from_images([img])
		return tex
	return ImageTexture.create_from_image(img)


func _material(stem: String, array: bool, cutout: bool, mode: int,
		directory: String = "") -> ShaderMaterial:
	var dir := pack if directory.is_empty() else directory
	var mat := ShaderMaterial.new()
	var shader_name := "nodes_array" if array else "entity"
	if cutout:
		shader_name += "_scissor"
	if not array and mode != 0:
		shader_name = "entity_diamond"
	mat.shader = load("res://shaders/" + shader_name + ".gdshader")
	mat.set_shader_parameter("albedo_array" if array else "albedo",
		_texture(_image(dir + stem + ".png"), array))
	for suffix in ["n", "s"]:
		var path: String = dir + stem + "_" + suffix + ".png"
		if not FileAccess.file_exists(path):
			continue
		var channel := "normal" if suffix == "n" else "spec"
		mat.set_shader_parameter(channel + ("_array" if array else "_tex"),
			_texture(_image(path), array))
		mat.set_shader_parameter("has_" + channel, true)
	if array:
		var modes := PackedInt32Array()
		modes.resize(256)
		modes[0] = mode
		mat.set_shader_parameter("layer_diamond", modes)
		var depths := PackedFloat32Array()
		depths.resize(256)
		depths[0] = 0.04
		mat.set_shader_parameter("layer_depth", depths)
	else:
		mat.set_shader_parameter("diamond_mode", mode)
		mat.set_shader_parameter("class_smoothness", 0.92)
		mat.set_shader_parameter("class_f0", 0.04)
		mat.set_shader_parameter("block_fill", 0.0)
	materials.append(mat)
	return mat


func _mesh(box: bool) -> ArrayMesh:
	var primitive: PrimitiveMesh = BoxMesh.new() if box else QuadMesh.new()
	if box:
		primitive.size = Vector3.ONE * 1.25
	else:
		primitive.size = Vector2.ONE * 1.45
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA8_UNORM)
	var arrays := primitive.surface_get_arrays(0)
	for index: int in arrays[Mesh.ARRAY_INDEX]:
		var normal: Vector3 = arrays[Mesh.ARRAY_NORMAL][index]
		var vertex: Vector3 = arrays[Mesh.ARRAY_VERTEX][index]
		st.set_normal(normal)
		var uv: Vector2 = arrays[Mesh.ARRAY_TEX_UV][index]
		if box:
			uv = Vector2(vertex.x, -vertex.y)
			if absf(normal.x) > 0.5:
				uv = Vector2(vertex.z, -vertex.y)
			elif absf(normal.y) > 0.5:
				uv = Vector2(vertex.x, vertex.z)
			uv = uv / 1.25 + Vector2.ONE * 0.5
		st.set_uv(uv)
		st.set_uv2(Vector2.ZERO)
		st.set_color(Color.WHITE)
		st.set_custom(0, Color(0, 0, 1, 1))
		st.add_vertex(arrays[Mesh.ARRAY_VERTEX][index])
	st.generate_tangents()
	return st.commit()


func _display(mat: ShaderMaterial, at: Vector3, box: bool, label: String) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = _mesh(box)
	mesh.material_override = mat
	viewport.add_child(mesh)
	mesh.position = at
	mesh.set_instance_shader_parameter("node_light", Vector2.ZERO)
	if box:
		mesh.rotation_degrees = Vector3(12, -18, 0)
	var text := Label3D.new()
	text.text = label
	text.font_size = 30
	text.pixel_size = 0.005
	text.no_depth_test = true
	viewport.add_child(text)
	text.position = at + Vector3(0, -0.94, 0.3)


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	var world := WorldEnvironment.new()
	var env := Environment.new()
	environment = env
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.025, 0.032, 0.045)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.8, 1.0)
	env.ambient_light_energy = 0.1
	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("clouds_enabled", false)
	sky_mat.set_shader_parameter("radiance_ground_lift", 0.5)
	sky.sky_material = sky_mat
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	world.environment = env
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.fov = 39
	viewport.add_child(camera)
	camera.position = Vector3(0, 0, 9)
	camera.current = true
	lamp = OmniLight3D.new()
	lamp.omni_range = 14.0
	lamp.light_energy = 6.0
	lamp.light_color = Color(1.0, 0.88, 0.72)
	viewport.add_child(lamp)
	lamp.position = Vector3(-1.5, 2.8, 4)
	_display(_material("default_diamond_block", true, false, 2),
		Vector3(-2.8, 1.25, 0), true, "Diamond block")
	_display(_material("mcl_core_diamond_ore", true, false, 1),
		Vector3(-0.9, 1.25, 0), true, "Stone ore")
	_display(_material("mcl_deepslate_diamond_ore", true, true, 1),
		Vector3(1.0, 1.25, 0), true, "Deepslate ore")
	_display(_material("default_diamond_block", false, false, 2),
		Vector3(2.9, 1.25, 0), true, "Held block path")
	_display(_material("default_tool_diamondpick", false, true, 1),
		Vector3(-2.8, -1.15, 0), false, "Diamond pick")
	_display(_material("default_tool_diamondsword", false, true, 1),
		Vector3(-0.9, -1.15, 0), false, "Diamond sword")
	if not armour_dir.is_empty():
		_display(_material("mcl_armor_inv_chestplate_diamond", false, true, 1, armour_dir),
			Vector3(1.0, -1.15, 0), false, "Diamond chestplate")
		_display(_material("mcl_armor_inv_helmet_diamond", false, true, 1, armour_dir),
			Vector3(2.9, -1.15, 0), false, "Diamond helmet")


func shot(path: String) -> Image:
	for frame in 4:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	img.save_png(path)
	return img


func capture(directory: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(directory)
	for mat in materials:
		mat.set_shader_parameter("diamond_strength", 0.0)
	await shot(directory.path_join("before.png"))
	for mat in materials:
		mat.set_shader_parameter("diamond_strength", 1.0)
	await shot(directory.path_join("diamond.png"))
	lamp.position = Vector3(2.0, 0.3, 4)
	await shot(directory.path_join("light-moved.png"))
	lamp.visible = false
	await shot(directory.path_join("unlit.png"))
	# Zero illumination must never reveal ore. Compare the complete frame,
	# including labels, with the treatment enabled and disabled.
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.ambient_light_energy = 0.0
	environment.background_color = Color.BLACK
	var dark_on := await shot(directory.path_join("dark-on.png"))
	for mat in materials:
		mat.set_shader_parameter("diamond_strength", 0.0)
	var dark_off := await shot(directory.path_join("dark-off.png"))
	var checks := {"darkness_unchanged": dark_on.get_data() == dark_off.get_data()}
	# A texture that has not opted in stays byte-identical under a lamp.
	lamp.visible = true
	for mat in materials:
		if mat.get_shader_parameter("diamond_mode") != null:
			mat.set_shader_parameter("diamond_mode", 0)
		else:
			var modes := PackedInt32Array()
			modes.resize(256)
			mat.set_shader_parameter("layer_diamond", modes)
	var plain_off := await shot(directory.path_join("ordinary-off.png"))
	for mat in materials:
		mat.set_shader_parameter("diamond_strength", 1.0)
	var plain_on := await shot(directory.path_join("ordinary-on.png"))
	checks["ordinary_materials_unchanged"] = plain_on.get_data() == plain_off.get_data()
	FileAccess.open(directory.path_join("checks.json"), FileAccess.WRITE).store_string(
		JSON.stringify(checks, "\t"))
	return checks


func capture_interior(directory: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(directory)
	lamp.visible = true
	lamp.position = Vector3(-1.4, 1.8, 4.0)
	camera.fov = 28.0
	var target := Vector3(-1.8, 1.25, 0)
	var checks := {}
	for angle in [-1, 0, 1]:
		camera.position = target + Vector3(float(angle) * 1.4, 0.7, 5.5)
		camera.look_at(target)
		for mat in materials:
			mat.set_shader_parameter("diamond_interior_strength", 0.0)
		var before := await shot(directory.path_join("surface-%d.png" % (angle + 1)))
		for mat in materials:
			mat.set_shader_parameter("diamond_interior_strength", 1.0)
		var after := await shot(directory.path_join("interior-%d.png" % (angle + 1)))
		checks["interior_visible_%d" % angle] = before.get_data() != after.get_data()
	# Distinguish subsurface light from the surface and inner specular lobes.
	lamp.position = Vector3(-3.0, 2.2, 1.0)
	for mat in materials:
		mat.set_shader_parameter("sss_strength", 0.0)
	var scatter_off := await shot(directory.path_join("scatter-off.png"))
	for mat in materials:
		mat.set_shader_parameter("sss_strength", 1.0)
	var scatter_on := await shot(directory.path_join("scatter-on.png"))
	checks["scattering_visible"] = scatter_on.get_data() != scatter_off.get_data()
	FileAccess.open(directory.path_join("interior-checks.json"), FileAccess.WRITE).store_string(
		JSON.stringify(checks, "\t"))
	return checks


func capture_transparency(directory: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(directory)
	# The contrasting wall makes actual background transmission measurable.
	var wall := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(10, 6)
	wall.mesh = quad
	var backing := StandardMaterial3D.new()
	backing.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var pattern := Image.create(16, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in 16:
			pattern.set_pixel(x, y, Color(0.8, 0.35, 0.12) if (x + y) % 2 == 0
				else Color(0.12, 0.3, 0.55))
	backing.albedo_texture = ImageTexture.create_from_image(pattern)
	backing.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	wall.material_override = backing
	viewport.add_child(wall)
	wall.position.z = -1.4
	for mat in materials:
		mat.set_shader_parameter("diamond_transparency", 0.0)
	await shot(directory.path_join("opaque.png"))
	for mat in materials:
		mat.set_shader_parameter("diamond_transparency", 1.0)
	await shot(directory.path_join("transparent.png"))
	# Change only the background and sample the middle of source texels on
	# the pick. The cyan head must transmit; its wooden handle must not.
	backing.albedo_texture = null
	backing.albedo_color = Color(0.05, 0.08, 0.1)
	var dark := await shot(directory.path_join("background-dark.png"))
	backing.albedo_color = Color(0.8, 0.8, 0.8)
	var light := await shot(directory.path_join("background-light.png"))
	var art := _image(pack + "default_tool_diamondpick.png")
	var gem_change := 0.0
	var handle_change := 0.0
	var gem_samples := 0
	var handle_samples := 0
	var gem_pixel := Vector2i.ZERO
	for y in 16:
		for x in 16:
			var texel := art.get_pixel((x * 2 + 1) * art.get_width() / 32,
				(y * 2 + 1) * art.get_height() / 32)
			if texel.a < 0.9:
				continue
			var linear := texel.srgb_to_linear()
			var cyan := minf(linear.g, linear.b) - linear.r
			var point := Vector3(-2.8 + ((x + 0.5) / 16.0 - 0.5) * 1.45,
				-1.15 - ((y + 0.5) / 16.0 - 0.5) * 1.45, 0.0)
			var pixel := Vector2i(camera.unproject_position(point))
			var a := dark.get_pixelv(pixel)
			var b := light.get_pixelv(pixel)
			var change := Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			if cyan > 0.055:
				gem_pixel = pixel
				gem_change += change
				gem_samples += 1
			elif cyan < 0.0:
				handle_change += change
				handle_samples += 1
	gem_change /= maxf(gem_samples, 1)
	handle_change /= maxf(handle_samples, 1)
	var checks := {"gem_background_change": gem_change,
		"handle_background_change": handle_change,
		"gem_samples": gem_samples, "handle_samples": handle_samples,
		"gem_transmits": gem_samples > 0 and gem_change > 0.2,
		"handle_opaque": handle_samples > 0 and handle_change < 0.01}
	# The world material must not expose hidden terrain behind its backing.
	var block_pixel := Vector2i(camera.unproject_position(Vector3(-2.8, 1.25, 0)))
	checks["placed_block_backed"] = dark.get_pixelv(block_pixel) == light.get_pixelv(block_pixel)
	var ore_pixel := Vector2i(camera.unproject_position(Vector3(-0.9, 1.25, 0)))
	checks["ore_backed"] = dark.get_pixelv(ore_pixel) == light.get_pixelv(ore_pixel)
	# Opaque foreground geometry must continue to win the depth test.
	var foreground := MeshInstance3D.new()
	var cover := QuadMesh.new()
	cover.size = Vector2(1.5, 1.5)
	foreground.mesh = cover
	var cover_mat := StandardMaterial3D.new()
	cover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cover_mat.albedo_color = Color(0.3, 0.1, 0.05)
	foreground.material_override = cover_mat
	viewport.add_child(foreground)
	foreground.position = Vector3(-2.8, -1.15, 0.5)
	var covered_on := await shot(directory.path_join("foreground-on.png"))
	for mat in materials:
		mat.set_shader_parameter("diamond_transparency", 0.0)
	var covered_off := await shot(directory.path_join("foreground-off.png"))
	checks["foreground_occludes"] = gem_samples > 0 \
		and covered_on.get_pixelv(gem_pixel) == covered_off.get_pixelv(gem_pixel) \
		and covered_on.get_pixelv(gem_pixel) != light.get_pixelv(gem_pixel)
	FileAccess.open(directory.path_join("transparency-checks.json"), FileAccess.WRITE).store_string(
		JSON.stringify(checks, "\t"))
	return checks
