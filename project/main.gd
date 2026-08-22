extends Node3D

var client: GoannaClient
var ui: CanvasLayer
var cam: Camera3D
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var env: WorldEnvironment
var sky_mat: ShaderMaterial
var sky_tex_cache := {}
var cloud_off := Vector2.ZERO
var cloud_speed := Vector2(-2.0, 0.0)
var cloud_height := 120.0
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
# The background layer's shape (docs/far-rendering.md, "Background, overlay,
# foreground"), swept with GOANNA_FOG_CLEAR and GOANNA_FOG_CURVE. The fraction
# of the drawn distance that stays clear of haze, and the exponent on the ramp
# over the rest: above 1 the haze holds off and then closes near the edge,
# below 1 it starts early and rises slowly.
var fog_clear_fraction := 0.5
var fog_curve := 3.0
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
var iris: GoannaIrisEffect
var test_started := 0.0

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
	fog_clear_fraction = _envf("GOANNA_FOG_CLEAR", fog_clear_fraction)
	fog_curve = _envf("GOANNA_FOG_CURVE", fog_curve)
	sky_ground_curve = _envf("GOANNA_GROUND_CURVE", sky_ground_curve)
	if cfg.load("user://goanna.cfg") == OK:
		for k in ["sun", "ambient", "sdfgi", "sdfgi_cell", "ssao", "white", "exposure", "fill"]:
			if cfg.has_section_key("settings", "light_" + k):
				set("light_" + k, float(cfg.get_value("settings", "light_" + k)))
	client = GoannaClient.new()
	if OS.get_environment("GOANNA_SHADOW_LAMPS") != "":
		client.set_shadow_lamps(int(OS.get_environment("GOANNA_SHADOW_LAMPS")))
	add_child(client)
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
	if OS.get_environment("GOANNA_PERF") != "":
		# Uncapped: with vsync on, every measurement reads as the refresh rate
		# and says nothing about headroom.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
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

	env = WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/sky.gdshader")
	sky_mat = sm
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
	e.sdfgi_enabled = OS.get_environment("GOANNA_NO_SDFGI") == ""
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
	e.ssao_light_affect = 0.5
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
	if event is InputEventMouseButton and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dig_down = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			place_down = event.pressed
			if event.pressed:
				place_pressed = true
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_wield((wield + 7) % 8)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_wield((wield + 1) % 8)
	if event is InputEventKey and event.pressed and event.keycode >= KEY_1 and event.keycode <= KEY_8:
		_set_wield(event.keycode - KEY_1)
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		var dy: float = event.relative.y * mouse_sensitivity * (1.0 if invert_mouse else -1.0)
		pitch = clamp(pitch + dy, -89, 89)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F:
		fly_mode = not fly_mode
		print("fly mode: ", fly_mode)

func _process(delta: float) -> void:
	t += delta
	_apply_sky()
	var s: Dictionary = client.status()
	if not placed and s.get("state") == "ready":
		var p: Vector3 = client.server_player_position()
		cam.position = p + Vector3(0, 1.6, 0)
		placed = true
		print("camera placed at ", cam.position)
	if placed and not fly_mode:
		var keys := {
			"up": Input.is_key_pressed(KEY_W), "down": Input.is_key_pressed(KEY_S),
			"left": Input.is_key_pressed(KEY_A), "right": Input.is_key_pressed(KEY_D),
			"jump": Input.is_key_pressed(KEY_SPACE), "sneak": Input.is_key_pressed(KEY_SHIFT),
			"aux1": Input.is_key_pressed(KEY_E),
		}
		if OS.get_environment("GOANNA_WALKTEST") != "":
			keys = _walktest_keys()
		test_dig = false
		test_plc_pressed = false
		_test_hooks(keys)
		var ui_blocks: bool = ui != null and ui.blocks_input()
		if ui_blocks:
			for k in keys:
				keys[k] = false
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
	elif placed:
		# fly controls
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
			print("perf fps=%.0f frame=%.1fms | mesh=%.2f upload=%.2f lights=%.2f motes=%.2f ents=%.2f | meshed=%d queued=%d blocks=%d mats=%d | draws=%d objs=%d vram=%.0fMB | lod tiers=%s regions=%d dirty=%d quads=%d/%d surfaces=%d lod_ms=%.2f" % [
				Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0),
				st["mesh_ms"], st["upload_ms"], st["lights_ms"], st["motes_ms"], st["entities_ms"],
				st["blocks_meshed_last"], st["blocks_queued"], st["block_meshes"], st["materials"],
				st.get("draw_calls", 0), st.get("objects", 0), st.get("video_mem_mb", 0.0),
				str(st.get("lod_tiers", {})), st.get("lod_regions", 0), st.get("lod_regions_dirty", 0),
				st.get("lod_quads", 0), st.get("lod_faces", 0), st.get("lod_surfaces", 0), st.get("lod_ms", 0.0)]
				+ " | far=%d grant=%d store=%d/%.0fMB | poll_max=%.1fms chains=%d queue=%d" % [st.get("far_blocks", 0), st.get("far_grant", 0),
				st.get("store_blocks", 0), st.get("store_mb", 0.0), st.get("poll_max_ms", 0.0),
				st.get("lod_chains", 0), st.get("lod_chain_queue", 0)])
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
	# scroll the cloud layer by the server's cloud speed
	cloud_off += cloud_speed * get_process_delta_time() * 0.004
	sky_mat.set_shader_parameter("cloud_offset", cloud_off)
	sky_mat.set_shader_parameter("cloud_plane_h", clampf(cloud_height - cam.position.y, 10.0, 400.0))
	var under: bool = client.is_underwater(cam.position)
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
	e.sdfgi_min_cell_size = light_sdfgi_cell
	e.ssao_intensity = light_ssao
	# exposure and the sky fill follow on the next _apply_sky, which scales
	# them by the server's correction and the time of day

func _envf(name: String, dflt: float) -> float:
	var v := OS.get_environment(name)
	return float(v) if v != "" else dflt


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
	sun.light_energy = lerp(0.0, light_sun, day)
	sun.visible = sun.light_energy > 0.01
	var moon_up: float = smoothstep(-0.02, 0.15, moon_dir.y) * (1.0 - day)
	moon.light_energy = 0.25 * moon_up
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
	# Night was measured near black on the chart and in play (stone 22 on top,
	# 0 on a wall); the vanilla client's night is about 17.5 per cent of day.
	# The floor at 3.5 and a night fill in the night horizon colour put stone
	# near 70 on top and 20 on a wall, with noon unchanged.
	var floor_col: Color = sky["night_horizon"] * (3.5 * night)
	sky_mat.set_shader_parameter("radiance_floor", Vector3(floor_col.r, floor_col.g, floor_col.b))
	# The night share is 1.6 times the day strength: measured on the jungle at
	# the spawn, a night fill equal to the day's left the canopy at a fifth of
	# its day brightness, which is the vanilla client's night and reads as
	# black next to it; 1.6 puts it near two fifths, dark but legible.
	var fill: Color = hor.lerp(Color(hor.v, hor.v, hor.v), 0.5) * (light_fill * day) \
			+ sky["night_horizon"] * (light_fill * 1.6 * night)
	RenderingServer.global_shader_parameter_set("goanna_sky_fill", Vector3(fill.r, fill.g, fill.b))
	sky_mat.set_shader_parameter("sun_dir", sun_dir.normalized() if sun_dir.length() > 0.001 else Vector3.UP)
	sky_mat.set_shader_parameter("moon_dir", moon_dir.normalized() if moon_dir.length() > 0.001 else Vector3.DOWN)
	sky_mat.set_shader_parameter("sun_visible", bool(st["sun"]["visible"]))
	sky_mat.set_shader_parameter("moon_visible", bool(st["moon"]["visible"]))
	sky_mat.set_shader_parameter("sun_size", 0.045 * float(st["sun"]["scale"]))
	sky_mat.set_shader_parameter("moon_size", 0.02 * float(st["moon"]["scale"]))
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
	# clouds go dark at night, not glowing grey
	var cdim: float = lerp(1.0, 0.16, night)
	ccol = Color(ccol.r * cdim, ccol.g * cdim, ccol.b * cdim, ccol.a)
	sky_mat.set_shader_parameter("cloud_color", ccol)
	sky_mat.set_shader_parameter("cloud_coverage", clamp(float(clouds["density"]), 0.0, 0.95) if bool(sky.get("clouds", true)) else 0.0)
	var cs: Vector2 = clouds["speed"]
	cloud_speed = cs
	cloud_height = float(clouds["height"])
	# --- fog ---
	# While the eye is underwater, _update_environment_extras owns the fog and
	# the shaft volume; sky packets must not clobber them.
	if not underwater:
		var fog_col: Color = hor
		if str(sky["fog_tint_type"]) == "default":
			fog_col = fog_col.lerp(sky["fog_sun_tint"], 0.35 * dawn)
		var fc: Color = sky["fog_color"]
		if fc.a > 0.0:
			fog_col = fc
		e.fog_light_color = fog_col
		# How far there is actually something to see, which is not how far we
		# are permitted to draw. The live range is always there; past it the
		# far field reaches only as far as the store and the server's
		# summaries have filled, which on a new world is very little and grows
		# for minutes. Haze tied to the permitted distance instead left the
		# terrain ending in clear air, which is the whole of what a fresh
		# world looked wrong for: measured 2026-08-22 on a fresh profile with
		# far_blocks at 0, terrain stopping at 192 nodes and the fog set to
		# close at 512. So the cap bounds it and the content decides it.
		var draw_nodes: float = maxf(float(client.view_range()) * 16.0, 64.0)
		var stats: Dictionary = client.render_stats() if client.has_method("render_stats") else {}
		if int(stats.get("far_grant", 0)) > 0 and client.has_method("far_distance"):
			var cap: float = minf(float(client.far_distance()), float(stats.get("far_grant", 0)))
			draw_nodes = clampf(float(stats.get("far_extent", 0)), draw_nodes, maxf(draw_nodes, cap))
		# The far plane has to clear whatever is actually drawn, or the
		# far tiers' own horizon is what clips them, not the fog. A fixed
		# margin on top of draw_nodes rather than a multiple: at a 4000
		# node grant a 10 per cent margin is 400 nodes for no reason,
		# while 256 covers the coarsest region's own size at any grant.
		cam.far = maxf(1000.0, draw_nodes + 256.0)
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
		e.fog_mode = Environment.FOG_MODE_DEPTH
		e.fog_depth_begin = fog_end * fog_clear_fraction
		e.fog_depth_end = fog_end
		e.fog_depth_curve = fog_curve
		e.fog_density = 1.0
		# Aerial perspective blends distant geometry toward the sky, which is
		# what actually sells a vista; it wants to be stronger the further we
		# draw, so a 512 node horizon reads as haze rather than a hard edge.
		e.fog_aerial_perspective = clamp(0.12 + 0.35 * clamp((draw_nodes - 192.0) / 512.0, 0.0, 1.0), 0.12, 0.5)
		e.fog_sky_affect = 0.1 if draw_nodes < 260.0 else 0.5
	# --- ambient / grade from day-night ratio and server lighting ---
	var ratio: float = st["day_night_ratio"]
	# Kept wired and kept honest: this line is inert while SDFGI is on, for
	# the reason measured in _apply_lighting, and it is the sdfgi off path
	# that it is here for. Day and night differ through the sky itself and
	# through background_energy_multiplier below, not through this.
	e.ambient_light_energy = lerp(0.14, 0.42, ratio) * light_ambient
	# do not push the sky toward white; it reads as haze and flattens the blue
	e.background_energy_multiplier = lerp(0.25, 0.95, ratio)
	var lighting: Dictionary = st["lighting"]
	# Server saturation on top of our base grade, not instead of it.
	e.adjustment_saturation = clamp(1.12 * float(lighting["saturation"]), 0.0, 2.0)
	e.tonemap_exposure = clamp(light_exposure * (1.0 + float(lighting["exposure_correction"]) * 0.25), 0.1, 3.0)
	e.glow_intensity = clamp(0.3 + float(lighting["bloom_intensity"]) * 2.0, 0.0, 2.0)
	# Luanti's volumetric_light_strength is god-ray strength (0..1), not fog
	# density: thin volume, scattering scaled by the strength.
	var vol: float = lighting["volumetric_light_strength"]
	if not underwater:
		e.volumetric_fog_enabled = vol > 0.0
		if vol > 0.0:
			e.volumetric_fog_density = 0.00025 + 0.0006 * vol
			e.volumetric_fog_emission_energy = 0.0
			e.volumetric_fog_anisotropy = 0.7
			e.volumetric_fog_albedo = Color(0.9, 0.93, 1.0)
			e.volumetric_fog_length = 96.0
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
