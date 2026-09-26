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
#     storm the other way when the setting changes;
#   - on an open beach the cover map, read back from its texture the way the
#     shader reads it, leaves every rain layer open, and an empty or part
#     scanned map hides nothing;
#   - the peak opacity of a rain streak at the constants weather.gd pushes
#     to the material is at least MIN_NEAR_ALPHA on the first full layer and
#     MIN_FAR_ALPHA on the farthest, at 1080 lines and 70 degrees;
#   - the layers leave no clear ground round the player looking down (the
#     "umbrella"), and nothing is drawn close enough to the eye to sit on
#     the lens;
#   - the splash and puddle terms are there on open, flat, up facing ground
#     and not under a roof;
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


func _test_shaders() -> void:
	var p := _shader_uniforms("res://shaders/precipitation.gdshader")
	for n in ["rain_amount", "snow_amount", "rain_speed", "snow_speed", "wind", "layer_radius",
			"layer_alpha", "layer_fade", "rain_alpha", "snow_alpha", "streak_half_width", "rain_density",
			"snow_density", "rain_period", "mesh_span"]:
		check(p.has(n), "precipitation.gdshader has no uniform " + n)
	# Both surfaces that react to rain must still compile with the include.
	_shader_uniforms("res://shaders/water.gdshader")
	_shader_uniforms("res://shaders/nodes_array.gdshader")
	var l := _shader_uniforms("res://shaders/lightning.gdshader")
	for n in ["bolt_texture", "use_texture", "flash", "seed", "energy"]:
		check(l.has(n), "lightning.gdshader has no uniform " + n)
	# The shader's layer count is the script's.
	var src := FileAccess.get_file_as_string(PRECIP)
	check(src.contains("const int LAYERS = %d;" % Weather.LAYER_RADII.size()),
			"precipitation.gdshader's LAYERS is not weather.gd's layer count")
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
	for r in Weather.LAYER_RADII:
		for s in 64:
			var a := TAU * float(s) / 64.0
			for y in [2.6, 3.0, 4.0, 10.0, 30.0]:
				var p := eye + Vector3(cos(a) * float(r), 0.0, sin(a) * float(r))
				p.y = y
				tried += 1
				if _shader_open(cover, p, 1.0) < 0.5:
					hidden += 1
	check(hidden == 0, "rain over an open beach is never covered: %d of %d points hidden" % [hidden, tried])
	# And the other way round, so the check can fail: under a roof it is.
	var roofed := RainCover.new(FakeMap.new())
	while not roofed.step(Vector3(3, 1, -1), 0.016):
		pass
	check(_shader_open(roofed, Vector3(3.0, 2.0, -2.0), 1.0) == 0.0, "under a roof the shader lookup is covered")


# How visible a streak is at the look weather.gd draws with. The floor is
# a judgement: a quarter opacity is where a thin light streak over a bright
# ground stops being lost, and the first version's 0.17 was not seen.
const MIN_NEAR_ALPHA := 0.5
const MIN_FAR_ALPHA := 0.25
# And a ceiling for the low layers, which are under a node from the eye.
const MAX_LOW_ALPHA := 0.45

# The second live check: rain in one narrow band ahead, the sky speckled
# with sub pixel dots, and bright arcs, all turning with yaw. All three were
# the column coordinate: it carried dot(camera.xz, tangent), whose change
# round the turn is the camera's distance from world zero, so the columns
# were squeezed, spread and smeared by direction. What is checked here is
# the column coordinate as the shader now computes it, copied below and tied
# to the source by text: that it advances round every layer at a steady
# rate, never runs backwards under the wind's shear anywhere a layer is
# drawn, and that the first version's formula fails the same check (so the
# check can fail at all).
const PRECIP := "res://shaders/precipitation.gdshader"
const SPACING := 0.16

func _shader_const(src: String, pattern: String) -> float:
	var re := RegEx.new()
	re.compile(pattern)
	var m := re.search(src)
	check(m != null, "precipitation.gdshader no longer matches " + pattern)
	return float(m.get_string(1)) if m != null else NAN


# du/dtheta of the column coordinate in columns per radian, by central
# difference, as the shader's `along + y_eye * lean` over `spacing`, with
# y_eye held to `reach` radii either side of the eye.
func _columns_rate(r: float, theta: float, y_eye: float, wind: Vector2, speed: float,
		max_lean: float, cam := Vector2.ZERO, reach := INF) -> float:
	var e := 1e-3
	var yc := clampf(y_eye, -reach * r, reach * r)
	var u := func(t: float) -> float:
		var tangent := Vector2(-sin(t), cos(t))
		var w := wind / maxf(speed, 0.1)
		if w.length() > max_lean:
			w *= max_lean / w.length()
		return (t * r + cam.dot(tangent) + yc * w.dot(tangent)) / SPACING
	return (u.call(theta + e) - u.call(theta - e)) / (2.0 * e)


func _test_columns() -> void:
	var src := FileAccess.get_file_as_string(PRECIP)
	check(src.contains("float along = theta * radius;"), "the column coordinate is arc length alone")
	check(not src.contains("+ dot(cam"), "no camera position term in the column coordinate")
	var max_lean := _shader_const(src, "const float MAX_LEAN = ([0-9.]+);")
	var reach := _shader_const(src, "const float SHEAR_REACH = ([0-9.]+);")
	check(src.contains("float y_eye = clamp(v_local.y, -SHEAR_REACH * radius, SHEAR_REACH * radius);"),
			"the shear's height is held to SHEAR_REACH radii")
	check(max_lean * reach < 1.0, "the wind's shear (%.2f of a radius) can fold the columns" % [max_lean * reach])
	var worst := INF
	var winds := [Vector2.ZERO, Vector2(7, 0), Vector2(-5, 5), Vector2(0, 14)]
	for li in Weather.LAYER_RADII.size():
		var r: float = Weather.LAYER_RADII[li]
		var span := Weather.layer_span(li)
		for speed in [0.8, 2.5, 17.5]:
			for wind in winds:
				for i in 72:
					var theta := -PI + TAU * (float(i) + 0.5) / 72.0
					# Every height the layer's mesh reaches, top to bottom.
					for y in [span.x, span.x * 0.5, 0.0, span.y * 0.5, span.y]:
						var rate := _columns_rate(r, theta, y, wind, speed, max_lean, Vector2.ZERO, reach)
						worst = minf(worst, rate / (r / SPACING))
	print("weather: slowest column rate, as a share of the calm rate: %.2f" % worst)
	check(worst > 0.3, "the column coordinate nearly stops or runs backwards (%.2f)" % worst)
	# Calm and level, the rate is the same all round: no band, no specks.
	var rates := []
	for i in 72:
		rates.append(_columns_rate(3.0, -PI + TAU * (float(i) + 0.5) / 72.0, 0.0, Vector2.ZERO, 17.5, max_lean))
	check(is_equal_approx(rates.min(), rates.max()), "columns are evenly spaced round the turn")
	# The first version, at the beach: the camera's world position in the
	# coordinate. Its rate swings by hundreds and through zero.
	var old_min := INF
	var old_max := -INF
	for i in 72:
		var rate := _columns_rate(3.0, -PI + TAU * (float(i) + 0.5) / 72.0, 0.0, Vector2.ZERO,
				17.5, max_lean, Vector2(515, -447))
		old_min = minf(old_min, rate)
		old_max = maxf(old_max, rate)
	check(old_min < 0.0 and old_max > 100.0 * 3.0 / SPACING,
			"the check would have caught the first version (%.0f to %.0f)" % [old_min, old_max])


func _test_visibility() -> void:
	var first := Weather.FIRST_FULL_LAYER
	var near := Weather.streak_alpha(first, Weather.pixel_at(first, 1080.0, 70.0))
	# The low layers are close enough to be read as marks on the screen if
	# they are drawn as strongly as the rain beyond them.
	for li in first:
		var a := Weather.streak_alpha(li, Weather.pixel_at(li, 1080.0, 70.0))
		print("weather: low layer %d (%.2f nodes) peak streak opacity %.2f" % [li, Weather.LAYER_RADII[li], a])
		check(a <= MAX_LOW_ALPHA, "low layer %d streak opacity %.2f is over %.2f" % [li, a, MAX_LOW_ALPHA])
	var last := Weather.LAYER_RADII.size() - 1
	var far := Weather.streak_alpha(last, Weather.pixel_at(last, 1080.0, 70.0))
	print("weather: peak streak opacity at intensity 1, 1080 lines, 70 degrees: first full layer %.2f, farthest %.2f" % [near, far])
	check(near >= MIN_NEAR_ALPHA, "first full layer's streak opacity %.2f is under %.2f" % [near, MIN_NEAR_ALPHA])
	check(far >= MIN_FAR_ALPHA, "farthest streak opacity %.2f is under %.2f" % [far, MIN_FAR_ALPHA])
	# The shader fades columns under 5 pixels apart (minify). At 1080 lines
	# the farthest layer's must be clear of that, or the far rain is gone.
	var col_px := SPACING / Weather.pixel_at(last, 1080.0, 70.0)
	print("weather: farthest layer's columns are %.1f pixels apart at 1080 lines" % col_px)
	check(col_px >= 5.0, "the farthest layer's columns are minified away at 1080 lines")
	# Opacity does not fall with intensity (density does), so the lightest
	# rain any spawner can ask for still draws streaks this strong; and at
	# Mineclonia's ordinary rain, a column carries a drop more often than not
	# once in two periods.
	check(Weather.RAIN_DENSITY * 1.0 >= 0.5, "ordinary rain puts a drop in at least half the cells")
	# The material draws with these, not with the shader's own defaults.
	var w: Node3D = Weather.new()
	root.add_child(w)
	await process_frame
	var m: ShaderMaterial = w._material
	check(m != null, "the weather node builds its material")
	if m == null:
		return
	check(is_equal_approx(float(m.get_shader_parameter("rain_alpha")), Weather.RAIN_ALPHA), "rain_alpha reaches the material")
	var la: PackedFloat32Array = m.get_shader_parameter("layer_alpha")
	check(la.size() == Weather.LAYER_ALPHA.size() and is_equal_approx(la[0], Weather.LAYER_ALPHA[0])
			and is_equal_approx(la[la.size() - 1], Weather.LAYER_ALPHA[Weather.LAYER_ALPHA.size() - 1]),
			"layer_alpha reaches the material")
	var lr: PackedFloat32Array = m.get_shader_parameter("layer_radius")
	check(lr.size() == Weather.LAYER_RADII.size() and is_equal_approx(lr[0], Weather.LAYER_RADII[0]),
			"layer_radius reaches the material")
	var lf: PackedVector4Array = m.get_shader_parameter("layer_fade")
	check(lf.size() == Weather.LAYER_FADE.size() and lf[0].is_equal_approx(Weather.LAYER_FADE[0]),
			"layer_fade reaches the material")
	var hw: Vector2 = m.get_shader_parameter("streak_half_width")
	check(hw.is_equal_approx(Weather.STREAK_HALF_WIDTH), "streak width reaches the material")
	w.queue_free()


func _test_mesh() -> void:
	var mesh := Weather.build_mesh()
	check(mesh.get_surface_count() == 1, "the weather is one surface, one draw")
	var arrays := mesh.surface_get_arrays(0)
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var tags := {}
	for c in colours:
		tags[snappedf(c.r * float(Weather.LAYER_RADII.size() - 1), 0.01)] = true
	check(tags.size() == Weather.LAYER_RADII.size(), "every layer is tagged")
	# A low layer's wall is where it is drawn: below the eye, from where it
	# fades in to where it has faded out.
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var top := -INF
	for i in verts.size():
		if snappedf(colours[i].r * float(Weather.LAYER_RADII.size() - 1), 0.01) == 0.0:
			top = maxf(top, verts[i].y)
	check(top < 0.0, "the nearest layer's wall is wholly below the eye (top %.2f)" % top)


func _initialize() -> void:
	_test_shaders()
	_test_cover()
	_test_mesh()
	_test_client_binding()
	_test_open_beach()
	await _test_routing()
	await _test_visibility()
	_test_columns()
	_test_near_field()
	_test_ground_terms()
	await _test_lightning()
	_test_flash_sky()
	print("weather: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)


# The umbrella. How much of a layer the shader draws at a view elevation
# whose sine is `s` (negative below the eye): layer_fade's fade in with
# depression for a low layer, and the edge on fade for all, as fragment()
# computes them, and nothing outside the layer's mesh. A full layer's rim
# fade is 6 nodes from its ends, far from the ground near the player, and
# is left out.
func _layer_weight(r: float, fade: Vector4, span: Vector2, s: float) -> float:
	var c := sqrt(maxf(1.0 - s * s, 1e-9))
	var y := r * s / c   # height of the wall where this ray meets it
	if y < span.x or y > span.y:
		return 0.0
	var w := 1.0 if fade.x < -1.0 else smoothstep(fade.x, fade.y, -s)
	return w * (1.0 - smoothstep(fade.z, fade.w, absf(s)))


# The depressions, 0 to 90 degrees in quarter degrees, at which a ray meets
# flat ground `eye_h` below the eye more than `clear` nodes out horizontally
# without first crossing a layer drawn at half strength or more. None means
# no clear circle wider than `clear` round the player, at any pitch: a
# camera pitched 30 to 60 degrees down with a 70 degree field sees
# depressions from -5 to 95, and a ray's depression is all that decides
# which cylinders round the eye it crosses and where it meets level ground.
func _clear_rays(radii: Array, fades: Array, spans: Array, eye_h: float, clear: float) -> Array:
	var misses := []
	for i in range(1, 360):
		var dep := deg_to_rad(float(i) * 0.25)
		var d := eye_h / tan(dep)
		if d <= clear:
			continue
		var covered := false
		for li in radii.size():
			var r: float = radii[li]
			if r < d and _layer_weight(r, fades[li], spans[li], -sin(dep)) >= 0.5:
				covered = true
				break
		if not covered:
			misses.append(float(i) * 0.25)
	return misses


const LENS := 0.55

func _test_near_field() -> void:
	var fades := []
	var spans := []
	for li in Weather.LAYER_RADII.size():
		fades.append(Weather.LAYER_FADE[li])
		spans.append(Weather.layer_span(li))
	# Standing (Mineclonia's eye is 1.5 to 1.625 over the feet), crouching,
	# and a step up on a slab.
	for eye_h in [1.3, 1.5, 1.625, 2.1]:
		var misses := _clear_rays(Weather.LAYER_RADII, fades, spans, eye_h, 0.5)
		check(misses.is_empty(), "eye %.2f over the ground: no rain in front of the ground at %d depressions, from %s degrees"
				% [eye_h, misses.size(), str(misses.front()) if not misses.is_empty() else ""])
	# The layout the owner saw, so the check can fail: four layers from 3
	# nodes, all fading from 45 to 60 degrees.
	var old_fade := Vector4(-2.0, -1.5, 0.707, 0.866)
	var old_span := Vector2(-26, 34)
	var old := _clear_rays([3.0, 6.5, 12.0, 22.0], [old_fade, old_fade, old_fade, old_fade],
			[old_span, old_span, old_span, old_span], 1.625, 0.5)
	print("weather: the old layers left %d of 359 depressions clear, from %.2f degrees"
			% [old.size(), old.front() if not old.is_empty() else 0.0])
	check(old.size() > 100, "the check would have caught the umbrella")
	# Nothing on the lens: anywhere a layer is drawn at all, its wall is at
	# least LENS nodes from the eye along the ray, and the low layers are
	# never drawn at or above eye level.
	var nearest := INF
	for li in Weather.LAYER_RADII.size():
		var r: float = Weather.LAYER_RADII[li]
		for i in range(-359, 360):
			var e := deg_to_rad(float(i) * 0.25)
			if _layer_weight(r, fades[li], spans[li], sin(e)) > 0.02:
				nearest = minf(nearest, r / cos(e))
				if li < Weather.FIRST_FULL_LAYER:
					check(e < 0.0, "low layer %d is drawn at %.2f degrees up" % [li, rad_to_deg(e)])
	print("weather: nearest drawn rain is %.2f nodes from the eye" % nearest)
	check(nearest >= LENS, "rain is drawn %.2f nodes from the eye" % nearest)


# The ground terms, as nodes_array.gdshader computes them, with the pieces
# of weather_common.gdshaderinc they use mirrored here and tied to the
# source by text. GDScript's floats are doubles, the shader's are not, so
# the hash lands its puddles in other places; the shape and the gating are
# what is checked.
const NODES := "res://shaders/nodes_array.gdshader"
const COMMON := "res://shaders/weather_common.gdshaderinc"

func _fract(x: float) -> float:
	return x - floorf(x)


func _hash(p: Vector2) -> float:
	var p3 := Vector3(_fract(p.x * 0.1031), _fract(p.y * 0.1031), _fract(p.x * 0.1031))
	var k := p3.dot(Vector3(p3.y, p3.z, p3.x) + Vector3(33.33, 33.33, 33.33))
	p3 += Vector3(k, k, k)
	return _fract((p3.x + p3.y) * p3.z)


func _noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	var u := f * f * (Vector2(3, 3) - 2.0 * f)
	var a := _hash(i)
	var b := _hash(i + Vector2(1, 0))
	var c := _hash(i + Vector2(0, 1))
	var d := _hash(i + Vector2(1, 1))
	return lerpf(lerpf(a, b, u.x), lerpf(c, d, u.x), u.y)


func _puddle(p: Vector2, wet: float, dry: float, soaked: float) -> float:
	var n := 0.7 * _noise(p / 3.1) + 0.3 * _noise(p / 1.13 + Vector2(17, 5))
	var t := lerpf(dry, soaked, clampf(wet, 0.0, 1.0))
	return smoothstep(t, t + 0.08, n)


# nodes_array's gating: (splash, puddle) at a point.
func _ground_terms(p: Vector3, normal_y: float, rain: float, wet: float, open: float,
		eye: Vector3, dry: float, soaked: float) -> Vector2:
	if not ((rain > 0.001 or wet > 0.35) and normal_y > 0.7):
		return Vector2.ZERO
	var puddle := 0.0
	if wet > 0.35 and normal_y > 0.95:
		puddle = _puddle(Vector2(p.x, p.z), wet, dry, soaked) * open
	var splash := minf(rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, p.distance_to(eye))) * open
	return Vector2(splash, puddle)


func _test_ground_terms() -> void:
	var common := FileAccess.get_file_as_string(COMMON)
	var nodes := FileAccess.get_file_as_string(NODES)
	var dry := _shader_const(common, "const float GOANNA_PUDDLE_DRY = ([0-9.]+);")
	var soaked := _shader_const(common, "const float GOANNA_PUDDLE_SOAKED = ([0-9.]+);")
	for text in ["float n = 0.7 * goanna_weather_noise(p / 3.1)",
			"+ 0.3 * goanna_weather_noise(p / 1.13 + vec2(17.0, 5.0));",
			"return smoothstep(t, t + 0.08, n);"]:
		check(common.contains(text), "goanna_puddle no longer matches the test's copy: " + text)
	for text in ["if ((goanna_rain > 0.001 || goanna_wetness > 0.35) && v_wnormal.y > 0.7) {",
			"float open_sky = goanna_rain_open(v_world, smoothstep(0.85, 0.95, v_nodelight.g));",
			"if (goanna_wetness > 0.35 && v_wnormal.y > 0.95)",
			"puddle = goanna_puddle(v_world.xz, goanna_wetness) * open_sky * (1.0 - flatten);",
			"splash = min(goanna_rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, eye_d))",
			"* (1.0 - flatten) * open_sky;"]:
		check(nodes.contains(text), "nodes_array's rain terms no longer match the test's copy: " + text)
	# The roofed map from _test_cover: a roof at 10.5 over x 2..5, z -3..0,
	# open ground at 0.5 everywhere else.
	var cover := RainCover.new(FakeMap.new())
	while not cover.step(Vector3(3, 1, -1), 0.016):
		pass
	var eye := Vector3(8.0, 2.1, 4.0)
	# Puddle share of open flat ground, over a patch of the world, by
	# wetness: none when damp, some once soaked.
	var shares := {}
	for wet in [0.3, 0.6, 1.0]:
		var n := 0
		var wet_n := 0
		for x in 80:
			for z in 80:
				n += 1
				if _puddle(Vector2(100.0 + x * 0.5, 100.0 + z * 0.5), wet, dry, soaked) > 0.5:
					wet_n += 1
		shares[wet] = float(wet_n) / float(n)
	print("weather: puddle share of open flat ground at wetness 0.3, 0.6, 1: %.2f, %.2f, %.2f"
			% [shares[0.3], shares[0.6], shares[1.0]])
	check(shares[0.3] < 0.01 and shares[1.0] > 0.08 and shares[1.0] < 0.4 and shares[0.6] < shares[1.0],
			"puddles grow with wetness to between a tenth and two fifths of the ground")
	# An open point with a puddle, found near the eye, and the same terms
	# on a wall and under the roof.
	var found := Vector3.INF
	for x in 60:
		for z in 60:
			var p := Vector3(6.0 + x * 0.25, 0.5, 2.0 + z * 0.25)
			if _puddle(Vector2(p.x, p.z), 1.0, dry, soaked) > 0.9:
				found = p
				break
		if found != Vector3.INF:
			break
	check(found != Vector3.INF, "no puddle anywhere near the eye at full wetness")
	if found != Vector3.INF:
		var open := _shader_open(cover, found, 1.0)
		var t := _ground_terms(found, 1.0, 1.0, 1.0, open, eye, dry, soaked)
		check(open == 1.0 and t.x > 0.5 and t.y > 0.5,
				"open flat ground at intensity 1 splashes and puddles: %s" % str(t))
		var side := _ground_terms(found, 0.0, 1.0, 1.0, open, eye, dry, soaked)
		check(side == Vector2.ZERO, "a wall does not splash or puddle")
	# Under the roof, on a floor whose top face is at 1.5, with the puddle
	# threshold at its lowest: nothing.
	var under := Vector3(3.0, 1.5, -2.0)
	var covered := _shader_open(cover, under, 1.0)
	var tu := _ground_terms(under, 1.0, 1.0, 1.0, covered, Vector3(3.0, 3.1, -1.0), dry, 0.0)
	check(covered == 0.0 and tu == Vector2.ZERO, "under a roof nothing splashes or puddles: %s" % str(tu))
	# The splash crown, from goanna_rain_rings, at the ground's cell, period
	# and density: at ordinary rain the ground near the eye has flecks on it
	# at any moment.
	check(common.contains("acc.z += (1.0 - smoothstep(0.05, 0.2, age)) * (1.0 - smoothstep(0.08, 0.2, r));"),
			"the splash crown no longer matches the test's reading of it")
	check(nodes.contains("rings = goanna_rain_rings(v_world.xz, TIME, 0.7, 0.5,")
			and nodes.contains("clamp(0.5 * goanna_rain, 0.0, 0.9));"),
			"the ground's ring cell, period and density are not what the fleck count assumes")
	# Two grids of 0.7 node cells, half of them struck each 0.5 second
	# period; each crown is over half bright out to about 0.14 of a cell for
	# about a tenth of the period.
	var per_second := 2.0 / (0.7 * 0.7) * 0.5 / 0.5
	var bright_share := per_second * 0.5 * PI * pow(0.14 * 0.7, 2.0) * 0.1
	print("weather: splash flecks: %.1f a square node a second, %.2f per cent of open ground bright at once"
			% [per_second, bright_share * 100.0])
	check(per_second >= 3.0, "fewer than three splashes a square node a second at intensity 1")


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
