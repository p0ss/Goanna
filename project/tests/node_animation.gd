# SPDX-License-Identifier: LGPL-2.1-or-later
# GPU fixture: --path project --script res://tests/node_animation.gd
#
# Animated node tiles in the array shaders (docs/node-animation.md). Builds
# an animation array the way GoannaTextureSource does, each
# tile's frames as consecutive layers with layer_anim naming the frame count
# and length at the first, sets the clock through GoannaClient itself, and
# reads back which frame each quad drew. The expected frame is Luanti's rule,
# AnimationInfo::getTexture in luanti/src/client/tile.cpp:
#
#   frame = floor(time * 1000 / frame_length_ms) mod frame_count
#
# Also checks the clock (Client::step: dtime capped at 2.5 s, wrapping at 60
# seconds), that a still layer beside animated ones never changes, that the
# scissor variant animates too, and that a companion map follows the frame:
# tile C has the same colour in every frame and emission only in frame 1.
#
# GOANNA_SHOT=<dir> also writes each capture there.
extends SceneTree

const SIZE := Vector2i(640, 200)
# Tile A: 4 frames of 1000 ms, devtest's testnodes:anim (A to D in 4 s).
const A_BASE := 1
const A_MS := 1000
const A_COLOURS := [Color(1, 0, 0), Color(0, 1, 0), Color(0, 0, 1), Color(1, 1, 0)]
# Tile B: 3 frames of 250 ms, drawn by the scissor shader.
const B_BASE := 5
const B_MS := 250
const B_COLOURS := [Color(1, 0, 1), Color(0, 1, 1), Color(1, 1, 1)]
# Tile C: 3 frames of 500 ms, one colour, emission in frame 1 only.
const C_BASE := 8
const C_MS := 500
const C_FRAMES := 3
const STILL := Color(0.5, 0.5, 0.5)
const LAYERS := 11

var world: Node3D
var client: Object
var failures := 0
var shot_dir := ""


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	if not ok:
		push_error(message)
		failures += 1


func solid(c: Color, hole := false) -> Image:
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(c)
	if hole:
		# a cut out corner, so the scissor variant has something to cut
		for y in 4:
			for x in 4:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	img.generate_mipmaps()
	return img


func array_of(images: Array) -> Texture2DArray:
	var a := Texture2DArray.new()
	a.create_from_images(images)
	return a


func quad(x: float, layer: int, mat: Material) -> void:
	var verts := PackedVector3Array([Vector3(x, 0, 0), Vector3(x + 1, 0, 0),
		Vector3(x + 1, 1, 0), Vector3(x, 1, 0)])
	var uvs := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	var norms := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	for i in 4:
		norms.append(Vector3.BACK)
		uv2.append(Vector2(float(layer), 0.0))
		col.append(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	# counter clockwise seen from +z is a back face in Godot; wind it the
	# other way so cull_back keeps it
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	world.add_child(mi)


func material(shader_path: String, albedo: Texture2DArray, spec: Texture2DArray,
		flat_n: Texture2DArray, anim: PackedInt32Array) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(shader_path)
	mat.set_shader_parameter("albedo_array", albedo)
	mat.set_shader_parameter("normal_array", flat_n)
	mat.set_shader_parameter("spec_array", spec)
	mat.set_shader_parameter("has_normal", false)
	mat.set_shader_parameter("has_spec", true)
	# The quads carry no CUSTOM0, so no sky light and no occlusion; without
	# these the ambient term would be scaled by zero.
	mat.set_shader_parameter("sky_light_strength", 0.0)
	mat.set_shader_parameter("vertex_ao_strength", 0.0)
	mat.set_shader_parameter("vertex_ao_light_strength", 0.0)
	# the same flat pairs GoannaClient::materialFor hands over
	mat.set_shader_parameter("layer_anim", anim)
	return mat


func capture() -> Image:
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


# Centre of quad i in the capture: four quads 1.5 apart, centred on x.
func sample(img: Image, i: int) -> Color:
	var cam_size := 6.4
	var px_per_unit := SIZE.x / cam_size
	var cx := (float(i) * 1.5 + 0.5 - 2.75) * px_per_unit + SIZE.x * 0.5
	var cy := SIZE.y * 0.5
	var sum := Color(0, 0, 0)
	var n := 0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var c := img.get_pixel(int(cx) + dx, int(cy) + dy)
			sum += c
			n += 1
	return Color(sum.r / n, sum.g / n, sum.b / n)


func nearest(c: Color, palette: Array) -> int:
	var v := Vector3(c.r, c.g, c.b).normalized()
	var best := -1
	var best_d := 1e9
	for i in palette.size():
		var p: Color = palette[i]
		var d := v.distance_to(Vector3(p.r, p.g, p.b).normalized())
		if d < best_d:
			best_d = d
			best = i
	return best


func expected(time_s: float, ms: int, frames: int) -> int:
	# AnimationInfo::getTexture, in single precision as upstream computes it
	return int(time_s * 1000.0 / float(max(1, ms))) % frames


func run() -> void:
	shot_dir = OS.get_environment("GOANNA_SHOT")
	if shot_dir != "":
		DirAccess.make_dir_recursive_absolute(shot_dir)
	root.size = SIZE
	world = Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.4 * SIZE.y / SIZE.x
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.position = Vector3(0, 0.5, 10)
	camera.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	camera.environment = env

	# Layer 0 still; A at 1..4; B at 5..7 (with a hole); C at 8..10.
	var albedo := [solid(STILL)]
	for c in A_COLOURS:
		albedo.append(solid(c))
	for c in B_COLOURS:
		albedo.append(solid(c, true))
	for i in C_FRAMES:
		albedo.append(solid(STILL))
	var spec := []
	for i in LAYERS:
		# rough dielectric; A = 1.0 is no emission, except C's frame 1
		var a := 0.5 if i == C_BASE + 1 else 1.0
		spec.append(solid(Color(0.0, 0.04, 0.0, a)))
	var flat := []
	for i in LAYERS:
		flat.append(solid(Color(0.5, 0.5, 1.0, 0.0)))
	var albedo_arr := array_of(albedo)
	var spec_arr := array_of(spec)
	var flat_arr := array_of(flat)
	var anim := PackedInt32Array()
	anim.resize(LAYERS * 2)
	anim[A_BASE * 2] = A_COLOURS.size()
	anim[A_BASE * 2 + 1] = A_MS
	anim[B_BASE * 2] = B_COLOURS.size()
	anim[B_BASE * 2 + 1] = B_MS
	anim[C_BASE * 2] = C_FRAMES
	anim[C_BASE * 2 + 1] = C_MS
	var opaque := material("res://shaders/nodes_array.gdshader", albedo_arr, spec_arr,
		flat_arr, anim)
	var scissor := material("res://shaders/nodes_array_scissor.gdshader", albedo_arr,
		spec_arr, flat_arr, anim)
	quad(-2.75, 0, opaque)
	quad(-1.25, A_BASE, opaque)
	quad(0.25, B_BASE, scissor)
	quad(1.75, C_BASE, opaque)

	client = ClassDB.instantiate("GoannaClient")
	check(client != null, "GoannaClient is not registered; is the extension built?")
	if client == null:
		quit(1)
		return

	# The clock, through the client: Client::step caps dtime at 2.5 s and
	# keeps the time in [0, 60).
	client.set_node_animation_time(-1.0)
	client.step_node_animation(10.0)
	var t0: float = client.node_animation()["time"]
	check(is_equal_approx(t0, 2.5), "dtime is not capped at 2.5 s: clock %f" % t0)
	for i in 23:
		client.step_node_animation(2.5)
	var t1: float = client.node_animation()["time"]
	check(t1 < 0.001, "clock does not wrap at 60 s: %f after 60 s" % t1)
	client.step_node_animation(0.75)
	var t2: float = client.node_animation()["time"]
	check(is_equal_approx(t2, 0.75), "clock after wrap %f, wanted 0.75" % t2)

	var still_ref := Color(-1, 0, 0)
	var c_dark := 0.0
	var c_lit := 0.0
	var times := [0.0, 0.3, 0.6, 0.9, 1.2, 2.1, 3.7, 59.9]
	for time_s in times:
		client.set_node_animation_time(time_s)
		var img := await capture()
		if shot_dir != "":
			img.save_png(shot_dir.path_join("anim_%05.2f.png" % time_s))
		var still := sample(img, 0)
		if still_ref.r < 0.0:
			still_ref = still
		check(absf(still.r - still_ref.r) + absf(still.g - still_ref.g) < 0.01,
			"still layer changed at %.2f s: %s vs %s" % [time_s, still, still_ref])
		var a_seen := nearest(sample(img, 1), A_COLOURS)
		var a_want := expected(time_s, A_MS, A_COLOURS.size())
		check(a_seen == a_want, "tile A at %.2f s drew frame %d, Luanti draws %d" % [time_s, a_seen, a_want])
		var b_seen := nearest(sample(img, 2), B_COLOURS)
		var b_want := expected(time_s, B_MS, B_COLOURS.size())
		check(b_seen == b_want, "tile B (scissor) at %.2f s drew frame %d, Luanti draws %d" % [time_s, b_seen, b_want])
		var c_lum := sample(img, 3).get_luminance()
		if expected(time_s, C_MS, C_FRAMES) == 1:
			c_lit = maxf(c_lit, c_lum)
		else:
			c_dark = maxf(c_dark, c_lum)
		print("t=%5.2f  A frame %d (want %d)  B frame %d (want %d)  C luminance %.3f (frame %d)" % [
			time_s, a_seen, a_want, b_seen, b_want, c_lum, expected(time_s, C_MS, C_FRAMES)])
	check(c_lit > c_dark * 1.5 and c_lit > 0.0,
		"companion did not follow the frame: frame 1 luminance %.3f vs others %.3f" % [c_lit, c_dark])
	client.set_node_animation_time(-1.0)
	client.free()
	print("Node animation: %d failures" % failures)
	quit(1 if failures > 0 else 0)
