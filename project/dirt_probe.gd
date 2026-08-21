extends Node3D

# One-off probe: does entity.gdshader show visible relief from the REAL
# baked default_dirt_n.png/_s.png, in complete isolation from the world
# (no SDFGI, no ambient, no sky, no distance/mip confounds)? material_probe.gd
# already proved the shader's LabPBR decode matches Godot's own material for
# synthetic 1x1 swatches; this feeds it the actual file DeepBump produced,
# because docs/pbr-plan.md's own instruments section is explicit that no
# conclusion here has ever survived being read off a world screenshot.
#
# Three quads, same light, same albedo:
#   left:   entity.gdshader, has_normal=false (flat) -- the "definitely no
#           bump" baseline
#   centre: entity.gdshader, has_normal=true, fed the real default_dirt_n.png
#   right:  StandardMaterial3D with Godot's OWN normal mapping, fed the same
#           file -- if even this shows nothing, the data itself is too weak
#           to read here, not our shader
#
# Run: godot --path project dirt_probe.tscn

const BAKED_DIR := "/tmp/claude-1000/-var-home-poss-Documents-Code-Godot-goanna/a67327f1-51f2-48d8-8e26-89a6d982a42b/scratchpad/baked_bulk"


func _load(name: String) -> ImageTexture:
	var img := Image.new()
	var err := img.load(BAKED_DIR.path_join(name))
	if err != OK:
		push_error("failed to load %s: %d" % [name, err])
		return null
	return ImageTexture.create_from_image(img)


func _quad() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _ready() -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0, 0, 0)
	e.ambient_light_energy = 0.0
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.ssao_enabled = false
	e.ssil_enabled = false
	e.sdfgi_enabled = false
	e.glow_enabled = false
	e.fog_enabled = false
	e.adjustment_enabled = false
	var we := WorldEnvironment.new()
	we.environment = e
	add_child(we)

	var albedo := _load("default_dirt_albedo.png")
	var normal := _load("default_dirt_n.png")
	var spec := _load("default_dirt_s.png")

	# left: flat, no normal at all
	var flat_sm := ShaderMaterial.new()
	flat_sm.shader = load("res://shaders/entity.gdshader")
	flat_sm.set_shader_parameter("albedo", albedo)
	flat_sm.set_shader_parameter("has_normal", false)
	flat_sm.set_shader_parameter("has_spec", false)
	var flat_mi := MeshInstance3D.new()
	flat_mi.mesh = _quad()
	flat_mi.material_override = flat_sm
	flat_mi.position = Vector3(-2.6, 0, 0)
	add_child(flat_mi)

	# centre: our shader, real baked normal+spec
	var real_sm := ShaderMaterial.new()
	real_sm.shader = load("res://shaders/entity.gdshader")
	real_sm.set_shader_parameter("albedo", albedo)
	real_sm.set_shader_parameter("normal_tex", normal)
	real_sm.set_shader_parameter("spec_tex", spec)
	real_sm.set_shader_parameter("has_normal", true)
	real_sm.set_shader_parameter("has_spec", true)
	var real_mi := MeshInstance3D.new()
	real_mi.mesh = _quad()
	real_mi.material_override = real_sm
	real_mi.position = Vector3(0, 0, 0)
	add_child(real_mi)

	# right: Godot's own StandardMaterial3D normal mapping, same file
	var ref := StandardMaterial3D.new()
	ref.albedo_texture = albedo
	ref.roughness = 0.05  # matches default_dirt's baked smoothness (~5%)
	ref.set_feature(BaseMaterial3D.FEATURE_NORMAL_MAPPING, true)
	ref.normal_texture = normal
	ref.normal_scale = 1.0
	var ref_mi := MeshInstance3D.new()
	ref_mi.mesh = _quad()
	ref_mi.material_override = ref
	ref_mi.position = Vector3(2.6, 0, 0)
	add_child(ref_mi)

	var light := DirectionalLight3D.new()
	# steep raking angle: roughness/bump differences vanish head-on, this is
	# the same reasoning material_probe.gd uses for its own light
	light.rotation_degrees = Vector3(-15, -60, 0)
	light.light_energy = 2.5
	light.shadow_enabled = false
	add_child(light)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4)
	cam.current = true
	add_child(cam)

	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := OS.get_environment("PROBE_OUT")
	if path != "":
		img.save_png(path)
		print("saved ", path)
	get_tree().quit()
