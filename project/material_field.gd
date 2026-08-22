extends Node3D

# A field of node sized tiles per material, through the shader the client
# actually uses, so a surface treatment can be judged without a server.
#
# The repetition this is here to look at only shows over many nodes, which a
# cube cannot show and which the live client could not be made to show on the
# machine this was written on: four other clients were up, the test server was
# logging maximum lag, and no client could hold enough resident blocks to draw
# the ground. So the field is built here instead, at a known size, under a
# known light, from the pack's own textures.
#
# Each strip is one material, sixteen nodes by sixteen, with the tile
# repeating once per node exactly as the mesher makes it repeat. The camera
# looks along the strips, because a repeat is loudest in perspective.
#
#   GOANNA_PACK_DIR=<dir>   textures, default baked/pack-mineclonia-v2
#   GOANNA_SHOT=<dir>       write detail_off.png and detail_on.png, then quit
#   GOANNA_FIELD_CELL=<n>   stochastic cell size in nodes, default 3
#
# Run: godot --path project material_field.tscn

# name, texture stem, MaterialClass (src/goanna_materials.h). Five granular
# classes the treatment claims, and one plank strip that it must leave alone.
const STRIPS := [
	["sand", "default_sand", 5],
	["stone", "default_stone", 1],
	["gravel", "default_gravel", 6],
	["dirt", "default_dirt", 9],
	["snow", "default_snow", 7],
	["planks (control)", "mcl_cherry_blossom_planks", 2],
]

const NODES := 16  # strip length, in nodes
const WIDE := 5    # strip width, in nodes

var shot_dir := ""
var materials: Array[ShaderMaterial] = []


func _tex_array(img: Image) -> Texture2DArray:
	var m := Image.create_from_data(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8, img.get_data())
	m.generate_mipmaps()
	var a := Texture2DArray.new()
	a.create_from_images([m])
	return a


func _solid(c: Color) -> Image:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


func _load(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var img := Image.load_from_file(path)
	if img and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


# One flat strip, UV running one tile per node, which is what the mesher
# gives a node face and what the world space treatment assumes.
func _strip() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(WIDE, 0, 0),
		Vector3(WIDE, 0, NODES), Vector3(0, 0, NODES)])
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(WIDE, 0), Vector2(WIDE, NODES), Vector2(0, NODES)])
	var norms := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	for i in 4:
		norms.append(Vector3.UP)
		uv2.append(Vector2.ZERO)  # array layer 0
		col.append(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _environment() -> void:
	var e := Environment.new()
	var sky := Sky.new()
	var pm := ProceduralSkyMaterial.new()
	pm.sky_top_color = Color(0.28, 0.42, 0.72)
	pm.sky_horizon_color = Color(0.72, 0.78, 0.85)
	pm.ground_bottom_color = Color(0.22, 0.2, 0.18)
	pm.ground_horizon_color = Color(0.5, 0.47, 0.44)
	sky.sky_material = pm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.5
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_white = 4.0
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)


func _ready() -> void:
	var dir := OS.get_environment("GOANNA_PACK_DIR")
	if dir == "":
		dir = ProjectSettings.globalize_path("res://../baked/pack-mineclonia-v2/textures")
	shot_dir = OS.get_environment("GOANNA_SHOT")
	var cell := 3.0
	if OS.get_environment("GOANNA_FIELD_CELL") != "":
		cell = float(OS.get_environment("GOANNA_FIELD_CELL"))

	_environment()

	# Every sampler2DArray must be bound even where a case does not use it:
	# an unbound array sampler is undefined and corrupts the albedo sample.
	# material_cube.gd spent four wrong diagnoses on that.
	var flat_n := _tex_array(_solid(Color(0.5, 0.5, 1.0, 1.0)))
	var flat_s := _tex_array(_solid(Color(0.0, 0.04, 0.0, 1.0)))
	var shader: Shader = load("res://shaders/nodes_array.gdshader")

	for i in STRIPS.size():
		var s: Array = STRIPS[i]
		var img := _load(dir.path_join(str(s[1]) + ".png"))
		if img.get_width() <= 1:
			push_error("no texture at " + dir.path_join(str(s[1]) + ".png"))
			continue
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("albedo_array", _tex_array(img))
		mat.set_shader_parameter("normal_array", flat_n)
		mat.set_shader_parameter("spec_array", flat_s)
		mat.set_shader_parameter("has_normal", false)
		mat.set_shader_parameter("has_spec", false)
		mat.set_shader_parameter("layer_class", PackedInt32Array([int(s[2])]))
		mat.set_shader_parameter("detail_cell", cell)
		mat.set_shader_parameter("detail_strength", 0.0)
		# The per vertex channels the client fills from the map. There is no
		# map here, so take the light out of the way rather than leaving the
		# strips in the dark: full sky, no occlusion, no fill, no block light.
		mat.set_shader_parameter("sky_light_strength", 0.0)
		mat.set_shader_parameter("vertex_ao_strength", 0.0)
		mat.set_shader_parameter("sky_fill_strength", 0.0)
		mat.set_shader_parameter("block_light_emission", 0.0)
		materials.append(mat)
		var mi := MeshInstance3D.new()
		mi.mesh = _strip()
		mi.material_override = mat
		mi.position = Vector3(i * (WIDE + 1), 0, 0)
		add_child(mi)
		print("strip %d: %s (class %d) at x=%d" % [i, s[0], int(s[2]), i * (WIDE + 1)])

	var cam := Camera3D.new()
	var span := STRIPS.size() * (WIDE + 1)
	cam.position = Vector3(span * 0.5, 9.0, -7.0)
	cam.fov = 60.0
	add_child(cam)
	# Aiming needs the node in the tree; look_at before add_child is a silent
	# no-op that leaves the camera pointing away from the field.
	cam.look_at(Vector3(span * 0.5, 0.0, NODES * 0.55), Vector3.UP)
	cam.current = true

	if shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
		_shoot()


func _set_detail(v: float) -> void:
	for m in materials:
		m.set_shader_parameter("detail_strength", v)


# Two frames of the same field, the treatment off and on, so the difference is
# the treatment and nothing else.
func _shoot() -> void:
	for pass_i in 2:
		_set_detail(0.0 if pass_i == 0 else 1.0)
		for _f in 6:
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := shot_dir.path_join("detail_off.png" if pass_i == 0 else "detail_on.png")
		img.save_png(path)
		print("wrote ", path)
	get_tree().quit()
