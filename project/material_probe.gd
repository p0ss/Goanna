extends Node3D

# Differential probe for the LabPBR decode in shaders/nodes_array.gdshader.
#
# Screenshots of the game can show that something changed, and they catch
# gross breakage, but they cannot show that a material is correct: the world
# has ambient, GI, AO, fog, a sky and a tonemap on top, and any of those can
# hide or manufacture an effect. So compare against something whose answer is
# already known instead.
#
# Each case draws two quads under one directional light with everything else
# switched off. The left quad runs our shader, fed LabPBR bytes. The right
# runs Godot's own StandardMaterial3D, set to the values our shader is
# supposed to decode those bytes into. If the decode is right the two are the
# same pixel. Any difference is ours.
#
# Run: godot --path project material_probe.tscn

const SIZE := 1


func _tex(c: Color) -> ImageTexture:
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func _arr(c: Color) -> Texture2DArray:
	var img := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(c)
	var a := Texture2DArray.new()
	a.create_from_images([img])
	return a


func _quad() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	# UV2.x is the array layer the mesher writes. The vertex colour channel
	# carries Luanti's per vertex light, which the shader multiplies into the
	# albedo, so it is white here and the comparison is of the material alone.
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
		Vector2(0, 0), Vector2(0, 0), Vector2(0, 0), Vector2(0, 0)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([
		Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


# byte -> the unit float the shader sees
func _u(b: int) -> float:
	return float(b) / 255.0


# Each case: a name, the LabPBR _s bytes, and the StandardMaterial3D setup
# that our shader claims those bytes mean.
func _cases() -> Array:
	var out := []
	# smoothness 0: roughness (1-0)^2 = 1.0, dielectric F0 10 -> specular 0.078
	out.append(["rough (sm 0)", Color8(0, 10, 0, 255), 1.0, 0.0, _u(10) / 0.08, 0.0])
	# smoothness 128: roughness (1-0.502)^2 = 0.248
	out.append(["mid (sm 128)", Color8(128, 10, 0, 255), pow(1.0 - _u(128), 2.0), 0.0, _u(10) / 0.08, 0.0, false])
	# smoothness 230: roughness 0.0096, clamped by the shader to 0.04
	out.append(["smooth (sm 230)", Color8(230, 10, 0, 255), 0.04, 0.0, _u(10) / 0.08, 0.0, false])
	# G at 230 is the first metal index: metallic 1, specular 0.5
	out.append(["metal (g 230)", Color8(128, 230, 0, 255), pow(1.0 - _u(128), 2.0), 1.0, 0.5, 0.0, false])
	# A below 255 is emission, at ALBEDO * a * 4
	out.append(["emissive (a 16)", Color8(0, 10, 0, 16), 1.0, 0.0, _u(10) / 0.08, _u(16) * 4.0, true])
	return out


func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0, 0, 0)
	e.ambient_light_energy = 0.0
	# Everything that could flatter or hide the result, off. A tonemap in
	# particular would squash exactly the differences being measured.
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.tonemap_white = 1.0
	e.ssao_enabled = false
	e.ssil_enabled = false
	e.sdfgi_enabled = false
	e.glow_enabled = false
	e.fog_enabled = false
	e.adjustment_enabled = false
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)

	var albedo := Color8(128, 128, 128, 255)
	var flat_n := Color8(128, 128, 255, 0) # flat normal, AO 1.0, height 0
	var cases := _cases()

	for i in cases.size():
		var c: Array = cases[i]
		var x := (i - (cases.size() - 1) / 2.0) * 2.6

		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/nodes_array.gdshader")
		sm.set_shader_parameter("albedo_array", _arr(albedo))
		sm.set_shader_parameter("normal_array", _arr(flat_n))
		sm.set_shader_parameter("spec_array", _arr(c[1]))
		sm.set_shader_parameter("has_normal", true)
		sm.set_shader_parameter("has_spec", true)
		sm.set_shader_parameter("scissor", false)
		var ours := MeshInstance3D.new()
		ours.mesh = _quad()
		ours.material_override = sm
		ours.position = Vector3(x, 1.1, 0)
		add_child(ours)

		if c.size() > 6 and c[6]:
			var off := ShaderMaterial.new()
			off.shader = load("res://shaders/nodes_array.gdshader")
			off.set_shader_parameter("albedo_array", _arr(albedo))
			off.set_shader_parameter("normal_array", _arr(flat_n))
			off.set_shader_parameter("spec_array", _arr(Color8(0, 10, 0, 255)))
			off.set_shader_parameter("has_normal", true)
			off.set_shader_parameter("has_spec", true)
			off.set_shader_parameter("scissor", false)
			var offi := MeshInstance3D.new()
			offi.mesh = _quad()
			offi.material_override = off
			offi.position = Vector3(x, -1.1, 0)
			add_child(offi)
			continue
		var ref := StandardMaterial3D.new()
		ref.albedo_texture = _tex(albedo)
		ref.roughness = c[2]
		ref.metallic = c[3]
		ref.metallic_specular = c[4]
		if c[5] > 0.0:
			ref.emission_enabled = true
			# the shader emits ALBEDO * a * 4, and ALBEDO is the decoded texture
			ref.emission = Color(1, 1, 1)
			ref.emission_energy_multiplier = c[5]
			ref.emission_operator = BaseMaterial3D.EMISSION_OP_ADD
			ref.emission_texture = _tex(albedo)
		var refi := MeshInstance3D.new()
		refi.mesh = _quad()
		refi.material_override = ref
		refi.position = Vector3(x, -1.1, 0)
		add_child(refi)

	var light := DirectionalLight3D.new()
	# Off axis on purpose. Head on, the specular lobe lands the same whatever
	# the roughness, so every roughness case renders identically and a match
	# proves nothing. At a glancing angle the lobe is what separates them.
	light.rotation_degrees = Vector3(-38, -52, 0)
	light.light_energy = 2.0
	light.shadow_enabled = false
	add_child(light)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 9)
	cam.current = true
	add_child(cam)

	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := OS.get_environment("PROBE_OUT")
	if path != "":
		img.save_png(path)

	print("case               ours            standard        max delta")
	var worst := 0.0
	for i in cases.size():
		var c: Array = cases[i]
		var x := (i - (cases.size() - 1) / 2.0) * 2.6
		var a := _sample(img, cam, Vector3(x, 1.1, 0))
		var b := _sample(img, cam, Vector3(x, -1.1, 0))
		var d: float = maxf(maxf(absf(a.x - b.x), absf(a.y - b.y)), absf(a.z - b.z))
		worst = maxf(worst, d)
		if c.size() > 6 and c[6]:
			# EMISSION = ALBEDO * a * 4, all in linear
			var lit_a := pow((a.x / 255.0 + 0.055) / 1.055, 2.4)
			var lit_b := pow((b.x / 255.0 + 0.055) / 1.055, 2.4)
			var alb := pow((128.0 / 255.0 + 0.055) / 1.055, 2.4)
			var want: float = alb * c[5]
			var got: float = lit_a - lit_b
			print("%-18s emission linear got %.4f want %.4f%s"
				% [c[0], got, want, "   MISMATCH" if absf(got - want) > 0.01 else ""])
			continue
		print("%-18s %-15s %-15s %.1f%s" % [c[0], _fmt(a), _fmt(b), d,
			"   MISMATCH" if d > 3.0 else ""])
	print("worst channel delta: %.1f (8 bit)" % worst)
	get_tree().quit()


func _fmt(v: Vector3) -> String:
	return "%d,%d,%d" % [int(v.x), int(v.y), int(v.z)]


# average a small patch at the centre of a quad, in screen space
func _sample(img: Image, cam: Camera3D, world: Vector3) -> Vector3:
	var p := cam.unproject_position(world)
	var acc := Vector3.ZERO
	var n := 0
	for dy in range(-12, 13):
		for dx in range(-12, 13):
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b) * 255.0
			n += 1
	return acc / maxf(n, 1)
