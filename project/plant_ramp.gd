extends Node3D
# Plants close up, through the shader the world draws them with
# (waving_plants.gdshader) and the pack's own maps, the way the material
# ramp judges blocks. Each stem is a plantlike node: two crossed quads,
# standing on a log or on stone, so the plant reads against extruded
# blocks as it does in play. Every case is rendered with the authored
# relief on and off.
#
#   GOANNA_SHOT=<dir> godot --path project plant_ramp.tscn
#
# GOANNA_PLANT_STEMS="a,b,c" picks the stems (default: mushrooms, fern,
# flowers, a sapling), GOANNA_PACK_DIR the textures, GOANNA_TIMES the
# cases (afternoon, low, low_south, lamp), GOANNA_PLANT_SIDE=back views
# the plants from behind, which is the mirrored face of each quad.
# Writes plants_<case>_relief.png and plants_<case>_flat.png.

const CASES := {
	"afternoon": {"sun": 0.40, "azimuth": 0.6},
	"low": {"sun": 0.18, "azimuth": 1.0},
	"low_south": {"sun": 0.18, "azimuth": -1.0},
	"lamp": {"sun": -0.5, "lamp": true},
}
const LOG := "default_jungletree"
# Grass and fern art is grey and tinted by the biome palette in play.
const TINTED := ["mcl_flowers_fern", "mcl_flowers_tallgrass", "mcl_flowers_double_plant_fern_top", "mcl_flowers_double_plant_fern_bottom", "mcl_flowers_double_plant_grass_top", "mcl_flowers_double_plant_grass_bottom"]
const DEFAULT_STEMS := "farming_mushroom_red,farming_mushroom_brown,mcl_flowers_fern,mcl_flowers_poppy,mcl_flowers_tallgrass,mcl_flowers_allium,default_sapling"

var pack_dir := ""
var env: Environment
var sun: DirectionalLight3D
var lamp: OmniLight3D
var cam: Camera3D
var plant_mats: Array[ShaderMaterial] = []


func _tex(stem: String, suffix := "") -> Texture2D:
	var img := Image.new()
	if img.load(pack_dir.path_join(stem + suffix + ".png")) != OK:
		return null
	if img.get_height() > img.get_width():
		# An animated strip: the first frame.
		img = img.get_region(Rect2i(0, 0, img.get_width(), img.get_width()))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _plant_mesh(tint := Color.WHITE) -> ArrayMesh:
	# Luanti's plantlike: two quads on the node's diagonals, UV v = 0 at the
	# top, sky light 255 in CUSTOM0.g as the mesher writes it.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA8_UNORM)
	var h := 0.5 * sqrt(2.0) * 0.5 * sqrt(2.0)
	for diag in [Vector3(1, 0, 1), Vector3(1, 0, -1)]:
		var a: Vector3 = -diag * h
		var b: Vector3 = diag * h
		var c := [a + Vector3(0, 1, 0), b + Vector3(0, 1, 0), b, a]
		var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		var n: Vector3 = (b - a).cross(Vector3.UP).normalized()
		for tri in [[0, 1, 2], [0, 2, 3]]:
			for i in tri:
				st.set_normal(n)
				st.set_uv(uvs[i])
				st.set_color(tint)
				st.set_custom(0, Color(0.0, 1.0, 1.0, 1.0))
				st.add_vertex(c[i] + Vector3(0, -0.5, 0))
	return st.commit()


func _block(stem_top: String, stem_side: String, pos: Vector3) -> void:
	# A block with the pack's albedo and normal on a StandardMaterial3D:
	# only a backdrop, not a judgement of the block.
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.albedo_texture = _tex(stem_side)
	var n := _tex(stem_side, "_n")
	if n:
		mat.normal_enabled = true
		mat.normal_texture = n
	mat.roughness = 0.9
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


func _ready() -> void:
	pack_dir = OS.get_environment("GOANNA_PACK_DIR")
	if pack_dir == "":
		pack_dir = ProjectSettings.globalize_path("res://../pbr_packs/mineclonia/textures")
	var stems_env := OS.get_environment("GOANNA_PLANT_STEMS")
	var stems := (stems_env if stems_env != "" else DEFAULT_STEMS).split(",", false)

	env = Environment.new()
	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color(0.35, 0.55, 0.85)
	sky.sky_horizon_color = Color(0.72, 0.8, 0.9)
	var s := Sky.new()
	s.sky_material = sky
	env.background_mode = Environment.BG_SKY
	env.sky = s
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 4.0
	env.tonemap_exposure = 0.5
	env.ssao_enabled = true
	env.ssao_intensity = 4.0
	env.ssao_radius = 2.2
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	add_child(sun)
	lamp = OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.85, 0.6)
	lamp.omni_range = 12.0
	lamp.omni_attenuation = 1.2
	lamp.shadow_enabled = true
	add_child(lamp)

	var shader: Shader = load("res://shaders/waving_plants.gdshader")
	var mesh := _plant_mesh()
	var spacing := 1.15
	var x0 := -spacing * (stems.size() - 1) * 0.5
	for i in stems.size():
		var stem: String = stems[i].strip_edges()
		var x := x0 + spacing * i
		# Mushrooms grow on the log, the rest on stone.
		var on_log := stem.contains("mushroom")
		_block("", LOG if on_log else "default_stone", Vector3(x, 0, 0))
		var sm := ShaderMaterial.new()
		sm.shader = shader
		sm.set_shader_parameter("albedo_tex", _tex(stem))
		sm.set_shader_parameter("waving", false)
		var n := _tex(stem, "_n")
		var sp := _tex(stem, "_s")
		sm.set_shader_parameter("has_normal", n != null)
		sm.set_shader_parameter("has_spec", sp != null)
		if n:
			sm.set_shader_parameter("normal_tex", n)
		if sp:
			sm.set_shader_parameter("spec_tex", sp)
		plant_mats.append(sm)
		var mi := MeshInstance3D.new()
		mi.mesh = _plant_mesh(Color(0.42, 0.72, 0.3)) if stem in TINTED else mesh
		mi.material_override = sm
		mi.position = Vector3(x, 1, 0)
		add_child(mi)

	cam = Camera3D.new()
	cam.fov = 40
	var back := OS.get_environment("GOANNA_PLANT_SIDE") == "back"
	var dist := 0.58 * spacing * stems.size() + 0.4
	cam.position = Vector3(0, 1.75, -dist if back else dist)
	add_child(cam)
	cam.look_at(Vector3(0, 1.05, 0))
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(0.26, 0.29, 0.33))
	RenderingServer.global_shader_parameter_set("goanna_ground_fill", Vector3(0.12, 0.11, 0.1))
	_run.call_deferred()


func _apply_case(c: Dictionary) -> void:
	var elev: float = c["sun"]
	var hz := sqrt(maxf(1.0 - elev * elev, 0.0))
	var sun_dir := Vector3(hz * c.get("azimuth", 0.6), elev, hz * 0.6).normalized()
	sun.transform = Transform3D(Basis.looking_at(-sun_dir, Vector3.UP), Vector3.ZERO)
	sun.light_energy = 1.0 if elev > 0.0 else 0.0
	sun.visible = elev > 0.0
	sun.light_color = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.62, 0.32), 1.0 - smoothstep(0.0, 0.32, elev))
	RenderingServer.global_shader_parameter_set("goanna_sun_dir", sun_dir)
	lamp.visible = c.get("lamp", false)
	lamp.light_energy = 6.0 if lamp.visible else 0.0
	lamp.position = cam.position + Vector3(0.6, -0.4, -0.5 * signf(cam.position.z))
	env.ambient_light_energy = 0.05 if lamp.visible else 0.42
	RenderingServer.global_shader_parameter_set("goanna_sky_fill",
			Vector3.ZERO if lamp.visible else Vector3(0.26, 0.29, 0.33))


func _run() -> void:
	var dir := OS.get_environment("GOANNA_SHOT")
	var names: Array = CASES.keys()
	if OS.get_environment("GOANNA_TIMES") != "":
		names = Array(OS.get_environment("GOANNA_TIMES").split(",", false))
	for t in names:
		_apply_case(CASES[t])
		for relief in [true, false]:
			for sm in plant_mats:
				sm.set_shader_parameter("relief", relief)
			for i in 30:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			if dir != "":
				var path := dir.path_join("plants_%s_%s.png" % [t, "relief" if relief else "flat"])
				get_viewport().get_texture().get_image().save_png(path)
				print("saved ", path)
	get_tree().quit()
