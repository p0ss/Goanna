extends Node3D

# The water calibration ramp: water.gdshader over a sand bed stepped from
# half a node deep to eight, beside a strip of the same sand left dry, under
# the same sky and lighting recipe as material_ramp.gd, seen from a low bank
# at about thirty degrees down, which is the view in every "the water looks
# like plastic" screenshot.
#
# What it measures, per depth strip: the rendered colour and its HSV
# saturation, next to the dry sand and next to the sky the surface would be
# reflecting. Three things have to be true of water that reads as water:
#
#   1. A shallow over sand is a little darker than the dry sand, never
#      brighter. Light that has already lit the bed once must not be lit a
#      second time on the way out.
#   2. Deep water is dark and no more saturated than the tile is; what
#      colour it has beyond the reflected sky comes from the tile, dimly.
#      Real water bodies are a few percent reflective; a bright saturated
#      body is a painted floor.
#   3. The deep strip's colour moves toward the sky's as the view flattens.
#
# PROBE_OUT=/dir saves water_ramp.png; WATER_OUT=/path.json the numbers.
# GOANNA_WATER_TEX is the water tile (default: Mineclonia's animation strip,
# first frame, from the game as installed; failing that a flat blue).
# GOANNA_BAKED_DIR is the pack, for the sand.
#
# Run: PROBE_OUT=/tmp/w godot --path project water_ramp.tscn

const DEPTHS := [0.5, 1.0, 2.0, 4.0, 8.0]
const STRIP_W := 6.0
const STRIP_L := 24.0

const SKY := {
	"day_sky": Color(0.4745, 0.651, 1.0), "day_horizon": Color(0.7529, 0.8471, 1.0),
}
const EXPOSURE_CORRECTION := 0.35
const SATURATION := 1.1
const BLOOM := 0.05

var env: Environment
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D
var cam: Camera3D
var results := {}


func _envf(name: String, dflt: float) -> float:
	var v := OS.get_environment(name)
	return float(v) if v != "" else dflt


func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _water_texture() -> ImageTexture:
	var path := OS.get_environment("GOANNA_WATER_TEX")
	if path == "":
		path = OS.get_environment("HOME").path_join(
				".var/app/org.luanti.luanti/.minetest/games/mineclone2/textures/mcl_core_water_source_animation.png")
	var img := Image.new()
	if img.load(path) == OK:
		var w := img.get_width()
		var frame := img.get_region(Rect2i(0, 0, w, w))
		frame.convert(Image.FORMAT_RGBA8)
		frame.generate_mipmaps()
		print("WATER tile ", path, " ", w, "px, mean ", _mean(frame))
		return ImageTexture.create_from_image(frame)
	push_warning("water ramp: no water tile at %s, using flat blue" % path)
	img = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.15, 0.35, 0.55))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _mean(img: Image) -> Color:
	var acc := Color(0, 0, 0, 0)
	for y in img.get_height():
		for x in img.get_width():
			acc += img.get_pixel(x, y)
	return acc / float(img.get_width() * img.get_height())


# A flat quad with world space UVs, so the tile repeats per node as it does
# in the world; PlaneMesh would stretch one tile over the whole sheet.
func _sheet(x0: float, x1: float, z0: float, z1: float, y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)]
	# Clockwise seen from above is the front face under cull.
	for tri in [[0, 1, 2], [0, 2, 3]]:
		for i in tri:
			var c: Vector3 = corners[i]
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(c.x, c.z))
			st.set_color(Color.WHITE)
			st.add_vertex(c)
	return st.commit()


func _ready() -> void:
	var baked := OS.get_environment("GOANNA_BAKED_DIR")
	if baked == "":
		baked = ProjectSettings.globalize_path("res://../baked/pack-mineclonia-v2/textures")

	env = Environment.new()
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.42
	env.ambient_light_color = Color(0.72, 0.8, 0.9)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = _envf("GOANNA_WHITE", 4.0)
	env.tonemap_exposure = _envf("GOANNA_EXPOSURE", clamp(0.46 * (1.0 + EXPOSURE_CORRECTION * 0.25), 0.1, 3.0))
	env.adjustment_enabled = true
	env.adjustment_saturation = clamp(1.12 * SATURATION, 0.0, 2.0)
	env.adjustment_contrast = 1.05
	env.adjustment_brightness = 1.0
	env.sdfgi_enabled = true
	env.sdfgi_cascades = 6
	env.sdfgi_min_cell_size = 0.5
	env.sdfgi_energy = _envf("GOANNA_SDFGI", 1.4)
	env.sdfgi_read_sky_light = true
	env.ssao_enabled = true
	env.ssao_intensity = _envf("GOANNA_SSAO", 4.0)
	env.ssao_radius = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 1.0
	env.ssao_light_affect = 0.5
	env.ssil_enabled = true
	env.ssil_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = clamp(0.3 + BLOOM * 2.0, 0.0, 2.0)
	env.fog_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	add_child(sun)

	# Afternoon, sun behind the camera's left shoulder, as lighting_chart's
	# afternoon column has it.
	var elev := _envf("GOANNA_SUN_ELEV", 0.40)
	var h := sqrt(maxf(1.0 - elev * elev, 0.0)) / 0.403
	var sun_dir := Vector3(0.35 * h, elev, 0.2 * h).normalized()
	sun.transform = Transform3D(Basis.looking_at(-sun_dir, Vector3.UP), Vector3.ZERO)
	sun.light_color = Color(1.0, 0.98, 0.94)
	sun.light_energy = _envf("GOANNA_SUN", 1.0)
	sun.shadow_opacity = 0.85
	var zenith: Color = SKY["day_sky"]
	zenith.s = maxf(zenith.s, 0.42)
	zenith.v = minf(zenith.v, 0.92)
	var hor: Color = SKY["day_horizon"]
	sky_mat.set_shader_parameter("sky_top", zenith)
	sky_mat.set_shader_parameter("sky_horizon", hor)
	sky_mat.set_shader_parameter("ground_color", hor.darkened(0.6))
	sky_mat.set_shader_parameter("radiance_ground_lift", 1.0)
	sky_mat.set_shader_parameter("radiance_desaturate", 0.25)
	sky_mat.set_shader_parameter("radiance_floor", Vector3.ZERO)
	sky_mat.set_shader_parameter("sun_dir", sun_dir)
	sky_mat.set_shader_parameter("moon_dir", -sun_dir)
	sky_mat.set_shader_parameter("sun_visible", true)
	sky_mat.set_shader_parameter("moon_visible", false)
	sky_mat.set_shader_parameter("sun_size", 0.045)
	sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	sky_mat.set_shader_parameter("star_opacity", 0.0)
	sky_mat.set_shader_parameter("cloud_coverage", 0.0)
	env.background_energy_multiplier = 0.95
	var fill: Color = hor.lerp(Color(hor.v, hor.v, hor.v), 0.5) * 0.4
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(fill.r, fill.g, fill.b))
	# What main.gd's _apply_sky hands the water for its off screen sky.
	var zl := zenith.srgb_to_linear()
	var hl := hor.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("goanna_sky_top", Vector3(zl.r, zl.g, zl.b))
	RenderingServer.global_shader_parameter_set("goanna_sky_horizon", Vector3(hl.r, hl.g, hl.b))
	RenderingServer.global_shader_parameter_set("goanna_sun_dir", sun_dir)
	var glow := sun.light_color.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("goanna_sun_glow", Vector3(glow.r, glow.g, glow.b))
	RenderingServer.global_shader_parameter_set("goanna_eye_underwater", 0.0)

	# The bed: sand, the pack's own albedo, fully rough.
	var sand := StandardMaterial3D.new()
	var sand_img := Image.new()
	if sand_img.load(baked.path_join("default_sand.png")) == OK:
		sand_img.generate_mipmaps()
		sand.albedo_texture = ImageTexture.create_from_image(sand_img)
		sand.uv1_scale = Vector3(STRIP_W, STRIP_L, 1)
	else:
		sand.albedo_color = Color(0.85, 0.78, 0.6)
	sand.roughness = 1.0
	var total_w := STRIP_W * (DEPTHS.size() + 1)
	# The dry strip stands above the waterline; each wet strip's bed is a box
	# whose top is at minus the depth, and the water sheet at 0 covers them.
	var strips := DEPTHS.duplicate()
	strips.push_front(-0.2)
	for i in strips.size():
		var top: float = -strips[i]
		var box := BoxMesh.new()
		box.size = Vector3(STRIP_W, 10.0, STRIP_L)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = sand
		mi.position = Vector3(i * STRIP_W + STRIP_W * 0.5, top - 5.0, 0.0)
		add_child(mi)
	# Bank behind the camera side, so the depth buffer has ground under the
	# camera and the sheet has an edge to meet.
	var bank := BoxMesh.new()
	bank.size = Vector3(total_w + 40, 10.0, 2.0)
	var bank_mi := MeshInstance3D.new()
	bank_mi.mesh = bank
	bank_mi.material_override = sand
	bank_mi.position = Vector3(total_w * 0.5, -4.5, STRIP_L * 0.5 + 1.0)
	add_child(bank_mi)

	var water := ShaderMaterial.new()
	water.shader = load("res://shaders/water.gdshader")
	water.set_shader_parameter("albedo_tex", _water_texture())
	water.set_shader_parameter("waving", OS.get_environment("GOANNA_WATER_STILL") == "")
	water.set_shader_parameter("lod_flatten", true)
	var sheet := MeshInstance3D.new()
	sheet.mesh = _sheet(STRIP_W, total_w, -STRIP_L * 0.5, STRIP_L * 0.5, 0.0)
	sheet.material_override = water
	add_child(sheet)

	cam = Camera3D.new()
	cam.fov = 50
	var pitch := _envf("GOANNA_PITCH", 30.0)
	var dist := 30.0
	cam.position = Vector3(total_w * 0.5, dist * sin(deg_to_rad(pitch)),
			dist * cos(deg_to_rad(pitch)))
	add_child(cam)
	cam.look_at(Vector3(total_w * 0.5, 0.0, 0.0), Vector3.UP)
	cam.current = true

	for i in 90:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := OS.get_environment("PROBE_OUT")
	if dir != "":
		img.save_png(dir.path_join("water_ramp.png"))
		print("saved ", dir.path_join("water_ramp.png"))

	# The sky at the horizon, as rendered, which is what the sheet reflects
	# at this pitch.
	var hz := _patch_px(img, img.get_width() / 2,
			int(cam.unproject_position(Vector3(total_w * 0.5, 0.0, -2000.0)).y) - 10, 4)
	_report("sky horizon", hz)
	for i in strips.size():
		var label := "dry sand" if i == 0 else "depth %.1f" % strips[i]
		# Two rows down the strip: near the camera and further along the
		# sheet, where the view is flatter.
		for z in [STRIP_L * 0.5 - 4.0, -STRIP_L * 0.5 + 4.0]:
			var p := _patch(img, Vector3(i * STRIP_W + STRIP_W * 0.5, 0.0, z), 6)
			_report("%s %s" % [label, "near" if z > 0 else "far"], p)
	var out := OS.get_environment("WATER_OUT")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(results, "  "))
	get_tree().quit()


func _report(label: String, p: Dictionary) -> void:
	var rgb: Vector3 = p["rgb"]
	var c := Color(rgb.x / 255.0, rgb.y / 255.0, rgb.z / 255.0)
	print("WATER %-16s rgb=%d,%d,%d luma=%.0f sat=%.2f sd=%.1f" % [label, rgb.x, rgb.y, rgb.z, p["luma"], c.s, p["sd"]])
	results[label] = {"rgb": [rgb.x, rgb.y, rgb.z], "luma": p["luma"], "sat": c.s, "sd": p["sd"]}


func _patch(img: Image, world: Vector3, half: int) -> Dictionary:
	var p := cam.unproject_position(world)
	return _patch_px(img, int(p.x), int(p.y), half)


func _patch_px(img: Image, px: int, py: int, half: int) -> Dictionary:
	var acc := Vector3.ZERO
	var l_acc := 0.0
	var l_acc2 := 0.0
	var n := 0
	for dy in range(-half, half + 1):
		for dx in range(-half, half + 1):
			var x := px + dx
			var y := py + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += Vector3(c.r, c.g, c.b) * 255.0
			var l := _luma(c) * 255.0
			l_acc += l
			l_acc2 += l * l
			n += 1
	var mean := l_acc / maxf(n, 1)
	return {"rgb": acc / maxf(n, 1), "luma": mean,
		"sd": sqrt(maxf(l_acc2 / maxf(n, 1) - mean * mean, 0.0))}
