# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/weather.gd
#
# Shader weather (docs/systems/weather.md), everything about it that can be checked
# without drawing a frame:
#   - the shaders it touches compile and declare what the scripts set;
#   - the rain cover map, fed by a stand in for GoannaClient::rain_cover_rows,
#     scans in bands, publishes only whole maps, puts each column where the
#     shaders will look for it, and recentres when the player walks off;
#   - particles.gd hands a player attached rain or snow spawner to the shader
#     path and builds no emitter for it, keeps precipitation() reporting it,
#     leaves everything else on the particle path, and rebuilds a running
#     storm the other way when the setting changes;
#   - on an open beach the cover map, read back from its texture the way the
#     shader reads it, leaves the air round the eye open, and an empty or
#     part scanned map hides nothing;
#   - the rain box, by a copy of the shader's drop placing tied to its
#     source: drops stay in their box and in place in the world as the eye
#     moves, rays from straight down to straight up all meet rain, nothing
#     is drawn on the lens, and nothing under a roof;
#   - the peak opacity of a drop at the constants weather.gd pushes to the
#     material;
#   - both node array shaders draw the ground's rain from the shared terms:
#     standing water fills a relief's hollows at wetness 0.6 while its crests
#     are only damp, basins flood after a minute of rain, nothing under a
#     roof; a splash ring grows over its life and its colour is a factor on
#     the ground's own; and the status trace of every gate reads them open
#     on open sand;
#   - a lightning spawner becomes a bolt and a light, not an emitter, and
#     both are gone after its time; main.gd tells the server's white flash
#     sky from a real one.
# It renders nothing: how any of it looks is not tested here.
extends SceneTree

const RainCover := preload("res://ui/rain_cover.gd")
const Weather := preload("res://ui/weather.gd")
const Particles := preload("res://ui/particles.gd")
const Lightning := preload("res://ui/lightning.gd")

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


# A world with a roof: a slab of cover at y 10 over x 2..5, z -3..0, open
# ground at y 0 everywhere else. Counts its calls and the rows asked for.
class FakeMap:
	extends RefCounted
	var calls := 0
	var rows_asked := 0
	var tops := []

	func height(x: int, z: int, y_bottom: int) -> float:
		if x >= 2 and x <= 5 and z >= -3 and z <= 0:
			return 10.5
		if x == 20 and z == 20:
			return float(y_bottom) - 0.5   # a shaft open all the way down
		return 0.5

	func rain_cover_rows(x0: int, z0: int, width: int, rows: int, y_top: int, y_bottom: int) -> PackedFloat32Array:
		calls += 1
		rows_asked += rows
		tops.append(y_top)
		var out := PackedFloat32Array()
		out.resize(width * rows)
		for j in rows:
			for i in width:
				out[j * width + i] = minf(height(x0 + i, z0 + j, y_bottom), float(y_top) + 0.5)
		return out


# The part of GoannaClient particles.gd polls each frame, with nothing to say.
class FakeClient:
	extends Node
	func take_particle_spawners() -> Array: return []
	func take_deleted_spawners() -> PackedInt32Array: return PackedInt32Array()
	func take_particles() -> Array: return []


func _shader_uniforms(path: String) -> Dictionary:
	var shader: Shader = load(path)
	check(shader != null, "cannot load " + path)
	var names := {}
	if shader:
		for u in shader.get_shader_uniform_list(true):
			names[u["name"]] = true
	check(not names.is_empty(), path + " did not compile")
	return names


func _test_cover() -> void:
	var map := FakeMap.new()
	var cover := RainCover.new(map)
	var here := Vector3(3.2, 1.0, -1.4)
	var steps := 0
	var published := false
	while not published and steps < 100:
		published = cover.step(here, 0.016)
		steps += 1
		if not published:
			check(not cover.ready, "a part scanned map is never published")
	var bands := RainCover.SIZE / RainCover.ROWS_PER_STEP
	check(steps == bands, "a map takes %d bands, took %d" % [bands, steps])
	check(map.rows_asked == RainCover.SIZE, "every row is scanned once")
	check(cover.ready and cover.texture != null, "a whole map is published")
	check(map.tops[0] == 1 + RainCover.SCAN_UP, "scanned from above the player")
	# The roof, the ground, the open shaft and the edge of the map.
	check(is_equal_approx(cover.height_at(3.0, -2.0), 10.5), "the roof is cover")
	check(is_equal_approx(cover.height_at(8.0, 4.0), 0.5), "open ground is its own cover")
	check(cover.height_at(20.0, 20.0) < 1.0 - RainCover.SCAN_DOWN, "an open shaft is open to the scan floor")
	check(cover.height_at(5.49, 0.49) > 10.0 and cover.height_at(5.51, 0.0) < 1.0,
			"a node's texel ends half way to the next node")
	check(cover.height_at(500.0, 0.0, -7.0) == -7.0, "off the map answers the fallback")
	check(not cover.exposed(Vector3(3.0, 2.0, -2.0)), "under the roof is sheltered")
	check(cover.exposed(Vector3(3.0, 11.0, -2.0)), "on the roof is open")
	check(cover.exposed(Vector3(8.0, 0.5, 4.0)), "a top face is open")
	check(cover.exposed(Vector3(8.0, 0.1, 4.0)), "a liquid surface just under its node top is open")
	# The texture holds the same numbers the shader will sample: texel (i, j)
	# at uv ((x - area.x) / size, (z - area.y) / size).
	var img := cover.texture.get_image()
	var i := floori(3.0 - cover.area.x)
	var j := floori(-2.0 - cover.area.y)
	check(is_equal_approx(img.get_pixel(i, j).r, 10.5), "the texture carries the cover height")
	check(cover.area.w == 1.0 and cover.area.z == float(RainCover.SIZE), "area names a whole map")

	# Standing still, nothing is rescanned until the refresh is due.
	var before := map.calls
	cover.step(here, 0.1)
	check(map.calls == before, "no rescan before the refresh is due")
	# Walking off: the next map is centred on the new place, and until it is
	# whole the old one stays up.
	var there := here + Vector3(RainCover.RECENTRE_H + 1, 0, 0)
	cover.step(there, 0.016)
	check(map.calls == before + 1, "moving far enough starts a rescan")
	check(is_equal_approx(cover.height_at(3.0, -2.0), 10.5), "the old map stays up while the new one scans")
	while not cover.step(there, 0.016):
		pass
	check(cover.area.x == float(floori(there.x + 0.5) - RainCover.SIZE / 2) - 0.5,
			"the new map is centred on the new place")
	cover.clear()
	check(not cover.ready and cover.area.w == 0.0, "clear withdraws the map")


# Other games' weather, as their mods define it. pmb_core's aom_weather:
# light rain one spawner of 300 over 30 by 36; heavy rain 200 medium drops
# over 30 by 18 beside 50 sheets 260 across on the horizon. Kythen: a 0.55
# second burst of 60 at world coordinates round the player, called water.
func _test_other_games() -> void:
	var W = load("res://ui/weather.gd")
	var light: Dictionary = W.describe({"amount": 300, "time": 0.0,
		"pos_min": Vector3(-15, 30, -15), "pos_max": Vector3(15, 30, 21),
		"vel_min": Vector3(-1, -30, -1), "vel_max": Vector3(1, -20, 1), "size_min": 10.0},
		"aom_weather_rain.png")
	var medium: Dictionary = W.describe({"amount": 200, "time": 0.0,
		"pos_min": Vector3(-15, 30, -3), "pos_max": Vector3(15, 30, 15),
		"vel_min": Vector3(-1, -30, -1), "vel_max": Vector3(1, -20, 1), "size_min": 10.0},
		"aom_weather_rain_medium.png")
	var curtain: Dictionary = W.describe({"amount": 50, "time": 0.0,
		"pos_min": Vector3(-81, 60, 24), "pos_max": Vector3(81, 60, 51),
		"vel_min": Vector3(-1, -60, -1), "vel_max": Vector3(1, -60, 1), "size_min": 260.0},
		"aom_weather_rain_heavy.png")
	check(float(medium["rate"]) + float(curtain["rate"]) > float(light["rate"]) * 1.3,
			"pmb_core's heavy rain draws heavier than its light rain")
	check(float(curtain["rate"]) == 0.0, "a rain curtain sprite is not counted as drops")
	var kythen := {"amount": 60, "time": 0.55, "vertical": true, "collision_removal": true,
		"pos_min": Vector3(92, 17, -208), "pos_max": Vector3(108, 20, -192),
		"vel_min": Vector3(0, -14, 0), "vel_max": Vector3(0.3, -11, 0.3)}
	var P = load("res://ui/particles.gd")
	check(P.rain_burst(kythen), "Kythen's burst falls like rain")
	check(P._centred_on_player(kythen, Vector3(100, 10, -200)), "Kythen's burst is round the player")
	check(not P._centred_on_player(kythen, Vector3(140, 10, -200)), "a burst 40 nodes off is not")
	var spark := kythen.duplicate()
	spark["vel_min"] = Vector3(-3, 2, -3)
	spark["vel_max"] = Vector3(3, 5, 3)
	check(not P.rain_burst(spark), "sparks thrown upward are not rain")
	_test_regional_weather()
	print("weather: aom light rain %.2f, heavy %.2f; Kythen burst %.2f"
			% [float(light["rate"]) / 500.0, (float(medium["rate"]) + float(curtain["rate"])) / 500.0,
			float(W.describe(kythen, "kythen_water.png")["rate"]) / 500.0])


# Regional Weather (TestificateMods), through Climate API's particle effect
# as parse_config builds each spawner: a 0.5 second burst every short cycle
# at world coordinates, the box centred on the player and raised by
# v_offset, the fall along -y with the wind added. The player stands at
# (0, 10, 0) with a wind of 3 along x. Values from ca_weathers/*.lua.
func _rw(box: Vector3, v_offset: float, amount: float, velocity: float, size: float) -> Dictionary:
	var feet := Vector3(0, 10, 0)
	var lo := feet + Vector3(-box.x / 2, v_offset, -box.z / 2)
	var hi := feet + Vector3(box.x / 2, v_offset + box.y, box.z / 2)
	return {"amount": amount, "time": 0.5, "vertical": true, "collision_removal": true,
		"pos_min": lo, "pos_max": hi, "size_min": size, "size_max": size,
		"vel_min": Vector3(3, -velocity, 0), "vel_max": Vector3(3, -velocity, 0)}


func _test_regional_weather() -> void:
	var W = load("res://ui/weather.gd")
	var P = load("res://ui/particles.gd")
	var feet := Vector3(0, 10, 0)
	var rain := _rw(Vector3(18, 2, 18), 6, 15, 6, 2)
	var heavy := _rw(Vector3(18, 0, 18), 7, 17, 7, 30)
	var snow := _rw(Vector3(24, 6, 24), 2, 4, 0.85, 1)
	var snow_heavy := _rw(Vector3(14, 3, 14), 3, 6, 0.75, 15)
	var hail := _rw(Vector3(18, 0, 18), 7, 6, 20, 1)
	var sand := _rw(Vector3(8, 4.5, 8), 0, 12, 0.6, 25)
	for d in [rain, heavy, snow, snow_heavy]:
		check(P._centred_on_player(d, feet), "Regional Weather's box is round the player")
	check(P.rain_burst(rain) and P.rain_burst(heavy), "Regional Weather's rain falls like rain in a wind")
	check(P.rain_burst(hail), "its hail falls like rain too, so hail is excluded by name")
	check(not P.rain_burst(sand), "its sandstorm does not fall like rain")
	check(not P.rain_burst(snow), "nor does its snow; snow is known by name")
	var r := float(W.describe(rain, "weather_raindrop.png")["rate"]) / 500.0
	var h := float(W.describe(heavy, "weather_rain.png")["rate"]) / 500.0
	var s := float(W.describe(snow, "weather_snowflake1.png")["rate"]) / 100.0
	var sh := float(W.describe(snow_heavy, "weather_snow.png")["rate"]) / 100.0
	check(h > r * 3.0, "Regional Weather's heavy rain draws far heavier than its rain")
	check(sh > s, "and its heavy snow than its snow")
	check(W.describe(snow, "weather_snowflake1.png")["kind"] == "snow", "its flakes are snow")
	check(not W.is_snow_name("snowdrift_raindrop.png"), "Snowdrift's raindrop is rain, whatever the mod is called")
	check(W.is_snow_name("snowdrift_snowflake3.png") and W.is_snow_name("weather_snow.png"),
			"flakes and plain snow are snow")
	# Per burst. Climate API runs about a dozen at once (a new one every
	# server step), and a live server showed its snow and heavy snow both
	# reaching the cap of 2 before the storm field scales them.
	print("weather: Regional Weather per burst, rain %.2f, heavy rain %.2f, snow %.2f, heavy snow %.2f"
			% [r, h, s, sh])


func _spawner(id: int, tex: String, amount: int, attached := 1) -> Dictionary:
	return {"id": id, "amount": amount, "time": 0.0,
		"pos_min": Vector3(-15, 20, -15), "pos_max": Vector3(15, 25, 15),
		"vel_min": Vector3(0, -20, 0), "vel_max": Vector3(0, -15, 0),
		"exp_min": 1.0, "exp_max": 4.0, "size_min": 4.0, "size_max": 8.0,
		"texture": tex, "vertical": true, "attached_id": attached}


func _emitters(p: Node) -> int:
	var n := 0
	for c in p.get_children():
		if c is GPUParticles3D and not c.is_queued_for_deletion():
			n += 1
	return n


func _test_routing() -> void:
	var p: Node3D = Particles.new()
	p.client = FakeClient.new()   # no texture(): particles fall back to a tint
	root.add_child(p)
	await process_frame
	check(p.weather != null, "particles builds a weather node")
	# Mineclonia runs one rain spawner at a time (weather.gd, RAIN_REFERENCE).
	p._add_spawner(_spawner(1, "weather_pack_rain_raindrop_1.png", 500))
	check(_emitters(p) == 0, "shader weather builds no emitter for rain")
	check(p.precipitation() == 1.0, "shader rain still reports precipitation")
	var t: Dictionary = p.weather.targets()
	check(is_equal_approx(t["rain"], 1.0), "Mineclonia's rain is intensity 1, got %s" % t["rain"])
	check(is_equal_approx(t["rain_speed"], 17.5), "the fall speed is the spawners' own")
	check(t["snow"] == 0.0, "no snow in rain")
	# Thunder: Mineclonia deletes it and adds one of 900 under a new id.
	p._remove_spawner(1)
	p._add_spawner(_spawner(2, "weather_pack_rain_raindrop_2.png", 900))
	check(is_equal_approx(p.weather.targets()["rain"], 1.8), "a thunderstorm is heavier")
	# Something else entirely stays on the particle path: smoke from a
	# chimney, somewhere out in the world.
	var smoke := _spawner(3, "mcl_particles_smoke.png", 20, 0)
	smoke["pos_min"] = Vector3(200, 10, 200)
	smoke["pos_max"] = Vector3(201, 11, 201)
	p._add_spawner(smoke)
	check(_emitters(p) == 1, "an ordinary spawner still gets an emitter")
	# A rain textured spawner fixed far out in the world is not weather
	# round the player, so it keeps its particles.
	var fixed := _spawner(4, "fountain_rain.png", 50, 0)
	fixed["pos_min"] = Vector3(300, 10, 300)
	fixed["pos_max"] = Vector3(302, 12, 302)
	p._add_spawner(fixed)
	check(_emitters(p) == 2, "world fixed rain keeps its particles")
	check(not p.weather.has_spawner(4), "and is not drawn by shader")
	# Turning the setting off mid storm rebuilds the storm as particles.
	p.set_shader_weather(false)
	check(_emitters(p) == 3, "shader weather off: the storm becomes emitters")
	check(p.weather.targets()["rain"] == 0.0, "and the shader stops drawing it")
	check(p.precipitation() == 1.0, "precipitation is unchanged by the setting")
	p.set_shader_weather(true)
	check(_emitters(p) == 2, "and back on: the emitters go again")
	# Cancellation, as the server sends it.
	p._remove_spawner(2)
	check(p.weather.targets()["rain"] == 0.0 and p.precipitation() == 0.0, "cancelled rain stops")
	# Snow, with Mineclonia's rates.
	var snow := _spawner(5, "weather_pack_snow_snowflake1.png", 100)
	snow["vel_min"] = Vector3(-0.2, -1, -0.2)
	snow["vel_max"] = Vector3(0.2, -4, 0.2)
	# Mineclonia's own snow box, snow.lua: 50 by 50, twice the rain's.
	snow["pos_min"] = Vector3(-25, 20, -25)
	snow["pos_max"] = Vector3(25, 25, 25)
	p._add_spawner(snow)
	var st: Dictionary = p.weather.targets()
	check(is_equal_approx(st["snow"], 1.0) and st["rain"] == 0.0, "Mineclonia's snow is intensity 1")
	check(is_equal_approx(st["snow_speed"], 2.5), "snow falls at its own speed")
	p.client.free()
	p.queue_free()


# The real source, as far as it can be asked with no world: bound, and with
# no session every column is open to the scan floor rather than an error.
func _test_client_binding() -> void:
	if not ClassDB.class_exists("GoannaClient"):
		push_warning("weather: GoannaClient not loaded, binding not checked")
		return
	check(ClassDB.class_has_method("GoannaClient", "rain_cover_rows"),
			"GoannaClient has rain_cover_rows")
	var c: Object = ClassDB.instantiate("GoannaClient")
	var band: PackedFloat32Array = c.rain_cover_rows(0, 0, 4, 2, 10, -5)
	check(band.size() == 8, "a band is width by rows")
	check(band.size() == 8 and band[7] == -5.5, "no world: open to the scan floor")
	check(c.rain_cover_rows(0, 0, 0, 2, 10, -5).is_empty(), "an empty band is empty")
	c.free()


# The shader's lookup, done on the texture as uploaded: goanna_rain_open in
# weather_common.gdshaderinc, with the same area, uv, nearest texel and
# 0.55 margin. `fallback` is what the shader passes for off the map.
func _shader_open(cover: RefCounted, p: Vector3, fallback: float) -> float:
	var area: Vector4 = cover.area
	if area.w < 0.5:
		return fallback
	var uv := (Vector2(p.x, p.z) - Vector2(area.x, area.y)) / area.z
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return fallback
	var img: Image = cover.texture.get_image()
	var texel := Vector2i(mini(floori(uv.x * img.get_width()), img.get_width() - 1),
			mini(floori(uv.y * img.get_height()), img.get_height() - 1))
	var h := img.get_pixel(texel.x, texel.y).r
	return 1.0 if p.y >= h - 0.55 else 0.0


# The live report was an open beach with no rain to be seen. The eye at
# Godot (515, 4, 447), sand at y 2 (its top at 2.5), sea at y 0 to the
# east: nothing overhead. Every point a rain layer draws at, all round
# the eye and from the ground up to well overhead, must read open.
class Beach:
	extends RefCounted
	func rain_cover_rows(x0: int, z0: int, width: int, rows: int, y_top: int, y_bottom: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize(width * rows)
		for j in rows:
			for i in width:
				out[j * width + i] = 0.5 if x0 + i > 520 else 2.5
		return out


func _test_open_beach() -> void:
	var cover := RainCover.new(Beach.new())
	var eye := Vector3(515.3, 4.0, 447.6)
	# An empty map hides nothing: before the first map is whole the area
	# is withdrawn and the shader answers its fallback, open.
	check(cover.area.w == 0.0, "an empty map has no area")
	cover.step(eye, 0.016)
	check(not cover.ready and cover.area.w == 0.0, "a part scanned map has no area either")
	while not cover.step(eye, 0.016):
		pass
	check(is_equal_approx(cover.open_share(eye.y), 1.0), "the whole beach is open at eye height")
	var hidden := 0
	var tried := 0
	for r in [0.5, 1.0, 3.0, 6.0, 12.0]:
		for s in 64:
			var a := TAU * float(s) / 64.0
			for y in [2.6, 3.0, 4.0, 10.0, 30.0]:
				var p := eye + Vector3(cos(a) * float(r), 0.0, sin(a) * float(r))
				p.y = y
				tried += 1
				if _shader_open(cover, p, 1.0) < 0.5:
					hidden += 1
	check(hidden == 0, "the air over an open beach is never covered: %d of %d points hidden" % [hidden, tried])
	# And the other way round, so the check can fail: under a roof it is.
	var roofed := RainCover.new(FakeMap.new())
	while not roofed.step(Vector3(3, 1, -1), 0.016):
		pass
	check(_shader_open(roofed, Vector3(3.0, 2.0, -2.0), 1.0) == 0.0, "under a roof the shader lookup is covered")


func _initialize() -> void:
	_test_shaders()
	_test_cover()
	_test_client_binding()
	_test_open_beach()
	await _test_routing()
	_test_other_games()
	_test_drop_source()
	_test_box_wrap()
	_test_rays()
	_test_lens()
	_test_box_cover()
	await _test_visibility()
	_test_ground_terms()
	await _test_gate_trace()
	await _test_lightning()
	_test_flash_sky()
	print("weather: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)


func _test_shaders() -> void:
	var p := _shader_uniforms(PRECIP)
	for n in ["amount", "max_amount", "snow", "speed", "wind", "eye", "far_box", "far_below",
			"near_box", "near_below", "near_instances", "drop_alpha", "drop_half_width",
			"streak_time", "max_lean"]:
		check(p.has(n), "precipitation.gdshader has no uniform " + n)
	# Every surface that reacts to rain must still compile with the include.
	_shader_uniforms("res://shaders/water.gdshader")
	_shader_uniforms(NODES)
	_shader_uniforms(SCISSOR)
	var l := _shader_uniforms("res://shaders/lightning.gdshader")
	for n in ["bolt_texture", "use_texture", "flash", "seed", "energy"]:
		check(l.has(n), "lightning.gdshader has no uniform " + n)
	# The storm work's surfaces: snow on leaves, droplets on grass, and the
	# particle weather kept from under roofs, one shader per blend.
	_shader_uniforms("res://shaders/waving_leaves.gdshader")
	_shader_uniforms("res://shaders/grass_volume.gdshader")
	for blend in ["mix", "add", "sub"]:
		var c := _shader_uniforms("res://shaders/particle_covered_%s.gdshader" % blend)
		check(c.has("albedo_tex") and c.has("scissor"),
				"particle_covered_%s.gdshader lacks what particles.gd sets" % blend)
	for g in ["goanna_rain", "goanna_rain_cover", "goanna_rain_cover_area", "goanna_snow_cover"]:
		check(g in RenderingServer.global_shader_parameter_get_list(),
				"global " + g + " is not registered in project.godot")


# The rain box. The drop placing in weather.gd is a copy of vertex()'s, and
# these lines tie the copy to the source, so the checks below are checks of
# the shader.
const PRECIP := "res://shaders/precipitation.gdshader"

func _test_drop_source() -> void:
	var src := FileAccess.get_file_as_string(PRECIP)
	for text in ["uint state = v * 747796405u + 2891336453u;",
			"uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;",
			"return (word >> 22u) ^ word;",
			"return float(h >> 8u) / 16777216.0;",
			"vec3 seed = vec3(goanna_unit(h0), goanna_unit(h1), goanna_unit(h2));",
			"float pick = goanna_unit(h3);",
			"float vary = goanna_unit(h4);",
			"bool near = INSTANCE_ID < near_instances;",
			"vec3 corner = eye - vec3(box.x * 0.5, near ? near_below : far_below, box.z * 0.5);",
			"float fall = speed * (snow ? 0.75 + 0.5 * vary : 0.85 + 0.3 * vary);",
			"float cap = snow ? snow_lean * fall : max_lean * fall;",
			"vec3 vel = vec3(w.x, -fall, w.y);",
			"vec3 p = corner + mod(seed * box + vel * TIME - corner, box);",
			"float edge = smoothstep(0.0, EDGE_FADE, min(min(lo.x, hi.x), min(lo.z, hi.z)))",
			"* smoothstep(0.0, EDGE_FADE, min(lo.y, hi.y));",
			"float len = snow ? 0.0 : fall * streak_time * (0.8 + 0.4 * seed.x);",
			"vec3 tail = p - dir * len;",
			"float open = goanna_rain_open(tail, 0.0);",
			"bool shown = pick * max_amount < amount && edge > 0.001 && nearest > NEAR_CLIP",
			"float lens = smoothstep(NEAR_CLIP, NEAR_FADE, d);",
			"float open = goanna_rain_open(v_world, 0.0);",
			"float half_w = max(drop_half_width * flake, pixel * 0.75);"]:
		check(src.contains(text), "precipitation.gdshader no longer matches weather.gd's copy: " + text)
	check(is_equal_approx(_shader_const(src, "const float NEAR_CLIP = ([0-9.]+);"), Weather.NEAR_CLIP)
			and is_equal_approx(_shader_const(src, "const float NEAR_FADE = ([0-9.]+);"), Weather.NEAR_FADE)
			and is_equal_approx(_shader_const(src, "const float EDGE_FADE = ([0-9.]+);"), Weather.EDGE_FADE),
			"the shader's lens and edge fades are weather.gd's")
	# The hash, in 32 bit arithmetic: the reference values are PCG's own.
	check(Weather.pcg(0) == 129708002 and Weather.pcg(1) == 2831084092,
			"pcg is not 32 bit PCG: %d, %d" % [Weather.pcg(0), Weather.pcg(1)])


func _shader_const(src: String, pattern: String) -> float:
	var re := RegEx.new()
	re.compile(pattern)
	var m := re.search(src)
	check(m != null, "shader source no longer matches " + pattern)
	return float(m.get_string(1)) if m != null else NAN


const RAIN_SPEED := 17.5

func _open_everywhere(_p: Vector3) -> float:
	return 1.0


# Drops stay inside their box, fall at their speed, and stay where they are
# in the world while the eye moves: only the box moves round them.
func _test_box_wrap() -> void:
	var n := Weather.instance_count(false)
	var outside := 0
	var moved := 0
	var interior := 0
	var wrong_fall := 0
	var wind := Vector2(3.0, -1.5)
	var eye := Vector3(515.3, 4.1, 447.6)
	for step in 6:
		var t := 3.0 + float(step) * 41.37
		var e1 := eye + Vector3(step * 1.7, step * 0.3, -step * 2.2)
		# Less than a quarter of the near box's fade band, so a drop well
		# inside its box stays inside after the move.
		var e2 := e1 + Vector3(0.21, -0.07, 0.13)
		for id in range(0, n, 3):
			var d := Weather.drop(id, t, e1, RAIN_SPEED, wind, false)
			var c: Vector3 = d["corner"]
			var b: Vector3 = d["box"]
			var h: Vector3 = d["head"]
			if h.x < c.x or h.y < c.y or h.z < c.z or h.x > c.x + b.x or h.y > c.y + b.y or h.z > c.z + b.z:
				outside += 1
			var d2 := Weather.drop(id, t, e2, RAIN_SPEED, wind, false)
			if float(d["weight"]) > 0.999 and float(d2["weight"]) > 0.999:
				interior += 1
				if (d2["head"] as Vector3).distance_to(h) > 1e-3:
					moved += 1
			# A short time later a drop well inside has moved by its
			# velocity, down and with the wind.
			var d3 := Weather.drop(id, t + 0.1, e1, RAIN_SPEED, wind, false)
			if float(d["weight"]) > 0.999 and float(d3["weight"]) > 0.999:
				var v := ((d3["head"] as Vector3) - h) / 0.1
				if v.y > -RAIN_SPEED * 0.84 or v.y < -RAIN_SPEED * 1.16 \
						or absf(v.x - wind.x) > 0.02 or absf(v.z - wind.y) > 0.02:
					wrong_fall += 1
	check(outside == 0, "%d drops outside their box" % outside)
	check(interior > 1000, "too few interior drops to judge world stability (%d)" % interior)
	check(moved == 0, "%d of %d drops moved in the world when the eye moved" % [moved, interior])
	check(wrong_fall == 0, "%d drops did not fall at their velocity" % wrong_fall)
	# Snow keeps to its box too, give or take the sway.
	var snow_out := 0
	for id in range(0, Weather.instance_count(true), 5):
		var d := Weather.drop(id, 77.7, eye, 2.5, wind, true)
		var c: Vector3 = d["corner"]
		var b: Vector3 = d["box"]
		var h: Vector3 = d["head"]
		if h.y < c.y or h.y > c.y + b.y or h.x < c.x - 0.21 or h.x > c.x + b.x + 0.21 \
				or h.z < c.z - 0.21 or h.z > c.z + b.z + 0.21:
			snow_out += 1
	check(snow_out == 0, "%d flakes outside their box" % snow_out)
	# The intensity picks a share of the drops, and the same drops always.
	var drawn := 0
	for id in n:
		if Weather.drop(id, 0.0, eye, RAIN_SPEED, wind, false)["pick"] * Weather.MAX_INTENSITY < 1.0:
			drawn += 1
	var want := Weather.RAIN_FAR + Weather.RAIN_NEAR
	print("weather: %d of %d rain drops drawn at intensity 1 (%d wanted)" % [drawn, n, want])
	check(absi(drawn - want) < want / 20, "intensity 1 draws about %d drops, drew %d" % [want, drawn])


# The eye 1.625 over level sand whose top face is at 0.5; the ground is
# cover (the cover map's own number) and is where a ray stops.
const GROUND := 0.5
const EYE_H := 1.625
# A ray is a cone this many degrees across its half angle: about a sixth of
# a 70 degree view across, the patch of screen a hole would be seen as.
const CONE := 12.0

func _ground_open(p: Vector3) -> float:
	return 1.0 if p.y >= GROUND - 0.55 else 0.0


# Drops drawn round a ray from the eye: within `cone` degrees of it, nearer
# than the ground along it, and weighed by the opacity they are drawn at.
# The owner's two reports were a clear disc looking down and a clear circle
# overhead with streaks radiating round it; a volume must have neither.
func _cone_drops(eye: Vector3, dir: Vector3, t: float, cone: float) -> float:
	var ground_d := INF
	if dir.y < -1e-4:
		ground_d = (GROUND - eye.y) / dir.y
	var cos_cone := cos(deg_to_rad(cone))
	var sum := 0.0
	for id in Weather.instance_count(false):
		var d := Weather.drop(id, t, eye, RAIN_SPEED, Vector2(2.0, 1.0), false)
		if not Weather.drop_shown(d, eye, 1.0, _ground_open):
			continue
		var mid: Vector3 = ((d["head"] as Vector3) + (d["tail"] as Vector3)) * 0.5
		var to := mid - eye
		var dist := to.length()
		if dist >= ground_d or to.normalized().dot(dir) < cos_cone:
			continue
		sum += Weather.drop_peak_alpha(false, dist, 1080.0, 70.0) * float(d["weight"])
	return sum


func _test_rays() -> void:
	var eye := Vector3(515.3, GROUND + EYE_H, 447.6)
	var line := ""
	var worst := INF
	for pitch in [-80.0, -45.0, 0.0, 45.0, 80.0]:
		for yaw in [0.0, 130.0, 250.0]:
			var pr := deg_to_rad(pitch)
			var yr := deg_to_rad(yaw)
			var dir := Vector3(cos(pr) * cos(yr), sin(pr), cos(pr) * sin(yr))
			var total := 0.0
			var hit := 0
			var samples := 8
			for s in samples:
				var w := _cone_drops(eye, dir, 11.0 + float(s) * 7.31, CONE)
				total += w
				if w > 0.05:
					hit += 1
			var mean := total / float(samples)
			worst = minf(worst, float(hit) / float(samples))
			if yaw == 0.0:
				line += " %+.0f: %.2f" % [pitch, mean]
			check(hit * 4 >= samples * 3,
					"pitch %.0f yaw %.0f: rain within %.0f degrees of the view in only %d of %d moments"
					% [pitch, yaw, CONE, hit, samples])
	print("weather: drawn drop opacity within %.0f degrees of a ray, by pitch:%s" % [CONE, line])


# Nothing on the lens: no drop drawn with any part of it within NEAR_CLIP of
# the eye, quad corners included, wherever the eye is and whenever.
func _test_lens() -> void:
	var worst := INF
	var shown := 0
	for step in 12:
		var eye := Vector3(515.3 + step * 0.37, 4.1 + step * 0.11, 447.6 - step * 0.53)
		var t := 5.0 + step * 13.1
		for id in Weather.instance_count(false):
			var d := Weather.drop(id, t, eye, RAIN_SPEED, Vector2(4.0, 0.0), false)
			if not Weather.drop_shown(d, eye, Weather.MAX_INTENSITY, _open_everywhere):
				continue
			shown += 1
			var near := Weather.segment_distance(d["tail"], d["head"], eye)
			# The quad's side is at most a pixel and a half wide, well
			# under a hundredth of a node this close.
			worst = minf(worst, near - 0.01)
	print("weather: nearest drawn drop, of %d, is %.2f nodes from the eye" % [shown, worst])
	check(worst >= 0.29, "a drop is drawn %.2f nodes from the eye" % worst)
	check(smoothstep(Weather.NEAR_CLIP, Weather.NEAR_FADE, 0.29) == 0.0,
			"the fragment's lens fade is shut inside the clip")


# Under a roof no drop is drawn; beside it they are.
func _test_box_cover() -> void:
	var cover := RainCover.new(FakeMap.new())
	while not cover.step(Vector3(3, 1, -1), 0.016):
		pass
	var lookup := func(p: Vector3) -> float: return _shader_open(cover, p, 1.0)
	var eye := Vector3(3.5, 2.1, -1.5)
	var under := 0
	var open_drawn := 0
	for step in 4:
		var t := 9.0 + step * 3.3
		for id in Weather.instance_count(false):
			var d := Weather.drop(id, t, eye, RAIN_SPEED, Vector2.ZERO, false)
			if not Weather.drop_shown(d, eye, 1.0, lookup):
				continue
			var h: Vector3 = d["head"]
			var roofed := h.x >= 1.5 and h.x < 5.5 and h.z >= -3.5 and h.z < 0.5
			if roofed and h.y < 10.5 - 0.55:
				under += 1
			elif h.y > 0.5:
				open_drawn += 1
	check(under == 0, "%d drops drawn under the roof" % under)
	check(open_drawn > 100, "rain still falls beside the roof (%d drops)" % open_drawn)


# How visible a drop is at the look weather.gd draws with. The floors are a
# judgement: the first version's 0.17 was not seen at noon.
func _test_visibility() -> void:
	var near := Weather.drop_peak_alpha(false, 3.0, 1080.0, 70.0)
	var far := Weather.drop_peak_alpha(false, 10.0, 1080.0, 70.0)
	var close := Weather.drop_peak_alpha(false, 0.6, 1080.0, 70.0)
	print("weather: peak streak opacity at 1080 lines, 70 degrees: 0.6 nodes %.2f, 3 nodes %.2f, 10 nodes %.2f"
			% [close, near, far])
	check(near >= 0.5, "a streak 3 nodes away peaks at %.2f, under 0.5" % near)
	check(far >= 0.2, "a streak 10 nodes away peaks at %.2f, under 0.2" % far)
	check(close <= 0.45, "a streak 0.6 nodes away peaks at %.2f: a scratch on the lens" % close)
	var flake := Weather.drop_peak_alpha(true, 3.0, 1080.0, 70.0)
	check(flake >= 0.5, "a flake 3 nodes away peaks at %.2f" % flake)
	# The materials draw with these, not with the shader's own defaults.
	var w: Node3D = Weather.new()
	root.add_child(w)
	await process_frame
	var m: ShaderMaterial = w._rain_material
	check(m != null, "the weather node builds its material")
	if m != null:
		check(is_equal_approx(float(m.get_shader_parameter("drop_alpha")), Weather.RAIN_ALPHA), "drop_alpha reaches the material")
		check(is_equal_approx(float(m.get_shader_parameter("drop_half_width")), Weather.RAIN_HALF_WIDTH), "the streak width reaches the material")
		check(int(m.get_shader_parameter("near_instances")) == Weather.near_instances(false), "near_instances reaches the material")
		check((m.get_shader_parameter("far_box") as Vector3).is_equal_approx(Weather.FAR_BOX), "far_box reaches the material")
		check(bool(w._snow_material.get_shader_parameter("snow")), "the snow material draws snow")
	var mm: MultiMesh = w._rain_mesh.multimesh
	check(mm.instance_count == Weather.instance_count(false), "one instance per drop at the most intense")
	check(mm.get_instance_transform(7).is_equal_approx(Transform3D.IDENTITY), "instance transforms are identity")
	w.queue_free()


# The ground terms, goanna_ground_rain, and where they are used.
const NODES := "res://shaders/nodes_array.gdshader"
const SCISSOR := "res://shaders/nodes_array_scissor.gdshader"
const COMMON := "res://shaders/weather_common.gdshaderinc"
# main.gd's wetness after a minute of rain from dry: it eases toward 1 with
# a 30 second time constant.
const WET_AFTER_A_MINUTE := 0.8647

func _test_ground_terms() -> void:
	var common := FileAccess.get_file_as_string(COMMON)
	for pair in [["GOANNA_PUDDLE_DRY", Weather.PUDDLE_DRY], ["GOANNA_PUDDLE_SOAKED", Weather.PUDDLE_SOAKED],
			["GOANNA_POOL_FILL", Weather.POOL_FILL], ["GOANNA_BASIN_RISE", Weather.BASIN_RISE],
			["GOANNA_SPLASH_PX_FULL", Weather.SPLASH_PX_FULL], ["GOANNA_SPLASH_PX_GONE", Weather.SPLASH_PX_GONE],
			["GOANNA_SPLASH_CELL", Weather.SPLASH_CELL], ["GOANNA_SPLASH_PERIOD", Weather.SPLASH_PERIOD],
			["GOANNA_SPLASH_LIFE", Weather.SPLASH_LIFE], ["GOANNA_SPLASH_WIDTH", Weather.SPLASH_WIDTH]]:
		check(is_equal_approx(_shader_const(common, "const float %s = ([0-9.]+);" % pair[0]), pair[1]),
				"weather.gd's %s is not the shader's" % pair[0])
	# Each GDScript copy in weather.gd, line by line against the source, so
	# the checks below are checks of the shader.
	for text in ["float n = 0.7 * goanna_weather_noise(p / 3.1)",
			"+ 0.3 * goanna_weather_noise(p / 1.13 + vec2(17.0, 5.0));",
			"return smoothstep(t - 0.06, t + 0.1, n);",
			"return GOANNA_POOL_FILL * smoothstep(0.35, 1.0, wet)",
			"+ GOANNA_BASIN_RISE * goanna_puddle(p, wet);",
			"float water = (1.0 - smoothstep(level - 0.04, level, h)) * weight;",
			"float shore = (1.0 - smoothstep(level, level + 0.25, h)) * weight * (1.0 - water);",
			"float depth = clamp((level - h) * 4.0, 0.0, 1.0) * water;",
			"if ((goanna_rain > 0.001 || wet > 0.35) && n.y > 0.7) {",
			"float open_sky = goanna_rain_open(p, smoothstep(0.85, 0.95, sky));",
			"if (wet > 0.35 && n.y > 0.95) {",
			"t.x = goanna_water_level(p.xz, wet);",
			"t.y = smoothstep(0.35, 0.45, wet) * open_sky * (1.0 - flatten);",
			"t.z = min(goanna_rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, eye_d))",
			"* (1.0 - smoothstep(GOANNA_SPLASH_PX_FULL, GOANNA_SPLASH_PX_GONE, px))",
			"* (1.0 - flatten) * open_sky;",
			"float soak = max(pool.y, mark) * (1.0 - pool.x);",
			"return (1.0 - pool.x * (0.28 + 0.12 * porosity + 0.2 * pool.z))",
			"* (1.0 - soak * (0.08 + 0.17 * porosity));",
			"float radius = rmax * (1.0 - (1.0 - k) * (1.0 - k));",
			"float x = (r - radius) / w;",
			"float fade = (1.0 - k) * (1.0 - k) * (GOANNA_SPLASH_WIDTH / w);",
			"float slope = -1.2 * x * exp(-x * x) * fade;",
			"float mark = (1.0 - smoothstep(radius, radius + 2.0 * w, r)) * (1.0 - k);",
			"float density = clamp(0.45 * rain, 0.0, 0.9);",
			"vec2 ring = goanna_splash_ring(r, age / GOANNA_SPLASH_LIFE, max(edge - 2.5 * w, 0.0), w);"]:
		check(common.contains(text), "weather_common.gdshaderinc no longer matches weather.gd's copy: " + text)
	# Both array shaders draw the terms, from the one shared set. In play the
	# ground was once drawn by the scissor one (docs/systems/weather.md), which had
	# none, and nobody ever saw a splash or a puddle. The near mesh now picks
	# by the tile's own layer, but the far tiers and every cut-out still take
	# the scissor one.
	for path in [NODES, SCISSOR]:
		var src := FileAccess.get_file_as_string(path)
		for text in ["vec3 ground_rain = goanna_ground_rain(v_world, v_wnormal, v_nodelight.g, flatten,",
				"vec3 pool = goanna_pool(ground_rain.x, ground_rain.y, relief_h);",
				"splash = goanna_rain_splash(v_world.xz, TIME, px, goanna_rain) * min(ground_rain.z, 1.0);",
				"ALBEDO *= goanna_wet_darken(pool, splash.z, porosity);",
				"float px = max(length(",
				"relief_h = n.a;"]:
			check(src.contains(text), path + " does not draw the ground's rain: " + text)
		# Nothing in the rain block adds light or mixes toward a colour of
		# its own: a splash is the surface's own shading.
		var from := src.find("vec3 ground_rain = goanna_ground_rain(")
		var to := src.find("// Node light and occlusion.")
		var block := src.substr(from, to - from) if from >= 0 and to > from else ""
		check(block != "" and not block.contains("EMISSION") and not block.contains("ALBEDO = mix("),
				path + ": the rain block adds light or paints a colour of its own")
		# The height is taken only from a layer whose map has one.
		check(src.contains("if (layer_depth[layer] > 0.0) {\n\t\t\trelief_h = n.a;"),
				path + " takes a height from a layer with no authored height")
	# In nodes_array.gdshader the height is the one the march landed on: it
	# is read from the fetch at the moved coordinate, after the move.
	var nsrc := FileAccess.get_file_as_string(NODES)
	var moved := nsrc.find("tile_uv = tile_uv - slope * d_hit;")
	var fetch := nsrc.find("vec4 n = textureGrad(normal_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);")
	var height := nsrc.find("relief_h = n.a;")
	check(moved > 0 and fetch > moved and height > fetch,
			"nodes_array.gdshader's water does not read the height the march landed on")

	var cover := RainCover.new(FakeMap.new())
	while not cover.step(Vector3(3, 1, -1), 0.016):
		pass
	var eye := Vector3(8.0, 2.1, 4.0)
	var px_near := Weather.pixel_at(3.0)
	# Basins, where the level passes every crest: none on merely damp
	# ground, some after a minute, more when soaked.
	var shares := {}
	for wet in [0.3, 0.6, WET_AFTER_A_MINUTE, 1.0]:
		var n := 0
		var flooded := 0
		for x in 80:
			for z in 80:
				n += 1
				var t := Weather.ground_terms(Vector3(100.0 + x * 0.5, 0.5, 100.0 + z * 0.5),
						1.0, 1.0, wet, 1.0, 0.0, 3.0, px_near)
				if Weather.pool(t.x, t.y, 1.0).x > 0.5:
					flooded += 1
		shares[wet] = float(flooded) / float(n)
	print("weather: flooded share of open flat ground at wetness 0.3, 0.6, %.2f (a minute), 1: %.2f, %.2f, %.2f, %.2f"
			% [WET_AFTER_A_MINUTE, shares[0.3], shares[0.6], shares[WET_AFTER_A_MINUTE], shares[1.0]])
	check(shares[0.3] < 0.01, "no basin floods on merely damp ground")
	check(shares[WET_AFTER_A_MINUTE] >= 0.1, "after a minute of rain basins flood a tenth of open flat ground or more")
	check(shares[1.0] < 0.4 and shares[0.6] < shares[1.0], "basins grow with wetness, to under two fifths")
	# The relief fills: on open flat ground clear of any basin, at wetness
	# 0.6, a hollow of the relief is water and a crest is not, nor its wet
	# margin, so the crest is left to the damp film.
	var dry := _find_basin(Vector3(6.0, 0.5, 2.0), 0.6, false)
	check(dry != Vector3.INF, "no ground clear of a basin near the eye")
	if dry != Vector3.INF:
		var open := _shader_open(cover, dry, 1.0)
		var t := Weather.ground_terms(dry, 1.0, 1.0, 0.6, open, 0.0, eye.distance_to(dry), px_near)
		var low := Weather.pool(t.x, t.y, 0.05)
		var crest := Weather.pool(t.x, t.y, 0.95)
		print("weather: at wetness 0.6 the level is %.2f; a hollow at 0.05 is water %.2f, a crest at 0.95 water %.2f, margin %.2f"
				% [t.x, low.x, crest.x, crest.y])
		check(open == 1.0 and low.x > 0.9, "a hollow of the relief stands under water at wetness 0.6")
		check(crest.x == 0.0 and crest.y == 0.0, "a crest is only damp at wetness 0.6")
		var margin := Weather.pool(t.x, t.y, t.x + 0.1)
		check(margin.x == 0.0 and margin.y > 0.3, "just above the waterline is a wet margin")
		var damp := Weather.ground_terms(dry, 1.0, 1.0, 0.3, open, 0.0, 2.0, px_near)
		check(Weather.pool(damp.x, damp.y, 0.0).x == 0.0, "no water stands at wetness 0.3, even in the deepest hollow")
		var side := Weather.ground_terms(dry, 0.0, 1.0, 1.0, open, 0.0, 2.0, px_near)
		check(side == Vector3.ZERO, "a wall does not splash or hold water")
	# A basin floods crests too, and a tile with no authored height (1).
	var basin := _find_basin(Vector3(6.0, 0.5, 2.0), WET_AFTER_A_MINUTE, true)
	check(basin != Vector3.INF, "no basin anywhere near the eye after a minute of rain")
	if basin != Vector3.INF:
		var t := Weather.ground_terms(basin, 1.0, 1.0, WET_AFTER_A_MINUTE, _shader_open(cover, basin, 1.0),
				0.0, eye.distance_to(basin), px_near)
		check(Weather.pool(t.x, t.y, 1.0).x > 0.9 and t.z > 0.5,
				"in a basin after a minute of rain a crest is under water, and splashes: %s" % str(t))
	# Nothing under cover: no water held, no splash, at any height.
	var under := Vector3(3.0, 1.5, -2.0)
	var covered := _shader_open(cover, under, 1.0)
	var tu := Weather.ground_terms(under, 1.0, 1.0, 1.0, covered, 0.0, 2.0, px_near)
	check(covered == 0.0 and tu.y == 0.0 and tu.z == 0.0 and Weather.pool(tu.x, tu.y, 0.0) == Vector3.ZERO,
			"under a roof nothing splashes or stands in water: %s" % str(tu))
	# Splashes fade where a pixel is too wide for a ring.
	var wide := Weather.ground_terms(Vector3(6.0, 0.5, 2.0), 1.0, 1.0, 0.0, 1.0, 0.0, 8.0, 0.05)
	check(wide.z == 0.0, "splashes are gone where a pixel is 5 cm")

	# A splash ring grows over its life and dies away, and its mark goes.
	# Where the ring is, by its leading edge: the steepest fall outward.
	var radii := []
	var peaks := []
	var prev_r := -1.0
	var grows := true
	for i in 9:
		var k := 0.05 + 0.1 * i
		var best_r := 0.0
		var best := 0.0
		for j in 500:
			var r := j * 0.001
			var v := -Weather.splash_ring(r, k, 0.3, Weather.SPLASH_WIDTH).x
			if v > best:
				best = v
				best_r = r
		radii.append(snappedf(best_r * Weather.SPLASH_CELL, 0.001))
		peaks.append(snappedf(best, 0.01))
		grows = grows and best_r > prev_r
		prev_r = best_r
	print("weather: splash ring radius (nodes) over its life: %s, peak slope %s" % [str(radii), str(peaks)])
	check(grows, "a splash ring grows over its life")
	check(peaks[8] < peaks[0] * 0.1, "a splash ring dies away over its life")
	check(Weather.splash_ring(0.0, 0.05, 0.3, Weather.SPLASH_WIDTH).y > 0.9
			and Weather.splash_ring(0.0, 0.99, 0.3, Weather.SPLASH_WIDTH).y < 0.02,
			"a splash's wet mark is there at impact and gone at the end of its life")
	# Its size, from the smallest cell margin to the largest.
	var smallest := 2.0 * (0.3 - 2.5 * Weather.SPLASH_WIDTH) * Weather.SPLASH_CELL
	var largest := 2.0 * (0.5 - 2.5 * Weather.SPLASH_WIDTH) * Weather.SPLASH_CELL
	print("weather: splash rings grow to %.3f to %.3f nodes across" % [smallest, largest])
	check(smallest >= 0.04 and largest <= 0.2, "a splash is a few centimetres to a tenth or two of a node")
	var per_second := 2.0 / (Weather.SPLASH_CELL * Weather.SPLASH_CELL) * 0.45 / Weather.SPLASH_PERIOD
	print("weather: splashes: %.1f a square node a second, each ring %.2f s"
			% [per_second, Weather.SPLASH_PERIOD * Weather.SPLASH_LIFE])
	check(per_second >= 20.0, "fewer than twenty splashes a square node a second at intensity 1")

	# The colour: a function of the ground's own albedo, a factor on it and
	# never above it, so nothing white is painted or added.
	var worst_add := 0.0
	var worst_factor := 1.0
	for albedo in [Color(0, 0, 0), Color(0.9, 0.88, 0.85), Color(0.55, 0.32, 0.12), Color(0.2, 0.5, 0.1)]:
		for water in [0.0, 0.5, 1.0]:
			for shore in [0.0, 0.5, 1.0]:
				for mark in [0.0, 0.5, 1.0]:
					for porosity in [0.0, 0.35, 1.0]:
						var f := Weather.wet_darken(Vector3(water, shore, water), mark, porosity)
						worst_factor = minf(worst_factor, f)
						for c in 3:
							worst_add = maxf(worst_add, albedo[c] * f - albedo[c])
	print("weather: rain on the ground scales albedo by %.2f to 1; largest addition %.3f" % [worst_factor, worst_add])
	check(worst_add <= 0.01, "rain adds colour to the ground: %.3f" % worst_add)
	check(worst_factor >= 0.35, "rain darkens the ground past recognition: %.2f" % worst_factor)


# A point on open flat ground in a basin (`inside`) or clear of any, at
# wetness `wet`.
func _find_basin(from: Vector3, wet: float, inside: bool) -> Vector3:
	for x in 80:
		for z in 80:
			var p := from + Vector3(x * 0.25, 0.0, z * 0.25)
			var b := Weather.puddle(Vector2(p.x, p.z), wet)
			if (inside and b > 0.95) or (not inside and b == 0.0):
				return p
	return Vector3.INF


# A client with a world: sand whose top face is at 0.5 everywhere, drawn by
# the shader the owner's ground is drawn by, and open sky over it. Sand's
# own layer is opaque, in an array that holds cut-outs too, as every
# Mineclonia array does, so the near mesh draws it with nodes_array.
class SandClient:
	extends RefCounted
	var shader := "nodes_array"
	func top_surface_at(pos: Vector3) -> Dictionary:
		if floori(pos.y + 0.5) > 0:
			return {"node": "air", "shader": "none"}
		return {"node": "mcl_core:sand", "texture": "default_sand.png", "array": true,
			"array_path": true, "array_alpha": true,
			"layer_alpha": shader == "nodes_array_scissor", "shader": shader}
	func rain_cover_rows(_x0: int, _z0: int, width: int, rows: int, _y_top: int, _y_bottom: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize(width * rows)
		out.fill(0.5)
		return out


# The status trace, on the owner's case: open flat sand, intensity 1, a
# minute into the rain. Every gate open, both terms non-zero; and the same
# trace against a shader with no terms names the shader as the gate that
# was shut.
func _test_gate_trace() -> void:
	var w: Node3D = Weather.new()
	w.client = SandClient.new()
	root.add_child(w)
	await process_frame
	while not w.cover.step(Vector3(515, 2, 447), 0.016):
		pass
	var spot := _find_basin(Vector3(510.0, 0.5, 440.0), WET_AFTER_A_MINUTE, true)
	check(spot != Vector3.INF, "no basin near the beach to stand in")
	var eye := Vector3(spot.x, 0.5 + EYE_H, spot.z)
	var g: Dictionary = w.ground_trace(eye, 1.0, WET_AFTER_A_MINUTE)
	print("weather: ground trace on open sand: shader %s, open %s, splash %.2f, water level %.2f, held %.2f, failing \"%s\""
			% [g.get("shader"), g.get("open"), g.get("splash", -1.0), g.get("water_level", -1.0),
			g.get("pool", -1.0), g.get("failing")])
	check(g.get("node") == "mcl_core:sand" and is_equal_approx((g["point"] as Vector3).y, 0.5),
			"the trace finds the sand's top face under the eye")
	check(g.get("failing") == "", "a gate is shut on open sand: %s" % g.get("failing"))
	for k in ["shader_has_terms", "weather_on", "up_facing", "flat", "wet_enough_to_puddle", "near_mesh"]:
		check(bool(g.get(k, false)), "gate %s is shut on open sand" % k)
	check(float(g.get("open", 0.0)) == 1.0, "open sand is open by the cover map")
	check(float(g.get("splash", 0.0)) > 0.5 and float(g.get("pool", 0.0)) > 0.5
			and float(g.get("water_level", 0.0)) > 1.0,
			"splash and standing water in a basin on open sand: %.2f, %.2f, %.2f"
			% [g.get("splash", 0.0), g.get("pool", 0.0), g.get("water_level", 0.0)])
	check(not bool(g.get("layer_alpha", true)), "the trace reports sand's own layer as opaque")
	# The scissor shader as it was, with no terms, drawing the sand as it
	# once did: the trace names it.
	w.client.shader = "nodes_array_scissor"
	w._shader_text["res://shaders/nodes_array_scissor.gdshader"] = "// no rain terms"
	var old: Dictionary = w.ground_trace(eye, 1.0, WET_AFTER_A_MINUTE)
	check(String(old.get("failing")).contains("nodes_array_scissor"),
			"the trace names a shader without terms: %s" % old.get("failing"))
	w._shader_text.clear()
	w.client.shader = "nodes_array"
	# Under the roof of the stand in map it is the cover that is shut.
	w.client = null
	w.cover = RainCover.new(FakeMap.new())
	while not w.cover.step(Vector3(3, 1, -1), 0.016):
		pass
	w.client = SandClient.new()
	var roofed: Dictionary = w.ground_trace(Vector3(3.2, 2.1, -1.7), 1.0, 1.0)
	check(String(roofed.get("failing")).begins_with("covered"), "under a roof the cover is the gate: %s" % roofed.get("failing"))
	# And the real binding, with no world loaded: answers, and says nothing.
	if ClassDB.class_exists("GoannaClient"):
		check(ClassDB.class_has_method("GoannaClient", "top_surface_at"), "GoannaClient has top_surface_at")
		var c: Object = ClassDB.instantiate("GoannaClient")
		var s: Dictionary = c.top_surface_at(Vector3.ZERO)
		check(s.is_empty(), "no world: top_surface_at is empty")
		c.free()
	w.queue_free()


func _lights_under(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		if c is OmniLight3D and not c.is_queued_for_deletion():
			out.append(c)
		out.append_array(_lights_under(c))
	return out


func _test_lightning() -> void:
	# The shape of a strike: at full strength at once, and dark by the end.
	var st := Lightning.strokes(12345)
	check(is_equal_approx(Lightning.flicker(0.0, 0.2, st), 1.0), "a strike starts at full strength")
	check(Lightning.flicker(0.2 + Lightning.TAIL, 0.2, st) < 0.02, "a strike is dark by the end of its tail")
	var p: Node3D = Particles.new()
	p.client = FakeClient.new()
	root.add_child(p)
	# The eye on the warm beach, 16 nodes from the strike.
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(515, 4, 447)
	cam.make_current()
	await process_frame
	check(p.lightning != null, "particles builds a lightning node")
	# Mineclonia's strike, as mcl_lightning.strike_func sends it, on sand at
	# y 2 (its top at 2.5): the particle centred 50 nodes over the top face.
	var ev := {"id": 42, "amount": 1, "time": 0.2,
		"pos_min": Vector3(530, 52.5, 440), "pos_max": Vector3(530, 52.5, 440),
		"vel_min": Vector3.ZERO, "vel_max": Vector3.ZERO,
		"exp_min": 0.2, "exp_max": 0.2, "size_min": 1000.0, "size_max": 1000.0,
		"texture": "lightning_lightning_2.png", "vertical": true, "collision": true,
		"glow": 14, "attached_id": 0}
	p._add_spawner(ev)
	check(_emitters(p) == 0, "a strike builds no emitter")
	check(p.lightning.bolt_count() == 1, "a strike draws one bolt")
	check(p.precipitation() == 0.0, "a strike is not precipitation")
	var lights: Array = _lights_under(p.lightning)
	check(lights.size() == 1, "a strike lights one light, found %d" % lights.size())
	var meshes: Array = p.lightning.find_children("*", "MeshInstance3D", true, false)
	check(meshes.size() == 1 and is_equal_approx((meshes[0].mesh as QuadMesh).size.y, 100.0),
			"the bolt is the spawner's 100 nodes tall")
	if lights.size() == 1:
		var light: OmniLight3D = lights[0]
		var at := light.global_position
		check(absf(at.x - 530.0) < 0.01 and at.y > 3.0 and at.y < 10.0,
				"the light is a few nodes over the strike point, at %s" % str(at))
		check(light.light_energy > 1.0, "the light is on at the strike")
	check(p.lightning_flash() > 0.5, "a strike flashes the sky")
	await create_timer(0.2 + Lightning.TAIL + 0.1).timeout
	await process_frame
	check(p.lightning.bolt_count() == 0, "the bolt is gone after its time")
	check(_lights_under(p.lightning).is_empty(), "and so is its light")
	check(p.lightning_flash() == 0.0, "and the flash")
	# Shader weather off: the particle path, with a culling box that holds
	# the whole 100 node quad rather than a node round its centre.
	p.set_shader_weather(false)
	p._add_spawner(ev)
	check(_emitters(p) == 1 and p.lightning.bolt_count() == 0, "shader weather off: a strike is an emitter")
	for c in p.get_children():
		if c is GPUParticles3D and not c.is_queued_for_deletion():
			check(c.visibility_aabb.size.y >= 100.0,
					"the strike's culling box holds its quad: %s" % str(c.visibility_aabb))
	# Someone else's texture with lightning in the name, a stream of sparks,
	# is not a strike.
	var sparks := ev.duplicate()
	sparks["amount"] = 40
	check(not Lightning.is_bolt(sparks, "lightning_lightning_2.png"), "forty a second is not a strike")
	p.client.free()
	p.queue_free()
	cam.queue_free()


func _test_flash_sky() -> void:
	var main_script := Lightning
	check(FileAccess.get_file_as_string("res://main.gd").contains("Lightning.is_flash_sky(sky)"),
			"main.gd tells the flash by lightning.gd's test")
	var white := Color(1, 1, 1)
	var flash := {"day_sky": white, "day_horizon": white, "dawn_sky": white,
		"night_sky": white, "night_horizon": white}
	check(main_script.is_flash_sky(flash), "Mineclonia's lightning layer is a flash")
	# A storm sky: grey by day, dark by night.
	var rain := {"day_sky": Color8(108, 108, 108), "day_horizon": Color8(108, 108, 108),
		"dawn_sky": Color8(90, 90, 90), "night_sky": Color8(0, 0, 0), "night_horizon": Color8(0, 0, 0)}
	check(not main_script.is_flash_sky(rain), "a storm sky is not a flash")
	var day := flash.duplicate()
	day["night_sky"] = Color8(0, 0, 30)
	check(not main_script.is_flash_sky(day), "a white day sky with a night is not a flash")
