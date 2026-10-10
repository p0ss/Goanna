# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/wake.gd
#
# Wake ripples on water (docs/systems/weather.md, "Wakes"), everything about them
# that can be checked without drawing a frame:
#   - the water shader compiles with the wake include, and the globals it
#     reads are registered;
#   - wake.gd, driven with a fake body moving across a fake lake, lays points
#     spaced by its speed, stronger the faster it goes; none while it stands
#     still except the bob, about one a BOB_PERIOD; none out of the water or
#     wholly under it; one splash on coming into the water; no trail across
#     a teleport; and every point is gone from what is published once it is
#     older than MAX_AGE;
#   - the nearest sources are taken, within range, up to the cap;
#   - the ring maths, by a copy of the shader's tied to its source by text:
#     a fresh point bends the normal near its ring and not past its age, a
#     body swimming faster than the rings spread leaves them on two lines
#     behind it (the V), and a still body's bob stays round it.
# It renders nothing: how any of it looks is not tested here.
extends SceneTree

const Wake := preload("res://ui/wake.gd")
const INCLUDE := "res://shaders/wake.gdshaderinc"
const WATER := "res://shaders/water.gdshader"

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _initialize() -> void:
	_test_shader()
	_test_source_ties()
	_test_trail_spacing()
	_test_still_bob()
	_test_out_of_water()
	_test_entry_and_teleport()
	_test_ageing()
	_test_nearest()
	_test_ring()
	_test_v_shape()
	print("wake: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)


# A lake: water in every node at or below y 0 for x 0 to 40, so its surface
# is at y 0.5; dry land everywhere else.
func _lake(p: Vector3) -> bool:
	var ny := floori(p.y + 0.5)
	return ny <= 0 and p.x >= 0.0 and p.x <= 40.0


func _new_wake() -> Node:
	var w: Node = Wake.new()
	w.water_at = _lake
	return w


# A body swimming along +x at `speed`, feet at `y`, sampled every
# SAMPLE_INTERVAL for `seconds`, from `x0`. Returns the clock at the end.
func _swim(w: Node, x0: float, y: float, speed: float, seconds: float, t0 := 0.0,
		key = "body") -> float:
	var t := t0
	var steps := int(round(seconds / Wake.SAMPLE_INTERVAL))
	for i in steps + 1:
		t = t0 + Wake.SAMPLE_INTERVAL * i
		w.step([{"key": key, "pos": Vector3(x0 + speed * (t - t0), y, 5.0)}], t)
	return t


func _test_shader() -> void:
	var shader: Shader = load(WATER)
	check(shader != null, "cannot load " + WATER)
	var names := {}
	if shader:
		for u in shader.get_shader_uniform_list(true):
			names[u["name"]] = true
	check(not names.is_empty(), WATER + " did not compile")
	var src := FileAccess.get_file_as_string(WATER)
	check(src.contains('#include "res://shaders/wake.gdshaderinc"'),
			"water.gdshader does not include the wake")
	check(src.contains("vec3 wake = goanna_wake(world_pos.xz, here);"),
			"water.gdshader does not draw the wake")
	for g in ["goanna_wake_points", "goanna_wake_state", "goanna_wake_area"]:
		check(g in RenderingServer.global_shader_parameter_get_list(),
				"global " + g + " is not registered in project.godot")
	var inc := FileAccess.get_file_as_string(INCLUDE)
	for decl in ["global uniform sampler2D goanna_wake_points", "global uniform vec4 goanna_wake_state;",
			"global uniform vec4 goanna_wake_area;"]:
		check(inc.contains(decl), "wake.gdshaderinc does not declare " + decl)


func _shader_const(src: String, name: String) -> float:
	var re := RegEx.new()
	re.compile("const (?:float|int) " + name + " = ([0-9.]+);")
	var m := re.search(src)
	return float(m.get_string(1)) if m else NAN


# ring() in wake.gd is a copy of goanna_wake_ring; these lines tie it to the
# source, so the ring checks below are checks of the shader.
func _test_source_ties() -> void:
	var inc := FileAccess.get_file_as_string(INCLUDE)
	for pair in [["GOANNA_WAKE_MAX_POINTS", Wake.MAX_POINTS], ["GOANNA_WAKE_MAX_AGE", Wake.MAX_AGE],
			["GOANNA_WAKE_SPREAD", Wake.SPREAD], ["GOANNA_WAKE_START", Wake.START],
			["GOANNA_WAKE_WIDTH", Wake.WIDTH], ["GOANNA_WAKE_WAVE", Wake.WAVE],
			["GOANNA_WAKE_RANGE", Wake.RANGE]]:
		check(is_equal_approx(_shader_const(inc, pair[0]), float(pair[1])),
				"%s in the shader is not wake.gd's %s" % [pair[0], pair[1]])
	for text in ["float age = now - pt.z;",
			"if (age < 0.0 || age > GOANNA_WAKE_MAX_AGE)",
			"float radius = GOANNA_WAKE_START + GOANNA_WAKE_SPREAD * age;",
			"float u = r - radius;",
			"float x = u / GOANNA_WAKE_WIDTH;",
			"if (abs(x) > 3.0)",
			"float life = 1.0 - age / GOANNA_WAKE_MAX_AGE;",
			"float amp = pt.w * life * smoothstep(0.0, 0.1, age)",
			"* inversesqrt(1.0 + 2.0 * radius);",
			"float k = 6.2831853 / GOANNA_WAKE_WAVE;",
			"float env = exp(-x * x);",
			"float slope = amp * env * (-2.0 * x / (GOANNA_WAKE_WIDTH * k) * cos(k * u) - sin(k * u));",
			"float crest = amp * env * max(cos(k * u), 0.0);",
			"return vec3((r > 1e-4 ? d / r : vec2(0.0)) * slope, crest);",
			"if (n <= 0 || eye_d > GOANNA_WAKE_RANGE)",
			"float fade = 1.0 - smoothstep(GOANNA_WAKE_RANGE * 0.6, GOANNA_WAKE_RANGE, eye_d);",
			"return vec3(acc.xy * fade, min(acc.z, 1.0) * fade);"]:
		check(inc.contains(text), "wake.gdshaderinc no longer matches wake.gd's copy: " + text)


# Distances between consecutive points, in the order they were laid.
func _gaps(w: Node) -> Array:
	var out := []
	for i in range(1, w.points.size()):
		out.append(Vector2(w.points[i].x, w.points[i].y).distance_to(
				Vector2(w.points[i - 1].x, w.points[i - 1].y)))
	return out


func _test_trail_spacing() -> void:
	var results := {}
	for speed in [1.0, 2.0, 4.0]:
		var w := _new_wake()
		# Feet half a node under the surface, as a swimmer's are.
		_swim(w, 5.0, -0.5, speed, 1.5)
		var gaps := _gaps(w)
		var want: float = Wake.spacing_for(speed)
		var ok := not gaps.is_empty()
		for g in gaps:
			ok = ok and absf(g - want) < 0.02
		check(ok, "at %.1f nodes a second the points are not %.2f apart: %s" % [speed, want, gaps])
		var n: int = w.points.size()
		# 1.5 seconds of path over the spacing, give or take the first.
		var expect := int(speed * 1.5 / want)
		check(absi(n - expect) <= 1, "at %.1f nodes a second %d points, not about %d"
				% [speed, n, expect])
		for p in w.points:
			check(is_equal_approx(p.w, Wake.strength_for(speed)), "a point's strength is not its speed's")
		# Births along the path at the time the body was there.
		for p in w.points:
			var at: float = (p.x - 5.0) / speed
			check(absf(p.z - at) < 1e-3, "a point's birth %.3f is not when the body passed, %.3f"
					% [p.z, at])
		results[speed] = [n, want, Wake.strength_for(speed)]
		w.free()
	check(Wake.spacing_for(4.0) > Wake.spacing_for(1.0) and Wake.strength_for(4.0) > Wake.strength_for(1.0),
			"a faster body lays points no further apart or no stronger")
	print("wake: points laid in 1.5 s at 1, 2, 4 nodes a second (count, spacing, strength): ", results)


func _test_still_bob() -> void:
	var w := _new_wake()
	var t := _swim(w, 10.0, -0.5, 0.0, 6.0)
	var n: int = w.points.size()
	# Six seconds, a bob every BOB_PERIOD after the first, jittered start.
	check(n >= 4 and n <= 5, "a body still in water for 6 s bobbed %d times" % n)
	var ok := true
	for p in w.points:
		ok = ok and is_equal_approx(p.w, Wake.BOB_STRENGTH) and is_equal_approx(p.x, 10.0)
	check(ok, "a still body's points are not bobs where it stands")
	var births := []
	for p in w.points:
		births.append(p.z)
	for i in range(1, births.size()):
		check(absf(births[i] - births[i - 1] - Wake.BOB_PERIOD) < Wake.SAMPLE_INTERVAL + 1e-3,
				"bobs %.2f s apart, not about %.2f" % [births[i] - births[i - 1], Wake.BOB_PERIOD])
	# Slow drifting under STILL_SPEED is still standing.
	var w2 := _new_wake()
	_swim(w2, 10.0, -0.5, Wake.STILL_SPEED * 0.5, 3.0, t)
	for p in w2.points:
		check(is_equal_approx(p.w, Wake.BOB_STRENGTH), "a drifting body laid a trail point")
	w.free()
	w2.free()


func _test_out_of_water() -> void:
	# Walking on land beside the lake.
	var w := _new_wake()
	_swim(w, -20.0, 0.5, 4.0, 3.0)
	check(w.points.is_empty(), "a body walking on land laid %d points" % w.points.size())
	# Deep under the lake: the surface is far over its head.
	_swim(w, 5.0, -6.0, 2.0, 3.0, 10.0, "diver")
	check(w.points.is_empty(), "a body wholly under the water laid %d points" % w.points.size())
	# Standing on a bank a node over the water.
	_swim(w, 5.0, 2.5, 0.0, 3.0, 20.0, "bank")
	check(w.points.is_empty(), "a body standing over the water laid %d points" % w.points.size())
	check(is_nan(w.water_surface(Vector3(-5.0, 0.5, 5.0))), "dry land has a water surface")
	check(is_equal_approx(w.water_surface(Vector3(5.0, -0.5, 5.0)), 0.5),
			"the lake's surface is not at 0.5 for a swimmer")
	check(is_equal_approx(w.water_surface(Vector3(5.0, 0.0, 5.0)), 0.5),
			"the lake's surface is not at 0.5 for a body wading at its top")
	w.free()


func _test_entry_and_teleport() -> void:
	var w := _new_wake()
	# From x -2 on the bank into the lake at x 0, feet level with the
	# surface, at 2 nodes a second.
	_swim(w, -2.0, 0.0, 2.0, 2.0)
	var entries: Array = w.points.filter(func(p): return is_equal_approx(p.w, Wake.ENTRY_STRENGTH))
	check(entries.size() == 1, "coming into the water made %d splashes, not 1" % entries.size())
	if entries.size() == 1:
		check(entries[0].x >= 0.0 and entries[0].x < 0.5, "the splash is not where the body came in")
	# A jump of 10 nodes in one sample lays nothing across the gap.
	var w2 := _new_wake()
	w2.step([{"key": 1, "pos": Vector3(5.0, -0.5, 5.0)}], 0.0)
	w2.step([{"key": 1, "pos": Vector3(15.0, -0.5, 5.0)}], 0.1)
	check(w2.points.is_empty(), "a teleport laid %d points" % w2.points.size())
	# A source no longer given is forgotten.
	w2.step([], 0.2)
	check(w2._sources.is_empty(), "a source that left kept its state")
	w.free()
	w2.free()


func _test_ageing() -> void:
	var w := _new_wake()
	var t := _swim(w, 5.0, -0.5, 2.0, 1.0)
	var live: Array = w.live_points(t)
	check(live.size() == w.points.size(), "fresh points are not all live")
	w.publish(t)
	check(w._live == live.size(), "publish did not count the live points")
	var area: Vector4 = w.area_of(live)
	check(area.x < 5.0 and area.z > 7.0 and area.y < 5.0 and area.w > 5.0,
			"the published area %s does not hold the trail" % area)
	# Half the trail is past its age a second later.
	var later: Array = w.live_points(t + 1.5)
	check(later.size() > 0 and later.size() < live.size(),
			"after 1.5 s %d of %d points live" % [later.size(), live.size()])
	var gone := t + Wake.MAX_AGE + 0.01
	check(w.live_points(gone).is_empty(), "points outlived MAX_AGE")
	w.publish(gone)
	check(w._live == 0, "publish still counts dead points")
	# The ring buffer overwrites the oldest past MAX_POINTS.
	var w2 := _new_wake()
	for i in Wake.MAX_POINTS + 10:
		w2.add_point(Vector3(i, 0, 0), float(i) * 0.01, 1.0)
	check(w2.points.size() == Wake.MAX_POINTS, "the ring buffer grew past its size")
	var xs: Array = w2.points.map(func(p): return p.x)
	check(not xs.has(0.0) and xs.has(float(Wake.MAX_POINTS + 9)), "the ring buffer kept the oldest")
	w.free()
	w2.free()


func _test_nearest() -> void:
	var many := []
	for i in 40:
		many.append({"key": i, "pos": Vector3(float(i), 0, 0)})
	var got: Array = Wake.nearest_sources(many, Vector3(-0.5, 0, 0), 15, Wake.RANGE)
	check(got.size() == 15, "took %d sources, not 15" % got.size())
	check(got[0]["key"] == 0 and got[14]["key"] == 14, "did not take the nearest")
	var far: Array = Wake.nearest_sources(many, Vector3(-30.0, 0, 0), 15, Wake.RANGE)
	check(far.size() == 3, "took %d sources within range, not 3" % far.size())
	check(Wake.is_water_name("mcl_core:water_source") and Wake.is_water_name("default:river_water_flowing")
			and not Wake.is_water_name("mcl_core:lava_source") and not Wake.is_water_name("air"),
			"is_water_name misreads a node name")


func _test_ring() -> void:
	var pt := Vector4(10.0, 5.0, 0.0, 1.0)
	# At 0.4 s the ring is START + SPREAD * 0.4 across; the largest slope on
	# a line through it, sampled finely across the packet.
	var best := 0.0
	var age := 0.4
	var radius := Wake.START + Wake.SPREAD * age
	for i in 200:
		var r := radius - 3.0 * Wake.WIDTH + 6.0 * Wake.WIDTH * float(i) / 199.0
		var s: Vector3 = Wake.ring(Vector2(10.0 + r, 5.0), pt, age)
		best = maxf(best, Vector2(s.x, s.y).length())
	check(best > 0.2, "a fresh full strength ring's slope peaks at only %.3f" % best)
	var zero := true
	for i in 200:
		var r := float(i) * 0.02
		for a in [Wake.MAX_AGE + 0.01, 3.0, -0.1]:
			zero = zero and Wake.ring(Vector2(10.0 + r, 5.0), pt, a) == Vector3.ZERO
	check(zero, "a ring bends the water past its age or before its birth")
	# Far off its packet, nothing.
	check(Wake.ring(Vector2(10.0 + radius + 0.5, 5.0), pt, age) == Vector3.ZERO,
			"a ring reaches past its packet")
	print("wake: peak slope of a fresh full strength ring at 0.4 s: %.2f" % best)


# A body swimming at 2 nodes a second, faster than the rings spread: across
# a line behind it, square to its path, the water is bent on both sides of
# the path and hardly on it, and more than a node to the side not at all.
# That is the V. A still body's bob stays within a couple of nodes of it.
func _test_v_shape() -> void:
	var w := _new_wake()
	var t := _swim(w, 5.0, -0.5, 2.0, 3.0)
	var head := 5.0 + 2.0 * 3.0
	var behind := head - 2.0
	var profile := []
	var side := 0.0
	var centre := 0.0
	var outside := 0.0
	for i in 81:
		var z := 5.0 - 2.0 + 4.0 * float(i) / 80.0
		var s: Vector3 = w.wake_at(Vector2(behind, z), t, 5.0)
		var m := Vector2(s.x, s.y).length()
		profile.append(snappedf(m, 0.01))
		var off := absf(z - 5.0)
		if off < 0.1:
			centre = maxf(centre, m)
		elif off > 0.3 and off < 1.0:
			side = maxf(side, m)
		elif off > 1.6:
			outside = maxf(outside, m)
	check(side > 0.1, "no wake beside the path 2 nodes behind a swimmer (%.3f)" % side)
	check(side > 2.0 * centre, "the wake 2 nodes behind is not a V: side %.3f, centre %.3f"
			% [side, centre])
	check(outside == 0.0, "the wake reaches %.3f 1.6 nodes to the side" % outside)
	# Beyond range, nothing is drawn however fresh.
	check(w.wake_at(Vector2(head - 0.3, 5.0), t, Wake.RANGE + 1.0) == Vector3.ZERO,
			"the wake is drawn beyond its range")
	print("wake: slope across the path 2 nodes behind a swimmer at 2 nodes a second (z 3 to 7): ",
			profile)
	w.free()
