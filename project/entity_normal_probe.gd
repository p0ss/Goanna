# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends Node3D

# Does an entity's normal map sit on its art? A fixture, no server, no
# client: quads built the way buildGodotModel builds a mob's mesh (positions,
# normals and UVs, no tangent array), drawn through entity.gdshader with a
# probe _n that holds one dome, under a light from the right and then from
# the top. A dome lit from the right is brighter on its right half; lit from
# the top, on its upper half. Every quad must agree.
#
# The quads cover the six directions a mob's box faces can have in mesh
# space, each turned by its instance to face the camera, each once with its
# UVs as drawn and once mirrored along U (Minecraft style skins mirror the
# limbs). The first quad is the reference: the same material on a mesh
# whose tangents SurfaceTool wrote, which is the frame the node mesher
# matches (goanna_client.cpp, node_tangents). The last two quads have no _n
# of their own: their albedo has a bright disc and their normal map is the
# auto bump inference, ported from inferNormalImage in goanna_textures.cpp,
# so a bright (raised) disc must light as a dome too, on the node frame and
# on the entity one. The port is checked here, not the C++ itself; keep the
# two in step.
#
# The probe dome is authored as: red above 128 tilts the normal along +U
# (right in the image), green above 128 tilts it toward the top of the image
# (smaller V). That is the encoding the node path decodes with no green flip.
#
# Run, inside headless gamescope (it needs a display):
#   godot --path project entity_normal_probe.tscn
# ENTITY_PROBE_OUT names a directory for right.png and top.png. Exit code 0
# when every quad agrees, 1 otherwise.

const SIZE := 32
const DOME := 0.42 # radius as a fraction of the quad
const TILT := 0.8

var failures := 0


func _dome_normal_map() -> ImageTexture:
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var u := (x + 0.5) / SIZE - 0.5
			var v := (y + 0.5) / SIZE - 0.5
			var r := sqrt(u * u + v * v) / DOME
			var nx := 0.0
			var ny_up := 0.0
			if r < 1.0:
				nx = u / DOME * TILT
				ny_up = -v / DOME * TILT
			img.set_pixel(x, y, Color(nx * 0.5 + 0.5, ny_up * 0.5 + 0.5, 1.0, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _flat_albedo(bright_disc: bool) -> Image:
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			var u := (x + 0.5) / SIZE - 0.5
			var v := (y + 0.5) / SIZE - 0.5
			var inside := sqrt(u * u + v * v) < DOME * 0.6
			var g := 0.85 if bright_disc and inside else 0.5
			img.set_pixel(x, y, Color(g, g, g, 1.0))
	return img


# inferNormalImage (goanna_textures.cpp) with labpbr = true, line for line.
func _inferred_normal_map(albedo: Image, strength: float) -> ImageTexture:
	var w := albedo.get_width()
	var h := albedo.get_height()
	var lum := PackedFloat32Array()
	lum.resize(w * h)
	for y in h:
		for x in w:
			var c := albedo.get_pixel(x, y)
			lum[y * w + x] = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	var at := func(x: int, y: int) -> float:
		return lum[((y + h) % h) * w + ((x + w) % w)]
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var gx: float = (at.call(x + 1, y - 1) + 2 * at.call(x + 1, y) + at.call(x + 1, y + 1)) \
					- (at.call(x - 1, y - 1) + 2 * at.call(x - 1, y) + at.call(x - 1, y + 1))
			var gy: float = (at.call(x - 1, y + 1) + 2 * at.call(x, y + 1) + at.call(x + 1, y + 1)) \
					- (at.call(x - 1, y - 1) + 2 * at.call(x, y - 1) + at.call(x + 1, y - 1))
			var n := Vector3(-gx * strength, -gy * strength, 1.0).normalized()
			img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, -n.y * 0.5 + 0.5, 1.0, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# A unit quad in mesh space facing `n`, with U along `right` (or against it
# when mirrored) and V running along -`up`, wound front facing for cull_back.
func _quad(n: Vector3, right: Vector3, up: Vector3, mirrored: bool,
		with_tangents: bool) -> ArrayMesh:
	var corners := [
		-right * 0.5 + up * 0.5, right * 0.5 + up * 0.5,
		right * 0.5 - up * 0.5, -right * 0.5 - up * 0.5]
	var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	if mirrored:
		for i in 4:
			uvs[i].x = 1.0 - uvs[i].x
	var order := [0, 1, 2, 0, 2, 3]
	# Godot's front faces wind clockwise seen from the normal's side; flip
	# the order if this corner list runs the other way.
	if (corners[1] - corners[0]).cross(corners[2] - corners[0]).dot(n) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	if with_tangents:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in order:
			st.set_normal(n)
			st.set_uv(uvs[i])
			st.add_vertex(corners[i])
		st.generate_tangents()
		return st.commit()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(corners)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(uvs)
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(order)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _material(shader: Shader, albedo: Image, normal: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("albedo", ImageTexture.create_from_image(albedo))
	m.set_shader_parameter("has_normal", true)
	m.set_shader_parameter("normal_tex", normal)
	return m


func _ready() -> void:
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3.ZERO)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.05
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var shader: Shader = load("res://shaders/entity.gdshader")
	var probe := _dome_normal_map()
	var grey := _flat_albedo(false)
	var disc := _flat_albedo(true)
	var probe_mat := _material(shader, grey, probe)
	var inferred_mat := _material(shader, disc, _inferred_normal_map(disc, 0.95))

	# Mesh space faces: normal, right, up, with right x up = normal so the
	# instance basis that turns them to the camera is a pure rotation.
	var faces := [
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
		[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
		[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
		[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	]
	var cases := [{"name": "reference (SurfaceTool tangents)", "face": faces[0],
			"mirrored": false, "tangents": true, "mat": probe_mat}]
	for f in faces:
		for mirrored in [false, true]:
			cases.append({"name": "normal %s%s" % [f[0], " mirrored" if mirrored else ""],
					"face": f, "mirrored": mirrored, "tangents": false, "mat": probe_mat})
	cases.append({"name": "auto bump, SurfaceTool tangents", "face": faces[0],
			"mirrored": false, "tangents": true, "mat": inferred_mat})
	cases.append({"name": "auto bump, normal (1, 0, 0)", "face": faces[2],
			"mirrored": false, "tangents": false, "mat": inferred_mat})

	var cols := 5
	var quads := []
	for i in cases.size():
		var c: Dictionary = cases[i]
		var f: Array = c["face"]
		var mi := MeshInstance3D.new()
		mi.mesh = _quad(f[0], f[1], f[2], c["mirrored"], c["tangents"])
		mi.material_override = c["mat"]
		# Columns: mesh right, mesh up, mesh normal. Its inverse takes them
		# to screen right, screen up and toward the camera.
		var mesh_basis := Basis(f[1], f[2], f[0])
		var pos := Vector3((i % cols) * 1.25, -(i / cols) * 1.25, 0.0)
		mi.transform = Transform3D(mesh_basis.inverse(), pos)
		add_child(mi)
		quads.append(pos)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.2
	add_child(cam)
	cam.position = Vector3((cols - 1) * 1.25 * 0.5, -1.25, 6.0)
	cam.current = true

	var light := DirectionalLight3D.new()
	light.light_energy = 2.0
	add_child(light)

	var out_dir := OS.get_environment("ENTITY_PROBE_OUT")
	if out_dir == "":
		out_dir = "/tmp"
	# From the right (and a little in front), then from the top.
	for pass_name in ["right", "top"]:
		var dir := Vector3(-1, 0, -0.6) if pass_name == "right" else Vector3(0, -1, -0.6)
		light.basis = Basis.looking_at(dir, Vector3(0, 0, -1) if pass_name == "top" else Vector3.UP)
		for i in 8:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_dir.path_join(pass_name + ".png"))
		for i in cases.size():
			var c: Dictionary = cases[i]
			var p: Vector3 = quads[i]
			var centre := cam.unproject_position(p)
			var edge := cam.unproject_position(p + Vector3(DOME, 0, 0))
			var rad := edge.x - centre.x
			var lit := 0.0
			var unlit := 0.0
			var n_lit := 0
			var n_unlit := 0
			for y in range(int(centre.y - rad), int(centre.y + rad)):
				for x in range(int(centre.x - rad), int(centre.x + rad)):
					var d := Vector2(x + 0.5, y + 0.5) - centre
					if d.length() > rad * 0.85 or d.length() < rad * 0.15:
						continue
					# Toward the light: +x on screen for "right", -y for "top".
					var s := d.x if pass_name == "right" else -d.y
					if absf(s) < rad * 0.15:
						continue
					var l := img.get_pixel(x, y).get_luminance()
					if s > 0.0:
						lit += l
						n_lit += 1
					else:
						unlit += l
						n_unlit += 1
			lit /= maxf(n_lit, 1)
			unlit /= maxf(n_unlit, 1)
			var ok := lit > unlit * 1.15
			if not ok:
				failures += 1
			print("%-5s %-34s lit side %.3f  far side %.3f  %s" % [
					pass_name, c["name"], lit, unlit, "ok" if ok else "WRONG"])
	print("entity normal probe: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
