extends Node3D

# Render a baked material on cubes, through the shader the client actually
# uses, so the channels can be seen rather than trusted.
#
# The LabPBR pair is four channels of numbers in two PNGs. Opening them shows
# a purple picture and a nearly black one, which says nothing about whether
# porosity, scattering, emission or metalness are being decoded, or whether
# the values chosen are sensible. So put them on a cube under a known light.
#
# The row is one albedo and one normal map throughout, with only the specular
# map changing along it, so any difference you see is that channel and not
# the texture. The rightmost cube uses the baked _s as it was written.
#
#   GOANNA_MAT=<dir>          where <name>_n.png and <name>_s.png live
#   GOANNA_MAT_NAME=<stem>    default_stone
#   GOANNA_MAT_ALBEDO=<path>  the game texture, for colour
#   GOANNA_SHOT=<dir>         write frames here and quit
#   GOANNA_MAT_TOD=<0..1>     where the sun sits, default mid morning
#
# Run: godot --path project material_cube.tscn

const CASES := [
	["albedo only", 0.0, 0.04, false, 0.0, 0.0, 1.0],
	["normal off", 0.1, 0.04, false, 0.0, 0.0, 0.0],
	["rough", 0.1, 0.04, false, 0.0, 0.0, 1.0],
	["smooth", 0.8, 0.04, false, 0.0, 0.0, 1.0],
	["metal", 0.7, 1.0, true, 0.0, 0.0, 1.0],
	["scattering", 0.2, 0.04, false, 0.9, 0.0, 1.0],
	["emissive", 0.2, 0.04, false, 0.0, 0.5, 1.0],
	["baked _s", -1.0, 0.0, false, 0.0, 0.0, 1.0],
]

var shot_dir := ""


func _tex_array(img: Image) -> Texture2DArray:
	# Mipmaps matter: the shader samples filter_nearest_mipmap, and without
	# them a 16 px texture on a small cube face aliases into noise. The
	# client generates them; a probe that does not is measuring itself.
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


# A specular map made of one value, so a case isolates a single channel.
func _spec_image(smoothness: float, f0: float, metal: bool, sss: float,
		emission: float) -> Image:
	var g := 1.0 if metal else clampf(f0, 0.0, 229.0 / 255.0)
	var b := 0.0
	if sss > 0.0:
		b = (65.0 + sss * (255.0 - 65.0)) / 255.0
	var a := 1.0 if emission <= 0.0 else clampf(emission, 0.0, 254.0 / 255.0)
	return _solid(Color(smoothness, g, b, a))


func _load(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var img := Image.load_from_file(path)
	if img and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


func _ready() -> void:
	var dir := OS.get_environment("GOANNA_MAT")
	var name := OS.get_environment("GOANNA_MAT_NAME")
	if name == "":
		name = "default_stone"
	shot_dir = OS.get_environment("GOANNA_SHOT")

	var normal_img := _load(dir.path_join(name + "_n.png"))
	var spec_img := _load(dir.path_join(name + "_s.png"))
	var albedo_img := _load(OS.get_environment("GOANNA_MAT_ALBEDO"))
	if albedo_img.get_width() <= 1:
		albedo_img = _solid(Color(0.55, 0.52, 0.5))
	if normal_img.get_width() <= 1:
		push_error("no normal map at " + dir.path_join(name + "_n.png"))
		normal_img = _solid(Color(0.5, 0.5, 1.0, 1.0))
	print("albedo %s, normal %s, spec %s" % [albedo_img.get_size(),
		normal_img.get_size(), spec_img.get_size() if spec_img.get_width() > 1 else "none"])

	if shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
		albedo_img.save_png(shot_dir.path_join("_loaded_albedo.png"))
		normal_img.save_png(shot_dir.path_join("_loaded_normal.png"))

	_environment()

	var albedo_arr := _tex_array(albedo_img)
	var normal_arr := _tex_array(normal_img)
	# Every sampler2DArray must be bound, even the ones a case does not use.
	# Left unset, Godot supplies a default 2D texture for an array sampler,
	# which is undefined and on this driver corrupts the albedo sample into
	# noise. The client always binds all three; this scene did not, and spent
	# four wrong diagnoses on it.
	var flat_n := _tex_array(_solid(Color(0.5, 0.5, 1.0, 1.0)))
	var flat_s := _tex_array(_solid(Color(0.0, 0.04, 0.0, 1.0)))
	var shader: Shader = load("res://shaders/nodes_array.gdshader")

	for i in CASES.size():
		var c: Array = CASES[i]
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("albedo_array", albedo_arr)
		mat.set_shader_parameter("normal_array", normal_arr if i > 0 else flat_n)
		mat.set_shader_parameter("spec_array", flat_s)
		mat.set_shader_parameter("has_normal", i > 0)  # case 0 is albedo alone
		mat.set_shader_parameter("scissor", false)
		if c[1] < 0.0:
			# the baked specular map, exactly as the pipeline wrote it
			if spec_img.get_width() <= 1:
				mat.set_shader_parameter("has_spec", false)
			else:
				mat.set_shader_parameter("spec_array", _tex_array(spec_img))
				mat.set_shader_parameter("has_spec", true)
		elif i == 0:
			mat.set_shader_parameter("has_normal", false)
			mat.set_shader_parameter("has_spec", false)
			# case 0 uses Godot's own material, so a noisy render here means
			# the scene or the texture, and a clean one means our shader
			var std := StandardMaterial3D.new()
			std.albedo_texture = ImageTexture.create_from_image(albedo_img)
			std.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
			var mi0 := MeshInstance3D.new()
			mi0.mesh = _cube()
			mi0.material_override = std
			mi0.position = Vector3((i - (CASES.size() - 1) / 2.0) * 1.45, 0, 0)
			mi0.rotation_degrees = Vector3(0, -25, 0)
			add_child(mi0)
			continue
		else:
			mat.set_shader_parameter("spec_array",
				_tex_array(_spec_image(c[1], c[2], c[3], c[4], c[5])))
			mat.set_shader_parameter("has_spec", true)
		mat.set_shader_parameter("normal_strength", float(c[6]))

		var mi := MeshInstance3D.new()
		mi.mesh = _cube()
		mi.material_override = mat
		mi.position = Vector3((i - (CASES.size() - 1) / 2.0) * 1.45, 0, 0)
		mi.rotation_degrees = Vector3(0, -25, 0)
		add_child(mi)
		print("  %d: %s" % [i, c[0]])

	# One more cube, sampling the array and doing nothing else. Clean here
	# means the array and the mesh are fine and the fault is further down our
	# shader; noisy here means the sampling itself.
	var raw := Shader.new()
	raw.code = """shader_type spatial;
render_mode unshaded;
uniform sampler2DArray albedo_array : source_color, filter_nearest_mipmap, repeat_enable;
void fragment() { ALBEDO = texture(albedo_array, vec3(UV, 0.0)).rgb; }
"""
	# and one showing the vertex colour alpha as a greyscale, since our
	# shader feeds that into ALPHA and a value below 1 turns on Godot's
	# alpha hashing, which dithers exactly like this
	var probe := Shader.new()
	probe.code = """shader_type spatial;
render_mode unshaded;
void fragment() { ALBEDO = vec3(COLOR.a, COLOR.a, COLOR.a); }
"""
	var rawmat := ShaderMaterial.new()
	rawmat.shader = raw
	rawmat.set_shader_parameter("albedo_array", albedo_arr)
	var rawmi := MeshInstance3D.new()
	rawmi.mesh = _cube()
	rawmi.material_override = rawmat
	rawmi.position = Vector3((CASES.size() - (CASES.size() - 1) / 2.0) * 1.45, 0, 0)
	rawmi.rotation_degrees = Vector3(0, -25, 0)
	add_child(rawmi)
	print("  %d: raw array sample, unshaded" % CASES.size())
	var pmat := ShaderMaterial.new()
	pmat.shader = probe
	var pmi := MeshInstance3D.new()
	pmi.mesh = _cube()
	pmi.material_override = pmat
	pmi.position = Vector3((CASES.size() + 1 - (CASES.size() - 1) / 2.0) * 1.45, 0, 0)
	pmi.rotation_degrees = Vector3(0, -25, 0)
	add_child(pmi)
	print("  %d: vertex colour alpha (white means 1.0)" % (CASES.size() + 1))

	var cam := Camera3D.new()
	cam.position = Vector3(1.5, 1.6, 9.0)
	cam.rotation_degrees = Vector3(-11, 0, 0)
	cam.fov = 55
	cam.current = true
	add_child(cam)

	if shot_dir != "":
		await _shoot()


# BoxMesh alone will not do: the shader reads its array layer from UV2.x and
# tints by the vertex colour, and a primitive mesh carries neither, so it
# samples an undefined layer and renders as noise. Take the box's arrays and
# add the two the mesher would have written.
func _cube() -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var arrays := box.surface_get_arrays(0)
	var n: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	uv2.resize(n)
	col.resize(n)
	for i in n:
		uv2[i] = Vector2.ZERO      # layer 0
		col[i] = Color.WHITE       # Luanti's per vertex light, neutral here
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _environment() -> void:
	# A sky, because metalness is invisible without something to reflect, and
	# a single directional light, because relief is invisible without one.
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
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_white = 4.0
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)

	var tod := 0.32
	if OS.get_environment("GOANNA_MAT_TOD") != "":
		tod = float(OS.get_environment("GOANNA_MAT_TOD"))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-lerpf(8.0, 78.0, tod), 38.0, 0)
	sun.light_energy = 1.1
	# No shadows. On unit cubes at default bias they self shadow into a dense
	# speckle that looks exactly like a broken texture, and shadow quality is
	# not what this scene is for.
	sun.shadow_enabled = false
	add_child(sun)


func _shoot() -> void:
	DirAccess.make_dir_recursive_absolute(shot_dir)
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var p: String = shot_dir.path_join("cubes.png")
	img.save_png(p)
	print("saved ", p)
	# a second frame with the sun round the back, since scattering and
	# emission only declare themselves against the light
	var sun: DirectionalLight3D = null
	for c in get_children():
		if c is DirectionalLight3D:
			sun = c
	if sun:
		sun.rotation_degrees = Vector3(-18, 158, 0)
		for i in 6:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var b := get_viewport().get_texture().get_image()
		var q: String = shot_dir.path_join("cubes_backlit.png")
		b.save_png(q)
		print("saved ", q)
	get_tree().quit()
