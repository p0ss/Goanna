extends Node3D

# Differential probe for the LabPBR decode in shaders/nodes_array.gdshader,
# and (for the non-emissive cases) shaders/entity.gdshader, the single
# sampler2D version used for mob materials. Both share the same decode maths
# by construction (entity.gdshader is a duplicate, not a shared function:
# Godot does not allow a called function to write fragment built-ins), so
# this is really one probe with an extra row confirming the duplication
# stayed faithful.
#
# Screenshots of the game can show that something changed, and they catch
# gross breakage, but they cannot show that a material is correct: the world
# has ambient, GI, AO, fog, a sky and a tonemap on top, and any of those can
# hide or manufacture an effect. So compare against something whose answer is
# already known instead.
#
# Each case draws quads under one directional light with everything else
# switched off: the top-most runs shaders/entity.gdshader, the middle runs
# shaders/nodes_array.gdshader, both fed the same LabPBR bytes, and the
# bottom runs Godot's own StandardMaterial3D, set to the values our shaders
# are supposed to decode those bytes into. If the decode is right all three
# are the same pixel. Any difference is ours.
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
	# CUSTOM0 is the mesher's night light in R, day light in G and vertex
	# occlusion in B. Full day, no night and no occlusion: without the day
	# light the sun gate in direct_light.gdshaderinc shuts the sun out of
	# nodes_array.gdshader altogether.
	var light := PackedFloat32Array()
	for v in 4:
		light.append_array([0.0, 1.0, 1.0, 0.0])
	arrays[Mesh.ARRAY_CUSTOM0] = light
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return m


# byte -> the unit float the shader sees
func _u(b: int) -> float:
	return float(b) / 255.0


# The SPECULAR that makes Godot's dielectric F0, 0.16 * SPECULAR squared,
# equal the LabPBR F0 byte, clamped where F0 passes Godot's 0.16 ceiling.
func _spec(f0_byte: int) -> float:
	return minf(sqrt(_u(f0_byte) / 0.16), 1.0)


# Each case: a name, the LabPBR _s bytes, and the StandardMaterial3D setup
# that our shader claims those bytes mean. Roughness is 1 - smoothness,
# unsquared, clamped at 0.04, because Godot squares it itself.
func _cases() -> Array:
	var out := []
	# smoothness 0: roughness 1.0, dielectric F0 10 -> F0 0.039, specular 0.494
	out.append(["rough (sm 0)", Color8(0, 10, 0, 255), 1.0, 0.0, _spec(10), 0.0])
	# smoothness 128: roughness 1 - 0.502 = 0.498
	out.append(["mid (sm 128)", Color8(128, 10, 0, 255), 1.0 - _u(128), 0.0, _spec(10), 0.0, false])
	# smoothness 230: roughness 0.098
	out.append(["smooth (sm 230)", Color8(230, 10, 0, 255), 1.0 - _u(230), 0.0, _spec(10), 0.0, false])
	# F0 bytes other than 10, as the authored packs write them, beside the
	# plain 10, on quads turned to the half vector so the lobe's peak is what
	# the camera sees and F0 is what separates them: 6 (enderman eyes), 15
	# (player and mob eyes), 20 (amethyst), 26 (end portal frame eye). Until
	# 2026-10-03 the shaders wrote F0 / 0.08, which is right only at 0.04.
	for b in [10, 6, 15, 20, 26]:
		out.append(["f0 %d (sm 120)" % b, Color8(120, b, 0, 255), 1.0 - _u(120), 0.0, _spec(b), 0.0, false, true])
	# G at 230 is the first metal index: metallic 1, specular 0.5
	out.append(["metal (g 230)", Color8(128, 230, 0, 255), 1.0 - _u(128), 1.0, 0.5, 0.0, false])
	# A below 255 is emission, at ALBEDO * a * 4
	out.append(["emissive (a 16)", Color8(0, 10, 0, 16), 1.0, 0.0, _spec(10), _u(16) * 4.0, true])
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
	# Flat normal, AO 1.0, and height 255, the crest: LabPBR's 0 is the
	# deepest point, which the parallax self shadow darkens.
	var flat_n := Color8(128, 128, 255, 255)
	var cases := _cases()
	# The light's rotation, set below; known here so the F0 cases can face
	# the half vector between it and the camera.
	var to_light := Basis.from_euler(Vector3(deg_to_rad(-38), deg_to_rad(-52), 0)).z
	var cam_pos := Vector3(0, 0, 9)

	for i in cases.size():
		var c: Array = cases[i]
		var x := (i - (cases.size() - 1) / 2.0) * 2.3

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
		_face(ours, c, to_light, cam_pos)
		add_child(ours)

		# entity.gdshader only ever runs for the opaque case (see
		# EntityRenderer::materialForMeshTexture), so it is only worth
		# checking against the non-emissive cases here.
		if not (c.size() > 6 and c[6]):
			var esm := ShaderMaterial.new()
			esm.shader = load("res://shaders/entity.gdshader")
			esm.set_shader_parameter("albedo", _tex(albedo))
			esm.set_shader_parameter("normal_tex", _tex(flat_n))
			esm.set_shader_parameter("spec_tex", _tex(c[1]))
			esm.set_shader_parameter("has_normal", true)
			esm.set_shader_parameter("has_spec", true)
			var entity_mi := MeshInstance3D.new()
			entity_mi.mesh = _quad()
			entity_mi.material_override = esm
			entity_mi.position = Vector3(x, 3.3, 0)
			_face(entity_mi, c, to_light, cam_pos)
			add_child(entity_mi)

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
			_face(offi, c, to_light, cam_pos)
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
		_face(refi, c, to_light, cam_pos)
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
	cam.position = cam_pos
	cam.current = true
	add_child(cam)

	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := OS.get_environment("PROBE_OUT")
	if path != "":
		img.save_png(path)

	print("case               entity          ours            standard        max delta")
	var worst := 0.0
	for i in cases.size():
		var c: Array = cases[i]
		var x := (i - (cases.size() - 1) / 2.0) * 2.3
		var a := _sample(img, cam, Vector3(x, 1.1, 0))
		var b := _sample(img, cam, Vector3(x, -1.1, 0))
		var d: float = maxf(maxf(absf(a.x - b.x), absf(a.y - b.y)), absf(a.z - b.z))
		worst = maxf(worst, d)
		if c.size() > 6 and c[6]:
			# EMISSION = ALBEDO * a * 4, all in linear. entity.gdshader is not
			# checked here; see the comment where it is built.
			var lit_a := pow((a.x / 255.0 + 0.055) / 1.055, 2.4)
			var lit_b := pow((b.x / 255.0 + 0.055) / 1.055, 2.4)
			var alb := pow((128.0 / 255.0 + 0.055) / 1.055, 2.4)
			var want: float = alb * c[5]
			var got: float = lit_a - lit_b
			print("%-18s emission linear got %.4f want %.4f%s"
				% [c[0], got, want, "   MISMATCH" if absf(got - want) > 0.01 else ""])
			continue
		var ent := _sample(img, cam, Vector3(x, 3.3, 0))
		var ed: float = maxf(maxf(absf(ent.x - b.x), absf(ent.y - b.y)), absf(ent.z - b.z))
		worst = maxf(worst, ed)
		print("%-18s %-15s %-15s %-15s %.1f%s" % [c[0], _fmt(ent), _fmt(a), _fmt(b), maxf(d, ed),
			"   MISMATCH" if maxf(d, ed) > 3.0 else ""])
	print("worst channel delta: %.1f (8 bit)" % worst)
	get_tree().quit()


# Turn a case's quad, whose normal is +Z, to the half vector between the
# light and the camera, when the case asks for it.
func _face(mi: MeshInstance3D, c: Array, to_light: Vector3, cam_pos: Vector3) -> void:
	if not (c.size() > 7 and c[7]):
		return
	var half := (to_light.normalized() + (cam_pos - mi.position).normalized()).normalized()
	mi.basis = Basis.looking_at(-half)


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
