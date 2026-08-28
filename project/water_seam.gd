# Goanna: offline fixture for the near/far water hand-off.
#
# One sheet of water, split at HANDOFF into a "near mesh" strip and a "far
# tier" strip, each on its own water.gdshader material configured the way
# goanna_client.cpp configures the real ones. The camera looks along the
# sheet toward a low sun, which is the view that shows the hand-off line
# hardest: at grazing angles the surface is nearly all reflection, so any
# difference between the two materials is a hard edge across the frame.
#
# The far strip's floor sits just under its surface, because that is what a
# tier plane does in the world (docs/far-rendering.md, "the far tier water
# plane"), so the absorption discontinuity is reproduced too, not only the
# reflection one.
#
# GOANNA_SHOT names the output directory (default user://). GOANNA_SEAM_OLD=1
# configures the materials the way the client did before the hand-off work
# (far strip waving off, near strip lod_flatten off), for a before shot.
extends Node3D

const HANDOFF := 240.0
const FAR_END := 4000.0
const HALF_W := 3000.0

var shot_dir := "user://"


func _ready() -> void:
	var env_dir := OS.get_environment("GOANNA_SHOT")
	if env_dir != "":
		shot_dir = env_dir
	var old := OS.get_environment("GOANNA_SEAM_OLD") == "1"

	# A sunset: warm horizon, dark zenith, sun low and dead ahead (-Z).
	var sun_dir := Vector3(0.0, 0.05, -1.0).normalized()
	RenderingServer.global_shader_parameter_set("goanna_sky_top",
			Vector3(0.05, 0.09, 0.22))
	RenderingServer.global_shader_parameter_set("goanna_sky_horizon",
			Vector3(0.85, 0.38, 0.14))
	RenderingServer.global_shader_parameter_set("goanna_sun_dir", sun_dir)
	RenderingServer.global_shader_parameter_set("goanna_sun_glow",
			Vector3(1.0, 0.45, 0.18))
	RenderingServer.global_shader_parameter_set("goanna_eye_underwater", 0.0)

	var world_env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	# The backdrop above the waterline, and what a marched ray that hits sky
	# pixels samples: the same horizon colour, in sRGB.
	e.background_color = Color(0.85, 0.38, 0.14).linear_to_srgb()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.4, 0.3, 0.3)
	e.ambient_light_energy = 0.4
	world_env.environment = e
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.62, 0.32)
	sun.light_energy = 1.2
	add_child(sun)
	sun.transform = Transform3D(Basis.looking_at(-sun_dir, Vector3.UP), Vector3.ZERO)

	# Sea floor: deep under the near strip, right under the far strip, which
	# is where a tier plane really sits.
	_add_floor(-6.0, 4.0, HANDOFF, Color(0.35, 0.30, 0.22))
	_add_floor(-0.25, HANDOFF, FAR_END, Color(0.30, 0.28, 0.20))

	var tex := _water_texture()
	var sh: Shader = load("res://shaders/water.gdshader")

	var near_mat := ShaderMaterial.new()
	near_mat.shader = sh
	near_mat.set_shader_parameter("albedo_tex", tex)
	near_mat.set_shader_parameter("waving", true)
	near_mat.set_shader_parameter("lod_flatten", not old)

	var far_mat := ShaderMaterial.new()
	far_mat.shader = sh
	far_mat.set_shader_parameter("albedo_tex", tex)
	far_mat.set_shader_parameter("waving", not old)
	far_mat.set_shader_parameter("lod_flatten", true)

	_add_water(4.0, HANDOFF, near_mat)
	_add_water(HANDOFF, FAR_END, far_mat)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 14.0, 8.0)
	cam.fov = 70.0
	cam.far = 8000.0
	add_child(cam)
	cam.look_at(Vector3(0.0, 0.0, -500.0), Vector3.UP)
	cam.current = true

	_shoot(old)


func _add_floor(y: float, z0: float, z1: float, col: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = _quad(y, z0, z1)
	mi.material_override = mat
	add_child(mi)


func _add_water(z0: float, z1: float, mat: ShaderMaterial) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _quad(0.0, z0, z1)
	mi.material_override = mat
	# One transparent surface must not be culled behind the other at the
	# shared edge; sort each strip by its own centre.
	mi.extra_cull_margin = 16384.0
	add_child(mi)


# A horizontal quad from z = -z0 to z = -z1 (camera looks along -Z), facing
# up, with UV in nodes so the texture tiles per node like a mapblock mesh.
func _quad(y: float, z0: float, z1: float) -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-HALF_W, y, -z0), Vector3(HALF_W, y, -z0),
		Vector3(HALF_W, y, -z1), Vector3(-HALF_W, y, -z1)])
	var uvs := PackedVector2Array([
		Vector2(-HALF_W, -z0), Vector2(HALF_W, -z0),
		Vector2(HALF_W, -z1), Vector2(-HALF_W, -z1)])
	var norms := PackedVector3Array()
	var col := PackedColorArray()
	var uv2 := PackedVector2Array()
	for i in 4:
		norms.append(Vector3.UP)
		col.append(Color.WHITE)
		uv2.append(Vector2.ZERO)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = col
	# Seen from above (+Y): 0,2,1 / 0,3,2 is the front facing winding here,
	# the same lesson material_field.gd's wall learnt.
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


# A small two-blue texture with mipmaps, standing in for the pack's water
# tile; textureLod at the last mip needs the mip chain to exist.
func _water_texture() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGB8)
	for py in 16:
		for px in 16:
			var a := (px / 4 + py / 4) % 2 == 0
			img.set_pixel(px, py,
					Color(0.15, 0.35, 0.55) if a else Color(0.12, 0.30, 0.50))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _shoot(old: bool) -> void:
	for _f in 10:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := shot_dir.path_join("seam_old.png" if old else "seam_new.png")
	img.save_png(path)
	print("wrote ", path)
	get_tree().quit()
