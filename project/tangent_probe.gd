extends Node3D

# Throwaway probe: does Godot apply a normal map to a runtime ArrayMesh that
# carries no tangent array? Two identical quads, same material, same light.
# The left one is given a tangent frame, the right one is not. If the right
# quad shades like the left, tangents are not required and normal mapping
# was working without them.
#
# Run: godot --path project tangent_probe.tscn

func _make_normal_map() -> ImageTexture:
	# A bump: normals tilt away from the centre, which lights as a dome.
	var n := 64
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) / n) * 2.0 - 1.0
			var v := (float(y) / n) * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var nx := 0.0
			var ny := 0.0
			if r > 0.001 and r < 1.0:
				nx = u * 0.9
				ny = -v * 0.9
			var nz := sqrt(maxf(1.0 - nx * nx - ny * ny, 0.0))
			img.set_pixel(x, y, Color(nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5, 1.0))
	return ImageTexture.create_from_image(img)


func _quad(with_tangent: bool) -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	var norms := PackedVector3Array([
		Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	var uvs := PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if with_tangent:
		var t := PackedFloat32Array()
		for i in 4:
			t.append_array([1.0, 0.0, 0.0, 1.0])
		arrays[Mesh.ARRAY_TANGENT] = t
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.8, 0.8)
	mat.roughness = 0.6
	mat.normal_enabled = true
	mat.normal_texture = _make_normal_map()
	mat.normal_scale = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # do not care which way I wound it

	for i in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = _quad(i == 0)
		mi.material_override = mat
		mi.position = Vector3(-1.2 if i == 0 else 1.2, 0, 0)
		add_child(mi)

	var light := DirectionalLight3D.new()
	# from the upper left, so a dome reads as clearly lit and shadowed halves
	light.rotation_degrees = Vector3(-35, 35, 0)
	light.light_energy = 3.0
	add_child(light)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.current = true
	add_child(cam)

	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := OS.get_environment("PROBE_OUT")
	if path == "":
		path = "/tmp/tangent_probe.png"
	img.save_png(path)

	# Report the shading spread on each quad. A working normal map varies
	# across the dome; an ignored one leaves the quad flatly lit.
	# Project each quad's own corners to find where to look, rather than
	# guessing screen fractions.
	var h := img.get_height()
	for side in 2:
		var cx := -1.2 if side == 0 else 1.2
		var a := cam.unproject_position(Vector3(cx - 1.0, 1.0, 0.0))
		var b := cam.unproject_position(Vector3(cx + 1.0, -1.0, 0.0))
		var lo := 2.0
		var hi := -1.0
		var lit := 0
		var total := 0
		for y in range(int(a.y) + 2, int(b.y) - 2):
			for x in range(int(a.x) + 2, int(b.x) - 2):
				if x < 0 or y < 0 or x >= img.get_width() or y >= h:
					continue
				var l := img.get_pixel(x, y).get_luminance()
				lo = minf(lo, l)
				hi = maxf(hi, l)
				total += 1
				if l > 0.01:
					lit += 1
		print("quad ", "with tangents" if side == 0 else "no tangents",
			": luminance %.3f to %.3f, spread %.3f, lit %d/%d px"
			% [lo, hi, hi - lo, lit, total])
	get_tree().quit()
