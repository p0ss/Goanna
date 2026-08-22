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
#   GOANNA_FIELD_LOD=<dir>  write lod_off.png and lod_on.png and print the
#                           strip colours, which is the near mesh against the
#                           far tiers on one surface under one sky
#   GOANNA_FIELD_LAYER=<n>  put the tile at array layer n rather than 0, with
#                           a different colour in every other lod_avg_colour
#                           entry, so an index that misses shows up
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
var lod_dir := ""
var lod_layer := 0
var materials: Array[ShaderMaterial] = []
# One strip's tile average, in linear light, in the order the strips are made.
var tile_means: Array[Vector3] = []
var strip_x: Array[int] = []


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


# The same strip, with the tile at some other array layer. The client's arrays
# hold up to 256 tiles and a node face carries its layer in UV2.x, so layer 0
# is the one case that cannot catch an index that is off or an array that is
# strided differently from the way it was packed. _strip_at(0) builds exactly
# what _strip() builds.
func _strip_at(layer: int) -> ArrayMesh:
	var m := _strip()
	var arrays: Array = m.surface_get_arrays(0)
	var uv2 := PackedVector2Array()
	for i in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		uv2.append(Vector2(float(layer), 0.0))
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


# An array with the tile at `layer` and a flat magenta everywhere else, so a
# sample that reads the wrong layer is unmistakable.
func _tex_array_at(img: Image, layer: int) -> Texture2DArray:
	var tile := Image.create_from_data(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8, img.get_data())
	tile.generate_mipmaps()
	var imgs: Array[Image] = []
	for i in layer + 1:
		if i == layer:
			imgs.append(tile)
			continue
		var other := Image.create_empty(img.get_width(), img.get_height(), true,
			Image.FORMAT_RGBA8)
		other.fill(Color(1.0, 0.0, 1.0, 1.0))
		imgs.append(other)
	var a := Texture2DArray.new()
	a.create_from_images(imgs)
	return a


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
	lod_dir = OS.get_environment("GOANNA_FIELD_LOD")
	if OS.get_environment("GOANNA_FIELD_LAYER") != "":
		lod_layer = int(OS.get_environment("GOANNA_FIELD_LAYER"))
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
		mat.set_shader_parameter("albedo_array",
			_tex_array_at(img, lod_layer) if lod_layer > 0 else _tex_array(img))
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
		# The tile's own average in linear light, which is the colour a
		# correctly minified sample converges to and therefore what a far
		# tier has to reach if it is to meet the near mesh (docs/
		# launch-target.md, "one light, one air").
		var acc := Vector3.ZERO
		var count := 0
		for y in img.get_height():
			for x in img.get_width():
				var c: Color = img.get_pixel(x, y)
				if c.a <= 0.0:
					continue
				var lin: Color = c.srgb_to_linear()
				acc += Vector3(lin.r, lin.g, lin.b)
				count += 1
		if count > 0:
			acc /= count
		tile_means.append(acc)
		# Every other entry a different colour, so an index that lands one
		# short, or a driver that strides the array differently from the way
		# the value was packed, paints something obviously wrong rather than
		# something plausible.
		var avg := PackedVector3Array()
		avg.resize(256)
		for k in 256:
			avg[k] = Vector3(float((k * 7) % 32) / 31.0, float((k * 13) % 32) / 31.0,
				float((k * 29) % 32) / 31.0)
		avg[lod_layer] = acc
		mat.set_shader_parameter("lod_avg_colour", avg)
		materials.append(mat)
		strip_x.append(i * (WIDE + 1))
		var mi := MeshInstance3D.new()
		mi.mesh = _strip_at(lod_layer)
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

	if lod_dir != "":
		DirAccess.make_dir_recursive_absolute(lod_dir)
		_shoot_lod()
	elif shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
		_shoot()


func _set_detail(v: float) -> void:
	for m in materials:
		m.set_shader_parameter("detail_strength", v)


# The near mesh against the far tiers, on one surface, under one sky.
#
# Added for docs/far-rendering.md, "The far field's albedo, 2026-08-23". The
# only thing that separates the two in the shader is lod_flatten and the
# colour the flatten blends to, so this draws each strip both ways and prints
# what came out. Nothing about the field itself moves between the two frames,
# so a difference is the shader's and nothing else's.
func _shoot_lod() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	for pass_i in 2:
		var on := pass_i == 1
		for m in materials:
			m.set_shader_parameter("lod_flatten", on)
			# Flatten from nothing, so the whole strip is the far case rather
			# than a ramp across it.
			m.set_shader_parameter("lod_flatten_near", 0.0)
			m.set_shader_parameter("lod_flatten_far", 0.001)
			m.set_shader_parameter("lod_repeat_near", 100000.0)
			m.set_shader_parameter("lod_repeat_far", 200000.0)
		for _f in 6:
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := lod_dir.path_join("lod_off.png" if pass_i == 0 else "lod_on.png")
		img.save_png(path)
		print("wrote ", path)
		for i in materials.size():
			# A patch of the strip, halfway along it, read back off the frame.
			var world := Vector3(strip_x[i] + WIDE * 0.5, 0.0, NODES * 0.5)
			var p: Vector2 = cam.unproject_position(world)
			var acc := Vector3.ZERO
			var n := 0
			for dy in range(-6, 7):
				for dx in range(-6, 7):
					var x := int(p.x) + dx
					var y := int(p.y) + dy
					if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
						continue
					var c := img.get_pixel(x, y)
					acc += Vector3(c.r, c.g, c.b)
					n += 1
			if n == 0:
				continue
			acc = acc / n * 255.0
			var mean: Vector3 = tile_means[i]
			print("%-18s %s  frame (%6.2f,%6.2f,%6.2f)  tile linear mean (%.4f,%.4f,%.4f)"
				% [STRIPS[i][0], "far " if on else "near", acc.x, acc.y, acc.z,
					mean.x, mean.y, mean.z])
	get_tree().quit()


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
