extends Node3D

# One plinth per material, each carrying the same stuff twice: a block on the
# left, through the node array shader, and an item card on the right, through
# the entity shader. Those are the two paths a material can reach the screen
# by, they are lit by different code, and until this scene existed there was
# nowhere to see them agree or disagree.
#
# It is a gallery rather than a measurement. material_field.tscn is where the
# numbers come from; this is where you decide whether iron looks like iron,
# which is a judgement and wants everything side by side under one light.
#
# Lit by Goanna's own sky, not Godot's procedural one. For a dielectric that
# is a detail. For a metal it decides the answer, because a metal is its
# reflection, and against a plain blue dome a grey iron texture comes out
# blue: a whole finding was withdrawn over that.
#
#   GOANNA_PACK_DIR=<dir>   textures, default baked/pack-mineclonia-v2
#   GOANNA_SHOT=<dir>       write gallery_off.png and gallery_on.png and quit
#
# Run: godot --path project material_gallery.tscn

# label, texture stem, MaterialClass (src/goanna_materials.h)
const CASES := [
	["stone", "default_stone", 1],
	["wood", "mcl_cherry_blossom_planks", 2],
	["sand", "default_sand", 5],
	["gravel", "default_gravel", 6],
	["snow", "default_snow", 7],
	["soil", "default_dirt", 9],
	["metal", "default_steel_block", 10],
	["cloth", "wool_white", 11],
]

# src/goanna_materials.cpp's CLASS_SPEC, the four values a class carries:
# smoothness, F0, metalness, scattering.
const CLASS_SPEC := {
	1: [0.30, 0.04, 0.0, 0.0],
	2: [0.25, 0.04, 0.0, 0.0],
	5: [0.15, 0.04, 0.0, 0.0],
	6: [0.10, 0.04, 0.0, 0.0],
	7: [0.35, 0.04, 0.0, 0.2],
	9: [0.05, 0.04, 0.0, 0.0],
	10: [0.55, 1.00, 1.0, 0.0],
	11: [0.08, 0.04, 0.0, 0.0],
}

const STEP := 2.4  # spacing between plinths

var shot_dir := ""
var block_mats: Array[ShaderMaterial] = []
var card_mats: Array[ShaderMaterial] = []


func _load(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	var img := Image.load_from_file(path)
	if img and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


func _solid(c: Color) -> Image:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


func _tex_array(img: Image) -> Texture2DArray:
	var m := Image.create_from_data(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8, img.get_data())
	m.generate_mipmaps()
	var a := Texture2DArray.new()
	a.create_from_images([m])
	return a


# The flat specular map the client fills in for a layer with no authored
# companion: smoothness in R, F0 or the metal flag in G, scattering in B,
# emission in A. Same convention and the same numbers as
# goanna_textures.cpp, which is what makes a block agree with its own item.
func _class_spec_array(cls: int) -> Texture2DArray:
	var sp: Array = CLASS_SPEC[cls]
	var b := 0.0
	if float(sp[3]) > 0.0:
		b = 0.2549 + float(sp[3]) * 0.7451
	var g: float = 1.0 if float(sp[2]) > 0.5 else float(sp[1])
	return _tex_array(_solid(Color(float(sp[0]), g, b, 1.0)))


# A cube for the node array shader: it wants the array layer in UV2 and a
# vertex colour, which BoxMesh does not provide.
func _block_mesh() -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 0.8, 0.8)
	var arrays := box.surface_get_arrays(0)
	var n: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	uv2.resize(n)
	col.resize(n)
	for i in n:
		uv2[i] = Vector2.ZERO  # array layer 0
		col[i] = Color.WHITE
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _environment() -> void:
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/sky.gdshader")
	sm.set_shader_parameter("sky_top", Color(0.20, 0.36, 0.68))
	sm.set_shader_parameter("sky_horizon", Color(0.72, 0.78, 0.85))
	sm.set_shader_parameter("ground_color", Color(0.29, 0.31, 0.34))
	sm.set_shader_parameter("sun_dir", Vector3(0.35, 0.72, 0.6).normalized())
	sm.set_shader_parameter("sun_visible", true)
	sm.set_shader_parameter("moon_visible", false)
	# The lower half of the dome filled with the horizon colour, which is what
	# main.gd sets and what stops a metal reflecting a dark floor.
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
	sun.light_energy = 1.3
	sun.rotation_degrees = Vector3(-38, 28, 0)
	sun.shadow_enabled = true
	add_child(sun)

	# A floor. Not decoration: a metal is its reflection, and a sample
	# standing in empty sky has only sky to be. The world has ground in it.
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(120, 120)
	var fs := StandardMaterial3D.new()
	fs.albedo_color = Color(0.34, 0.33, 0.30)
	fs.roughness = 0.95
	var fmi := MeshInstance3D.new()
	fmi.mesh = floor_mesh
	fmi.material_override = fs
	add_child(fmi)


func _plinth(at: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(1.9, 1.0, 1.0)
	var std := StandardMaterial3D.new()
	# Deliberately plain and mid grey: a plinth that has a look of its own
	# competes with what is standing on it.
	std.albedo_color = Color(0.32, 0.32, 0.33)
	std.roughness = 0.9
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = std
	mi.position = at + Vector3(0, 0.5, 0)
	add_child(mi)


func _label(text: String, at: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 128
	l.pixel_size = 0.0026
	# Upright on the face of the plinth, not lying on its top: a label read at
	# a glancing angle is not a label.
	l.position = at + Vector3(0, 0.52, 0.51)
	l.modulate = Color(0.95, 0.95, 0.97)
	l.outline_size = 20
	l.outline_modulate = Color(0, 0, 0, 0.85)
	add_child(l)


func _ready() -> void:
	var dir := OS.get_environment("GOANNA_PACK_DIR")
	if dir == "":
		dir = ProjectSettings.globalize_path("res://../baked/pack-mineclonia-v2/textures")
	shot_dir = OS.get_environment("GOANNA_SHOT")

	_environment()

	# An unbound array sampler is undefined and corrupts the albedo sample;
	# material_cube.gd spent four wrong diagnoses on that.
	var flat_n := _tex_array(_solid(Color(0.5, 0.5, 1.0, 1.0)))
	var flat_s := _tex_array(_solid(Color(0.0, 0.04, 0.0, 1.0)))
	var node_shader: Shader = load("res://shaders/nodes_array.gdshader")
	var item_shader: Shader = load("res://shaders/entity.gdshader")

	for i in CASES.size():
		var c: Array = CASES[i]
		var img := _load(dir.path_join(str(c[1]) + ".png"))
		if img.get_width() <= 1:
			push_error("no texture at " + dir.path_join(str(c[1]) + ".png"))
			continue
		var at := Vector3(i * STEP, 0.0, 0.0)
		_plinth(at)
		_label(str(c[0]), at)

		# The block, through the node array path.
		var bm := ShaderMaterial.new()
		bm.shader = node_shader
		bm.set_shader_parameter("albedo_array", _tex_array(img))
		# The pack's own relief and specular where it ships them, because a
		# material is all three channels together and judging the class
		# against flat filler is judging half of it.
		var nrm := _load(dir.path_join(str(c[1]) + "_n.png"))
		var spc := _load(dir.path_join(str(c[1]) + "_s.png"))
		var has_n: bool = nrm.get_width() > 1
		bm.set_shader_parameter("normal_array", _tex_array(nrm) if has_n else flat_n)
		bm.set_shader_parameter("has_normal", has_n)
		# Not the pack's own _s, which would answer the very question the
		# class is here to answer, but the flat one the client synthesises
		# from the class for a layer that has none (goanna_textures.cpp). That
		# is how a block gets its class in the real renderer, and binding
		# nothing here instead left the block matte beside a metallic card,
		# which is a disagreement this scene invented rather than found.
		bm.set_shader_parameter("spec_array", _class_spec_array(int(c[2])))
		bm.set_shader_parameter("has_spec", true)
		bm.set_shader_parameter("layer_class", PackedInt32Array([int(c[2])]))
		bm.set_shader_parameter("sky_light_strength", 0.0)
		bm.set_shader_parameter("vertex_ao_strength", 0.0)
		bm.set_shader_parameter("sky_fill_strength", 0.0)
		bm.set_shader_parameter("block_light_emission", 0.0)
		block_mats.append(bm)
		var bmi := MeshInstance3D.new()
		bmi.mesh = _block_mesh()
		bmi.material_override = bm
		bmi.position = at + Vector3(-0.45, 1.42, 0)
		bmi.rotation_degrees = Vector3(0, -22, 0)
		add_child(bmi)

		# The item card, through the entity path, which is what a tool, a
		# piece of armour or a dropped item is drawn by.
		var im := ShaderMaterial.new()
		im.shader = item_shader
		im.set_shader_parameter("albedo", ImageTexture.create_from_image(img))
		im.set_shader_parameter("normal_tex", ImageTexture.create_from_image(nrm) if has_n else null)
		im.set_shader_parameter("has_normal", has_n)
		im.set_shader_parameter("has_spec", false)
		im.set_shader_parameter("sky_light_strength", 0.0)
		im.set_shader_parameter("block_fill", 0.0)
		card_mats.append(im)
		var q := QuadMesh.new()
		q.size = Vector2(0.8, 0.8)
		var imi := MeshInstance3D.new()
		imi.mesh = q
		imi.material_override = im
		imi.position = at + Vector3(0.5, 1.42, 0)
		imi.rotation_degrees = Vector3(-12, 0, 0)
		add_child(imi)

	var cam := Camera3D.new()
	var span := (CASES.size() - 1) * STEP
	cam.position = Vector3(span * 0.5, 2.9, 11.0)
	cam.fov = 60.0
	add_child(cam)
	cam.look_at(Vector3(span * 0.5, 1.25, 0.0), Vector3.UP)
	cam.current = true

	if shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
		_shoot()


# Everything the classifier knows, withheld and then given. Off is what every
# one of these looked like before the material work: one flat rough dielectric
# whatever it was made of.
func _apply(on: bool) -> void:
	for i in CASES.size():
		var cls: int = int(CASES[i][2])
		var sp: Array = CLASS_SPEC[cls]
		block_mats[i].set_shader_parameter("layer_class",
			PackedInt32Array([cls if on else 0]))
		block_mats[i].set_shader_parameter("detail_strength", 1.0 if on else 0.0)
		# Off is a block that knows nothing about itself, which is the flat
		# rough dielectric every one of these was before the material work.
		block_mats[i].set_shader_parameter("has_spec", on)
		card_mats[i].set_shader_parameter("mat_class", cls if on else 0)
		card_mats[i].set_shader_parameter("class_smoothness", sp[0] if on else 0.0)
		card_mats[i].set_shader_parameter("class_f0", sp[1] if on else 0.04)
		card_mats[i].set_shader_parameter("class_metal", sp[2] if on else 0.0)
		card_mats[i].set_shader_parameter("class_sss", sp[3] if on else 0.0)


func _shoot() -> void:
	for pass_i in 2:
		_apply(pass_i == 1)
		for _f in 8:
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := shot_dir.path_join("gallery_off.png" if pass_i == 0 else "gallery_on.png")
		img.save_png(path)
		print("wrote ", path)
	get_tree().quit()
