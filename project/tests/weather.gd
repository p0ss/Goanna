# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/weather.gd
#
# Shader weather (docs/weather.md), everything about it that can be checked
# without drawing a frame:
#   - the three shaders it touches compile and declare what the scripts set;
#   - the rain cover map, fed by a stand in for GoannaClient::rain_cover_rows,
#     scans in bands, publishes only whole maps, puts each column where the
#     shaders will look for it, and recentres when the player walks off;
#   - particles.gd hands a player attached rain or snow spawner to the shader
#     path and builds no emitter for it, keeps precipitation() reporting it,
#     leaves everything else on the particle path, and rebuilds a running
#     storm the other way when the setting changes.
# It renders nothing: how any of it looks is not tested here.
extends SceneTree

const RainCover := preload("res://ui/rain_cover.gd")
const Weather := preload("res://ui/weather.gd")
const Particles := preload("res://ui/particles.gd")

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


func _test_shaders() -> void:
	var p := _shader_uniforms("res://shaders/precipitation.gdshader")
	for n in ["rain_amount", "snow_amount", "rain_speed", "snow_speed", "wind"]:
		check(p.has(n), "precipitation.gdshader has no uniform " + n)
	# Both surfaces that react to rain must still compile with the include.
	_shader_uniforms("res://shaders/water.gdshader")
	_shader_uniforms("res://shaders/nodes_array.gdshader")
	for g in ["goanna_rain", "goanna_rain_cover", "goanna_rain_cover_area"]:
		check(g in RenderingServer.global_shader_parameter_get_list(),
				"global " + g + " is not registered in project.godot")


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
	p._add_spawner(_spawner(1, "weather_pack_rain_raindrop_1.png", 500))
	p._add_spawner(_spawner(2, "weather_pack_rain_raindrop_2.png", 500))
	check(_emitters(p) == 0, "shader weather builds no emitter for rain")
	check(p.precipitation() == 1.0, "shader rain still reports precipitation")
	var t: Dictionary = p.weather.targets()
	check(is_equal_approx(t["rain"], 1.0), "Mineclonia's rain is intensity 1, got %s" % t["rain"])
	check(is_equal_approx(t["rain_speed"], 17.5), "the fall speed is the spawners' own")
	check(t["snow"] == 0.0, "no snow in rain")
	# Thunder: Mineclonia replaces both with 900 each.
	p._add_spawner(_spawner(1, "weather_pack_rain_raindrop_1.png", 900))
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
	check(_emitters(p) == 4, "shader weather off: the storm becomes emitters")
	check(p.weather.targets()["rain"] == 0.0, "and the shader stops drawing it")
	check(p.precipitation() == 1.0, "precipitation is unchanged by the setting")
	p.set_shader_weather(true)
	check(_emitters(p) == 2, "and back on: the emitters go again")
	# Cancellation, as the server sends it.
	p._remove_spawner(1)
	p._remove_spawner(2)
	check(p.weather.targets()["rain"] == 0.0 and p.precipitation() == 0.0, "cancelled rain stops")
	# Snow, with Mineclonia's rates.
	var snow := _spawner(5, "weather_pack_snow_snowflake1.png", 100)
	snow["vel_min"] = Vector3(-0.2, -1, -0.2)
	snow["vel_max"] = Vector3(0.2, -4, 0.2)
	p._add_spawner(snow)
	var st: Dictionary = p.weather.targets()
	check(is_equal_approx(st["snow"], 0.5) and st["rain"] == 0.0, "one snow spawner is half of Mineclonia's snow")
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


func _test_mesh() -> void:
	var mesh := Weather.build_mesh()
	check(mesh.get_surface_count() == 1, "the weather is one surface, one draw")
	var arrays := mesh.surface_get_arrays(0)
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var tags := {}
	for c in colours:
		tags[snappedf(c.r * 3.0, 0.01)] = true
	check(tags.size() == Weather.LAYER_RADII.size(), "every layer is tagged")


func _initialize() -> void:
	_test_shaders()
	_test_cover()
	_test_mesh()
	_test_client_binding()
	await _test_routing()
	print("weather: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)
