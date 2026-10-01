# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends Node3D

# Does the entity parallax march (entity_common.gdshaderinc) stay on its
# face? A fixture, no server: quads built the way buildGodotModel builds a
# mob's mesh (positions, normals, UVs and the face rectangle in CUSTOM0, no
# tangents), drawn through entity.gdshader and entity_scissor.gdshader from
# a small atlas, seen obliquely under a low sun from the side, once with
# parallax and once without.
#
# The atlas is three islands of 8 by 8 art texels in a row, drawn at 8 map
# texels each:
#   A (middle)  a sunk rim one texel wide all round, a grey floor at half
#               height, a raised red square and a sunk blue one;
#   B (sides)   bright green at the crest, the islands beside A in the image
#               that are not beside it on the model.
# A second atlas is A with a transparent hole (magenta under alpha 0) beside
# the sunk square, for the scissor variant.
#
# Checks, each of which fails the run:
#   - containment: no green on any quad whose rectangle is island A, while
#     the same quad with the whole atlas as its rectangle (no containment)
#     shows some, which proves the march does reach for the neighbour;
#   - the march moves the picture: the blue square's centroid shifts with
#     parallax on, and by the same screen direction on the plain and the
#     mirrored quad (a mirrored limb marches the way its view says, not the
#     way its UVs run);
#   - self shadow: the sunk square is darker with parallax than without;
#   - silhouette: the scissor quad covers the same pixels with and without,
#     and its hidden magenta never shows;
#   - a mesh with no CUSTOM0 draws exactly as with parallax off;
#   - walls: the raised square's walls draw whole, where the chord alone
#     (parallax_refine 0) drew them as a staircase of slices.
#
# Run, inside headless gamescope (it needs a display):
#   godot --path project entity_parallax_probe.tscn
# ENTITY_PROBE_OUT names a directory for on.png, off.png and chord.png. Exit code 0
# when every check passes, 1 otherwise.

const ART := Vector2i(24, 8)
const PX := 8
const DEPTH_NODES := 0.10
const QUAD_BASIS := Basis(Vector3.UP, deg_to_rad(55.0))

var failures := 0


func _check(ok: bool, what: String) -> void:
	print("%-6s %s" % ["ok" if ok else "WRONG", what])
	if not ok:
		failures += 1


# Island A's texel at (x, y), 0..7: colour and height byte.
func _island_a(x: int, y: int, hole: bool) -> Array:
	if hole and x >= 2 and x <= 3 and y >= 4 and y <= 5:
		return [Color(1, 0, 1, 0), 0.5]
	if x == 0 or y == 0 or x == 7 or y == 7:
		return [Color(0.3, 0.3, 0.3, 1), 0.0]
	if x >= 2 and x <= 3 and y >= 2 and y <= 3:
		return [Color(0.8, 0.15, 0.1, 1), 1.0]
	if x >= 4 and x <= 5 and y >= 4 and y <= 5:
		return [Color(0.1, 0.2, 0.9, 1), 0.0]
	return [Color(0.55, 0.55, 0.55, 1), 0.5]


# Albedo and _n at PX map texels per art texel. The normal tilts only on a
# step's two map texels either side, toward the lower side, as an authored
# plateau map does.
func _atlas(hole: bool) -> Array:
	var w := ART.x * PX
	var h := ART.y * PX
	var heights := PackedFloat32Array()
	heights.resize(w * h)
	var alb := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var ax := x / PX
			var ay := y / PX
			var c: Color
			var hgt: float
			if ax >= 8 and ax < 16:
				var t: Array = _island_a(ax - 8, ay, hole)
				c = t[0]
				hgt = t[1]
			else:
				c = Color(0.1, 0.9, 0.1, 1)
				hgt = 1.0
			alb.set_pixel(x, y, c)
			heights[y * w + x] = hgt
	var nrm := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var hx0 := heights[y * w + maxi(x - 1, 0)]
			var hx1 := heights[y * w + mini(x + 1, w - 1)]
			var hy0 := heights[maxi(y - 1, 0) * w + x]
			var hy1 := heights[mini(y + 1, h - 1) * w + x]
			# Red above 128 tilts toward +U, green above 128 toward the top
			# of the image (smaller V); see entity_normal_probe.gd.
			var n := Vector3(-(hx1 - hx0), (hy1 - hy0), 0.25).normalized()
			nrm.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, 1.0, heights[y * w + x]))
	alb.generate_mipmaps()
	nrm.generate_mipmaps()
	return [ImageTexture.create_from_image(alb), ImageTexture.create_from_image(nrm)]


# A unit quad facing +Z showing UV u0..u1 (u1 < u0 mirrors it), with the
# given face rectangle in CUSTOM0, or none.
func _quad(u0: float, u1: float, rect: Variant) -> ArrayMesh:
	var corners := PackedVector3Array([Vector3(-0.5, 0.5, 0), Vector3(0.5, 0.5, 0),
			Vector3(0.5, -0.5, 0), Vector3(-0.5, -0.5, 0)])
	var uvs := PackedVector2Array([Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, 1), Vector2(u0, 1)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = corners
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var flags := 0
	if rect != null:
		var r: Vector4 = rect
		var c := PackedFloat32Array()
		for i in 4:
			c.append_array([r.x, r.y, r.z, r.w])
		arrays[Mesh.ARRAY_CUSTOM0] = c
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return m


func _material(shader: Shader, maps: Array) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("albedo", maps[0])
	m.set_shader_parameter("has_normal", true)
	m.set_shader_parameter("normal_tex", maps[1])
	m.set_shader_parameter("has_height", true)
	m.set_shader_parameter("relief_depth", DEPTH_NODES)
	m.set_shader_parameter("art_texels", Vector2(ART))
	return m


func _ready() -> void:
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3.ZERO)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.25
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var opaque: Shader = load("res://shaders/entity.gdshader")
	var scissor: Shader = load("res://shaders/entity_scissor.gdshader")
	var maps := _atlas(false)
	var holed := _atlas(true)
	var mats := [_material(opaque, maps), _material(scissor, holed)]
	var a0 := 1.0 / 3.0
	var a1 := 2.0 / 3.0
	var island := Vector4(a0, 0.0, a1, 1.0)
	var cases := [
		{"name": "plain", "mesh": _quad(a0, a1, island), "mat": 0},
		{"name": "mirrored", "mesh": _quad(a1, a0, island), "mat": 0},
		{"name": "uncontained", "mesh": _quad(a0, a1, Vector4(0, 0, 1, 1)), "mat": 0},
		{"name": "no CUSTOM0", "mesh": _quad(a0, a1, null), "mat": 0},
		{"name": "scissor hole", "mesh": _quad(a0, a1, island), "mat": 1},
	]
	var spots := []
	for i in cases.size():
		var mi := MeshInstance3D.new()
		mi.mesh = cases[i]["mesh"]
		mi.material_override = mats[cases[i]["mat"]]
		# Turned 55 degrees about Y, so the camera sees every face obliquely
		# from its left, the same way, which is where a march runs furthest.
		mi.transform = Transform3D(QUAD_BASIS, Vector3(i * 1.3, 0, 0))
		add_child(mi)
		spots.append(mi.position)

	# Perspective, as in play, but narrow and far enough that every quad is
	# seen within ten degrees of straight on, and near enough that none is
	# in the march's distance fade (parallax_range). Godot's VIEW under an
	# orthographic camera still turns with the fragment's position, which
	# put the right hand quads at a grazing angle here.
	var cam := Camera3D.new()
	cam.fov = 20.0
	add_child(cam)
	cam.position = Vector3((cases.size() - 1) * 1.3 * 0.5, 0, 16.0)
	cam.current = true

	# A low sun from the faces' right, grazing them, so a sunk square's right
	# wall shades its floor.
	var right := QUAD_BASIS.x
	var normal := QUAD_BASIS.z
	var sun_dir := (0.85 * right + 0.3 * normal + Vector3(0, 0.3, 0)).normalized()
	RenderingServer.global_shader_parameter_set("goanna_sun_dir", sun_dir)
	var light := DirectionalLight3D.new()
	light.light_energy = 2.0
	add_child(light)
	light.basis = Basis.looking_at(-sun_dir, Vector3.UP)

	var out_dir := OS.get_environment("ENTITY_PROBE_OUT")
	if out_dir == "":
		out_dir = "/tmp"
	var shots := {}
	# "chord" is the march with the node path's chord alone, no wall
	# refinement, to show the staircase the refinement removes.
	for state in ["off", "on", "chord"]:
		for m in mats:
			m.set_shader_parameter("parallax_strength", 0.0 if state == "off" else 1.0)
			m.set_shader_parameter("parallax_refine", 0 if state == "chord" else 5)
		for i in 8:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_dir.path_join(state + ".png"))
		shots[state] = img

	var stats := {}
	for state in ["off", "on"]:
		var img: Image = shots[state]
		var per := []
		for i in cases.size():
			per.append(_measure(img, cam, spots[i]))
		stats[state] = per
	for i in cases.size():
		var n: String = cases[i]["name"]
		var on: Dictionary = stats["on"][i]
		var off: Dictionary = stats["off"][i]
		print("%-13s on: green %d blue %d at %s lum %.3f cover %d magenta %d | off: green %d blue %d at %s lum %.3f cover %d" % [
				n, on.green, on.blue, on.blue_at, on.blue_lum, on.cover, on.magenta,
				off.green, off.blue, off.blue_at, off.blue_lum, off.cover])

	var plain_on: Dictionary = stats["on"][0]
	var plain_off: Dictionary = stats["off"][0]
	var mir_on: Dictionary = stats["on"][1]
	var mir_off: Dictionary = stats["off"][1]
	_check(plain_on.green == 0 and mir_on.green == 0 and stats["on"][4].green == 0,
			"contained: no green from the neighbouring island")
	_check(stats["on"][2].green > 20, "uncontained: the march does reach the neighbour (%d px)" % stats["on"][2].green)
	var shift_plain: Vector2 = plain_on.blue_at - plain_off.blue_at
	var shift_mir: Vector2 = mir_on.blue_at - mir_off.blue_at
	print("blue square shift: plain %s mirrored %s" % [shift_plain, shift_mir])
	_check(shift_plain.length() > 1.5, "plain: the sunk square moves with parallax")
	_check(shift_mir.length() > 1.5, "mirrored: the sunk square moves with parallax")
	# The same way, by about as much: the two blue squares sit on opposite
	# sides of their faces, so what hides them differs a little.
	_check(shift_plain.dot(shift_mir) > 0.0
			and shift_mir.length() / shift_plain.length() > 0.6
			and shift_mir.length() / shift_plain.length() < 1.6,
			"mirrored marches the same screen way as plain")
	_check(plain_on.blue_lum < plain_off.blue_lum * 0.92, "self shadow darkens the sunk square")
	var sc_on: Dictionary = stats["on"][4]
	var sc_off: Dictionary = stats["off"][4]
	_check(sc_on.cover == sc_off.cover, "scissor: same silhouette on and off (%d, %d)" % [sc_on.cover, sc_off.cover])
	_check(sc_on.magenta == 0, "scissor: the hole's hidden colour never shows")
	_check(_same(shots["on"], shots["off"], cam, spots[3]), "no CUSTOM0: identical to parallax off")
	# Walls: along every row of the plain quad, how often the colour flips
	# between the raised red square and anything else. A wall drawn whole
	# flips twice per row it crosses; a staircase of slices flips at every
	# slice.
	var flips_on := _flips(shots["on"], cam, spots[0])
	var flips_chord := _flips(shots["chord"], cam, spots[0])
	print("red wall colour flips: refined %d, chord only %d" % [flips_on, flips_chord])
	_check(flips_on * 2 < flips_chord, "walls: the refinement removes the staircase")
	print("entity parallax probe: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)


# Pixels of one quad's screen box: green, blue and magenta counts, the blue
# centroid and mean luminance, and how many pixels the quad covers.
func _box(cam: Camera3D, at: Vector3) -> Rect2i:
	var a := cam.unproject_position(at + QUAD_BASIS * Vector3(-0.6, 0.6, 0))
	var b := cam.unproject_position(at + QUAD_BASIS * Vector3(0.6, -0.6, 0))
	var c := cam.unproject_position(at + QUAD_BASIS * Vector3(-0.6, -0.6, 0))
	var d := cam.unproject_position(at + QUAD_BASIS * Vector3(0.6, 0.6, 0))
	var lo := Vector2(minf(minf(a.x, b.x), minf(c.x, d.x)), minf(minf(a.y, b.y), minf(c.y, d.y)))
	var hi := Vector2(maxf(maxf(a.x, b.x), maxf(c.x, d.x)), maxf(maxf(a.y, b.y), maxf(c.y, d.y)))
	return Rect2i(Vector2i(lo), Vector2i(hi - lo))


func _measure(img: Image, cam: Camera3D, at: Vector3) -> Dictionary:
	var r := _box(cam, at).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var res := {"green": 0, "blue": 0, "magenta": 0, "cover": 0,
			"blue_at": Vector2.ZERO, "blue_lum": 0.0}
	var sum := Vector2.ZERO
	var lum := 0.0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c := img.get_pixel(x, y)
			if c.r + c.g + c.b > 0.02:
				res.cover += 1
			if c.g > 0.08 and c.g > c.r * 2.0 and c.g > c.b * 2.0:
				res.green += 1
			if c.b > 0.04 and c.b > c.r * 2.0 and c.b > c.g * 1.6:
				res.blue += 1
				sum += Vector2(x, y)
				lum += c.get_luminance()
			if c.r > 0.08 and c.b > 0.08 and c.g < 0.5 * minf(c.r, c.b):
				res.magenta += 1
	if res.blue > 0:
		res.blue_at = sum / res.blue
		res.blue_lum = lum / res.blue
	return res


func _flips(img: Image, cam: Camera3D, at: Vector3) -> int:
	var r := _box(cam, at).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var flips := 0
	for y in range(r.position.y, r.end.y):
		var was := false
		for x in range(r.position.x, r.end.x):
			var c := img.get_pixel(x, y)
			var red := c.r > 0.08 and c.r > c.g * 2.0 and c.r > c.b * 2.0
			if red != was and x > r.position.x:
				flips += 1
			was = red
	return flips


func _same(a: Image, b: Image, cam: Camera3D, at: Vector3) -> bool:
	var r := _box(cam, at).intersection(Rect2i(Vector2i.ZERO, a.get_size()))
	var diff := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.02:
				diff += 1
	print("no CUSTOM0: %d pixels differ" % diff)
	return diff == 0
