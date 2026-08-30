# Goanna: offline fixture for the dawn orchestration.
#
# Renders the real sky, fog, froxel mist and shaft shaders over a boxy
# stand-in ridge, sweeping the sun through a dawn, twice: once over flat
# terrain (the ridge probe reporting nothing, so every gate sits on the
# false horizon) and once with a ridge toward the sun (the probe reporting
# its true angular height, so the true dawn holds until the crest). The
# point is the ordering the compositional pass demands: the gap around a
# rising sun brightest, the cloud undersides second, the fog and land dark
# until their own beam arrives, and the dome's lower hemisphere reading as
# the same fog wall the terrain dissolves into.
#
# This is a sibling of _apply_sky in main.gd, not the thing itself: it
# feeds the same shaders through the same SkyDirector authorities with
# vanilla-ish server colours, but skips the server-fed state (weather,
# ground tint, far field extents) that needs a live client. Judge the
# composition here; confirm on a server afterwards.
#
# GOANNA_SHOT names the output directory (default user://). Writes
# dawn_<n>_<flat|ridge>.png per elevation in ELEVS and prints one line of
# the director's numbers for each frame. GOANNA_SWEEP_ELEVS (comma
# separated sines) overrides the sweep list, GOANNA_SWEEP_RIDGE=flat|ridge
# runs one variant only, and GOANNA_MIST_GLOW scales the night mist glow,
# all for quick calibration runs.
extends Node3D

const SkyDirector := preload("res://sky_director.gd")

const ELEVS := [-0.30, -0.20, -0.12, -0.06, 0.0, 0.06, 0.12, 0.20]

const RIDGE_D := 560.0
const RIDGE_H := 90.0
const CLOUD_H := 120.0
const EYE_H := 14.0

const DAY_SKY := Color8(97, 181, 245)
const DAY_HORIZON := Color8(144, 211, 246)
const DAWN_SKY := Color8(180, 186, 250)
const DAWN_HORIZON := Color8(186, 193, 240)
const NIGHT_SKY := Color8(15, 20, 40)
const NIGHT_HORIZON := Color8(74, 103, 144)

var shot_dir := "user://"
var elevs: Array = ELEVS
var variants: Array = [false, true]
var glow_scale := 1.0
var world_env: WorldEnvironment
var sky_mat: ShaderMaterial
var atmosphere_mat: ShaderMaterial
var shaft_mat: ShaderMaterial
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var cam: Camera3D


func _ready() -> void:
	var env_dir := OS.get_environment("GOANNA_SHOT")
	if env_dir != "":
		shot_dir = env_dir
	var ev := OS.get_environment("GOANNA_SWEEP_ELEVS")
	if ev != "":
		elevs = []
		for part in ev.split(","):
			elevs.append(float(part))
	var rv := OS.get_environment("GOANNA_SWEEP_RIDGE")
	if rv == "flat":
		variants = [false]
	elif rv == "ridge":
		variants = [true]
	var gv := OS.get_environment("GOANNA_MIST_GLOW")
	if gv != "":
		glow_scale = float(gv)

	world_env = WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	var cloud_noise := FastNoiseLite.new()
	cloud_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	cloud_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	cloud_noise.fractal_octaves = 5
	cloud_noise.frequency = 0.02
	var cloud_tex := NoiseTexture3D.new()
	cloud_tex.width = 128
	cloud_tex.height = 96
	cloud_tex.depth = 128
	cloud_tex.seamless = true
	cloud_tex.normalize = true
	cloud_tex.noise = cloud_noise
	sky_mat.set_shader_parameter("cloud_body_tex", cloud_tex)
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_white = 4.0
	e.tonemap_exposure = 0.46
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.15
	e.adjustment_contrast = 1.05
	e.glow_enabled = true
	e.glow_intensity = 0.3
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_depth_begin = 450.0
	e.fog_depth_end = 900.0
	e.fog_depth_curve = 1.45
	e.fog_density = 0.86
	world_env.environment = e
	add_child(world_env)

	var vol := FogVolume.new()
	vol.shape = RenderingServer.FOG_VOLUME_SHAPE_WORLD
	atmosphere_mat = ShaderMaterial.new()
	atmosphere_mat.shader = load("res://shaders/atmosphere_volume.gdshader")
	atmosphere_mat.set_shader_parameter("mist_level", 18.0)
	atmosphere_mat.set_shader_parameter("cloud_level", CLOUD_H)
	atmosphere_mat.set_shader_parameter("cloud_thickness", 48.0)
	atmosphere_mat.set_shader_parameter("cloud_coverage", 0.5)
	atmosphere_mat.set_shader_parameter("cloud_density", 0.026)
	atmosphere_mat.set_shader_parameter("quality", 1.0)
	vol.material = atmosphere_mat
	add_child(vol)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200
	sun.shadow_normal_bias = 1.6
	sun.shadow_bias = 0.04
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.shadow_enabled = true
	add_child(moon)

	_build_terrain()

	cam = Camera3D.new()
	cam.position = Vector3(0.0, EYE_H, 0.0)
	cam.fov = 70.0
	cam.far = 1400.0
	add_child(cam)
	cam.look_at(Vector3(0.0, EYE_H + 30.0, -RIDGE_D), Vector3.UP)
	cam.current = true

	# The screen space shafts, exactly as main.gd mounts them.
	var shaft_quad := MeshInstance3D.new()
	var shaft_mesh := QuadMesh.new()
	shaft_mesh.size = Vector2(2, 2)
	shaft_quad.mesh = shaft_mesh
	shaft_mat = ShaderMaterial.new()
	shaft_mat.shader = load("res://shaders/light_shafts.gdshader")
	shaft_mat.render_priority = 100
	shaft_quad.material_override = shaft_mat
	shaft_quad.custom_aabb = AABB(Vector3(-5e8, -5e8, -5e8), Vector3(1e9, 1e9, 1e9))
	shaft_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cam.add_child(shaft_quad)

	_sweep()


# A boxy heightfield: a plain, a ridge across the sun's azimuth at
# RIDGE_D with a notch in it, and a few near cubes for scale. Deliberately
# chunky, like far tier terrain.
func _build_terrain() -> void:
	var ground := StandardMaterial3D.new()
	ground.albedo_color = Color(0.30, 0.33, 0.22)
	ground.roughness = 1.0
	var rock := StandardMaterial3D.new()
	rock.albedo_color = Color(0.38, 0.34, 0.28)
	rock.roughness = 1.0
	_box(Vector3(0, -8, -700), Vector3(3000, 16, 3000), ground)
	# The ridge: sixteen 96 node wide segments, heights varying, one notch
	# left near the middle so the disc can peek through a gap the way the
	# reference screenshot's did.
	var seg_w := 96.0
	var heights := [52, 68, 84, RIDGE_H, 74, 30, 88, RIDGE_H, 80, 62, 76, 84, 58, 70, 66, 50]
	for i in heights.size():
		var h: float = heights[i]
		var x := (float(i) - heights.size() / 2.0 + 0.5) * seg_w
		_box(Vector3(x, h / 2.0, -RIDGE_D), Vector3(seg_w, h, 120), rock)
	# Near cubes standing in for trees and huts.
	_box(Vector3(-40, 4, -120), Vector3(10, 8, 10), rock)
	_box(Vector3(30, 6, -180), Vector3(12, 12, 12), rock)
	_box(Vector3(-15, 3, -70), Vector3(6, 6, 6), rock)


func _box(at: Vector3, size: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	add_child(mi)


# The relevant slice of _apply_sky, through the same SkyDirector
# authorities. `ridge_sin` is what the probe would report: zero for the
# flat run, the ridge's true angle for the ridge run.
func _apply(elev: float, use_ridge: bool) -> void:
	var e: Environment = world_env.environment
	var sun_dir := Vector3(0.0, elev, -sqrt(maxf(1.0 - elev * elev, 0.0))).normalized()
	var moon_dir := -sun_dir
	var ridge_sin := 0.0
	var ch := SkyDirector.cloud_horizon(0.0, 0.0, CLOUD_H)
	if use_ridge:
		ridge_sin = (RIDGE_H - EYE_H) / sqrt(RIDGE_D * RIDGE_D + RIDGE_H * RIDGE_H)
		ch = SkyDirector.cloud_horizon(RIDGE_H, RIDGE_D, CLOUD_H)
	var e_ground := elev - ridge_sin
	var e_cloud := elev - ch
	var dome: Dictionary = SkyDirector.bands(elev)
	var land: Dictionary = SkyDirector.bands(e_ground)
	var bs_ground := SkyDirector.beam_strength(e_ground)
	var beam_cloud := SkyDirector.beam(elev, e_cloud)
	var beam_air := SkyDirector.beam(elev, elev + SkyDirector.AIR_LIFT)
	var day: float = land["day"]
	var night: float = dome["night"]
	var dawn: float = dome["dawn"]

	sun.transform = Transform3D(Basis.looking_at(-sun_dir, Vector3.UP), Vector3.ZERO)
	moon.transform = Transform3D(Basis.looking_at(-moon_dir, Vector3.UP), Vector3.ZERO)
	sun.light_color = SkyDirector.beam_tint(elev)
	sun.light_energy = maxf(day, 0.4 * land["dusk_hold"])
	sun.visible = sun.light_energy > 0.01
	var moon_up: float = smoothstep(-0.02, 0.15, moon_dir.y) * (1.0 - day)
	moon.light_energy = 0.3 * moon_up
	moon.visible = moon.light_energy > 0.005

	var day_w: float = clampf(1.0 - dawn - night, 0.0, 1.0)
	var top: Color = DAY_SKY * day_w + DAWN_SKY * dawn + NIGHT_SKY * night
	var hor: Color = DAY_HORIZON * day_w + DAWN_HORIZON * dawn + NIGHT_HORIZON * night
	var zenith: Color = top.darkened(0.15)
	sky_mat.set_shader_parameter("sky_top", zenith)
	sky_mat.set_shader_parameter("sky_horizon", hor)
	sky_mat.set_shader_parameter("ground_curve", 3.0)
	sky_mat.set_shader_parameter("radiance_ground_lift", 1.0)
	sky_mat.set_shader_parameter("radiance_desaturate", 0.25)
	var nh_lum := NIGHT_HORIZON.get_luminance()
	var night_col: Color = NIGHT_HORIZON * (1.0 / nh_lum)
	var floor_col: Color = night_col * (0.045 * night)
	sky_mat.set_shader_parameter("radiance_floor", Vector3(floor_col.r, floor_col.g, floor_col.b))
	sky_mat.set_shader_parameter("sun_dir", sun_dir)
	sky_mat.set_shader_parameter("moon_dir", moon_dir)
	sky_mat.set_shader_parameter("sun_visible", true)
	sky_mat.set_shader_parameter("moon_visible", true)
	sky_mat.set_shader_parameter("sun_size", 0.045)
	sky_mat.set_shader_parameter("moon_size", 0.028)
	sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	sky_mat.set_shader_parameter("star_opacity", 0.85 * night)
	sky_mat.set_shader_parameter("star_density", 0.35)
	sky_mat.set_shader_parameter("cloud_coverage", 0.5)
	sky_mat.set_shader_parameter("cloud_plane_h", CLOUD_H - cam.position.y)
	sky_mat.set_shader_parameter("cloud_thickness", 16.0)
	sky_mat.set_shader_parameter("cloud_beam",
			Vector3(beam_cloud.r, beam_cloud.g, beam_cloud.b))
	sky_mat.set_shader_parameter("air_beam",
			Vector3(beam_air.r, beam_air.g, beam_air.b))
	var cloud_night: float = smoothstep(-0.22, -0.40, e_cloud)
	var cdim: float = lerpf(1.0, 0.16, cloud_night)
	sky_mat.set_shader_parameter("cloud_color",
			Color(cdim, cdim, cdim, 0.78))

	var fog_col: Color = hor
	sky_mat.set_shader_parameter("haze_color", fog_col)
	sky_mat.set_shader_parameter("haze_twilight", maxf(dawn, dome["tw"]))
	sky_mat.set_shader_parameter("ground_color", fog_col.darkened(0.3))
	atmosphere_mat.set_shader_parameter("atmosphere_color", fog_col)
	var mist_cycle := lerpf(0.7, 1.6, clampf(land["night"] + land["dawn"] * 0.6, 0.0, 1.0))
	atmosphere_mat.set_shader_parameter("mist_density", 0.012 * 0.85 * mist_cycle)
	var mist_glow: Color = night_col * (0.24 * glow_scale * land["night"])
	atmosphere_mat.set_shader_parameter("mist_glow",
			Vector3(mist_glow.r, mist_glow.g, mist_glow.b))

	# The server's day night ratio is astronomical; feeding the land's gated
	# day here dimmed the whole dome because a ridge stood in front of the
	# sun, which is exactly the coupling the per layer horizons exist to
	# break. main.gd gets this from the server; the dome's day stands in.
	var ratio: float = dome["day"]
	e.ambient_light_energy = lerpf(0.14, 0.42, maxf(ratio, day))
	# Without these two the Environment defaults (sky_affect 1.0, aerial 0)
	# repainted the whole dome, clouds and all, with the darkened fog
	# colour, which read as a black dawn. main.gd's values at a mid draw
	# distance.
	e.fog_sky_affect = 0.3
	e.fog_aerial_perspective = 0.3 * maxf(day, land["dawn"] * 0.65)
	e.background_energy_multiplier = lerpf(0.25, 0.95, ratio)
	e.fog_light_color = fog_col * e.background_energy_multiplier * lerpf(1.0, 0.5, night)

	var low: float = 1.0 - clampf(maxf(elev, 0.0) / 0.35, 0.0, 1.0)
	var air: float = (0.0007 + 0.0023 * low) * (0.25 + 0.75 * day)
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = air
	e.volumetric_fog_albedo = Color(1.0, 0.98, 0.95)
	e.volumetric_fog_anisotropy = 0.8
	e.volumetric_fog_length = 500.0
	e.volumetric_fog_detail_spread = 1.8
	e.volumetric_fog_ambient_inject = 0.9
	e.volumetric_fog_gi_inject = 0.4
	e.volumetric_fog_sky_affect = 0.30
	sun.light_volumetric_fog_energy = 2.4
	moon.light_volumetric_fog_energy = 0.15
	e.fog_sun_scatter = clampf((0.15 + 0.35 * land["dawn"]) * bs_ground, 0.0, 1.0)

	var sun_glow: Color = sun.light_color.srgb_to_linear() * bs_ground
	RenderingServer.global_shader_parameter_set("goanna_sun_dir", sun_dir)
	RenderingServer.global_shader_parameter_set("goanna_sun_glow",
			Vector3(sun_glow.r, sun_glow.g, sun_glow.b))
	shaft_mat.set_shader_parameter("shaft_strength", 0.55 * 0.6 * low)

	print("SWEEP ", JSON.stringify({"elev": elev, "ridge": use_ridge,
		"e_ground": e_ground, "e_cloud": e_cloud, "bs_ground": bs_ground,
		"beam_cloud": beam_cloud.get_luminance(), "beam_air": beam_air.get_luminance(),
		"day": day, "dawn_dome": dawn, "night_dome": night}))


func _sweep() -> void:
	# The 3D noise texture builds on a thread; give it and the froxel
	# grid's temporal blend time to settle before the first frame.
	for _f in 30:
		await RenderingServer.frame_post_draw
	for use_ridge in variants:
		for i in elevs.size():
			_apply(elevs[i], use_ridge)
			for _f in 14:
				await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var name := "dawn_%02d_%s.png" % [i, "ridge" if use_ridge else "flat"]
			var path := shot_dir.path_join(name)
			img.save_png(path)
			print("wrote ", path)
	get_tree().quit()
