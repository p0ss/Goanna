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
#   GOANNA_ITEM_DIR=<dir>   a copy of the game, for the tool and armour set:
#                           the baked pack has 1023 textures and not one
#                           pickaxe, because tools and armour come from the
#                           game the server is running
#   GOANNA_GALLERY_SET=items  show tools and armour rather than materials
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
# Copied from kSpecs in src/goanna_materials.cpp. Three of these had drifted
# from it, which is a fixture quietly measuring numbers the renderer does not
# use; if that file changes, this one has to follow.
const CLASS_SPEC := {
	0: [0.20, 0.04, 0.0, 0.0],   # none, the dull default
	1: [0.12, 0.04, 0.0, 0.0],   # stone
	2: [0.22, 0.04, 0.0, 0.0],   # wood
	3: [0.30, 0.04, 0.0, 0.5],   # leaves
	4: [0.92, 0.04, 0.0, 0.0],   # glass, and diamond by way of it
	5: [0.08, 0.04, 0.0, 0.0],   # sand
	6: [0.10, 0.04, 0.0, 0.0],   # gravel
	7: [0.35, 0.04, 0.0, 0.2],   # snow
	8: [0.88, 0.04, 0.0, 0.35],  # ice
	9: [0.05, 0.04, 0.0, 0.0],   # soil
	10: [0.55, 1.00, 1.0, 0.0],  # metal
	11: [0.08, 0.04, 0.0, 0.0],  # cloth
}

# Tools and armour, which is the case the class work is really for: they are
# textures rather than nodes, so the classifier has only their names to go
# on, and Mineclonia ships no authored specular for a single one of them.
# The class each name lands on is in the third column, so the scene states
# what it expects rather than only showing it.
const ITEM_CASES := [
	["iron pick", "default_tool_steelpick", 10],
	["gold sword", "default_tool_goldsword", 10],
	["diamond pick", "default_tool_diamondpick", 4],
	["netherite sword", "default_tool_netheritesword", 10],
	["wood pick", "default_tool_woodpick", 2],
	["iron helmet", "mcl_armor_inv_helmet_iron", 10],
	["chain chestplate", "mcl_armor_inv_chestplate_chain", 10],
	["diamond helmet", "mcl_armor_inv_helmet_diamond", 4],
	["leather chestplate", "mcl_armor_inv_chestplate_leather", 11],
]

const STEP := 2.4        # spacing between plinths
const ITEM_STEP := 3.2  # wider for the item set, whose labels are longer

var shot_dir := ""
var items_only := false
var item_paths := {}
var cases: Array = CASES
var block_mats: Array[ShaderMaterial] = []
var card_mats: Array[ShaderMaterial] = []


# Tools and armour are not in the baked pack: it has 1023 textures and not
# one pickaxe. They come from the game the server is running, so the scene is
# pointed at a copy of it and walks it once. GOANNA_ITEM_DIR names the game's
# directory; without it the item set has nothing to show and says so.
func _index_textures(root: String) -> Dictionary:
	var found := {}
	var stack: Array[String] = [root]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var da := DirAccess.open(d)
		if da == null:
			continue
		da.list_dir_begin()
		var name := da.get_next()
		while name != "":
			var full := d.path_join(name)
			if da.current_is_dir():
				if not name.begins_with("."):
					stack.append(full)
			elif name.ends_with(".png"):
				var stem := name.substr(0, name.length() - 4)
				if not found.has(stem):
					found[stem] = full
			name = da.get_next()
		da.list_dir_end()
	return found


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

	items_only = OS.get_environment("GOANNA_GALLERY_SET") == "items"
	if items_only:
		var item_dir := OS.get_environment("GOANNA_ITEM_DIR")
		if item_dir == "":
			push_error("GOANNA_GALLERY_SET=items needs GOANNA_ITEM_DIR pointing at a copy of the game")
			get_tree().quit()
			return
		item_paths = _index_textures(item_dir)
		print("indexed %d textures under %s" % [item_paths.size(), item_dir])
		cases = ITEM_CASES

	# An unbound array sampler is undefined and corrupts the albedo sample;
	# material_cube.gd spent four wrong diagnoses on that.
	var flat_n := _tex_array(_solid(Color(0.5, 0.5, 1.0, 1.0)))
	var flat_s := _tex_array(_solid(Color(0.0, 0.04, 0.0, 1.0)))
	var node_shader: Shader = load("res://shaders/nodes_array.gdshader")
	# An item icon is a cut out: most of it is transparent, and the plain
	# entity shader has no alpha, so every one of them came out on a black
	# card. The client picks the scissor variant for exactly this reason.
	var item_shader: Shader = load("res://shaders/entity_scissor.gdshader" if items_only
			else "res://shaders/entity.gdshader")

	for i in cases.size():
		var c: Array = cases[i]
		var stem := str(c[1])
		var path: String = item_paths.get(stem, "") if items_only else dir.path_join(stem + ".png")
		var img := _load(path)
		if img.get_width() <= 1:
			push_error("no texture for " + stem)
			continue
		var at := Vector3(i * (ITEM_STEP if items_only else STEP), 0.0, 0.0)
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
		# A pickaxe has no block form, and a cube of pickaxe would be a lie
		# about what the entity path draws.
		bmi.visible = not items_only
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
		q.size = Vector2(1.5, 1.5) if items_only else Vector2(0.8, 0.8)
		var imi := MeshInstance3D.new()
		imi.mesh = q
		imi.material_override = im
		imi.position = at + Vector3(0.0 if items_only else 0.5, 1.75 if items_only else 1.5, 0)
		imi.rotation_degrees = Vector3(-12, 0, 0)
		add_child(imi)

	var cam := Camera3D.new()
	var span := (cases.size() - 1) * (ITEM_STEP if items_only else STEP)
	cam.position = Vector3(span * 0.5, 2.4, 11.0 if not items_only else 12.5)
	cam.fov = 60.0
	add_child(cam)
	cam.look_at(Vector3(span * 0.5, 1.75 if items_only else 1.25, 0.0), Vector3.UP)
	cam.current = true

	if shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
		_shoot()


# Everything the classifier knows, withheld and then given. Off is what every
# one of these looked like before the material work: one flat rough dielectric
# whatever it was made of.
func _apply(on: bool) -> void:
	for i in cases.size():
		var cls: int = int(cases[i][2])
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
