# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Puts real trees on screen as impostors and saves the frames, so whether the
# march reads as a tree is a thing that can be looked at rather than argued
# about. It takes an atlas and a tree list exported by the tree_drive tool and
# draws nothing else: no ground, no sky, just the silhouettes.
extends SceneTree

const SHADER := preload("res://shaders/tree_impostor.gdshader")

var _frames: Array = []
var _index := 0
var _root: Node3D
var _camera: Camera3D
var _out := "/tmp"
var _debug := false
var _plain := false
var _compare := false
var _pick := 0


func _read_atlas(path: String) -> ImageTexture3D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("no atlas at " + path)
		return null
	var w := f.get_32()
	var h := f.get_32()
	var d := f.get_32()
	var slices: Array[Image] = []
	for z in range(d):
		var bytes := f.get_buffer(w * h * 4)
		# The atlas is 0xAARRGGBB in memory, little endian, so the bytes arrive
		# as B G R A and Godot's RGBA8 wants R G B A.
		var swizzled := PackedByteArray()
		swizzled.resize(bytes.size())
		for i in range(0, bytes.size(), 4):
			swizzled[i] = bytes[i + 2]
			swizzled[i + 1] = bytes[i + 1]
			swizzled[i + 2] = bytes[i]
			swizzled[i + 3] = bytes[i + 3]
		slices.append(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, swizzled))
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGBA8, w, h, d, false, slices)
	print("atlas %dx%dx%d" % [w, h, d])
	return tex


func _read_trees(path: String) -> Array:
	var out: Array = []
	var text := FileAccess.get_file_as_string(path)
	for line in text.split("\n"):
		var parts := line.strip_edges().split(" ")
		if parts.size() < 6:
			continue
		var row := {
			"pos": Vector3(float(parts[0]), float(parts[1]), float(parts[2])),
			"height": float(parts[3]),
			"radius": float(parts[4]),
			"slot": int(parts[5]),
			# x block light, y sky light, as the shader wants them
			"light_base": Vector2(0.0, 1.0),
			"light_top": Vector2(0.0, 1.0),
		}
		if parts.size() >= 10:
			row["light_base"] = Vector2(float(parts[8]) / 255.0, float(parts[6]) / 255.0)
			row["light_top"] = Vector2(float(parts[9]) / 255.0, float(parts[7]) / 255.0)
		out.append(row)
	return out


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var atlas_path := args[0] if args.size() > 0 else "/tmp/atlas.bin"
	_out = args[1] if args.size() > 1 else "/tmp"
	_debug = args.size() > 2 and args[2] == "debug"
	_plain = args.size() > 2 and args[2] == "plain"
	_compare = args.size() > 2 and args[2] == "compare"
	_pick = int(args[3]) if args.size() > 3 else 0
	var atlas := _read_atlas(atlas_path)
	if atlas == null:
		quit(1)
		return
	var trees := _read_trees(atlas_path + ".trees")
	print("%d trees" % trees.size())
	if trees.is_empty():
		quit(1)
		return

	_root = Node3D.new()
	get_root().add_child(_root)

	# main.gd sets these every frame from the horizon colour and the time of
	# day. Nothing does here, and an unset global is black, which would remove
	# the fill that is most of the light in a frame.
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(0.42, 0.52, 0.68))
	RenderingServer.global_shader_parameter_set("goanna_ground_fill", Vector3(0.24, 0.22, 0.18))

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.35, 0.45, 0.6)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Sky light, not a second sun. Full white ambient washed every tile out and
	# made a teal leaf read as cyan.
	env.ambient_light_color = Color(0.62, 0.72, 0.90)
	env.ambient_light_energy = 0.45
	_camera = Camera3D.new()
	_camera.environment = env
	_camera.fov = 50.0
	_camera.far = 4000.0
	_root.add_child(_camera)
	# Without this the viewport has no camera and renders the clear colour and
	# nothing else, which looks exactly like a shader that discards everything.
	_camera.make_current()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	sun.light_energy = 1.1
	sun.light_color = Color(1.0, 0.96, 0.88)
	_root.add_child(sun)

	var centre := Vector3.ZERO
	for t in trees:
		centre += t["pos"]
	centre /= float(trees.size())

	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for t in trees:
		lo = lo.min(t["pos"] - centre)
		hi = hi.max(t["pos"] - centre)
	print("stand spans %s .. %s" % [str(lo.round()), str(hi.round())])

	var slot := Vector3(24, 40, 24)
	var atlas_size := Vector3(atlas.get_width(), atlas.get_height(), atlas.get_depth())
	var columns := int(atlas_size.x / slot.x)

	# One MultiMesh for every tree in the view, which is what the client wants:
	# a uniform per tree would be a draw call per tree. The slot and the angle
	# ride in the instance custom data, the four light values in the instance
	# colour.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var box := BoxMesh.new()
	# A unit box, scaled per instance. The shader marches in object space and
	# wants that space to be the slot's own 0 to 1; a BoxMesh sized in metres
	# puts its vertices at plus or minus half the size instead.
	box.size = Vector3.ONE
	mm.mesh = box
	mm.instance_count = trees.size()
	for i in range(trees.size()):
		var t: Dictionary = trees[i]
		var basis := Basis().scaled(
			Vector3(t["radius"] * 2.0, t["height"], t["radius"] * 2.0))
		mm.set_instance_transform(i, Transform3D(basis,
			t["pos"] - centre + Vector3(0, t["height"] * 0.5, 0)))
		mm.set_instance_custom_data(i, Color(
			float(t["slot"] % columns), float(t["slot"] / columns),
			float(hash(str(t["pos"])) % 6283) / 1000.0, 0.0))
		mm.set_instance_color(i, Color(
			t["light_base"].y, t["light_top"].y,
			t["light_base"].x, t["light_top"].x))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("atlas", atlas)
	mat.set_shader_parameter("atlas_voxels", atlas_size)
	mat.set_shader_parameter("slot_voxels", slot)
	mat.set_shader_parameter("debug_steps", _debug)
	mmi.material_override = mat
	# Godot culls a MultiMesh by the bounds it knows, and the boxes are small
	# against the spread of the stand.
	mmi.extra_cull_margin = 64.0
	if not _plain:
		_root.add_child(mmi)
	else:
		for i in range(trees.size()):
			var t2: Dictionary = trees[i]
			var mi := MeshInstance3D.new()
			mi.mesh = box
			mi.scale = Vector3(t2["radius"] * 2.0, t2["height"], t2["radius"] * 2.0)
			mi.position = t2["pos"] - centre + Vector3(0, t2["height"] * 0.5, 0)
			var flat := StandardMaterial3D.new()
			flat.albedo_color = Color(0.9, 0.2, 0.2)
			flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mi.material_override = flat
			mi.extra_cull_margin = 16.0
			_root.add_child(mi)

	# Close enough to read a single tree, then back to where an impostor is
	# actually for, then overhead, which is the view a ring of billboards has
	# no picture for at all.
	_frames = [
		{"name": "near", "at": Vector3(18, 6, 18), "look": Vector3(0, 5, 0)},
		{"name": "mid", "at": Vector3(70, 18, 70), "look": Vector3(0, 4, 0)},
		{"name": "far", "at": Vector3(190, 45, 190), "look": Vector3(0, 4, 0)},
		{"name": "above", "at": Vector3(6, 60, 6), "look": Vector3(0, 4, 0)},
	]
	# After the default frames, or it would set its own and have them replaced.
	if _compare:
		_build_comparison(trees, atlas, atlas_size, slot, columns)

	get_root().set_size(Vector2i(900, 640))
	_aim()


func _aim() -> void:
	var frame: Dictionary = _frames[_index]
	_camera.look_at_from_position(frame["at"], frame["look"], Vector3.UP)


# One frame to move the camera and draw, the next to read the result back:
# asking for the image in the same frame gets whatever was there before.
var _settle := 2


# Every filled voxel of a slot as an actual cube, which is what the near mesher
# would draw. Slow and not meant for the client: this exists so the impostor can
# be held up against the thing it is standing in for.
func _cubes_for_slot(atlas: ImageTexture3D, slot: Vector3, at: Vector2,
		scale_to: Vector3) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var slices: Array[Image] = []
	for z in range(atlas.get_depth()):
		slices.append(atlas.get_data()[z])
	var step := Vector3(scale_to.x / slot.x, scale_to.y / slot.y, scale_to.z / slot.z)
	var faces := [
		[Vector3.UP, [Vector3(0,1,0), Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0)]],
		[Vector3.DOWN, [Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)]],
		[Vector3.RIGHT, [Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)]],
		[Vector3.LEFT, [Vector3(0,0,0), Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0)]],
		[Vector3.BACK, [Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)]],
		[Vector3.FORWARD, [Vector3(0,0,0), Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0)]],
	]
	for z in range(int(slot.z)):
		for y in range(int(slot.y)):
			for x in range(int(slot.x)):
				var sx := int(at.x * slot.x) + x
				var sz := int(at.y * slot.z) + z
				var col := slices[sz].get_pixel(sx, y)
				if col.a < 0.5:
					continue
				var origin := Vector3(x, y, z) * step - scale_to * Vector3(0.5, 0.5, 0.5)
				for f in faces:
					var n: Vector3 = f[0]
					var nx := x + int(n.x)
					var ny := y + int(n.y)
					var nz := z + int(n.z)
					if nx >= 0 and ny >= 0 and nz >= 0 and nx < int(slot.x) \
							and ny < int(slot.y) and nz < int(slot.z):
						var side := slices[int(at.y * slot.z) + nz].get_pixel(
								int(at.x * slot.x) + nx, ny)
						if side.a >= 0.5:
							continue
					st.set_normal(f[0])
					st.set_color(col)
					var q: Array = f[1]
					for idx in [0, 1, 2, 0, 2, 3]:
						st.add_vertex(origin + (q[idx] as Vector3) * step)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	# The same sRGB tile colours the atlas holds, so the two sides of the
	# comparison are lit from the same numbers.
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.95
	mat.specular = 0.05
	st.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	return mi


func _build_comparison(trees: Array, atlas: ImageTexture3D, atlas_size: Vector3,
		slot: Vector3, columns: int) -> void:
	for child in _root.get_children():
		if child is MeshInstance3D:
			child.queue_free()
	var t: Dictionary = trees[_pick % trees.size()]
	var extent := Vector3(t["radius"] * 2.0, t["height"], t["radius"] * 2.0)
	var at := Vector2(t["slot"] % columns, t["slot"] / columns)

	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = box
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis().scaled(extent),
		Vector3(-t["radius"] - 1.0, t["height"] * 0.5, 0)))
	mm.set_instance_custom_data(0, Color(at.x, at.y, 0.0, 0.0))
	mm.set_instance_color(0, Color(t["light_base"].y, t["light_top"].y,
		t["light_base"].x, t["light_top"].x))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("atlas", atlas)
	mat.set_shader_parameter("atlas_voxels", atlas_size)
	mat.set_shader_parameter("slot_voxels", slot)
	mmi.material_override = mat
	mmi.extra_cull_margin = 16.0
	_root.add_child(mmi)

	var cubes := _cubes_for_slot(atlas, slot, at, extent)
	cubes.position = Vector3(t["radius"] + 1.0, t["height"] * 0.5, 0)
	_root.add_child(cubes)

	var reach: float = maxf(t["height"], t["radius"] * 4.0)
	_frames = [
		{"name": "compare_near", "at": Vector3(0, t["height"] * 0.6, reach * 1.6),
			"look": Vector3(0, t["height"] * 0.5, 0)},
		{"name": "compare_far", "at": Vector3(0, t["height"] * 0.8, reach * 6.0),
			"look": Vector3(0, t["height"] * 0.5, 0)},
	]


func _process(_delta: float) -> bool:
	if _settle > 0:
		_settle -= 1
		return false
	var frame: Dictionary = _frames[_index]
	var img := get_root().get_texture().get_image()
	if img != null:
		var path := _out.path_join("impostor_%s.png" % frame["name"])
		img.save_png(path)
		print("saved %s" % path)
	else:
		print("no image for %s" % frame["name"])
	_index += 1
	if _index >= _frames.size():
		quit(0)
		return true
	_aim()
	_settle = 2
	return false
