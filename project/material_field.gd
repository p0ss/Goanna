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
#   GOANNA_FIELD_LEN=<n>    strip length in nodes, default 120
#   GOANNA_FIELD_PLAIN=1    do not bind the pack's _n and _s companions
#   GOANNA_FIELD_SHARPEN=<n> weight sharpening, default 8
#   GOANNA_FIELD_WALL=<stem> one material as a wall filling the frame, face
#                           on, which is where a seam in the cell grid has
#                           nowhere to hide: a perspective ground plane can
#                           swallow a straight line, a flat wall cannot
#   GOANNA_FIELD_LOD=<dir>  write lod_off.png and lod_on.png and print the
#                           strip colours, which is the near mesh against the
#                           far tiers on one surface under one sky
#   GOANNA_FIELD_ITEMS=1    render the item row through entity.gdshader instead
#                           of the ground strips, and write class_off.png and
#                           class_on.png
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

const WIDE := 9  # strip width, in nodes
# Strip length in nodes. Long by default, because the repeat this exists to
# break is a distance problem: sixteen nodes shows the tile, a hundred and
# twenty shows what a field of it does to the horizon, which is the thing
# anyone actually complains about.
var strip_len := 120.0

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
		Vector3(WIDE, 0, strip_len), Vector3(0, 0, strip_len)])
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(WIDE, 0), Vector2(WIDE, strip_len), Vector2(0, strip_len)])
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
	# Goanna's own sky, not Godot's procedural one. It is what the client
	# lights and reflects the world with, and the difference is not cosmetic:
	# a metal is its reflection, so a metallic surface judged against a plain
	# blue dome comes out blue, and against this one comes out as whatever
	# the client would really show. radiance_ground_lift is the part that
	# matters, since it fills the lower half of the dome with the horizon
	# colour rather than leaving a metal to reflect a dark floor.
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/sky.gdshader")
	sm.set_shader_parameter("sky_top", Color(0.20, 0.36, 0.68))
	sm.set_shader_parameter("sky_horizon", Color(0.72, 0.78, 0.85))
	sm.set_shader_parameter("ground_color", Color(0.29, 0.31, 0.34))
	sm.set_shader_parameter("sun_dir", Vector3(0.35, 0.72, 0.6).normalized())
	sm.set_shader_parameter("sun_visible", true)
	sm.set_shader_parameter("moon_visible", false)
	sm.set_shader_parameter("radiance_ground_lift", 1.0)
	sm.set_shader_parameter("radiance_desaturate", 0.25)
	sm.set_shader_parameter("ground_curve", 3.0)
	sky.sky_material = sm
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
	var sharpen := 8.0
	if OS.get_environment("GOANNA_FIELD_CELL") != "":
		cell = float(OS.get_environment("GOANNA_FIELD_CELL"))
	if OS.get_environment("GOANNA_FIELD_SHARPEN") != "":
		sharpen = float(OS.get_environment("GOANNA_FIELD_SHARPEN"))
	if OS.get_environment("GOANNA_FIELD_LEN") != "":
		strip_len = float(OS.get_environment("GOANNA_FIELD_LEN"))
	# GOANNA_FIELD_PLAIN=1 leaves the companions unbound, which is the older
	# behaviour of this scene and isolates what the colour alone is doing.
	var plain_pbr := OS.get_environment("GOANNA_FIELD_PLAIN") != ""

	_environment()

	var wall := OS.get_environment("GOANNA_FIELD_WALL")
	if wall != "":
		_wall(dir, wall, cell, sharpen)
		if shot_dir != "":
			DirAccess.make_dir_recursive_absolute(shot_dir)
			_shoot()
		return

	if OS.get_environment("GOANNA_FIELD_ITEMS") != "":
		_items(dir)
		if shot_dir != "":
			DirAccess.make_dir_recursive_absolute(shot_dir)
			_shoot_items()
		return

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
		# The pack's own relief and specular, when it ships them, because that
		# is what the client binds and because the question the treatment has
		# to answer is what the whole material does, not what its colour does.
		# A tile whose colour is shifted and whose bumps are not lights a
		# pattern that is no longer there.
		var nrm := _load(dir.path_join(str(s[1]) + "_n.png"))
		var spc := _load(dir.path_join(str(s[1]) + "_s.png"))
		var has_n: bool = nrm.get_width() > 1 and not plain_pbr
		var has_s: bool = spc.get_width() > 1 and not plain_pbr
		mat.set_shader_parameter("normal_array", _tex_array(nrm) if has_n else flat_n)
		mat.set_shader_parameter("spec_array", _tex_array(spc) if has_s else flat_s)
		mat.set_shader_parameter("has_normal", has_n)
		mat.set_shader_parameter("has_spec", has_s)
		# The class table is indexed by array layer, so it has to reach the
		# layer the strip actually sits on. Left at one entry, a run with
		# GOANNA_FIELD_LAYER set reads class 0 and quietly draws the plain
		# tile, which is the fixture passing while testing nothing: exactly
		# the shape of blindness that let a truncating layer index through.
		var classes := PackedInt32Array()
		classes.resize(lod_layer + 1)
		classes[lod_layer] = int(s[2])
		mat.set_shader_parameter("layer_class", classes)
		mat.set_shader_parameter("detail_cell", cell)
		mat.set_shader_parameter("detail_sharpen", sharpen)
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
	# Low and close to the near end: a repeat is loudest in perspective, and
	# the far end of a long strip is where mipmapping and the treatment have
	# to agree or the surface changes character somewhere in the middle.
	cam.position = Vector3(span * 0.5, 3.4, -6.0)
	cam.fov = 62.0
	add_child(cam)
	# Aiming needs the node in the tree; look_at before add_child is a silent
	# no-op that leaves the camera pointing away from the field.
	cam.look_at(Vector3(span * 0.5, 0.0, strip_len * 0.16), Vector3.UP)
	cam.current = true

	if lod_dir != "":
		DirAccess.make_dir_recursive_absolute(lod_dir)
		_shoot_lod()
	elif shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
		_shoot()


# Items, tools, armour and mob skins go through entity.gdshader, not the node
# array, and they are textures rather than nodes: no footstep, no groups, no
# drawtype. Nothing ever told that shader what they are made of, and
# Mineclonia ships no authored _s for any of them, so every one of them
# shaded as the flat rough dielectric the shader falls back to. This row is
# that path: the same quads twice, the class withheld and then given.
const ITEMS := [
	["iron", "mcl_raw_ores_raw_iron_block", 10],
	["wool", "wool_white", 11],
	["stone", "default_stone", 1],
	["planks", "mcl_cherry_blossom_planks", 2],
]

# The class constants are src/goanna_materials.cpp's CLASS_SPEC, which is
# where the real values live; these are the four the row needs.
const CLASS_SPEC := {
	1: [0.30, 0.04, 0.0, 0.0],
	2: [0.25, 0.04, 0.0, 0.0],
	10: [0.55, 1.00, 1.0, 0.0],
	11: [0.08, 0.04, 0.0, 0.0],
}


func _items(dir: String) -> void:
	var shader: Shader = load("res://shaders/entity.gdshader")
	for i in ITEMS.size():
		var it: Array = ITEMS[i]
		var img := _load(dir.path_join(str(it[1]) + ".png"))
		if img.get_width() <= 1:
			push_error("no texture at " + dir.path_join(str(it[1]) + ".png"))
			continue
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("albedo", ImageTexture.create_from_image(img))
		mat.set_shader_parameter("has_normal", false)
		mat.set_shader_parameter("has_spec", false)
		mat.set_shader_parameter("sky_light_strength", 0.0)
		mat.set_shader_parameter("block_fill", 0.0)
		materials.append(mat)
		var q := QuadMesh.new()
		q.size = Vector2(1.6, 1.6)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = mat
		mi.position = Vector3(i * 2.0, 1.0, 0.0)
		mi.rotation_degrees = Vector3(-20, 0, 0)
		add_child(mi)
		print("item %d: %s (class %d)" % [i, it[0], int(it[2])])

	var cam := Camera3D.new()
	var span := (ITEMS.size() - 1) * 2.0
	cam.position = Vector3(span * 0.5, 1.7, 5.6)
	cam.fov = 50.0
	add_child(cam)
	cam.look_at(Vector3(span * 0.5, 0.9, 0.0), Vector3.UP)
	cam.current = true


# The class withheld, then given, which is exactly the difference between what
# an item looked like before this and after it.
func _set_class(on: bool) -> void:
	for i in materials.size():
		var it: Array = ITEMS[i]
		var cls: int = int(it[2])
		var sp: Array = CLASS_SPEC[cls]
		materials[i].set_shader_parameter("mat_class", cls if on else 0)
		materials[i].set_shader_parameter("class_smoothness", sp[0] if on else 0.0)
		materials[i].set_shader_parameter("class_f0", sp[1] if on else 0.04)
		materials[i].set_shader_parameter("class_metal", sp[2] if on else 0.0)
		materials[i].set_shader_parameter("class_sss", sp[3] if on else 0.0)


func _shoot_items() -> void:
	for pass_i in 2:
		_set_class(pass_i == 1)
		for _f in 6:
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := shot_dir.path_join("class_off.png" if pass_i == 0 else "class_on.png")
		img.save_png(path)
		print("wrote ", path)
	get_tree().quit()


# One material, one wall, face on and filling the frame. Twenty by twenty
# nodes, so a cell grid of a few nodes has room to show its lines, and no
# perspective for them to hide in.
func _wall(dir: String, stem: String, cell: float, sharpen: float) -> void:
	var img := _load(dir.path_join(stem + ".png"))
	if img.get_width() <= 1:
		push_error("no texture at " + dir.path_join(stem + ".png"))
		get_tree().quit()
		return
	var nrm := _load(dir.path_join(stem + "_n.png"))
	var has_n: bool = nrm.get_width() > 1 and OS.get_environment("GOANNA_FIELD_PLAIN") == ""
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/nodes_array.gdshader")
	mat.set_shader_parameter("albedo_array", _tex_array(img))
	mat.set_shader_parameter("normal_array",
		_tex_array(nrm) if has_n else _tex_array(_solid(Color(0.5, 0.5, 1.0, 1.0))))
	mat.set_shader_parameter("spec_array", _tex_array(_solid(Color(0.0, 0.04, 0.0, 1.0))))
	mat.set_shader_parameter("has_normal", has_n)
	mat.set_shader_parameter("has_spec", false)
	# Stone unless told otherwise: the class only decides whether the
	# treatment runs at all, and this scene is about what it does when it does.
	mat.set_shader_parameter("layer_class", PackedInt32Array([1]))
	mat.set_shader_parameter("detail_cell", cell)
	mat.set_shader_parameter("detail_sharpen", sharpen)
	mat.set_shader_parameter("detail_strength", 0.0)
	mat.set_shader_parameter("sky_light_strength", 0.0)
	mat.set_shader_parameter("vertex_ao_strength", 0.0)
	mat.set_shader_parameter("sky_fill_strength", 0.0)
	mat.set_shader_parameter("block_light_emission", 0.0)
	materials.append(mat)

	var n := 20.0
	var verts := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(n, 0, 0), Vector3(n, n, 0), Vector3(0, n, 0)])
	var uvs := PackedVector2Array([
		Vector2(0, n), Vector2(n, n), Vector2(n, 0), Vector2(0, 0)])
	var norms := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	for i in 4:
		norms.append(Vector3(0, 0, 1))
		uv2.append(Vector2.ZERO)
		col.append(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	# The other winding from the ground strips: this quad faces the camera
	# rather than the sky, and cull_back does not forgive.
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	add_child(mi)

	var cam := Camera3D.new()
	cam.position = Vector3(n * 0.5, n * 0.5, n * 0.92)
	cam.fov = 60.0
	add_child(cam)
	cam.look_at(Vector3(n * 0.5, n * 0.5, 0.0), Vector3.UP)
	cam.current = true


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
			var world := Vector3(strip_x[i] + WIDE * 0.5, 0.0, strip_len * 0.5)
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
