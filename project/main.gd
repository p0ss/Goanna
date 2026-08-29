extends Node3D

var client: GoannaClient
var ui: CanvasLayer
var cam: Camera3D
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var env: WorldEnvironment
var sky_mat: ShaderMaterial
var atmosphere_volume: FogVolume
var atmosphere_mat: ShaderMaterial
var sky_tex_cache := {}
var cloud_off := Vector2.ZERO
# The sky hands these to the node shaders' cloud shadows each frame.
var cloud_cov := 0.0
var cloud_shadow_k := 0.0
# Coverage inferred from the rain itself, eased so a front rolls in over
# seconds rather than snapping. Mineclonia greys the cloud colour during
# rain but never raises the density, so without this it rained out of the
# same scattered fair-weather cumulus as a clear day.
var storm_cover := 0.0
var sun_par := Vector2.ZERO
var bounce: DirectionalLight3D
# The smoothed colour of the terrain around the camera (client.ground_albedo),
# sampled twice a second and eased over a few seconds so crossing a biome
# boundary drifts the bounce and the ground fill rather than snapping them.
# Starts at the old fixed earth constant, which is also what it falls back to
# before any blocks answer.
var ground_tint := Color(0.62, 0.55, 0.44)
var ground_tint_raw := Color(0.62, 0.55, 0.44)
var ground_tint_timer := 0.0
# How rained-on the world is, 0 to 1, fed to the goanna_wetness shader
# global: rises during rain and drains slowly after, see _apply_sky.
var wetness := 0.0
# The terrain height under the camera, from client.ground_height, sampled on
# the ground tint's clock and held at its last answer while flying too high
# for the scan to reach. The haze layer is anchored to it, so the depth fog
# thins as the camera climbs instead of drowning the map from altitude.
var terrain_ref := 0.0
var cloud_speed := Vector2(-2.0, 0.0)
var cloud_height := 120.0
var cloud_thickness := 16.0
var atmosphere_ground := 0.0
var atmosphere_ground_set := false
var atmosphere_length := 512.0
var t := 0.0
var last_print := -1.0
var placed := false
var yaw := 0.0
var pitch := 0.0
var speed := 12.0
# Look controls, set from the settings panel (game_ui) and saved in goanna.cfg.
var mouse_sensitivity := 0.15
var invert_mouse := false
var view_bobbing := 1.0        # walk-cycle camera bob, 0 = off
# Lighting levels, seeded from GOANNA_SUN/AMBIENT/SDFGI/SSAO/WHITE/EXPOSURE/
# SKY_FILL and then settable live from the Lighting settings tab. The values
# are the recipe settled on project/lighting_chart.tscn on 2026-08-21
# (docs/pbr-plan.md step 3): sun 1.0 and white 4.0 with exposure 0.46 put a
# sunlit stone top at 1.28 times its albedo and snow at 229 with no clipping,
# where 1.5, 1.5 and 1.0 had put stone at 1.87 times and snow flat white;
# the sky fill lifts a wall at noon from 0.18 of the top to 0.38.
var light_sun := 1.0
var light_ambient := 1.0
var light_sdfgi := 1.4
var light_sdfgi_cell := 0.5
var light_pool := 96.0
var light_ssao := 4.0
var light_white := 4.0
# Base exposure; the server's exposure_correction multiplies it in _apply_sky.
var light_exposure := 0.46
# Sky fill strength: Luanti's sky light added by the node shaders as a flat
# fill in the horizon colour (nodes_array_common.gdshaderinc). 0 turns it off.
var light_fill := 0.4
# Light shafts: how much of the sun's light scatters out of the air on its
# way past, and so how visible the shafts through a canopy or a gap are. A
# multiplier on what the server asks for, not a replacement; 0 turns the
# volume off and leaves the flat distance fog alone.
var light_shafts := 1.0
# Cost and reach of the shared atmospheric froxel volume. Zero leaves only
# the inexpensive sky and horizon fade.
var atmosphere_quality := 1.0
# The background layer's shape (docs/far-rendering.md, "Background, overlay,
# foreground"), swept with GOANNA_FOG_CLEAR and GOANNA_FOG_CURVE. The fraction
# of the drawn distance that stays clear of haze, and the exponent on the ramp
# over the rest: above 1 the haze holds off and then closes near the edge,
# below 1 it starts early and rises slowly.
var fog_clear_fraction := 0.40
var fog_curve := 1.45
# How opaque the haze is allowed to get at the drawn edge. Below 1 on purpose:
# see the note where fog_density is set. GOANNA_FOG_MAX sweeps it. 0.86 lets
# the last ridge dissolve into the haze with only a ghost of a silhouette,
# which is how a real horizon ends; 0.70 left the drawn edge visible as an
# edge, and 0.92 with an early start washed the whole day into pastel.
var fog_max := 0.86
# Coverage arrives in rectangular summary areas and LOD regions. Driving the
# atmosphere directly from each frame's quartiles made the whole horizon pump
# as one area arrived or changed owner. These are eased presentation values;
# geometry remains governed by the exact scheduler state.
var fog_draw_smoothed := 0.0
var fog_begin_smoothed := 0.0
# How broad the haze band below the horizon line is, sky.gdshader's
# ground_curve: the background terrain has not arrived over.
var sky_ground_curve := 3.0
var _bob_phase := 0.0
var shots_done := false
var _chat_sent := false
var chest_opened := false
var fly_mode := false
var walk_started := false
var dig_down := false
var place_down := false
var place_pressed := false
var wield := 0
var selection_box: MeshInstance3D
var pointed: Dictionary = {}
var _prune_timer := 2.0
var last_move: Dictionary = {}   # last step_player result, read by the audio layer
var swing_t := 1.0
var wield_dig_active := false
var test_dig := false
var test_plc_pressed := false
var mob_target_id := -1
var mob_last_pos := Vector3.ZERO
var inv_before := {}
var fall_reported := false
var underwater := false
var headlight: OmniLight3D
# The fixture runner zeroes the head light for determinism; this stops the
# per frame carried light update from turning it back on.
var headlight_auto := true
var iris: GoannaIrisEffect
var test_started := 0.0
var showcase_mode := false
var showcase_placed := false
# project/bench.gd when GOANNA_BENCH is set: the per frame recorder and
# the scripted route. Null in an ordinary session, so every use is guarded.
var bench: Node = null
# The profile this machine would open on, worked out in
# _apply_hardware_defaults and read by the settings panel so it can say when
# a stored config is below what the hardware could do.
var hardware_profile := "balanced"
const GraphicsProfiles := preload("res://graphics_profiles.gd")

# Named live-server fixtures bind the whole visual-test state together. These
# coordinates match goanna_visual_test_mod. Add a new site there and here as
# one change, rather than composing an unrecorded GOANNA_TP/TOD/VIEW command.
const VISUAL_TESTS := {
	# A lantern hanging under an overhang. Run it with Shadow casting lamps at 0
	# and again at 32: a lantern is a solid node, so without a shadow map its
	# light passes through itself and the overhang directly above it glows.
	# Measured 17.3 against 4.6, a 3.7x brightening of a surface with no lamp
	# having moved or changed.
	"eaves": {
		"server_position": Vector3(5120.0, 65.0, -14.0),
		"camera_start": Vector3(5114.0, 67.0, -12.0),
		"camera_step": Vector3(0.5, 0.0, 0.0),
		"steps": 24,
		"pitch": 10.0,
		"yaw": 180.0,
		"time_of_day": 0.5,
		"warm_frames": 20,
	},
	# Walks from the subject lamps toward sixty decoys. Crossing the
	# forty-eighth nearest lamp evicts the subject's own lamps from the pool, so
	# the wall the camera is looking at loses its light without anything in the
	# world having changed. That is the village symptom, reproduced.
	"light_pool": {
		"server_position": Vector3(4070.0, 65.0, -6.0),
		"camera_start": Vector3(4074.0, 70.0, -14.0),
		"camera_step": Vector3(0.5, 0.0, 0.0),
		"steps": 45,
		"pitch": -8.0,
		"yaw": 150.0,
		"time_of_day": 0.5,
		"warm_frames": 20,
	},
	"lighting_walk": {
		"server_position": Vector3(-4.0, 65.0, -16.0),
		"camera_start": Vector3(-4.0, 66.625, -16.0),
		"camera_step": Vector3(0.5, 0.0, 0.0),
		"steps": 17,
		"pitch": -5.0,
		"yaw": 180.0,
		"time_of_day": 0.5,
		"warm_frames": 60,
	},
}

func _ready() -> void:
	showcase_mode = OS.get_environment("GOANNA_SHOWCASE") != ""
	add_to_group("goanna_main")  # game_ui updates look controls through this group
	var cfg := ConfigFile.new()
	if cfg.load("user://goanna.cfg") == OK:
		mouse_sensitivity = float(cfg.get_value("settings", "mouse_sensitivity", mouse_sensitivity))
		invert_mouse = bool(cfg.get_value("settings", "invert_mouse", invert_mouse))
		view_bobbing = float(cfg.get_value("settings", "view_bobbing", view_bobbing))
	light_sun = _envf("GOANNA_SUN", light_sun)
	light_ambient = _envf("GOANNA_AMBIENT", light_ambient)
	light_sdfgi = _envf("GOANNA_SDFGI", light_sdfgi)
	light_sdfgi_cell = _envf("GOANNA_SDFGI_CELL", light_sdfgi_cell)
	light_pool = _envf("GOANNA_LIGHT_POOL", light_pool)
	light_ssao = _envf("GOANNA_SSAO", light_ssao)
	light_white = _envf("GOANNA_WHITE", light_white)
	light_exposure = _envf("GOANNA_EXPOSURE", light_exposure)
	light_fill = _envf("GOANNA_SKY_FILL", light_fill)
	light_shafts = _envf("GOANNA_SHAFTS", light_shafts)
	atmosphere_quality = _envf("GOANNA_ATMOSPHERE", atmosphere_quality)
	fog_clear_fraction = _envf("GOANNA_FOG_CLEAR", fog_clear_fraction)
	fog_curve = _envf("GOANNA_FOG_CURVE", fog_curve)
	fog_max = _envf("GOANNA_FOG_MAX", fog_max)
	sky_ground_curve = _envf("GOANNA_GROUND_CURVE", sky_ground_curve)
	if cfg.load("user://goanna.cfg") == OK:
		atmosphere_quality = float(cfg.get_value("settings", "atmosphere_quality", atmosphere_quality))
		for k in ["sun", "ambient", "sdfgi", "sdfgi_cell", "ssao", "white", "exposure", "fill", "shafts"]:
			if cfg.has_section_key("settings", "light_" + k):
				set("light_" + k, float(cfg.get_value("settings", "light_" + k)))
	client = GoannaClient.new()
	if OS.get_environment("GOANNA_SHADOW_LAMPS") != "":
		client.set_shadow_lamps(int(OS.get_environment("GOANNA_SHADOW_LAMPS")))
	add_child(client)
	_apply_hardware_defaults()
	# In-game UI (HUD, chat, inventory, formspecs, pause menu): project/ui/.
	# Guarded, because a script error anywhere in the UI leaves this node
	# without its script, and assigning to a property it no longer has aborts
	# the rest of _ready. That meant the camera below was never created and
	# the world never rendered, so a UI parse error presented as a grey
	# screen with the only visible complaint coming from _process.
	ui = preload("res://ui/game_ui.tscn").instantiate()
	if "client" in ui:
		ui.client = client
	else:
		push_error("game_ui failed to load its script; running without a UI")
		ui = null
	if ui:
		add_child(ui)
		if showcase_mode:
			ui.visible = false
	if OS.get_environment("GOANNA_PERF") != "":
		# Uncapped: with vsync on, every measurement reads as the refresh rate
		# and says nothing about headroom.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# GOANNA_VIEW_RANGE=<blocks>: set the streamed view range for perf runs,
	# so the draw-call curve can be measured without the settings UI.
	if OS.get_environment("GOANNA_VIEW_RANGE") != "":
		client.set_view_range(int(OS.get_environment("GOANNA_VIEW_RANGE")))
	if OS.get_environment("GOANNA_LOD") != "":
		client.set_lod_distance(int(OS.get_environment("GOANNA_LOD")))
	if OS.get_environment("GOANNA_LOD_CELL") != "":
		client.set_lod_cell(int(OS.get_environment("GOANNA_LOD_CELL")))
	print(client.hello())
	print(client.luanti_version())

	cam = Camera3D.new()
	cam.fov = 70
	cam.far = 1000
	add_child(cam)
	cam.current = true
	_report_fov()
	# And again whenever the window changes shape: the horizontal angle grows
	# with the aspect, and a window dragged wider after startup was otherwise
	# still reported at its old width, so the server culled the new edges.
	get_viewport().size_changed.connect(_report_fov)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200
	# Bevel chamfers meet the light at grazing angles; raise the normal bias
	# and soften the blend so the shadow edge does not flicker/acne on them.
	# Bias is a trade: too high erases the contact shadows that make a blocky
	# world read as lit, too low gives acne stripes on lit faces. Precision
	# (8192 map, 32-bit depth, set in project.godot) is what actually buys the
	# headroom, so a modest bias is enough. Blended splits stop the shadow
	# edge popping as cascades change while you move.
	sun.shadow_normal_bias = 1.6
	sun.shadow_bias = 0.04
	sun.shadow_blur = 1.0
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.9
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_energy = 0.0
	moon.light_color = Color(0.6, 0.7, 1.0)
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 200
	moon.shadow_normal_bias = 1.6
	moon.shadow_bias = 0.04
	moon.directional_shadow_blend_splits = true
	add_child(moon)

	# The bounce: ground light thrown back up, a dim wide light shining
	# upward biased away from the sun, in an earthy colour. Where SDFGI is
	# on it is nearly redundant (real bounce exists) and runs at a third;
	# where SDFGI is off it is the only light a ceiling or an eave ever
	# gets. No shadows: bounce light is soft by nature.
	bounce = DirectionalLight3D.new()
	bounce.light_energy = 0.0
	bounce.shadow_enabled = false
	bounce.light_color = Color(0.62, 0.55, 0.44)
	add_child(bounce)

	env = WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/sky.gdshader")
	sky_mat = sm
	# The 3D body the volumetric cumulus march samples (sky.gdshader,
	# cloud_density). A texture fetch is what makes 24 steps a pixel
	# affordable; seamless so the slab tiles, with the weather field breaking
	# the repetition. Generation is threaded and the march just sees no
	# density until it lands.
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
	sm.set_shader_parameter("cloud_body_tex", cloud_tex)
	sky.sky_material = sm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# The exposure was decided on project/lighting_chart.tscn, 2026-08-21,
	# by the numbers in docs/pbr-plan.md step 3: it used to be too hot
	# (sunlit stone of albedo 131 rendered at 207, snow and sea lanterns
	# clipped to flat white with every texel gone), and the fix is sun 1.0,
	# ACES white 4.0 and a base exposure of 0.46 (light_sun, light_white,
	# light_exposure above). What the chart could not fix by exposure is
	# walls: SDFGI gives a vertical face about 0.27 of a horizontal face's
	# ambient, so with the sun overhead a wall cannot reach a third of the
	# top's brightness whatever the energy, and the node shaders add a sky
	# fill from Luanti's own sky light instead (light_fill; see
	# nodes_array_common.gdshaderinc). The sky shader also feeds lighting a
	# different radiance from what it shows (radiance_* in sky.gdshader): the
	# lower half of the dome as the horizon colour rather than a darkened
	# ground, a quarter desaturated so shadow is less blue (half greyed the
	# sky that water and metal reflect for little gain on the chart), and a
	# dim floor at night so a black sky still lights the world the way
	# Luanti's does.
	#
	# GOANNA_AMBIENT does nothing, and cannot be made to while sdfgi_enabled
	# is true below. Measured with project/lighting_chart.gd, which renders
	# this same recipe with no world attached, sampling a dirt wall in a
	# roofed bay (values are srgb8, sun at midday):
	#
	#   sdfgi on:  sky_contribution 1.0 / ambient 0.42 -> 30, 22, 19
	#              sky_contribution 0.0 / ambient 0.0  -> 30, 22, 19
	#              sky_contribution 0.0 / ambient 3.0  -> 30, 22, 19
	#   sdfgi off: sky_contribution 0.0 / ambient 0.0  ->  0,  0,  0
	#              sky_contribution 0.0 / ambient 3.0  -> 110, 93, 79
	#              sky_contribution 1.0 / ambient 3.0  -> 25, 23, 26
	#
	# So two separate things gate it, and the second is the one that bites.
	# Below full sky contribution the flat ambient_light_color * energy term
	# blends in as documented, which is the sdfgi-off rows. But SDFGI
	# replaces environment ambient outright for the geometry it covers, so
	# with it on the whole ambient block is inert at any setting. An earlier
	# pass here set sky_contribution to 0.5 and gave ambient_light_color the
	# horizon colour, on the theory that the default of 1.0 was the only
	# thing keeping GOANNA_AMBIENT dead. The chart says that changes nothing:
	# both lines are reverted rather than left in looking load bearing.
	#
	# The levers that do reach a shadowed surface are sdfgi_energy (1.4 ->
	# 3.0 took that same wall from 30, 22, 19 to 57, 47, 43), ssil_intensity
	# (turning SSIL off at sdfgi 3.0 lifted it further to 81, 66, 59, so it
	# is costing indirect light here rather than adding it) and
	# sdfgi_read_sky_light, which is what actually carries sky colour into
	# shadow: off, the same wall falls to 14, 5, 0. None of that is retuned
	# here yet, only measured.
	e.ambient_light_energy = light_ambient # a starting value; _apply_sky owns it
	# AGX is deliberately desaturating: side by side with the vanilla client
	# (which does not tonemap at all) it turned Luanti's punchy greens grey.
	# ACES keeps saturation and contrast, which is the look this client is for.
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_white = light_white
	e.tonemap_exposure = light_exposure
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.15
	e.adjustment_contrast = 1.05
	e.adjustment_brightness = 1.0
	# GOANNA_NO_SDFGI=1 disables it outright. Setting Bounced light to 0 only
	# zeroes sdfgi_energy, which leaves SDFGI enabled and still overriding the
	# ordinary ambient path, so it is not a way to test life without it.
	# And energy 0 now disables it outright: an enabled SDFGI at zero energy
	# is the darkest possible configuration, still overriding ambient while
	# contributing nothing, and a profile was found running that way after a
	# slider sweep.
	e.sdfgi_enabled = OS.get_environment("GOANNA_NO_SDFGI") == "" and light_sdfgi > 0.01
	e.sdfgi_cascades = 6
	# GOANNA_SDFGI_CELL: cascade 0's cell size, which also sets how far each
	# cascade reaches and therefore how often the whole grid re-centres on the
	# camera. Small cells give finer bounced light and a smaller cascade, so
	# the grid re-centres constantly as the player walks and everything it
	# lights changes with it: measured at 0.5 as an irregular jump in shading
	# every few steps, worst step 3.6 times the smallest, against a smooth
	# ratio of 1.06 with SDFGI off entirely.
	e.sdfgi_min_cell_size = light_sdfgi_cell
	e.sdfgi_energy = light_sdfgi
	e.ssao_enabled = OS.get_environment("GOANNA_NO_SSAO") == ""
	e.ssao_intensity = light_ssao
	e.ssao_radius = 2.2
	e.ssao_power = 1.6
	e.ssao_detail = 1.0
	# The same mapping as apply_lighting, which owns this from then on.
	e.ssao_light_affect = clampf(light_ssao * 0.09, 0.0, 0.72)
	e.ssil_enabled = OS.get_environment("GOANNA_NO_SSIL") == ""
	e.ssil_intensity = 1.4
	e.glow_enabled = true
	e.glow_intensity = 0.3
	e.fog_enabled = true
	e.fog_light_color = Color(0.72, 0.80, 0.90)
	# Aerial perspective blends distant geometry toward the sky colour; at 0.5
	# it laid a milky veil over the whole view and desaturated mid-distance
	# terrain. Keep a little for depth, not a haze.
	e.fog_density = 0.0004
	e.fog_sky_affect = 0.1
	e.fog_aerial_perspective = 0.12
	env.environment = e
	add_child(env)
	# One world-sized fog volume supplies spatial density to the environment's
	# froxel grid. It adds no scene geometry or per-cloud objects: valleys and
	# the cloud body are two density bands in one shader.
	atmosphere_volume = FogVolume.new()
	atmosphere_volume.shape = RenderingServer.FOG_VOLUME_SHAPE_WORLD
	atmosphere_mat = ShaderMaterial.new()
	atmosphere_mat.shader = load("res://shaders/atmosphere_volume.gdshader")
	atmosphere_volume.material = atmosphere_mat
	add_child(atmosphere_volume)
	# Subtle head-light so caves are navigable rather than pitch black. Short
	# range and low energy, so it is negligible against daylight but lets you
	# see a few nodes underground. (A proper fix would feed Luanti's baked node
	# light as an ambient floor.)
	headlight = OmniLight3D.new()
	headlight.light_energy = 0.5
	headlight.omni_range = 9.0
	headlight.light_color = Color(1.0, 0.96, 0.9)
	headlight.shadow_enabled = false
	add_child(headlight)

	# GOANNA_SHADERPACK=/path/to/pack: run an Iris or OptiFine shader pack's
	# screen space chain (deferred, composite, final) as a CompositorEffect.
	# The gbuffers programs are not run; see docs/iris-compat.md.
	var shaderpack := OS.get_environment("GOANNA_SHADERPACK")
	if shaderpack != "":
		iris = GoannaIrisEffect.new()
		if OS.get_environment("GOANNA_SHADERPACK_DUMP") != "":
			iris.set_dump_dir(OS.get_environment("GOANNA_SHADERPACK_DUMP"))
		if OS.get_environment("GOANNA_SHADERPACK_RAW") != "":
			iris.set_bridge_colour(false)
		if iris.load_pack(shaderpack):
			var comp := Compositor.new()
			comp.compositor_effects = [iris]
			env.compositor = comp
			# A pack's final program is the finished image: it has done its own
			# exposure and tonemap, so Godot's must step aside or it is applied
			# twice. The effect decodes the pack's output back to linear for
			# the sRGB stage. GOANNA_SHADERPACK_RAW=1 keeps Godot's tonemap and
			# hands the pack linear HDR instead, for comparison.
			if iris.has_final() and iris.get_bridge_colour():
				env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
				env.environment.tonemap_white = 1.0
				env.environment.tonemap_exposure = 1.0
			print("shader pack ", iris.pack_name(), " ", iris.report())
		else:
			print("shader pack failed to load: ", iris.report())
			iris = null

	# GOANNA_MAT="channel=value,channel=value": set material strength channels
	# at startup, so a headless run can put one of them in a state the settings
	# panel would otherwise be needed for. Names are the ones
	# GoannaClient::set_material_strength accepts.
	if OS.get_environment("GOANNA_MAT") != "":
		for pair in OS.get_environment("GOANNA_MAT").split(",", false):
			var kv := pair.split("=")
			if kv.size() == 2:
				client.set_material_strength(kv[0].strip_edges(), float(kv[1]))
				print("material strength ", kv[0].strip_edges(), " = ", float(kv[1]))

	var host := OS.get_environment("GOANNA_HOST")
	if host == "":
		host = "127.0.0.1"
	var port := int(OS.get_environment("GOANNA_PORT")) if OS.get_environment("GOANNA_PORT") != "" else 30000
	var pname := OS.get_environment("GOANNA_NAME")
	if pname == "":
		pname = "goanna"
	# A directory searched by filename before the server's own media, LabPBR
	# _n and _s companions included. This is Luanti's own texture_path
	# override, exposed by set_texture_path. Settings panel writes
	# settings/texture_pack; GOANNA_PACK overrides it for a headless run.
	# Either way it has to be set before connect_to, because texture requests
	# start as soon as the session does.
	var pack := OS.get_environment("GOANNA_PACK")
	if pack == "" and cfg.load("user://goanna.cfg") == OK:
		pack = str(cfg.get_value("settings", "texture_pack", ""))
	# A name map lets that pack be an unmodified Minecraft resource pack, whose
	# files are named nothing like a Luanti game's. Without one, only a pack
	# already using this game's names does anything.
	var tmap := OS.get_environment("GOANNA_TEXTURE_MAP")
	if tmap == "" and cfg.load("user://goanna.cfg") == OK:
		tmap = str(cfg.get_value("settings", "texture_map", ""))
	# Without a choice, the bundled map for the game being launched, when
	# there is one (project/texture_maps/<game>.csv). The launcher sets
	# GOANNA_GAME for a local world; a remote server's game is unknown. The
	# session reads the file by path, and res:// is not a path once exported,
	# so the map is copied under user:// first.
	if tmap == "" and OS.get_environment("GOANNA_GAME") != "":
		var bundled := "res://texture_maps/%s.csv" % OS.get_environment("GOANNA_GAME")
		if FileAccess.file_exists(bundled):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://texture_maps"))
			var copy := "user://texture_maps/%s.csv" % OS.get_environment("GOANNA_GAME")
			var src_f := FileAccess.open(bundled, FileAccess.READ)
			var dst_f := FileAccess.open(copy, FileAccess.WRITE)
			if src_f and dst_f:
				dst_f.store_buffer(src_f.get_buffer(src_f.get_length()))
				dst_f = null
				tmap = ProjectSettings.globalize_path(copy)
	if tmap != "" and FileAccess.file_exists(tmap):
		client.set_texture_map(tmap)
		print("texture map ", tmap)
	# The local block store (docs/far-rendering.md rung 5): every block the
	# server sends is kept under the user directory, per server, and drawn as
	# far tiers beyond the live range when the server grants far rendering.
	# GOANNA_STORE=<dir> relocates it, GOANNA_NO_STORE=1 turns it off.
	if OS.get_environment("GOANNA_NO_STORE") == "":
		var store_root := OS.get_environment("GOANNA_STORE")
		if store_root == "":
			store_root = ProjectSettings.globalize_path("user://goanna_store")
		client.set_store_path(store_root)
		if OS.get_environment("GOANNA_FAR_DISTANCE") != "":
			client.set_far_distance(int(OS.get_environment("GOANNA_FAR_DISTANCE")))
	if pack != "":
		client.set_texture_path(pack)
		print("texture pack ", pack)
	else:
		print("no texture pack set (settings panel, or GOANNA_PACK)")
	print("connecting to ", host, ":", port, " as ", pname)
	# Something on screen from the first frame: joining a large public server
	# takes minutes at the media step, and a refusal arrives in seconds. Both
	# used to look like a black window.
	if OS.get_environment("GOANNA_SHOT") == "" and OS.get_environment("GOANNA_MENU_SHOT") == "" and not showcase_mode:
		_build_connect_overlay()
		connect_title.text = "Connecting"
		connect_detail.text = "%s:%d as %s" % [host, port, pname]
	client.connect_to(host, port, pname, OS.get_environment("GOANNA_PASS"))
	if OS.get_environment("GOANNA_TOD") != "":
		client.set_time_of_day_override(float(OS.get_environment("GOANNA_TOD")))
	# GOANNA_CONTROL=<port>: open the loopback command channel, so the client
	# can be driven and questioned while it runs instead of being relaunched
	# for each question. Development only; see docs/control-channel.md.
	if OS.get_environment("GOANNA_CONTROL") != "":
		if ResourceLoader.exists("res://control_channel.gd"):
			var cc: Node = (load("res://control_channel.gd") as GDScript).new()
			cc.main = self
			add_child(cc)
		else:
			push_error("GOANNA_CONTROL is set but control_channel.gd is not in this build")
	# GOANNA_BENCH=1: build the frame recorder now rather than when the first
	# bench command arrives, because the load stamps it takes start at process
	# start and a driver cannot connect that early. It is added after the
	# control channel so its _process runs after this node has moved the
	# camera, and the frame it records is the one that was just drawn.
	if OS.get_environment("GOANNA_BENCH") != "":
		if ResourceLoader.exists("res://bench.gd"):
			bench = (load("res://bench.gd") as GDScript).new()
			bench.main = self
			add_child(bench)
		else:
			push_error("GOANNA_BENCH is set but bench.gd is not in this build")
	# A control session is usually unattended, and grabbing the pointer there
	# takes the mouse away from whoever is watching. Escape still toggles it.
	if OS.get_environment("GOANNA_SHOT") == "" and OS.get_environment("GOANNA_CONTROL") == "":
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# Bob the camera along a walk cycle while moving on the ground: vertical at
# twice the stride frequency, a gentle side sway at the stride frequency,
# amplitude scaled by speed and the view_bobbing setting.
func _apply_view_bob(r: Dictionary, delta: float) -> void:
	if view_bobbing <= 0.0 or not r.get("on_ground", false):
		return
	var sp: Vector3 = r.get("speed", Vector3.ZERO)
	var hspeed := Vector2(sp.x, sp.z).length()
	if hspeed < 0.5:
		return
	_bob_phase += delta * (5.5 + hspeed * 0.8)
	var amp := view_bobbing * 0.02 * clampf(hspeed / 4.0, 0.0, 1.0)
	var basis := cam.global_transform.basis
	# side sway at the stride frequency, a smaller centred vertical at twice it
	# (both oscillate around the eye, so it reads as a gait, not a tiptoe)
	cam.position += basis.x * (cos(_bob_phase) * amp) + Vector3.UP * (sin(_bob_phase * 2.0) * amp * 0.5)

func _unhandled_input(event: InputEvent) -> void:
	# Same reason as the movement keys above: while a benchmark run is
	# recording, nothing outside the run may turn the camera. Escape is in
	# here too, because it toggles mouse capture and capture is what makes
	# mouse motion turn the view at all.
	if bench != null and bench.owns_input():
		return
	if event is InputEventMouseButton and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dig_down = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			place_down = event.pressed
			if event.pressed:
				place_pressed = true
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			var n := _hotbar_count()
			_set_wield((wield + n - 1) % n)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_wield((wield + 1) % _hotbar_count())
	# Slot keys 1 to 9, then 0 for the tenth, as Luanti's own keymap_slot1 to
	# keymap_slot10 defaults do. A key past the end of the hotbar does nothing,
	# which is what processItemSelection's loop over max_item amounts to.
	if event is InputEventKey and event.pressed and event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var slot: int = event.keycode - KEY_1
		if slot < _hotbar_count():
			_set_wield(slot)
	if event is InputEventKey and event.pressed and event.keycode == KEY_0 and _hotbar_count() > 9:
		_set_wield(9)
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		var dy: float = event.relative.y * mouse_sensitivity * (1.0 if invert_mouse else -1.0)
		pitch = clamp(pitch + dy, -89, 89)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		fly_mode = not fly_mode
		print("fly mode: ", fly_mode)
	# E is dual purpose, as aux1 already is in Luanti's own default keymap:
	# whatever it is pointed at, from the last frame's step_interact, decides
	# whether it opens the inventory or uses that node or object. A held E
	# also drives aux1 (climb/fly down) every frame below; this is only the
	# discrete "just pressed" edge for the UI/use side of the key.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E and ui != null:
		if not ui.blocks_input() and pointed.get("type", "nothing") != "nothing":
			place_pressed = true
		else:
			ui.toggle_inventory()

# Tell the client the wider of the camera's two field of view angles, which is
# what the server culls against. Godot's Camera3D.fov is the vertical one and
# keeps it fixed as the window changes shape, so on any window wider than it is
# tall the horizontal is the larger and is the one that reaches the corners.
# Under reporting it means the server sends nothing for the edges of the frame,
# which showed as wedges of missing world at the left and right of the screen.
func _report_fov() -> void:
	if client == null or not client.has_method("set_view_fov") or cam == null:
		return
	var vs := get_viewport().get_visible_rect().size
	var aspect: float = vs.x / vs.y if vs.y > 0.0 else 1.0
	var v := deg_to_rad(cam.fov)
	var h := 2.0 * atan(tan(v * 0.5) * aspect)
	# The diagonal, not the wider of the two axes. The server's cone is
	# circular around the view direction, so the angle that has to fit is
	# the one to the frame's corners, and on a pitched wide window a bottom
	# corner subtends more azimuth than the horizontal angle alone: measured
	# on a 16 by 9 frame at 70 degrees vertical, live blocks filled to 45
	# degrees off axis and the outer wedge of each bottom corner never
	# arrived, however long the camera held still, which read as the far
	# field refusing to sharpen at the edges of the screen.
	var d := 2.0 * atan(sqrt(pow(tan(h * 0.5), 2.0) + pow(tan(v * 0.5), 2.0)))
	client.set_view_fov(rad_to_deg(d))

# What the player sees between pressing Connect and the world appearing.
#
# Until now that was nothing at all: the state and the server's own message
# went to stdout and the screen stayed black, so a server saying "you need a
# password" looked exactly like a large server sending its media, and both
# looked exactly like a hang. A big public server legitimately takes minutes
# at the media step, so the two have to be told apart on screen.
var connect_overlay: Control
var connect_title: Label
var connect_detail: Label
var connect_bar: ProgressBar

func _build_connect_overlay() -> void:
	connect_overlay = ColorRect.new()
	(connect_overlay as ColorRect).color = Color(0.06, 0.07, 0.09)
	connect_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	connect_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	connect_overlay.add_child(centre)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(520, 0)
	centre.add_child(box)
	connect_title = Label.new()
	connect_title.add_theme_font_size_override("font_size", 22)
	box.add_child(connect_title)
	connect_bar = ProgressBar.new()
	connect_bar.custom_minimum_size = Vector2(520, 18)
	connect_bar.min_value = 0.0
	connect_bar.max_value = 1.0
	box.add_child(connect_bar)
	connect_detail = Label.new()
	connect_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	connect_detail.modulate = Color(1, 1, 1, 0.7)
	box.add_child(connect_detail)
	add_child(connect_overlay)

func _update_connect_overlay(s: Dictionary) -> void:
	if connect_overlay == null:
		return
	var state := str(s.get("state", ""))
	if state == "ready":
		# The world is up; never come back, even if the state flickers.
		connect_overlay.queue_free()
		connect_overlay = null
		return
	var got := int(s.get("media_received", 0))
	var want := int(s.get("media_announced", 0))
	var msg := str(s.get("message", ""))
	if state == "denied" or state == "error" or msg.begins_with("access denied"):
		# The server has refused and is not going to change its mind. Say what
		# it said, rather than leaving the player watching a blank screen.
		connect_title.text = "The server refused the connection"
		connect_bar.visible = false
		connect_detail.text = msg + "\n\nPress Escape to go back to the menu."
		connect_detail.modulate = Color(1, 0.65, 0.55)
		return
	connect_bar.visible = true
	connect_detail.modulate = Color(1, 1, 1, 0.7)
	if want > 0:
		connect_title.text = "Downloading media"
		connect_bar.value = float(got) / float(want)
		connect_detail.text = "%d of %d files. A large public server sends a great deal of media; this can take a few minutes the first time." % [got, want]
	else:
		connect_title.text = "Connecting"
		connect_bar.value = 0.0
		connect_detail.text = msg if msg != "" else state

# Start from what the machine says it is, rather than from one number chosen
# on the author's desktop.
#
# The compiled-in defaults are what a modest machine should run; this raises
# them where the hardware reports itself capable. It runs before the settings
# panel seeds goanna.cfg (ui/game_ui.gd), so what it picks becomes the recorded
# default, and it never touches a value the player has already chosen: a stored
# setting is applied over the top afterwards by _load_apply_settings.
#
# What Godot will actually tell us is narrow. Total video memory is not
# exposed: RenderingDevice.get_memory_usage(MEMORY_TOTAL) reports what Godot
# has allocated, not what the card has. So the discriminator is the adapter
# type, which separates a discrete card from an integrated one sharing system
# memory, and that is the distinction that matters most here anyway.
func _apply_hardware_defaults() -> void:
	var cores := OS.get_processor_count()
	# get_video_adapter_type returns a RenderingDevice.DeviceType, so the
	# constant lives there rather than on RenderingServer.
	var gpu: int = RenderingServer.get_video_adapter_type()
	var discrete: bool = gpu == RenderingDevice.DEVICE_TYPE_DISCRETE_GPU
	# The machine's profile is worked out even when the values are not
	# applied, because the settings panel shows it: a config written on an
	# older run pins a capable machine to the low tier for ever, and the
	# panel can only say so if it knows what the machine should have been.
	hardware_profile = GraphicsProfiles.for_hardware(discrete, cores)
	if OS.get_environment("GOANNA_NO_HW_DEFAULTS") != "":
		return
	# The values themselves are applied by ui/game_ui.gd's _load_apply_settings,
	# which runs when the panel is built: it has to put the profile down first
	# and the player's stored settings over the top, and doing it here would
	# be the wrong way round, because this runs before the panel exists.
	# Not part of a profile: a machine sharing memory with everything else
	# should leave a core for the game and one for the network, and that is
	# a fact about the machine rather than a look the player picks.
	if not discrete and client.has_method("set_mesh_threads"):
		client.set_mesh_threads(2)
	print("hardware: %d cores, %s (%s), profile %s" % [
		cores, RenderingServer.get_video_adapter_name(),
		"discrete" if discrete else "shared", hardware_profile])

func _process(delta: float) -> void:
	t += delta
	_apply_sky()
	var s: Dictionary = client.status()
	_update_connect_overlay(s)
	if showcase_mode and not showcase_placed and s.get("state") == "ready":
		showcase_placed = true
		fly_mode = true
		var showcase_pos := Vector3(float(OS.get_environment("GOANNA_SHOWCASE_X")),
				float(OS.get_environment("GOANNA_SHOWCASE_Y")),
				float(OS.get_environment("GOANNA_SHOWCASE_Z")))
		cam.position = showcase_pos + Vector3(0, 1.6, 0)
		await teleport_to(showcase_pos)
		cam.position = showcase_pos + Vector3(0, 1.6, 0)
		pitch = -8.0
		yaw = float(OS.get_environment("GOANNA_SHOWCASE_YAW"))
		cam.rotation_degrees = Vector3(pitch, yaw, 0)
		if headlight:
			headlight_auto = false
			headlight.light_energy = 0.0
	if not placed and s.get("state") == "ready":
		var p: Vector3 = client.server_player_position()
		cam.position = p + Vector3(0, 1.6, 0)
		atmosphere_ground = p.y
		atmosphere_ground_set = true
		placed = true
		print("camera placed at ", cam.position)
	if placed and not fly_mode and not showcase_mode:
		var keys := {
			"up": Input.is_key_pressed(KEY_W), "down": Input.is_key_pressed(KEY_S),
			"left": Input.is_key_pressed(KEY_A), "right": Input.is_key_pressed(KEY_D),
			"jump": Input.is_key_pressed(KEY_SPACE), "sneak": Input.is_key_pressed(KEY_SHIFT),
			"aux1": Input.is_key_pressed(KEY_E),
		}
		if OS.get_environment("GOANNA_WALKTEST") != "":
			keys = _walktest_keys()
		if bench != null and bench.owns_input():
			# A recording run owns the camera. This window can still be
			# clicked into and typed at, and a stray key in the middle of a
			# sample moves the player without anything saying so.
			for k in keys:
				keys[k] = false
		if bench != null and bench.route_active() and bench.route_mode == "walk":
			keys = bench.walk_keys()
		test_dig = false
		test_plc_pressed = false
		_test_hooks(keys)
		var ui_blocks: bool = ui != null and ui.blocks_input()
		if ui_blocks:
			for k in keys:
				keys[k] = false
			# A window opening while the mouse button is physically still
			# down (mid dig, say the player hits escape to check something)
			# must not leave that held state to resume the moment the
			# window closes: nothing clears it otherwise, since closing the
			# window is not itself a button event.
			dig_down = false
			place_down = false
		var r: Dictionary = client.step_player(delta, keys, pitch, yaw)
		last_move = r
		if r.has("eye_pos"):
			cam.position = r["eye_pos"]
			cam.rotation_degrees = Vector3(pitch, yaw, 0)
			_apply_view_bob(r, delta)
		var dig := (dig_down or test_dig) and not ui_blocks
		var plc := place_down and not ui_blocks
		var plc_pressed := (place_pressed or test_plc_pressed) and not ui_blocks
		if OS.get_environment("GOANNA_DIGTEST") != "":
			# look down at the ground in front (hand-diggable, timed) and use slot 4 (light14) to place
			pitch = -55.0
			if absf(t - 3.0) < delta * 0.6:
				_set_wield(4)
			dig = t > 4.0 and t < 4.9
			plc_pressed = absf(t - 8.5) < delta * 0.6 or absf(t - 9.5) < delta * 0.6
			plc = plc_pressed
			if OS.get_environment("GOANNA_SHOT") != "" and absf(t - 4.45) < delta * 0.6:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_SHOT").path_join("dig_crack.png"))
				print("saved crack shot")
			# The break itself, a few frames apart. The crack shot above is
			# taken mid dig and cannot show what the node does when it goes.
			if OS.get_environment("GOANNA_SHOT") != "":
				for mark in [4.70, 4.80, 4.95, 5.15]:
					if absf(t - mark) < delta * 0.6:
						await RenderingServer.frame_post_draw
						get_viewport().get_texture().get_image().save_png(
							OS.get_environment("GOANNA_SHOT").path_join("dig_break_%d.png" % int(mark * 100)))
						print("saved break shot at ", mark)
		if OS.get_environment("GOANNA_CHESTTEST") != "":
			# sweep the view until a chest is pointed, right-click it once, report
			# the formspec it opened, answer it
			pitch = -25.0
			if t > 3.0 and not chest_opened:
				yaw += 3.0
				if String(pointed.get("node_name", "")).contains("chest"):
					plc_pressed = true
					plc = true
					chest_opened = true
					print("chest test: pressing place at yaw ", yaw, " pointed ", pointed)
			# the in-game UI consumes take_shown_formspecs() and draws the form;
			# a screenshot shows the result
			if OS.get_environment("GOANNA_SHOT") != "" and absf(t - 8.0) < delta * 0.6:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(OS.get_environment("GOANNA_SHOT").path_join("chest_form.png"))
				print("saved chest shot")
			if t > 12.0:
				client.disconnect_from_server()
				get_tree().quit()
		pointed = client.step_interact(delta, dig, plc, plc_pressed, keys["sneak"])
		wield_dig_active = dig and str(pointed.get("type", "nothing")) != "nothing"
		if plc_pressed:
			swing_t = 0.0
		place_pressed = false
		_update_selection_box()
	elif placed and not showcase_mode:
		# fly controls
		if bench != null and bench.route_active() and bench.route_mode == "fly":
			# A benchmark route flies the camera in place of the keyboard, at a
			# fixed speed in nodes a second. It advances on elapsed time rather
			# than per frame on purpose: a setting that halves the frame rate
			# would otherwise cover half the ground in the same wall clock, and
			# the two runs would no longer be the same traversal.
			var step: Dictionary = bench.route_step(delta)
			cam.position = step["position"]
			pitch = step["pitch"]
			yaw = step["yaw"]
		elif bench != null and bench.owns_input():
			pass          # a recording run holds the camera where it put it
		else:
			var dir := Vector3.ZERO
			var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
			if Input.is_key_pressed(KEY_W): dir -= basis.z
			if Input.is_key_pressed(KEY_S): dir += basis.z
			if Input.is_key_pressed(KEY_A): dir -= basis.x
			if Input.is_key_pressed(KEY_D): dir += basis.x
			if Input.is_key_pressed(KEY_SPACE): dir += Vector3.UP
			if Input.is_key_pressed(KEY_SHIFT): dir -= Vector3.UP
			var sp := speed * (3.0 if Input.is_key_pressed(KEY_CTRL) else 1.0)
			cam.position += dir.normalized() * sp * delta if dir.length() > 0 else Vector3.ZERO
		cam.rotation_degrees = Vector3(pitch, yaw, 0)
		# Tell the server where the camera is, or it keeps streaming around
		# wherever we last walked and flying loads nothing. A server may reject
		# the movement as too fast without the fly privilege; that only resets
		# the walking position, which fly mode is not using anyway.
		client.set_player_pose(cam.position, pitch, yaw)
	client.poll_blocks(24)
	# Bounded residency: keep a margin beyond what we ask the server for, so
	# blocks just behind us survive a turn but a long session stays bounded.
	_prune_timer -= delta
	if _prune_timer <= 0.0 and client.has_method("prune_blocks"):
		_prune_timer = 2.0
		var keep: int = (client.view_range() if client.has_method("view_range") else 12) + 4
		if showcase_mode:
			# The showcase camera never moves. Keep only a tight radial envelope
			# around the fixed view; the far renderer still supplies the distant
			# mountain silhouette from its persistent store.
			keep = 18
		if OS.get_environment("GOANNA_KEEP") != "":
			keep = int(OS.get_environment("GOANNA_KEEP"))
		client.prune_blocks(keep)
	client.update_lights(cam.position, 0 if OS.get_environment("GOANNA_NO_LIGHTS") != "" else int(light_pool))
	client.update_motes(cam.position, 32)
	client.update_lod(cam.position, 8)
	client.sync_entities(delta)
	_update_environment_extras()
	_update_wield(delta)
	if t - last_print >= 1.0:
		last_print = t
		# GOANNA_DUMPTEX="dir=name1,name2": save generated textures (including
		# texture-modifier expressions) as PNGs, for inspecting composites.
		if OS.get_environment("GOANNA_DUMPTEX") != "" and int(t) == 3:
			var spec := OS.get_environment("GOANNA_DUMPTEX").split("=")
			for nm in spec[1].split(","):
				var tx: Texture2D = client.texture(nm)
				if tx != null:
					var fn: String = spec[0].path_join(nm.replace("^", "_").replace(":", "-") + ".png")
					tx.get_image().save_png(fn)
					print("dumped ", fn)
				else:
					print("no texture for ", nm)
		# GOANNA_ITEMMESH="name,name": report item_mesh() results, for checking
		# the 3D inventory icon meshes.
		if OS.get_environment("GOANNA_ITEMMESH") != "" and int(t) == 3:
			for nm in OS.get_environment("GOANNA_ITEMMESH").split(","):
				var im: Dictionary = client.item_mesh(nm)
				var m: Mesh = im.get("mesh")
				if m == null:
					print("item_mesh ", nm, ": no mesh")
				else:
					print("item_mesh ", nm, ": surfaces=", m.get_surface_count(), " aabb=", m.get_aabb().size, " scale=", im["scale"])
		# GOANNA_ICONTEST="dir=item,item": save item_icon() results, for
		# checking inventory icons (node items composite an isometric cube).
		if OS.get_environment("GOANNA_ICONTEST") != "" and int(t) == 3:
			var spec := OS.get_environment("GOANNA_ICONTEST").split("=")
			for nm in spec[1].split(","):
				var img: Image = null
				var itex: Texture2D = client.item_icon(nm)
				if itex != null:
					img = itex.get_image()
				if img == null:
					print("icon ", nm, ": no mesh")
				else:
					var op := 0
					var lit_px := 0
					for py in img.get_height():
						for px in img.get_width():
							var c := img.get_pixel(px, py)
							if c.a > 0.02:
								op += 1
							if c.r + c.g + c.b > 0.02:
								lit_px += 1
					img.save_png(spec[0].path_join(nm.replace(":", "-") + ".png"))
					print("icon ", nm, ": alpha>0=", op, " rgb>0=", lit_px, "/", img.get_width() * img.get_height())
		# GOANNA_PERF=1: one telemetry line a second, so frame cost can be
		# attributed rather than guessed at.
		if OS.get_environment("GOANNA_PERF") != "":
			var st: Dictionary = client.render_stats()
			print("perf fps=%.0f frame=%.1fms render=%.2f+%.2fms gpu=%.2fms | mesh=%.2f upload=%.2f lights=%.2f motes=%.2f ents=%.2f | meshed=%d queued=%d blocks=%d near=%d->%d/%d batch=%.2fms occ=%d/%d mats=%d | draws=%d objs=%d vram=%.0fMB | lod tiers=%s regions=%d dirty=%d quads=%d/%d surfaces=%d lod_ms=%.2f" % [
				Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0),
				st.get("render_cpu_setup_ms", 0.0), st.get("render_cpu_draw_ms", 0.0),
				st.get("render_gpu_ms", 0.0),
				st["mesh_ms"], st["upload_ms"], st["lights_ms"], st["motes_ms"], st["entities_ms"],
				st["blocks_meshed_last"], st["blocks_queued"], st["block_meshes"],
				st.get("near_source_surfaces", 0), st.get("near_surfaces", 0), st.get("near_regions", 0),
				st.get("near_batch_ms", 0.0), st.get("occluder_regions", 0),
				st.get("occluder_triangles", 0), st["materials"],
				st.get("draw_calls", 0), st.get("objects", 0), st.get("video_mem_mb", 0.0),
				str(st.get("lod_tiers", {})), st.get("lod_regions", 0), st.get("lod_regions_dirty", 0),
				st.get("lod_quads", 0), st.get("lod_faces", 0), st.get("lod_surfaces", 0), st.get("lod_ms", 0.0)]
				+ " | far=%d grant=%d reach=%d/%d req=%d areas=%d/%d/%d store=%d/%.0fMB | poll_max=%.1fms chains=%d queue=%d | mesh %dthr q=%d(%d/%d/%d) run=%d rdy=%d reject=%d build=%d" % [st.get("far_blocks", 0), st.get("far_grant", 0),
				st.get("far_extent", 0), st.get("far_reach", 0), st.get("far_requests_inflight", 0),
				st.get("far_areas_complete", 0), st.get("far_areas_partial", 0), st.get("far_areas_empty", 0),
				st.get("store_blocks", 0), st.get("store_mb", 0.0), st.get("poll_max_ms", 0.0),
				st.get("lod_chains", 0), st.get("lod_chain_queue", 0),
				st.get("mesh_threads", 0), st.get("mesh_queued", 0), st.get("mesh_q_coverage", 0),
				st.get("mesh_q_near", 0), st.get("mesh_q_structure", 0), st.get("mesh_running", 0),
				st.get("mesh_ready", 0), st.get("mesh_rejected", 0), st.get("lod_building", 0)]
				+ " | lod_frame=%.2f tier=%.2f sums=%.2f asks=%.2f far_scan=%.2f stats=%.2fms" % [
				st.get("lod_update_ms", 0.0), st.get("lod_tier_scan_ms", 0.0),
				st.get("lod_summary_ms", 0.0), st.get("lod_request_ms", 0.0),
				st.get("lod_far_scan_ms", 0.0), st.get("stats_ms", 0.0)])
		if OS.get_environment("GOANNA_DUMPSKY") != "" and int(t) == 3:
			print("SKY ", JSON.stringify(client.sky_state()))
		if OS.get_environment("GOANNA_DUMPUI") != "" and int(t) == 5:
			for dn in client.detached_inventory_names():
				var ds: Dictionary = client.inventory_state_at("detached:" + dn)
				print("detached ", dn, " lists ", (ds["lists"] as Dictionary).keys())
			if OS.get_environment("GOANNA_NODEMETA") != "":
				print("nodemeta ", client.inventory_state_at("nodemeta:" + OS.get_environment("GOANNA_NODEMETA")))
		if OS.get_environment("GOANNA_DUMPUI") != "":
			if int(t) == 2:
				client.send_chat("hello from goanna")
			for line in client.take_chat():
				print("CHAT ", line)
			if int(t) == 4:
				if client.has_method("server_options"):
					var so: Dictionary = client.server_options()
					print("SERVER OPTIONS ", so if not so.is_empty() else "(none, vanilla server)")
				var hud: Dictionary = client.hud_state()
				print("HUD flags=%d hotbar=%d elems=%d" % [hud.get("flags", 0), hud.get("hotbar_itemcount", 0), (hud.get("elements", []) as Array).size()])
				for e in hud.get("elements", []):
					print("  HUD ", e.get("type"), " ", e.get("name"), " ", e.get("text"), " n=", e.get("number"))
				var inv: Dictionary = client.inventory_state()
				for k in (inv.get("lists", {}) as Dictionary).keys():
					var items: Array = inv["lists"][k]
					var names := []
					for it in items:
						if it.get("name", "") != "": names.append("%s x%d" % [it["name"], it["count"]])
					print("  INV %s (%d slots): %s" % [k, items.size(), ", ".join(names)])
				var tex := client.texture("default_dirt.png^default_grass_side.png")
				print("  TEX grass side: ", tex != null, " ", (tex.get_size() if tex else Vector2()))
				print("  HP ", client.hp(), " breath ", client.breath())
		var extra := ""
		if placed and not fly_mode:
			var r: Dictionary = client.step_player(0.0, {}, pitch, yaw)
			extra = " | player %s ground=%s | pointed %s %s dig=%s prog=%.2f crack=%d" % [str(r.get("pos", Vector3())), str(r.get("on_ground", false)), str(pointed.get("type", "?")), str(pointed.get("node_name", pointed.get("object_name", ""))), str(pointed.get("digging", false)), float(pointed.get("progress", 0.0)), int(pointed.get("crack_level", -1))]
		print("[%5.1fs] %s | %s | media %d/%d | blocks recv %d meshed %d | mats %d | res %d | lights %d%s" % [
			t, s.get("state"), s.get("message"), s.get("media_received", 0), s.get("media_announced", 0),
			s.get("blocks_received", 0), s.get("blocks_meshed", 0), s.get("materials", 0), s.get("resident_blocks", 0), s.get("node_lights", 0), extra])
	# GOANNA_CHAT="cmd": send one chat line a few seconds in, so a server side
	# test fixture can be triggered from a headless run.
	if OS.get_environment("GOANNA_CHAT") != "" and not _chat_sent and t > 3.0:
		_chat_sent = true
		client.send_chat(OS.get_environment("GOANNA_CHAT"))
		print("sent chat: ", OS.get_environment("GOANNA_CHAT"))
	var shot := OS.get_environment("GOANNA_SHOT")
	if shot != "" and OS.get_environment("GOANNA_TOGGLETEST") != "":
		# walking mode, standing still, looking straight ahead: pillar appears 4 nodes in front
		client.poll_blocks(64)
		for st in [4.0, 5.5, 7.0, 8.5, 10.0, 11.5, 13.0]:
			if absf(t - st) < delta * 0.6:
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				var path: String = shot.path_join("toggle_%d.png" % int(round(t)))
				img.save_png(path)
				print("saved ", path)
		if t > 14.0:
			client.disconnect_from_server()
			get_tree().quit()
		return
	if shot != "" and OS.get_environment("GOANNA_WALKTEST") != "":
		if (absf(t - 5.0) < delta * 0.6) or (absf(t - 9.5) < delta * 0.6):
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var path: String = shot.path_join("walk_%d.png" % int(round(t)))
			img.save_png(path)
			print("saved ", path)
		if t > 11.0:
			client.disconnect_from_server()
			get_tree().quit()
		return
	if shot != "" and not shots_done and t > 8.0:
		shots_done = true
		await _shots(shot)
		client.disconnect_from_server()
		get_tree().quit()
	var limit := float(OS.get_environment("GOANNA_SMOKE")) if OS.get_environment("GOANNA_SMOKE") != "" else 0.0
	if limit > 0.0 and t > limit:
		client.disconnect_from_server()
		get_tree().quit()

# GOANNA_MANTLETEST=1: build a one-block step in front (needs give/place), walk
# into it, and report whether the player rose a block. Simpler: teleport to a
# known ledge on devtest and walk into it.
var _mantle_y0 := 0.0
var _mantle_done := false
func _mantle_test(keys: Dictionary) -> bool:
	if OS.get_environment("GOANNA_MANTLETEST") == "":
		return false
	# Build a clean one-block step in front on the flat devtest sand, then walk
	# north into it. yaw 180 faces -Z (Luanti +Z); the step is placed one node
	# ahead by pointing down at the sand and pressing place.
	yaw = 180.0
	if _mantle_y0 == 0.0:
		_mantle_y0 = -2.0
	if int(t) == 4:
		_set_wield(5)  # basenodes:dirt_with_grass in the devtest hotbar
	# aim down-forward and place one block one node ahead to make a step
	if t > 4.5 and t < 6.0:
		pitch = -55.0
		if absf(t - 5.0) < get_process_delta_time() * 0.6 or absf(t - 5.5) < get_process_delta_time() * 0.6:
			test_plc_pressed = true
	# now walk forward on the flat into the placed step
	if t >= 6.5 and t < 10.0:
		pitch = 0.0
		keys["up"] = true
		if _mantle_y0 < -1.0:
			_mantle_y0 = client.server_player_position().y
	if t > 10.5 and not _mantle_done:
		_mantle_done = true
		var dy := client.server_player_position().y - _mantle_y0
		print("mantletest: y rose %.2f nodes over the walk (mantle=%s)" % [dy, str(OS.get_environment("GOANNA_MANTLE"))])
		client.disconnect_from_server()
		get_tree().quit()
	return true

func _walktest_keys() -> Dictionary:
	# Hold W from 4 to 7s, then release. With GOANNA_WALKRELEASE=1, report how
	# far the player drifts in the 3s after release (should be ~0).
	var hold_w := t > 4.0 and t < 7.0
	if OS.get_environment("GOANNA_WALKRELEASE") != "":
		if absf(t - 7.0) < get_process_delta_time() * 0.6:
			_walk_release_pos = client.server_player_position()
		if t > 10.0 and not _walk_release_done:
			_walk_release_done = true
			var drift := (client.server_player_position() - _walk_release_pos).length()
			print("walkrelease: drifted %.2f nodes in 3s after releasing W" % drift)
			client.disconnect_from_server()
			get_tree().quit()
	return {"up": hold_w, "down": false, "left": false, "right": false,
		"jump": t > 6.0 and t < 6.3, "sneak": false, "aux1": false}

func _aim_at(target: Vector3) -> void:
	var d := (target - cam.position)
	if d.length() < 0.001:
		return
	d = d.normalized()
	yaw = rad_to_deg(atan2(-d.x, -d.z))
	pitch = rad_to_deg(asin(clamp(d.y, -1.0, 1.0)))

func _nearest_entity(sub: String) -> Dictionary:
	var best := {}
	var bestd := 1e9
	for e in client.entity_list():
		if not (String(e["name"]).contains(sub) or String(e["mesh"]).contains(sub)):
			continue
		var dd: float = (Vector3(e["position"]) - cam.position).length()
		if dd < bestd:
			bestd = dd
			best = e
	return best

func _main_list() -> Array:
	var inv: Dictionary = client.inventory_state()
	return (inv.get("lists", {}) as Dictionary).get("main", [])

# Test hooks: teleport next to a target instead of walking (walking a straight
# line into trees is what made the first mob test fail). Needs the teleport
# privilege on the test server. Godot z is mirrored relative to Luanti.
var test_teleported := 0.0
var _anim_reported := false
var _walk_release_pos := Vector3.ZERO
var _walk_release_done := false
func _teleport_near(target: Vector3) -> bool:
	if test_teleported > 0.0:
		return t - test_teleported > 2.0
	test_teleported = t
	var p := target + Vector3(1.5, 0.5, 1.5)
	client.send_chat("/teleport %.1f %.1f %.1f" % [p.x, p.y, -p.z])
	print("test: teleporting next to target at ", target)
	return false

# Development aid: GOANNA_ANIMPROBE=<substr> samples the "frame" field of the
# nearest matching entity every physics frame and reports frames advanced per
# second, so an animation-speed bug can be measured instead of eyeballed.
var _anim_samples: Array = []
func _anim_probe(delta: float) -> void:
	var sub := OS.get_environment("GOANNA_ANIMPROBE")
	if sub == "":
		return
	var e := _nearest_entity(sub)
	if not e.is_empty():
		_anim_samples.append({"t": t, "id": int(e["id"]), "frame": float(e.get("frame", 0.0)), "pos": Vector3(e["position"])})
	if t > 12.0 and not _anim_reported:
		_anim_reported = true
		# group by id, report frame span and moved distance
		var by_id := {}
		for smp in _anim_samples:
			by_id.get_or_add(smp["id"], []).append(smp)
		for id in by_id:
			var arr: Array = by_id[id]
			var fmin: float = arr[0]["frame"]
			var fmax := fmin
			var moved := 0.0
			var resets := 0
			for i in range(1, arr.size()):
				fmin = minf(fmin, arr[i]["frame"])
				fmax = maxf(fmax, arr[i]["frame"])
				moved += (arr[i]["pos"] - arr[i - 1]["pos"]).length()
				if arr[i]["frame"] < arr[i - 1]["frame"] - 0.01:
					resets += 1  # a loop wrap or a jitter reset
			var span: float = arr[-1]["t"] - arr[0]["t"]
			print("animprobe id=%d range %.1f..%.1f over %.1fs, %d frame-decreases (%.1f/s), moved %.1f nodes, %d samples" % [id, fmin, fmax, span, resets, resets / maxf(span, 0.01), moved, arr.size()])
			# raw trace at ~10 Hz so the sawtooth is visible
			var trace := ""
			var last_t := -1.0
			for smp in arr:
				if smp["t"] - last_t >= 0.1:
					last_t = smp["t"]
					trace += "%.1f " % smp["frame"]
			print("animprobe id=%d trace: %s" % [id, trace])
		client.disconnect_from_server()
		get_tree().quit()

var _click_sent := false
# GOANNA_CLICKTEST=1: exercise the real left-mouse dig path (dig_down), not the
# test_dig shortcut, to see whether a click actually starts a dig.
func _click_test() -> bool:
	if OS.get_environment("GOANNA_CLICKTEST") == "":
		return false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	pitch = -80.0
	if int(t) == 3 and not _click_sent:
		_click_sent = true
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		Input.parse_input_event(ev)
		print("clicktest: injected left-down; mouse_mode=", Input.get_mouse_mode())
	if absf(t - round(t)) < get_process_delta_time() * 0.6:
		print("clicktest: t=%d mouse_mode=%d dig_down=%s ui_blocks=%s" % [int(t), Input.get_mouse_mode(), str(dig_down), str(ui != null and ui.blocks_input())])
	if t > 12.0:
		client.disconnect_from_server()
		get_tree().quit()
	return true

# GOANNA_AUTOJUMPTEST=1: place a block one node ahead, walk into it, and report
# whether the player rose onto it (autojump) or was stopped by it.
var _aj_y := 0.0
var _aj_done := false
func _autojump_test(keys: Dictionary) -> bool:
	if OS.get_environment("GOANNA_AUTOJUMPTEST") == "":
		return false
	yaw = float(OS.get_environment("GOANNA_AJ_YAW")) if OS.get_environment("GOANNA_AJ_YAW") != "" else 0.0
	# Walk over natural terrain, which is full of one-block steps, and see
	# whether the jump control ever fires without the jump key.
	if absf(t - 4.0) < get_process_delta_time() * 0.6:
		_aj_y = client.server_player_position().y
		print("autojumptest: walking from y=%.2f" % _aj_y)
	if t > 4.0 and t < 11.0:
		pitch = 0.0
		keys["up"] = true
	if t > 11.5 and not _aj_done:
		_aj_done = true
		var dy := client.server_player_position().y - _aj_y
		print("autojumptest: rose %.2f nodes (autojump=%s)" % [dy, str(OS.get_environment("GOANNA_MANTLE"))])
		client.disconnect_from_server()
		get_tree().quit()
	return true

func _test_hooks(keys: Dictionary) -> void:
	if _autojump_test(keys):
		return
	if _click_test():
		return
	_anim_probe(get_process_delta_time())
	if _mantle_test(keys):
		return
	# GOANNA_FALLTEST=1: pillar-jump then fall; report hp drop and server damage line.
	if OS.get_environment("GOANNA_FALLTEST") != "":
		# grant fly+teleport, go up high, then drop and land
		if int(t) == 2 and test_started == 0.0:
			test_started = 1.0
			client.send_chat("/grant goanna all")
		if int(t) == 4 and test_started == 1.0:
			test_started = 2.0
			print("falltest: hp before ", client.hp())
			client.send_chat("/teleport 20 45 26")
		if t > 5.0:
			# stop holding anything; just fall under gravity
			for k in keys: keys[k] = false
		if client.hp() < 20 and not fall_reported:
			fall_reported = true
			print("falltest: hp after landing ", client.hp(), " at t ", t)
		if t > 20.0:
			print("falltest: final hp ", client.hp(), " (no damage taken)" if not fall_reported else "")
			client.disconnect_from_server()
			get_tree().quit()
		return
	# GOANNA_MOBTEST=<sub>: aim at nearest mob, walk to it, punch until it dies.
	var mob := OS.get_environment("GOANNA_MOBTEST")
	if mob != "":
		if inv_before.is_empty() and t > 2.0:
			inv_before = {"main": _main_list().duplicate(true)}
		var e := _nearest_entity(mob)
		if mob_target_id >= 0:
			# is our target still alive?
			var alive := false
			for x in client.entity_list():
				if int(x["id"]) == mob_target_id:
					alive = true
					mob_last_pos = Vector3(x["position"])
			if not alive:
				if test_started == 0.0:
					test_started = t
					print("mobtest: target ", mob_target_id, " gone at ", t, " main before ", inv_before.get("main", []).size())
				# walk onto the drop then report
				_aim_at(mob_last_pos)
				if (mob_last_pos - cam.position).length() > 1.2:
					keys["up"] = true
				if t - test_started > 5.0:
					print("mobtest: main after ", _main_list())
					client.disconnect_from_server()
					get_tree().quit()
				return
		if e.is_empty():
			return
		mob_target_id = int(e["id"])
		mob_last_pos = Vector3(e["position"])
		_aim_at(mob_last_pos + Vector3(0, 0.6, 0))
		var dist: float = (mob_last_pos - cam.position).length()
		if dist > 3.0:
			if _teleport_near(mob_last_pos):
				keys["up"] = true
		else:
			test_dig = true
		return
	# GOANNA_DIGDOWNTEST=1: aim straight down and dig the block underfoot; the
	# most reliable timed dig (always points at a solid node).
	if OS.get_environment("GOANNA_DIGDOWNTEST") != "":
		pitch = -89.0
		test_dig = t > 3.0 and t < 13.0
		if t > 14.0:
			client.disconnect_from_server()
			get_tree().quit()
		return
	# GOANNA_MINETEST=1: pitch down at the node in front, dig, report inventory delta.
	if OS.get_environment("GOANNA_MINETEST") != "":
		pitch = -75.0
		if int(t) == 2 and test_teleported == 0.0:
			test_teleported = 1.0
			# stand on a known solid spot (grass near the cow field) and dig down
			client.send_chat("/teleport 129 28 0")
		if int(t) == 3:
			_set_wield(int(OS.get_environment("GOANNA_MINE_SLOT")) if OS.get_environment("GOANNA_MINE_SLOT") != "" else 0)
		if inv_before.is_empty() and t > 2.0:
			inv_before = {"main": _main_list().duplicate(true)}
		test_dig = t > 4.0 and t < 11.0
		if t > 12.0:
			print("minetest: before ", inv_before.get("main", []))
			print("minetest: after ", _main_list())
			client.disconnect_from_server()
			get_tree().quit()
		return
	# GOANNA_USETEST=<sub>: aim at nearest match, right-click once, report formspecs + inventory delta.
	var use := OS.get_environment("GOANNA_USETEST")
	if use != "":
		var e2 := _nearest_entity(use)
		if inv_before.is_empty() and t > 2.0:
			inv_before = {"main": _main_list().duplicate(true)}
		if not e2.is_empty():
			var target: Vector3 = Vector3(e2["position"])
			_aim_at(target + Vector3(0, 0.6, 0))
			# get into reach first (vanilla hand reach is 4 nodes)
			if test_started == 0.0 and (target - cam.position).length() > 3.5:
				if _teleport_near(target):
					keys["up"] = true
			elif test_started == 0.0 and t > 3.0:
				test_started = t
				test_plc_pressed = true
				print("usetest: right-clicking ", e2["name"], " id ", e2["id"], " at ", (target - cam.position).length(), " nodes")
		for f in client.take_shown_formspecs():
			print("usetest: formspec name=", f["formname"], " context=", f["context"], " len=", String(f["formspec"]).length())
		if test_started > 0.0 and t - test_started > 3.0:
			print("usetest: main after ", _main_list())
			client.disconnect_from_server()
			get_tree().quit()
		return

# GOANNA_TP="x,y,z": stand at an exact spot before doing anything else.
# Ask the server to move us rather than moving the camera: a server side
# teleport is authoritative, so blocks stream to where we land, while moving
# ourselves is rejected as speed hacking and quietly reset. Coordinates are
# Godot space, matching GOANNA_VIEW, so z is negated for the server.
# Needs the teleport priv. Returns once the server agrees we are there.
func _teleport() -> bool:
	var tp := OS.get_environment("GOANNA_TP")
	if tp == "":
		return false
	var t := tp.split(",")
	if t.size() != 3:
		push_error("GOANNA_TP wants x,y,z")
		return false
	return await teleport_to(Vector3(float(t[0]), float(t[1]), float(t[2])))


# The teleport itself, also driven by the control channel. Coordinates are
# Godot space; the server is told the same place with z negated.
func teleport_to(want: Vector3) -> bool:
	client.send_chat("/teleport %.1f,%.1f,%.1f" % [want.x, want.y, -want.z])
	for i in 600:
		client.poll_blocks(64)
		await get_tree().process_frame
		if client.server_player_position().distance_to(want) < 2.0:
			break
	if client.server_player_position().distance_to(want) >= 2.0:
		push_error("teleport to %s never took, still at %s" % [want, client.server_player_position()])
		return false
	await wait_for_streaming()
	cam.position = want
	print("teleported to ", want)
	return true


# Wait for streaming to settle rather than for a fixed number of frames. A
# shot taken before the blocks arrive is a photograph of the sky, and looks
# exactly like a render with the feature under test turned off. Wall-clock
# quiet time matters here: at several hundred frames a second, a frame count
# settles long before the server has sent anything.
func wait_for_streaming() -> void:
	var t0 := Time.get_ticks_msec()
	var last_change := t0
	var last := -1
	while Time.get_ticks_msec() - t0 < 30000:
		client.poll_blocks(64)
		# Tier as they arrive. Blocks streamed against a stale LOD centre come
		# in as LOD and only convert later, so without this a capture races the
		# conversion and sometimes measures the merged mesh instead.
		client.update_lod(cam.position, 64)
		await get_tree().process_frame
		var n: int = int(client.status()["blocks_meshed"])
		if n != last:
			last = n
			last_change = Time.get_ticks_msec()
		var now := Time.get_ticks_msec()
		if now - t0 > 3000 and now - last_change > 2000:
			break
	print("blocks meshed at rest: ", last, " after ",
		(Time.get_ticks_msec() - t0) / 1000.0, "s")


# Capture a fixed-facing horizontal path through a named server fixture. The
# player, time, geometry, light positions, camera and convergence budget are
# all fixed, so adjacent-frame changes belong to the renderer rather than to
# a survival world's spawn, clock or weather.
func _fixture_shots(dir: String, name: String) -> bool:
	if not VISUAL_TESTS.has(name):
		push_error("unknown GOANNA_VISUAL_TEST '%s'" % name)
		return false
	var spec: Dictionary = VISUAL_TESTS[name]
	var want: Vector3 = spec["server_position"]
	client.set_time_of_day_override(float(spec["time_of_day"]))
	client.send_chat("/goanna_fixture " + name)
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 30000:
		client.poll_blocks(64)
		await get_tree().process_frame
		if client.server_player_position().distance_to(want) < 1.0:
			break
	if client.server_player_position().distance_to(want) >= 1.0:
		push_error(("fixture '%s' never became ready; install " +
			"goanna_visual_test_mod in a dedicated singlenode world") % name)
		return false
	await wait_for_streaming()
	if headlight:
		headlight_auto = false
		headlight.light_energy = 0.0
	var positions := []
	var churn := 0
	var in_range := 0
	var start: Vector3 = spec["camera_start"]
	var step: Vector3 = spec["camera_step"]
	var fixed_pitch: float = spec["pitch"]
	var fixed_yaw: float = spec["yaw"]
	for i in int(spec["steps"]):
		var pos := start + step * i
		positions.append([pos.x, pos.y, pos.z])
		cam.position = pos
		pitch = fixed_pitch
		yaw = fixed_yaw
		cam.rotation_degrees = Vector3(pitch, yaw, 0)
		client.set_player_pose(pos, pitch, yaw)
		for frame in int(spec["warm_frames"]):
			client.poll_blocks(64)
			# Fixtures have to tier blocks like the game does. Without this the
			# LOD centre stays wherever it last was, which for a fixture run is
			# the origin, so a site a thousand blocks out is drawn entirely as
			# LOD and every measurement is of the wrong mesh. That silently
			# invalidated a shadow measurement before it was noticed.
			client.update_lod(cam.position, 64)
			client.update_lights(cam.position, 0 if OS.get_environment("GOANNA_NO_LIGHTS") != "" else int(light_pool))
			var st: Dictionary = client.render_stats()
			churn += int(st.get("light_churn", 0))
			in_range = maxi(in_range, int(st.get("lights_in_range", 0)))
			await get_tree().process_frame
		# Settle the tiers before capturing. update_lod returns how many blocks
		# it still wants to re-mesh, so waiting for zero makes the tier state
		# deterministic instead of whatever the warm budget happened to reach.
		var guard := 0
		while guard < 120 and client.update_lod(cam.position, 64) > 0:
			client.poll_blocks(64)
			await get_tree().process_frame
			guard += 1
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var path := dir.path_join("%s_%02d.png" % [name, i])
		image.save_png(path)
		print("saved ", path, " at ", pos, " facing ", pitch, ",", yaw)
	var fs: Dictionary = client.render_stats()
	print("lod_distance=%d lod_cell=%d" % [client.lod_distance(), client.lod_cell() if client.has_method("lod_cell") else -1])
	print("pool: lights_in_range<=%d churn=%d over %d steps, draws=%d blocks=%d" % [in_range,
		churn, int(spec["steps"]), int(fs.get("draw_calls", -1)), int(fs.get("block_meshes", -1))])
	var metadata := {
		"fixture": name,
		"light_churn": churn,
		"lights_in_range": in_range,
		"time_of_day": spec["time_of_day"],
		"pitch": fixed_pitch,
		"yaw": fixed_yaw,
		"warm_frames": spec["warm_frames"],
		"positions": positions,
		"sdfgi_energy": light_sdfgi,
		"sdfgi_min_cell_size": light_sdfgi_cell,
		"ssao_intensity": light_ssao,
		"sun_energy": light_sun,
		"white_point": light_white,
		"exposure": light_exposure,
		"sky_fill": light_fill,
	}
	var metadata_file := FileAccess.open(dir.path_join(name + ".json"), FileAccess.WRITE)
	if metadata_file:
		metadata_file.store_string(JSON.stringify(metadata, "\t") + "\n")
	return true


func _shots(dir: String) -> void:
	fly_mode = true
	if ui:
		ui.visible = false  # keep the HUD/inventory out of rendering test shots
	var fixture := OS.get_environment("GOANNA_VISUAL_TEST")
	if fixture != "":
		await _fixture_shots(dir, fixture)
		return
	await _teleport()
	var base := cam.position
	if OS.get_environment("GOANNA_AIM_ENTITY") != "":
		# GOANNA_AIM_ENTITY=n (the first n visible entities) or a name
		# substring; close and far views, two frames apart so animation shows.
		var sel := OS.get_environment("GOANNA_AIM_ENTITY")
		var picked: Array = []
		for e in client.entity_list():
			if sel.is_valid_int():
				if picked.size() < int(sel):
					picked.append(e)
			elif String(e["name"]).contains(sel) or String(e["mesh"]).contains(sel):
				picked.append(e)
		for k in picked.size():
			var e: Dictionary = picked[k]
			var target: Vector3 = e["position"]
			print("aiming at ", e)
			var views_e := [["e%d_entity" % k, target + Vector3(1.5, 1.2, 4.0), target + Vector3(0, 0.8, 0)],
				["e%d_entity_far" % k, target + Vector3(-6, 3, 8), target]]
			for v in views_e:
				cam.position = v[1]
				cam.look_at(v[2], Vector3.UP)
				pitch = cam.rotation_degrees.x
				yaw = cam.rotation_degrees.y
				for suffix in ["", "_b"]:
					for i in 30:
						client.poll_blocks(64)
						client.sync_entities(get_process_delta_time())
						await get_tree().process_frame
					await RenderingServer.frame_post_draw
					var img := get_viewport().get_texture().get_image()
					var path: String = dir.path_join(v[0] + suffix + ".png")
					img.save_png(path)
					print("saved ", path, " frame ", client.entity_list().filter(func(x): return x["id"] == e["id"]))
		return
	var views := [
		["a_spawn", base + Vector3(0, 6, 14), base + Vector3(0, 0, -20)],
		["b_high", base + Vector3(30, 40, 30), base],
		["c_low", base + Vector3(-12, 2, 8), base + Vector3(20, -2, -20)],
	]
	# GOANNA_VIEW="name:x,y,z:pitch,yaw[;name:...]" replaces the fixed views.
	# Positions are relative to the spawn eye position, or absolute with a
	# leading "@"; angles in degrees.
	var custom := OS.get_environment("GOANNA_VIEW")
	if custom != "":
		views = []
		for spec in custom.split(";", false):
			var parts := spec.split(":")
			var pos_str: String = parts[1]
			var origin := base
			if pos_str.begins_with("@"):
				pos_str = pos_str.substr(1)
				origin = Vector3.ZERO
			var p := pos_str.split(",")
			var a := parts[2].split(",")
			views.append([parts[0], origin + Vector3(float(p[0]), float(p[1]), float(p[2])),
				Vector2(float(a[0]), float(a[1]))])
	# GOANNA_AB="channel[,channel]": for each view, save the frame, then set
	# those material strength channels to 0 and save it again as <name>_off.
	# Both frames come from one run, so the world has streamed identically and
	# the only difference is the channel. Two runs cannot do this: blocks
	# arrive in a different order each time and the difference that shows up is
	# the streaming, not the change.
	var ab: PackedStringArray = []
	if OS.get_environment("GOANNA_AB") != "":
		ab = OS.get_environment("GOANNA_AB").split(",", false)
	for v in views:
		cam.position = v[1]
		if v[2] is Vector2:
			pitch = v[2].x
			yaw = v[2].y
		else:
			cam.look_at(v[2], Vector3.UP)
			pitch = cam.rotation_degrees.x
			yaw = cam.rotation_degrees.y
		client.set_player_pose(cam.position, 0, 0)
		# GOANNA_BURST="0,1,2,4,8,16,30,60": capture at those frame counts after
		# the move instead of one settled frame. A settled capture cannot show a
		# transient, by construction: anything that pops on movement and then
		# resolves has already resolved by the time a 40 or 150 frame warmup
		# finishes, so every such capture reports the world as stable no matter
		# how badly it flickered on the way there. Frame 0 is the frame the move
		# lands on, which is where a light pool reshuffle or a cascade shift
		# shows up.
		var burst: Array = []
		if OS.get_environment("GOANNA_BURST") != "":
			for tok in OS.get_environment("GOANNA_BURST").split(",", false):
				burst.append(int(tok))
		if burst.is_empty():
			burst = [150 if OS.get_environment("GOANNA_MOTES") != "" else 40]
		var frame := 0
		for target in burst:
			# Settle: the frame count, and then until the mesh queue has been
			# empty for a few frames, bounded. poll_blocks is budgeted per
			# frame now, so a fixed count can capture sky where terrain has
			# not been meshed yet, which is a photograph of the budget.
			var settled := 0
			while frame < target or (burst.size() == 1 and settled < 5 and frame < 600):
				client.poll_blocks(64)
				client.update_motes(cam.position, 32)
				client.update_lod(cam.position, 64)
				var st: Dictionary = client.render_stats()
				settled = settled + 1 if int(st.get("blocks_queued", 0)) == 0 and int(st.get("lod_regions_dirty", 0)) == 0 else 0
				await get_tree().process_frame
				frame += 1
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var suffix := "" if burst.size() == 1 else "_f%d" % target
			var path: String = dir.path_join(v[0] + suffix + ".png")
			img.save_png(path)
			print("saved ", path)
			if not ab.is_empty():
				var was := {}
				for ch in ab:
					was[ch] = client.material_strength(ch)
					client.set_material_strength(ch, 0.0)
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var off_path: String = dir.path_join(v[0] + suffix + "_off.png")
				get_viewport().get_texture().get_image().save_png(off_path)
				print("saved ", off_path, " (", ",".join(ab), " = 0)")
				for ch in was:
					client.set_material_strength(ch, was[ch])
				await RenderingServer.frame_post_draw
	# Put the player back where the sweep found them. Each view pose is sent
	# to the server so it keeps streaming blocks around the camera, but the
	# server treats a large jump as speed-hacking and resets us, while a
	# small one it simply accepts. Left alone, every run walks the saved
	# position a little further along and eventually into a hillside.
	client.set_player_pose(base, 0, 0)


# Per-frame environment extras: the cave head-light follows the camera, and
# the fog switches to a dense underwater tint while the eye is submerged.
# First-person arm swing: continuous chop while digging, a single bob on
# place. The arm itself (and the item in its hand) is the body's right arm,
# posed toward the camera by the renderer; this just drives the phase.
func _update_wield(delta: float) -> void:
	if swing_t < 1.0:
		swing_t = minf(swing_t + delta * 3.4, 1.0)
	elif wield_dig_active:
		swing_t = 0.0
	client.set_arm_swing(sin(swing_t * PI))

func _update_environment_extras() -> void:
	if headlight:
		headlight.global_position = cam.global_position
		# The carried light: whatever is in the hand lights the world with
		# the light it would cast placed, on top of the faint cave aid. A
		# torch at night makes a pool that travels with the player, which no
		# vanilla client does and every night scene wanted. Lerped so
		# switching items breathes rather than snaps.
		if headlight_auto and client.has_method("wield_light"):
			var carried: float = float(client.wield_light()) / 255.0
			var k := minf(get_process_delta_time() * 8.0, 1.0)
			headlight.light_energy = lerpf(headlight.light_energy, 0.5 + 2.2 * carried, k)
			headlight.omni_range = lerpf(headlight.omni_range, 9.0 + 9.0 * carried, k)
			headlight.light_color = Color(1.0, 0.96, 0.9).lerp(Color(1.0, 0.72, 0.42), carried)
	# scroll the cloud layer by the server's cloud speed
	cloud_off += cloud_speed * get_process_delta_time() * 0.004
	sky_mat.set_shader_parameter("cloud_offset", cloud_off)
	# Signed height relative to the eye. Clamping this above the camera made the
	# visual deck rise forever as the player flew, so it behaved like a ceiling
	# that could never be entered or passed. The sky shader now intersects rays
	# with the slab from either side and while the eye is inside it.
	sky_mat.set_shader_parameter("cloud_plane_h", cloud_height - cam.position.y)
	# The node shaders' cloud shadows read the same deck: scroll, coverage,
	# strength, and where the deck is so the shadow is cast along the sun.
	RenderingServer.global_shader_parameter_set("goanna_cloud_shadow",
			Vector4(cloud_off.x, cloud_off.y, cloud_cov, cloud_shadow_k))
	# The x component is the scale of the weather envelope the sky's
	# volumetric clouds are placed by (cloud_weather in sky.gdshader), so the
	# ground shadows fall roughly under the masses that cast them.
	RenderingServer.global_shader_parameter_set("goanna_cloud_geom",
			Vector4(0.0009, maxf(cloud_height, cam.position.y + 10.0), sun_par.x, sun_par.y))
	if atmosphere_mat:
		atmosphere_mat.set_shader_parameter("weather_offset", cloud_off)
		atmosphere_mat.set_shader_parameter("cloud_level", cloud_height)
		# Luanti's decorative sheet is commonly only 8--16 nodes thick. A real
		# cloud body needs enough vertical extent to have a base, interior and
		# crown at the froxel resolution.
		atmosphere_mat.set_shader_parameter("cloud_thickness", maxf(cloud_thickness, 48.0))
		atmosphere_mat.set_shader_parameter("cloud_coverage", cloud_cov)
		# Local volume quality is the first atmospheric detail surrendered under
		# load; the horizon continuation remains in the much cheaper sky pass.
		atmosphere_mat.set_shader_parameter("cloud_density", 0.026 * atmosphere_quality)
		# Keep the reference at the world's inhabited surface while flying; a
		# camera-relative layer would rise with the player and erase valleys.
		atmosphere_mat.set_shader_parameter("mist_level",
				atmosphere_ground + 18.0 if atmosphere_ground_set else cam.position.y + 12.0)
		atmosphere_mat.set_shader_parameter("mist_density",
				0.012 * (0.35 + cloud_cov) * atmosphere_quality)
		atmosphere_mat.set_shader_parameter("quality", atmosphere_quality)
	var under: bool = client.is_underwater(cam.position)
	if atmosphere_volume:
		atmosphere_volume.visible = not under and atmosphere_quality > 0.01
	if under == underwater:
		return
	underwater = under
	var e := env.environment
	if under:
		# Murky blue-green underwater fog; you can tell you are submerged and
		# the view shortens the way it should.
		e.fog_enabled = true
		# Exponential, not the depth curve the open air uses: under water the
		# murk is a property of the water and starts at the eye, where the
		# air's haze is a property of how far there is anything to see and
		# holds off until near that edge. _apply_sky puts the depth curve back
		# when the eye leaves the water.
		e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		e.fog_light_color = Color(0.10, 0.28, 0.34)
		e.fog_density = 0.12
		e.fog_aerial_perspective = 0.0
		e.fog_sky_affect = 1.0
		# Light shafts: sun scattering through the participating water volume.
		# Moderate anisotropy and density: pushing either too hard shows the
		# fog volume's depth slices as bands.
		e.volumetric_fog_enabled = true
		e.volumetric_fog_density = 0.09
		e.volumetric_fog_albedo = Color(0.25, 0.55, 0.62)
		e.volumetric_fog_anisotropy = 0.72
		e.volumetric_fog_length = 48.0
		e.volumetric_fog_detail_spread = 2.0
		# The air's warm scatter toward a low sun belongs to the air. Left
		# standing while the eye is under water it lights the murk from the
		# direction of a sun that is not down here, which reads as a glow
		# with no source. _apply_sky sets it again on the way out.
		e.fog_sun_scatter = 0.0
	else:
		# Restore the surface fog from the current sky state.
		_apply_sky()

# Map Luanti's sky/lighting state onto Godot's sun, sky and fog. Colours and the
# day/dawn/night scheme are the server's (or Luanti's defaults); the blend by
# sun elevation approximates Sky::update in the vanilla client.
# Read a tuning override from the environment, falling back to the default.
# Push the lighting levels onto the environment. The sun follows on the next
# frame through _apply_sky, which reads light_sun directly.
func apply_lighting() -> void:
	if env == null or env.environment == null:
		return
	var e := env.environment
	e.tonemap_white = light_white
	e.sdfgi_energy = light_sdfgi
	e.sdfgi_enabled = OS.get_environment("GOANNA_NO_SDFGI") == "" and light_sdfgi > 0.01
	e.sdfgi_min_cell_size = light_sdfgi_cell
	e.ssao_intensity = light_ssao
	# The slider's visible half. SSAO's own intensity only darkens ambient
	# light, and the chart measured that with SDFGI on it "barely touched
	# the bay and cost the sun cube two counts": in a sunlit scene nearly
	# all light is direct, so the slider read as dead at any value. Scaling
	# the direct-light share with the same slider gives it teeth where the
	# player is actually looking.
	e.ssao_light_affect = clampf(light_ssao * 0.09, 0.0, 0.72)
	# exposure and the sky fill follow on the next _apply_sky, which scales
	# them by the server's correction and the time of day. The shafts are
	# shaped there too, by the sun's elevation and the weather, so ask for
	# that now rather than leaving the slider dead until the next sky packet.
	_apply_sky()

func _envf(name: String, dflt: float) -> float:
	var v := OS.get_environment(name)
	return float(v) if v != "" else dflt

# The colour clouds turn as the sun crosses the horizon: gold while it is
# still a little above it, hot orange right on the horizon, then through
# pink into magenta and on toward night blue as it sinks further. A single
# warm tint (what sun.light_color still uses, for the disc and direct
# light) reads as a mild colour shift; a sky on fire at sunset runs through
# several hues, which is what this stop table is for. `elev` is sun_dir.y,
# the same units _apply_sky already works in: 1 overhead, 0 the horizon,
# negative below it.
const CLOUD_TWILIGHT_STOPS := [
	[0.16, Color(1.0, 0.97, 0.90)],
	[0.06, Color(1.0, 0.82, 0.48)],
	[0.0, Color(1.0, 0.52, 0.22)],
	[-0.06, Color(0.95, 0.38, 0.42)],
	[-0.16, Color(0.62, 0.28, 0.48)],
	[-0.30, Color(0.30, 0.22, 0.42)],
	[-0.42, Color(0.14, 0.14, 0.24)],
]

static func _cloud_twilight_color(elev: float) -> Color:
	var stops := CLOUD_TWILIGHT_STOPS
	if elev >= stops[0][0]:
		return stops[0][1]
	if elev <= stops[-1][0]:
		return stops[-1][1]
	for i in stops.size() - 1:
		var a: Array = stops[i]
		var b: Array = stops[i + 1]
		if elev <= a[0] and elev >= b[0]:
			return (a[1] as Color).lerp(b[1], inverse_lerp(a[0], b[0], elev))
	return stops[-1][1]

# See the ground_tint declaration. The alpha of ground_albedo is the share of
# columns that answered; a frame with nothing loaded keeps the last colour.
func _ground_tint() -> Color:
	var dt := get_process_delta_time()
	ground_tint_timer -= dt
	if ground_tint_timer <= 0.0:
		ground_tint_timer = 0.5
		var cam := get_viewport().get_camera_3d()
		if cam != null and client != null:
			var s: Color = client.ground_albedo(cam.global_position)
			if s.a > 0.2:
				ground_tint_raw = Color(s.r, s.g, s.b)
			var h: float = client.ground_height(cam.global_position)
			if h > -1e8:
				terrain_ref = lerpf(terrain_ref, h, 0.35)
	ground_tint = ground_tint.lerp(ground_tint_raw, 1.0 - exp(-dt / 2.5))
	return ground_tint


func _apply_sky() -> void:
	var st: Dictionary = client.sky_state()
	if st.is_empty() or not st.has("sun_direction"):
		return
	var sun_dir: Vector3 = st["sun_direction"]
	var moon_dir: Vector3 = st["moon_direction"]
	var e := env.environment
	var sky: Dictionary = st["sky"]
	var elev: float = sun_dir.y  # 1 = overhead, <0 below horizon
	# --- sun and moon lights ---
	# At the zenith the direction is parallel to UP, so pick another up vector.
	if sun_dir.length() > 0.001:
		var up := Vector3.UP if absf(sun_dir.y) < 0.999 else Vector3.FORWARD
		sun.transform = Transform3D(Basis.looking_at(-sun_dir, up), Vector3.ZERO)
	if moon_dir.length() > 0.001:
		var up := Vector3.UP if absf(moon_dir.y) < 0.999 else Vector3.FORWARD
		moon.transform = Transform3D(Basis.looking_at(-moon_dir, up), Vector3.ZERO)
	var day: float = smoothstep(-0.02, 0.18, elev)
	var warm: float = 1.0 - smoothstep(0.0, 0.32, elev)
	sun.light_color = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.62, 0.32), warm)
	# Hold the sun through the golden hour. Its energy used to follow `day`
	# alone, which is near zero exactly when the sky peaks pink, so the
	# clouds burned and the trees stood in flat grey-green: the water showed
	# the sunset (it mirrors the sky) and nothing on land was lit by it. The
	# hold peaks as the disc crosses the horizon and hands over both ways:
	# to `day` above it, to the night lights below minus 0.06, so noon and
	# night calibration are untouched and the low orange light rakes the
	# canopy at the moment the sky is worth reflecting.
	var dusk_hold: float = smoothstep(-0.06, -0.005, elev) \
			* (1.0 - smoothstep(0.02, 0.10, elev))
	sun.light_energy = light_sun * maxf(day, 0.4 * dusk_hold)
	sun.visible = sun.light_energy > 0.01
	var moon_up: float = smoothstep(-0.02, 0.15, moon_dir.y) * (1.0 - day)
	# Scaled by the same slider as the sun, which is what its tooltip has
	# always claimed. The old hardcoded 0.25 was the reason night stayed
	# pitch black however the lighting settings were moved: no knob reached
	# it, and with SDFGI replacing ambient outright the moon is most of what
	# a night scene has.
	moon.light_energy = light_sun * 0.3 * moon_up
	moon.visible = moon.light_energy > 0.005
	var shadow_intensity: float = st["lighting"]["shadow_intensity"]
	# Luanti servers set 0..1; 0 means "not requested" for old games -> keep shadows but soft.
	# Luanti's shadow_intensity tunes its own much weaker shadow renderer
	# (Mineclonia sends 0.33), which left Goanna's shadows barely visible.
	# Treat it as a floor rather than a ceiling: real shadows are the point.
	sun.shadow_opacity = 1.0 if shadow_intensity <= 0.0 else clamp(shadow_intensity, 0.85, 1.0)
	moon.shadow_opacity = sun.shadow_opacity
	# --- sky colours: blend day / dawn / night like the vanilla sky ---
	var dawn: float = clamp(1.0 - abs(elev) / 0.22, 0.0, 1.0)
	var night: float = smoothstep(0.02, -0.25, elev)
	var day_w: float = clamp(1.0 - dawn - night, 0.0, 1.0)
	var top: Color = sky["day_sky"] * day_w + sky["dawn_sky"] * dawn + sky["night_sky"] * night
	var hor: Color = sky["day_horizon"] * day_w + sky["dawn_horizon"] * dawn + sky["night_horizon"] * night
	if str(sky["type"]) == "plain":
		top = sky["bgcolor"]; hor = sky["bgcolor"]
	# Servers send a fairly desaturated zenith (Mineclonia's day_sky is
	# 0.53,0.53,0.59), which the vanilla client renders flat. Deepen the
	# zenith while keeping the server's hue and leaving the horizon pale, so
	# the sky has the gradient a real one does. A look choice, like drawing
	# real shadows: black night skies are unaffected (saturating black is a
	# no-op).
	var zenith := top
	zenith.s = maxf(zenith.s, 0.42)
	zenith.v = minf(zenith.v, 0.92)
	sky_mat.set_shader_parameter("sky_top", zenith)
	sky_mat.set_shader_parameter("sky_horizon", hor)
	# The water surface reflects the sky wherever its screen space ray runs off
	# the frame, which is most of the time, so it needs the same two colours.
	# Linear, because source_color uniforms are converted on assignment and a
	# plain vec3 one is not.
	var zl := zenith.srgb_to_linear()
	var hl := hor.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("goanna_sky_top", Vector3(zl.r, zl.g, zl.b))
	RenderingServer.global_shader_parameter_set("goanna_sky_horizon", Vector3(hl.r, hl.g, hl.b))
	# The sun in that same fallback: the water shader draws the disc and its
	# halo itself, because a ray reflected off water near the horizon almost
	# always leaves the screen, and without this the sunrise and sunset never
	# reached the far sea. The glow carries the sun's warm colour and dies as
	# the disc sinks, or whenever the server hides it (weather skies).
	var sun_glow: Color = sun.light_color.srgb_to_linear() \
			* (smoothstep(-0.08, 0.0, elev) if bool(st["sun"]["visible"]) else 0.0)
	RenderingServer.global_shader_parameter_set("goanna_sun_dir",
			sun_dir.normalized() if sun_dir.length() > 0.001 else Vector3.UP)
	RenderingServer.global_shader_parameter_set("goanna_sun_glow",
			Vector3(sun_glow.r, sun_glow.g, sun_glow.b))
	sky_mat.set_shader_parameter("ground_color", hor.darkened(0.6))
	# The haze band under the horizon line, wide enough that a gap in the far
	# field reads as distance rather than as a hole in the world.
	sky_mat.set_shader_parameter("ground_curve", sky_ground_curve)
	# What the sky feeds to lighting, as against what it shows: see the
	# radiance_* uniforms in sky.gdshader and the environment comment in
	# _ready. The night floor is the night horizon colour, scaled, by how
	# much night it is; the sky fill the node shaders add is the horizon
	# colour pulled half way to grey, by day only, times light_fill.
	sky_mat.set_shader_parameter("radiance_ground_lift", 1.0)
	sky_mat.set_shader_parameter("radiance_desaturate", 0.25)
	# The floor takes the server's HUE and this client's BRIGHTNESS. It was
	# night_horizon * 3.5, a multiplier calibrated against a near-black
	# horizon; Mineclonia sends #4A6790 (luminance 0.39), and 3.5 times that
	# is a radiance of 1.4, which lit the midnight ground like an overcast
	# day and turned the sand salmon. Normalising to a fixed dim luminance
	# gives the same dim blue night whether a server authors its horizon
	# black or mid blue, and a black one no longer zeroes the whole chain.
	var nh: Color = sky["night_horizon"]
	var nh_lum := nh.get_luminance()
	# The server's hue at unit luminance; a black horizon falls back to the
	# dim blue every vanilla night has.
	var night_col: Color = nh * (1.0 / nh_lum) if nh_lum >= 0.004 else Color(0.72, 0.92, 1.6)
	var floor_col: Color = night_col * (0.045 * night)
	sky_mat.set_shader_parameter("radiance_floor", Vector3(floor_col.r, floor_col.g, floor_col.b))
	# The night share is 1.6 times the day strength: measured on the jungle at
	# the spawn, a night fill equal to the day's left the canopy at a fifth of
	# its day brightness, which is the vanilla client's night and reads as
	# black next to it; 1.6 puts it near two fifths, dark but legible.
	# The dawn term bridges a gap that read as the land going black at
	# sunrise: the night fill fades out as the sun nears the horizon, the
	# moon has set, the sun's own energy has barely begun its ramp, and with
	# SDFGI off the ambient follows the server's day night ratio, which lags
	# the sky colours. For a few minutes every source was near zero at once
	# under a bright sky. Twilight is the sky lighting the ground, so the
	# fill carries the horizon colour through dawn and dusk, handing over to
	# the day term as the sun's ramp arrives, and the golden light lasts as
	# long on the land as it does in the sky.
	# The night term is normalised the same way as the radiance floor above
	# and for the same reason: 1.6 times a mid blue horizon was daylight.
	# The land under a twilight sky borrows the colour ramp the cloud deck
	# burns through (_cloud_twilight_color, hoisted here from the cloud
	# block below): the server's horizon blend never reaches the magenta
	# band, so the fill stayed dull blue while the sky went purple, and a
	# cliff face stood grey under a violet sunset. Only the hue of the dawn
	# term moves; its magnitude curve keeps its calibration.
	var tw_rise: float = smoothstep(-0.42, -0.06, elev)
	var tw_fall: float = 1.0 - smoothstep(0.02, 0.28, elev)
	var tw_k: float = clamp(tw_rise * tw_fall, 0.0, 1.0)
	var tw_col: Color = _cloud_twilight_color(elev)
	# The twilight term rides maxf(dawn, tw_k * 0.45): the dawn band dies at
	# elev -0.22 while the violet phase of the ramp runs to -0.42, and with
	# dawn alone as the carrier the land had gone dark before the sky's
	# purple arrived, which read as grey cliffs under a violet sky. The
	# extension decays with tw_k itself, so deep night keeps its floor.
	var fill: Color = hor.lerp(Color(hor.v, hor.v, hor.v), 0.5) * (light_fill * day) \
			+ hor.lerp(tw_col, 0.6 * tw_k) \
			* (light_fill * 0.9 * maxf(dawn, 0.45 * tw_k) * (1.0 - day)) \
			+ night_col.lerp(tw_col, 0.35 * tw_k) * (0.10 * light_fill * night)
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(fill.r, fill.g, fill.b))
	# The lower hemisphere of the same fill: what the ground throws back,
	# dimmer and pulled toward earth. The node shaders blend by the world
	# normal. "Earth" used to be a constant (1.0, 0.9, 0.72); it is now the
	# sampled colour of the actual ground around the camera, so the underside
	# of a canopy is warm red over desert and green over a plain, which is
	# the colour bleed the GI is too coarse to show.
	var galb := _ground_tint()
	var glum: float = maxf(galb.get_luminance(), 0.05)
	var gw: Color = galb * (0.92 / glum)
	var gfill := fill * 0.6
	RenderingServer.global_shader_parameter_set("goanna_ground_fill",
			Vector3(gfill.r * minf(gw.r, 1.4), gfill.g * minf(gw.g, 1.4),
					gfill.b * minf(gw.b, 1.4)))
	# Cloud shadow strength: by day only, and by how much cloud there is to
	# cast one. 0.35 of the light at full coverage, soft, never black.
	#
	# Rain thickens the deck. The protocol has no weather, and Mineclonia
	# says "rain" with a particle spawner and a greyer cloud colour while
	# leaving the density alone, so the storm sky is inferred from the rain:
	# precipitation eases coverage toward overcast and back out again after,
	# and the same figure feeds the sky march, the froxel bodies and the
	# ground shadows so all three agree.
	var pnode_sky := get_tree().get_first_node_in_group("goanna_particles")
	var precip_now: float = float(pnode_sky.precipitation()) if pnode_sky != null else 0.0
	storm_cover = lerpf(storm_cover, 0.80 * precip_now,
			1.0 - exp(-get_process_delta_time() / 6.0))
	# Wet ground: rain soaks in over half a minute and dries off over a few
	# minutes after it stops, so a passing shower leaves the world gleaming
	# for a while. The shaders decide what wet means per surface (up facing,
	# sky lit, porosity from the pack's _s); this is only how rained-on the
	# world currently is.
	var wet_target: float = smoothstep(0.15, 0.6, precip_now)
	var wet_rate: float = 30.0 if wet_target > wetness else 150.0
	wetness = lerpf(wetness, wet_target,
			1.0 - exp(-get_process_delta_time() / wet_rate))
	RenderingServer.global_shader_parameter_set("goanna_wetness", wetness)
	var cdens: float = float(st["clouds"]["density"]) if st.has("clouds") else 0.0
	cdens = maxf(cdens, storm_cover)
	cloud_cov = clamp(cdens, 0.0, 0.95) if bool(sky.get("clouds", true)) else 0.0
	cloud_shadow_k = 0.35 * day * smoothstep(0.02, 0.15, cloud_cov)
	sun_par = Vector2(sun_dir.x, sun_dir.z) / maxf(sun_dir.y, 0.25)
	# And the bounce follows whichever light is up: strongest at noon,
	# earthy, from below, biased away from the light's azimuth as real
	# ground bounce is. At night it is the moon's light thrown back, cooler
	# and dimmer; without it the underside of everything was pure black,
	# which is the half of "night is pitch black" that the moon alone
	# cannot fix.
	var lit_dir := sun_dir if day > moon_up else moon_dir
	var bdir := Vector3(-lit_dir.x * 0.35, 1.0, -lit_dir.z * 0.35).normalized()
	bounce.transform = Transform3D(Basis.looking_at(bdir, Vector3.FORWARD), Vector3.ZERO)
	# The dusk hold reaches the bounce too: golden hour side light deserves
	# its counter-glow, or the shadow side of a canopy goes black while the
	# lit side burns.
	bounce.light_energy = light_sun * 0.16 * maxf(maxf(day, 0.5 * dusk_hold), 0.4 * moon_up) \
			* (0.35 if env.environment.sdfgi_enabled else 1.0)
	# What the bounce carries is the key light times what the ground
	# reflects. The ground's share used to be the fixed earthy constant
	# (0.62, 0.55, 0.44); it is now the sampled surroundings at that
	# constant's brightness, so the sliders keep their calibration and only
	# the hue follows the terrain.
	var bcol: Color = galb * (0.56 / glum)
	bcol = Color(minf(bcol.r, 1.0), minf(bcol.g, 1.0), minf(bcol.b, 1.0))
	bounce.light_color = (bcol * sun.light_color) if day > moon_up \
			else Color(bcol.r * 0.55, bcol.g * 0.62, bcol.b * 0.82)
	bounce.visible = bounce.light_energy > 0.005
	sky_mat.set_shader_parameter("sun_dir", sun_dir.normalized() if sun_dir.length() > 0.001 else Vector3.UP)
	sky_mat.set_shader_parameter("moon_dir", moon_dir.normalized() if moon_dir.length() > 0.001 else Vector3.DOWN)
	sky_mat.set_shader_parameter("sun_visible", bool(st["sun"]["visible"]))
	sky_mat.set_shader_parameter("moon_visible", bool(st["moon"]["visible"]))
	sky_mat.set_shader_parameter("sun_size", 0.045 * float(st["sun"]["scale"]))
	# 0.028, not 0.02: the disc graphic in a phase sheet fills about 40 per
	# cent of its cell (measured on Mineclonia's), so the quad has to be
	# larger than the moon the player should see.
	sky_mat.set_shader_parameter("moon_size", 0.028 * float(st["moon"]["scale"]))
	sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	_set_sky_disc("sun_tex", "sun_use_tex", str(st["sun"]["texture"]))
	_set_sky_disc("moon_tex", "moon_use_tex", str(st["moon"]["texture"]))
	# stars: the server gives colour, count and how much survives daylight
	var stars: Dictionary = st["stars"]
	var star_col: Color = stars["color"]
	var star_vis: float = (1.0 if bool(stars["visible"]) else 0.0) * lerp(1.0, float(stars["day_opacity"]), day)
	sky_mat.set_shader_parameter("star_opacity", star_col.a * star_vis)
	sky_mat.set_shader_parameter("star_color", star_col)
	sky_mat.set_shader_parameter("star_density", clamp(float(stars["count"]) / 3000.0, 0.05, 0.6))
	# clouds: density/colour here, scroll and height per frame
	var clouds: Dictionary = st["clouds"]
	var ccol: Color = clouds["color_bright"]
	ccol.a = clamp(0.55 + 0.45 * float(clouds["density"]), 0.0, 1.0)
	# Clouds are the highest thing in the scene, so the sun clears the
	# horizon for them before it does for the ground, and stays on them
	# after the ground has gone dark: real dawn shows in the clouds before
	# the ground brightens, and dusk lingers in them after it dims. So the
	# dark floor below only bites once well past where the ground alone
	# would already call it night (`night` reaches 1 by elev -0.25).
	var cloud_night: float = smoothstep(-0.42, -0.60, elev)
	var cdim: float = lerp(1.0, 0.16, cloud_night)
	ccol = Color(ccol.r * cdim, ccol.g * cdim, ccol.b * cdim, ccol.a)
	sky_mat.set_shader_parameter("cloud_color", ccol)
	# The twilight glow itself: a window centred on the horizon, wider than
	# the ground's own day/night bands for the same reason as cloud_night
	# above, carrying the colour ramp and how strongly it currently applies.
	# tw_k and tw_col are computed beside the sky fill above, which now
	# shares them.
	sky_mat.set_shader_parameter("cloud_twilight_color", Vector3(tw_col.r, tw_col.g, tw_col.b))
	sky_mat.set_shader_parameter("cloud_twilight_k", tw_k)
	sky_mat.set_shader_parameter("cloud_coverage",
			clamp(maxf(float(clouds["density"]), storm_cover), 0.0, 0.95)
			if bool(sky.get("clouds", true)) else 0.0)
	var cs: Vector2 = clouds["speed"]
	cloud_speed = cs
	cloud_height = float(clouds["height"])
	cloud_thickness = maxf(float(clouds.get("thickness", 16.0)), 8.0)
	sky_mat.set_shader_parameter("cloud_thickness", cloud_thickness)
	# --- fog ---
	# While the eye is underwater, _update_environment_extras owns the fog and
	# the shaft volume; sky packets must not clobber them.
	if not underwater:
		var fog_col: Color = hor
		if str(sky["fog_tint_type"]) == "default":
			fog_col = fog_col.lerp(sky["fog_sun_tint"], 0.35 * dawn)
		var fc: Color = sky["fog_color"]
		if fc.a > 0.0:
			# A server fog override is commonly authored as one daytime colour.
			# Replacing the blended night horizon with it made distant terrain
			# fade toward a pale day haze under a black sky. Honour it by day and
			# hand back to the server's time-aware horizon through the night.
			fog_col = fog_col.lerp(fc, fc.a * (1.0 - night))
		# The deck darkens with the storm but the haze band kept the server's
		# fair weather horizon, so a rainstorm wore a bright pale band between
		# dark clouds and dark ground, with a hard join where the fogged sky
		# hands over to the deck. Pull the air down with the same cover the
		# deck answers to and the two meet as one weather.
		fog_col = fog_col.darkened(0.5 * smoothstep(0.4, 0.95, cloud_cov))
		e.fog_light_color = fog_col
		sky_mat.set_shader_parameter("haze_color", fog_col)
		# `twilight` is deliberately wider than the ground's dawn band; using
		# dawn alone left the directly sunlit land orange after the sky had
		# already snapped back to blue.
		sky_mat.set_shader_parameter("haze_twilight", maxf(dawn, tw_k))
		if atmosphere_mat:
			atmosphere_mat.set_shader_parameter("atmosphere_color", fog_col)
		# How far there is actually something to see, which is not how far we
		# are permitted to draw. The live range is always there; past it the
		# far field reaches only as far as the store and the server's
		# summaries have filled, which on a new world is very little and grows
		# for minutes. Haze tied to the permitted distance instead left the
		# terrain ending in clear air, which is the whole of what a fresh
		# world looked wrong for: measured 2026-08-22 on a fresh profile with
		# far_blocks at 0, terrain stopping at 192 nodes and the fog set to
		# close at 512. So the cap bounds it and the content decides it.
		var live_nodes: float = maxf(float(client.view_range()) * 16.0, 64.0)
		var draw_nodes: float = live_nodes
		# Where the haze starts. The near field is the foreground layer and it
		# is meant to be clear (docs/launch-target.md, "The rule: one light,
		# one air"), so this is floored at the live range below.
		var haze_from: float = live_nodes
		var stats: Dictionary = client.render_stats() if client.has_method("render_stats") else {}
		if int(stats.get("far_grant", 0)) > 0 and client.has_method("far_distance"):
			var cap: float = minf(float(client.far_distance()), float(stats.get("far_grant", 0)))
			# Two numbers off the same per sector histogram, because one
			# radius cannot describe a ragged frontier. far_extent is the
			# lower quartile across the eight sectors, how far a poor
			# direction reaches; far_reach is the upper quartile, how far a
			# good one does. Closing the haze at the extent meant every good
			# direction had its real terrain flattened to sky colour: measured
			# on the test world at a 1024 node grant, the extent was 496 nodes
			# while the field reached past 900, so nearly half of what had
			# been built and drawn was behind solid fog, and the player
			# reported the fog as being nearer than the far land. A depth fog
			# has a begin and an end, so it can have both: the haze opens
			# where the sparse directions run out and closes where the rich
			# ones do.
			var far_extent: float = float(stats.get("far_extent", 0))
			var far_reach: float = maxf(far_extent, float(stats.get("far_reach", 0)))
			draw_nodes = clampf(far_reach, live_nodes, maxf(live_nodes, cap))
			haze_from = clampf(far_extent, live_nodes, draw_nodes)
		# Summary areas arrive a whole 128-node slab at a time. Ease that
		# quantisation out of the camera and fog endpoints, and retreat much
		# more slowly than we advance so a transient ownership change cannot
		# pull the horizon visibly toward the player.
		if fog_draw_smoothed <= 0.0:
			fog_draw_smoothed = draw_nodes
			fog_begin_smoothed = haze_from
		var dt := maxf(get_process_delta_time(), 0.001)
		var draw_tau := 1.5 if draw_nodes >= fog_draw_smoothed else 10.0
		var begin_tau := 2.5 if haze_from >= fog_begin_smoothed else 12.0
		fog_draw_smoothed = lerpf(fog_draw_smoothed, draw_nodes, 1.0 - exp(-dt / draw_tau))
		fog_begin_smoothed = lerpf(fog_begin_smoothed, haze_from, 1.0 - exp(-dt / begin_tau))
		draw_nodes = maxf(live_nodes, fog_draw_smoothed)
		haze_from = clampf(fog_begin_smoothed, live_nodes, draw_nodes)
		# The far plane has to clear whatever is actually drawn, or the
		# far tiers' own horizon is what clips them, not the fog. A fixed
		# margin on top of draw_nodes rather than a multiple: at a 4000
		# node grant a 10 per cent margin is 400 nodes for no reason,
		# while 256 covers the coarsest region's own size at any grant.
		cam.far = maxf(1000.0, draw_nodes + 256.0)
		atmosphere_length = clampf(draw_nodes + 96.0, 256.0, 768.0)
		# The background layer, docs/far-rendering.md "Background, overlay,
		# foreground". Depth fog rather than exponential: an exponential curve
		# cannot be both clear in the foreground and closed at the cap, because
		# the density that hides the far edge puts most of its extinction on
		# the mid ground and lays a veil over everything. Depth fog takes a
		# begin, an end and a curve, so the near field stays clear, the haze
		# builds over the outer part and closes at the edge of what is drawn.
		# Terrain that has not arrived yet, and the gaps between panels, are
		# then haze at the horizon's own colour rather than a void, and a panel
		# emerges from that haze as the player walks toward it.
		var fog_end: float = draw_nodes
		var fog_distance: float = sky["fog_distance"]
		if fog_distance > 0.0:
			# a server asking for closer fog than our range still wins
			fog_end = minf(fog_end, fog_distance)
			haze_from = minf(haze_from, fog_end)
		e.fog_mode = Environment.FOG_MODE_DEPTH
		# The fraction is the floor, not the answer. It was the whole answer,
		# and on the test world that put the haze's start at 149 nodes against
		# a 192 node live range: the near field, which is the one layer that
		# is always complete and always worth seeing, was under haze before
		# the far field began. Whichever of the two is further out wins, so
		# the foreground stays clear and the fraction still covers the case
		# where there is no far field at all and the live edge is what has to
		# be hidden.
		#
		# The ceiling is the other half. Once the field fills evenly the
		# extent catches the reach up, and without a bound the haze collapsed
		# into the last fifty nodes: measured at 958 to 1008 on a field that
		# had reached the whole grant, which is a hard edge rather than a
		# horizon. Half the drawn depth is always haze, whatever the
		# frontier is doing: the reference look builds its aerial
		# perspective over the whole back half of the vista rather than
		# saving it for the last stretch.
		e.fog_depth_begin = clampf(haze_from, fog_end * fog_clear_fraction, fog_end * 0.5)
		e.fog_depth_end = fog_end
		e.fog_depth_curve = fog_curve
		# Never quite all of it. Full extinction paints every pixel past the
		# drawn edge in one flat fog colour, and since that colour is the
		# horizon's it is brighter than night terrain and brighter than the
		# zenith, so it reads as a pale band laid across the world rather than
		# as distance. Measured on a server with no far rendering granted:
		# fog closing at the 192 node live edge, colour 74,103,144, against
		# near black ground. The vanilla client does not do this, and what it
		# does instead is exactly this: haze that keeps rising and never
		# arrives, so the furthest terrain is a tint of itself rather than
		# gone. What is left visible at the edge is a silhouette, which is a
		# better answer than a wall even where there is a ragged far field
		# frontier behind it.
		# The haze is a layer the terrain wears, not a property of distance in
		# empty air. Godot's depth fog knows only the ramp, so from altitude
		# every slant ray to the ground crossed it and the whole map drowned
		# in one flat horizon colour (reported from a Terrain Diffusion world
		# at height: "the entire ground turns into this horrible distance
		# fog"). Godot's own height fog modulates by the fragment's height,
		# and the ground is always inside the layer, so it cannot say this;
		# thinning the density by how far the camera stands above the terrain
		# can. At ground level nothing changes; climbing out of the layer
		# clears the view straight down while the sky shader's own haze band
		# still holds the horizon.
		var alt_above: float = get_viewport().get_camera_3d().global_position.y \
				- terrain_ref if get_viewport().get_camera_3d() else 0.0
		var alt_clear: float = smoothstep(90.0, 360.0, alt_above)
		e.fog_density = fog_max * (1.0 - 0.85 * alt_clear)
		# Aerial perspective blends distant geometry toward the sky, which is
		# what actually sells a vista; it wants to be stronger the further we
		# draw, so a 512 node horizon reads as haze rather than a hard edge.
		# Not stronger at night, though that was tried: Godot blends toward
		# the sky's radiance, which _apply_sky lifts at night so that the
		# ground is lit at all, and the haze came out brighter than the band.
		var aerial: float = clamp(0.12 + 0.35 * clamp((draw_nodes - 192.0) / 512.0, 0.0, 1.0), 0.12, 0.5)
		# Aerial perspective samples sky radiance, which is intentionally
		# lifted at night to provide ambient light. Using that lifted radiance
		# as fog colour is what faded mountains and trees toward white. Night
		# keeps the depth fog above, already coloured and dimmed from the night
		# horizon; sky-radiance blending belongs to daylight and twilight.
		e.fog_aerial_perspective = aerial * maxf(day, dawn * 0.65) * (1.0 - 0.7 * alt_clear)
		# Ramped, not stepped. draw_nodes follows far_reach, which grows as the
		# far field fills, so this crossed its threshold while the player stood
		# still and the sky snapped between clear and hazy like a switch. The
		# aerial term above already ramps over the same quantity; this was the
		# one hard edge left in the sky's response to draw distance.
		e.fog_sky_affect = lerpf(0.1, 0.5, smoothstep(220.0, 340.0, draw_nodes)) \
				* (1.0 - 0.6 * alt_clear)
	# --- ambient / grade from day-night ratio and server lighting ---
	var ratio: float = st["day_night_ratio"]
	# Kept wired and kept honest: this line is inert while SDFGI is on, for
	# the reason measured in _apply_lighting, and it is the sdfgi off path
	# that it is here for. Day and night differ through the sky itself and
	# through background_energy_multiplier below, not through this.
	# maxf with the sun's own ramp: the server's ratio arrives in a late
	# steep step, and holding the ambient to it kept the ground at its night
	# level under a sky that was already blue.
	e.ambient_light_energy = lerp(0.14, 0.42, maxf(ratio, day)) * light_ambient
	# do not push the sky toward white; it reads as haze and flattens the blue
	#
	# Do not scale this to make the sky brighter against the ground. It is
	# tempting, because the server sends sky colours as display sRGB and they
	# then go through this and tonemap_exposure, so the visible sky lands well
	# under the lamp-lit ground. But ambient_light_source is AMBIENT_SOURCE_SKY
	# (see _apply_lighting) and sdfgi_read_sky_light is on, so this multiplier
	# is also how much light the sky casts on the world. Dividing it by the
	# exposure was tried on 2026-08-26: the sky matched, and the land was lit
	# like noon at midnight, because the ambient went up by the same factor.
	# Whatever fixes the sky against ground mismatch has to leave the sky's
	# contribution as a light source alone.
	e.background_energy_multiplier = lerp(0.25, 0.95, ratio)
	# And the haze is dimmed with it. The fog colour above is the server's
	# horizon colour as sent, but the sky is not drawn at that colour: this
	# multiplier darkens it, by four times at night. So the haze was four
	# times brighter than the sky it is supposed to be blending terrain into,
	# and distant ground came out as pale patches glowing against a dark night
	# sky, which is the most distracting thing in a night frame and reads as
	# the far field being lit wrongly when it is the air in front of it.
	# Underwater keeps its own murk, set in _update_environment_extras.
	#
	# And darker again by night. With the multiplier alone the haze at night
	# was the horizon band's own brightness, about twice what the vanilla
	# client's night sky comes to, and a hazed mountain standing above that
	# band against the black sky read as a pale grey silhouette, the far
	# field glowing (reported 2026-08-23 from a Mineclonia village at night).
	# Halving it by full night puts a hazed hill below the band rather than
	# at it, a dark shape on the horizon, which is what a night horizon
	# looks like; dusk and dawn are untouched. `night` is the same sun
	# elevation blend the sky colours use above.
	if not underwater:
		e.fog_light_color = e.fog_light_color * e.background_energy_multiplier * lerp(1.0, 0.5, night)
	var lighting: Dictionary = st["lighting"]
	# Server saturation on top of our base grade, not instead of it.
	e.adjustment_saturation = clamp(1.12 * float(lighting["saturation"]), 0.0, 2.0)
	e.tonemap_exposure = clamp(light_exposure * (1.0 + float(lighting["exposure_correction"]) * 0.25), 0.1, 3.0)
	e.glow_intensity = clamp(0.3 + float(lighting["bloom_intensity"]) * 2.0, 0.0, 2.0)
	# --- light shafts, and the air they are shafts in ---
	# Luanti's volumetric_light_strength is the server asking for god rays,
	# 0 to 1. Take it the way shadow_intensity is taken above, as a floor on
	# something Goanna draws anyway rather than as a switch: a server that
	# never sets it is not asking for a vacuum, it is a server whose own
	# client cannot draw this at all. The slider is where "none" lives.
	var vol: float = lighting["volumetric_light_strength"]
	if not underwater:
		# A shaft is a low sun effect. The light crosses far more air near
		# the horizon, and the forward scattering that makes a shaft visible
		# points it at an eye looking that way; the same density at noon is
		# only haze, so most of it is spent when the sun is low.
		var low: float = 1.0 - clamp(maxf(elev, 0.0) / 0.35, 0.0, 1.0)
		var air: float = (0.0007 + 0.0023 * low) * (0.25 + 0.75 * day)
		# Rain and snow are the air made visible, so the shafts thicken with
		# them. The particle side is what knows, the sky packet does not.
		var pnode := get_tree().get_first_node_in_group("goanna_particles")
		if pnode != null:
			air += 0.010 * float(pnode.precipitation())
		air *= (0.6 + 1.4 * vol) * light_shafts
		e.volumetric_fog_enabled = atmosphere_quality > 0.01 and (atmosphere_mat != null or air > 0.0004)
		if e.volumetric_fog_enabled:
			e.volumetric_fog_density = air
			# The air scatters the sun's own colour, which is what makes a
			# dawn shaft warm and a noon one white.
			e.volumetric_fog_albedo = Color(1.0, 0.98, 0.95).lerp(sky["fog_sun_tint"], 0.5 * dawn)
			e.volumetric_fog_anisotropy = 0.8
			# The volume is a fixed grid of froxels stretched over this range,
			# so range is bought with resolution: at 160 nodes the near field
			# was too coarse to hold the shadow of anything smaller than a
			# hillside and the light came out as an even glow. Shorter, with
			# the spread pushing more of the grid into the near field, is what
			# lets a lane in the air have an edge. Past it there is no volume
			# at all, which is the distance fog's job.
			e.volumetric_fog_length = lerpf(192.0, atmosphere_length, atmosphere_quality)
			e.volumetric_fog_detail_spread = 1.8
			# Fog in shadow lit by nothing at all is black, and black air
			# between shafts reads as smoke. Sky in it keeps the shadowed air
			# as air, and a share of GI lets the bounced sky light whiten a
			# daytime bank the way a real one is white. Both were lower and
			# the fog sat darker than the sky behind it, which is what turned
			# the whole scene into grey murk rather than into air: measured
			# as the frame mean at 119 with the volume on against 216 with it
			# off, on the same noon vista.
			e.volumetric_fog_ambient_inject = 0.9
			e.volumetric_fog_emission_energy = 0.0
			e.volumetric_fog_gi_inject = 0.4
			# The volume must also composite against the sky or a cloud has depth
			# only where terrain happens to be behind it, the exact hill-shaped
			# overlay failure. Full influence previously flattened the dome because
			# uniform air occupied every froxel. A partial composite preserves the
			# gradient while making sparse cloud/mist density visible in open sky
			# and joins the land and sky through the same participating medium.
			# 0.55 laid the froxel medium over the whole dome and greyed the
			# sky into permanent overcast; most of the sky is above the
			# volume and should stay the sky's own colour.
			e.volumetric_fog_sky_affect = 0.30 * atmosphere_quality
		# The shaft is the lamp's contribution to the volume, so this is the
		# knob that decides how much shaft there is, as against how much haze.
		# Scaled by how much of the sun the deck lets through: the raymarched
		# clouds cast no shadow map, so under full overcast the froxel air was
		# still lit by the bare sun and a white radial wall swallowed the
		# horizon whenever the camera faced it.
		var sun_open: float = 1.0 - 0.9 * smoothstep(0.35, 0.9, cloud_cov)
		sun.light_volumetric_fog_energy = 2.4 * light_shafts * sun_open
		# A strong moon contribution projected the froxel field onto hills like a
		# radial screen overlay. The broad moon halo belongs in the sky shader;
		# retain only enough here to silver genuinely nearby mist and cloud.
		moon.light_volumetric_fog_energy = 0.15 * light_shafts
		# The warm bloom in the air around a low sun. Distance fog can carry
		# it without the volume, and it survives at any shaft setting. The
		# same deck gate as the shafts above: a storm hidden sun blooms into
		# nothing.
		e.fog_sun_scatter = clamp((0.15 + 0.35 * dawn) * sun_open, 0.0, 1.0)
	# --- shader pack world state ---
	# What a pack's uniforms can honestly be told: the sky zenith as the
	# server blended it (before the look tweak above), the fog colour as the
	# environment now has it (the underwater tint while submerged), the
	# precipitation from the particle side, and "in water" for any liquid,
	# since the node definition does not say which liquids are lava.
	if iris:
		var pn := get_tree().get_first_node_in_group("goanna_particles")
		var rain: float = pn.precipitation() if pn != null else 0.0
		iris.set_world_state({"sun_direction": sun_dir, "moon_direction": moon_dir,
			"time_of_day": st["time_of_day"], "in_water": 1 if underwater else 0,
			"sky_color": top, "fog_color": e.fog_light_color, "rain": rain})


# Sun/moon disc textures come from the server's media through the texture
# modifier DSL (e.g. Mineclonia's moon phase sheet); null until media arrives.
func _set_sky_disc(tex_param: String, flag_param: String, tex_name: String) -> void:
	if tex_name == "":
		sky_mat.set_shader_parameter(flag_param, false)
		return
	var t: Texture2D = sky_tex_cache.get(tex_name)
	if t == null:
		t = client.texture(tex_name)
		if t != null:
			sky_tex_cache[tex_name] = t
	sky_mat.set_shader_parameter(flag_param, t != null)
	if t != null:
		sky_mat.set_shader_parameter(tex_param, t)

# How many hotbar slots the server is showing. Luanti selects over
# Player::getMaxHotbarItemcount(), not a fixed eight: Mineclonia and
# MineClone2 both use nine, so hard coding eight left their last slot drawn
# but unreachable, and nothing in it could be wielded or placed.
func _hotbar_count() -> int:
	if not client.has_method("hud_state"):
		return 8
	return clampi(int(client.hud_state().get("hotbar_itemcount", 8)), 1, 32)

func _set_wield(i: int) -> void:
	wield = i
	client.set_wield_index(i)

func _update_selection_box() -> void:
	if selection_box == null:
		selection_box = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.01, 1.01, 1.01)
		selection_box.mesh = bm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0, 0, 0, 0.35)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_FRONT
		m.no_depth_test = false
		selection_box.material_override = m
		add_child(selection_box)
	if pointed.get("type", "nothing") == "node":
		selection_box.visible = true
		# node centre: Luanti node p spans p +- 0.5
		selection_box.position = pointed["node"]
	else:
		selection_box.visible = false
