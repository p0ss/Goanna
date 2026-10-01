# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/ripples.gd
#
# The ripple patch round the eye (docs/weather.md, "Ripples"), as wake.gd
# drives it, everything that can be checked without drawing a frame:
#   - the water shader compiles with it and the globals it reads are
#     registered;
#   - a player swimming through a lake is drawn by the patch, not the rings,
#     and so is an animal in the same lake; an animal in a pond at another
#     height keeps its rings;
#   - the patch pushes a crest up ahead of the swimmer;
#   - the water mask marks the lake open and an island and the higher pond
#     not;
#   - falling into the water splashes the patch, by sinking into it, rather
#     than laying a ring; a body in the air over the water, or wholly under
#     it, does nothing to the surface by going up or down;
#   - a player floating still in the water leaves it still: no waves come
#     from nothing the player did;
#   - splashes: falling in throws one crown, not one a frame, whose drops
#     come down as rings on the patch; climbing out fast drips; swimming
#     fast sprays off the bow and wading slowly or floating still throws
#     nothing; a blow at the water from the bank splashes it, but not past
#     the hand's reach nor through a block the blow hit first; and the
#     droplet emitters scale with strength and keep to their budgets;
#   - strokes: a hand of a body the patch draws going into the water kicks
#     it and throws a crown, a slow one smaller than a fast one; hands of
#     bodies it does not draw, or far from its surface, do nothing;
#   - once the player has left the water the patch settles, sleeps and
#     tells the shader so.
# The physics itself is goanna_ripples_test's. It renders nothing: how any
# of it looks is not tested here.
extends SceneTree

const Wake := preload("res://ui/wake.gd")
const WATER := "res://shaders/water.gdshader"
const DT := 1.0 / 60.0

var failures := 0
# Test functions that ran to their end: a runtime error stops a function
# without failing a check, so each one counts itself in on its last line.
var finished := 0


# Stands in for GoannaClient where wake.gd hands the shader its globals
# (PlayerContext.shader_parameter), and keeps them: the headless renderer
# stores none, so they cannot be read back from the RenderingServer.
# Stands in for splashes.gd and keeps what it was asked to draw.
class Recorder:
	extends RefCounted
	var bursts: Array = []
	var sprays: Array = []

	func burst(kind: String, pos: Vector3, strength: float) -> int:
		bursts.append([kind, pos, strength])
		return 1

	func spray(key, pos: Vector3, dir: Vector3, speed: float) -> bool:
		sprays.append([key, pos, dir, speed])
		return true


class Globals:
	extends RefCounted
	var values := {}

	func set_view_shader_parameter(key: StringName, value: Variant) -> void:
		values[key] = value


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _initialize() -> void:
	if not ClassDB.class_exists("GoannaRipples"):
		push_error("GoannaRipples is not in the extension; build it first")
		quit(1)
		return
	_test_shader()
	_test_swim()
	_test_entry()
	_test_still()
	_test_splash_events()
	_test_strike()
	_test_splash_emitters()
	_test_strokes()
	check(finished == 8, "%d of 8 tests ran to their end" % finished)
	print("ripples: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)


# A lake with its surface at y 0.5 over x and z 0 to 40, with an island at
# x 30 to 31, z 20 to 21; beside it, x 44 to 50, a pond whose surface is at
# y 3.5. Dry land everywhere else.
func _world(p: Vector3) -> bool:
	var ny := floori(p.y + 0.5)
	if p.z < 0.0 or p.z > 40.0:
		return false
	if p.x >= 0.0 and p.x <= 40.0:
		var island := p.x >= 29.5 and p.x < 31.5 and p.z >= 19.5 and p.z < 21.5
		return ny <= 0 and not island
	if p.x >= 44.0 and p.x <= 50.0:
		return ny <= 3
	return false


func _new_wake() -> Node:
	var w: Node = Wake.new()
	w.water_at = _world
	w.ripples = ClassDB.instantiate("GoannaRipples")
	w.client = Globals.new()
	return w


# Runs frames from `t` for `seconds`: the player's feet from `feet(t)`, the
# ten-a-second sample of every source as _process does it, and the patch
# every frame. Returns the clock at the end.
func _run(w: Node, t: float, seconds: float, feet: Callable, others: Array) -> float:
	var since := Wake.SAMPLE_INTERVAL
	var end := t + seconds
	while t < end:
		t += DT
		since += DT
		var me: Vector3 = feet.call(t)
		if since >= Wake.SAMPLE_INTERVAL:
			since = 0.0
			var sources := [{"key": "local", "pos": me}]
			for o in others:
				sources.append(o.duplicate())
			w.claim(sources)
			w.step(sources, t)
			w.publish(t)
		w.ripple_frame(me, DT, t)
	return t


func _test_shader() -> void:
	var shader: Shader = load(WATER)
	check(shader != null and shader.get_shader_uniform_list().size() > 0,
			"the water shader does not compile")
	var src := FileAccess.get_file_as_string(WATER)
	var globals := RenderingServer.global_shader_parameter_get_list()
	for name in ["goanna_ripple_height", "goanna_ripple_area", "goanna_ripple_state"]:
		check(src.contains("global uniform") and src.contains(name),
				"the water shader does not read " + name)
		check(globals.has(StringName(name)), name + " is not registered in project.godot")
	finished += 1


func _test_swim() -> void:
	var w := _new_wake()
	var duck := {"key": 7, "pos": Vector3(28.0, -0.5, 14.0)}
	var frog := {"key": 8, "pos": Vector3(46.0, 2.5, 12.0)}
	# Swimming along +x at 3 nodes a second, feet half a node under the
	# surface, for three seconds.
	var swim := func(t: float) -> Vector3: return Vector3(25.0 + 3.0 * t, -0.5, 10.0)
	var t := _run(w, 0.0, 3.0, swim, [duck, frog])
	check(is_equal_approx(w._plane, 0.5), "the patch is not on the lake's surface: %s" % w._plane)
	check(w._claimed.has("local") and w._claimed.has(7), "the swimmer and the duck are not the patch's")
	check(not w._claimed.has(8), "the frog on the higher pond was taken by the lake's patch")
	var stray: Array = w.points.filter(func(p): return p.x < 44.0 and p.w > 0.0)
	check(stray.is_empty(), "%d rings laid for bodies the patch draws" % stray.size())
	var frog_rings: Array = w.points.filter(func(p): return p.x > 44.0 and p.w > 0.0)
	check(not frog_rings.is_empty(), "the frog on the pond lost its rings")
	check(not w.ripples.is_asleep(), "the patch is still under a swimmer")
	check(w._mask_at > 0.0 and w._mask_build.is_empty(), "the water mask was never read in")
	var me: Vector3 = swim.call(t)
	var crest := -1.0
	for i in 32:
		var x := me.x + 0.2 + i * 0.03125
		crest = maxf(crest, w.ripples.height_at(Vector2(x, me.z)))
	print("ripples: crest ahead of a swimmer at 3 nodes a second: %.4f" % crest)
	check(crest > 0.02, "no bow wave ahead of the swimmer")
	var published: Dictionary = w.client.values
	var state: Vector4 = published.get(&"goanna_ripple_state", Vector4.ZERO)
	check(state.x == 1.0, "the shader is not told the patch is moving")
	var area: Vector4 = published.get(&"goanna_ripple_area", Vector4.ZERO)
	check(is_equal_approx(area.w, 0.5) and is_equal_approx(area.z, float(w.ripples.get_nodes())),
			"the shader is given the wrong surface or size: %s" % area)
	check(area.x < me.x and me.x < area.x + area.z and area.y < me.z and me.z < area.y + area.z,
			"the patch is not round the swimmer: %s, swimmer at %s" % [area, me])
	# The mask, read at the lake's surface: the lake open, the island and
	# the higher pond not.
	var origin := Vector2i(24, 0)
	var mask: PackedByteArray = w.water_mask(origin, 32, 0.5)
	var at := func(x: int, z: int) -> int: return mask[(z - origin.y) * 32 + (x - origin.x)]
	check(at.call(26, 10) == 1, "open lake is not water in the mask")
	check(at.call(30, 20) == 0 and at.call(31, 21) == 0, "the island is water in the mask")
	check(at.call(46, 12) == 0, "the higher pond is open water at the lake's surface")
	# Out onto the strip of land between the lake and the pond, near enough
	# that the patch keeps the waves: they settle, the patch sleeps, and the
	# shader is told. (Gone far away, the patch would move off them at once.)
	var dry := func(_t: float) -> Vector3: return Vector3(42.0, 1.5, 10.0)
	var settled := 0.0
	while not w.ripples.is_asleep() and settled < 30.0:
		t = _run(w, t, 0.5, dry, [])
		settled += 0.5
	print("ripples: still %.1f s after the swimmer left" % settled)
	check(w.ripples.is_asleep(), "the patch never settles after the swimmer leaves")
	check(settled > 2.0, "the waves vanished at once instead of settling")
	state = published.get(&"goanna_ripple_state", Vector4.ONE)
	check(state.x == 0.0, "the shader still thinks the water is moving")
	w.free()
	finished += 1


func _test_entry() -> void:
	var w := _new_wake()
	# Walking on the bank, then falling in: the feet go from over the
	# surface (y 0.5) to under it over a third of a second. One splash, by
	# sinking into the patch, and no ring for it.
	var walk := func(t: float) -> Vector3:
		if t < 0.5:
			return Vector3(-2.0, 0.5, 10.0)
		var f := clampf((t - 0.5) / 0.33, 0.0, 1.0)
		return Vector3(lerpf(-1.0, 2.0, f), lerpf(0.9, -0.5, f), 10.0)
	_run(w, 0.0, 0.5, walk, [])
	check(w.ripples.is_asleep(), "the patch moves before anyone is in the water")
	_run(w, 0.5, 0.6, walk, [])
	check(not w.ripples.is_asleep() and w.ripples.peak() > 0.0, "falling into the water made no splash")
	check(w.points.filter(func(p): return p.w > 0.0).is_empty(), "the splash laid a ring as well")
	# Jumping in the air over the water does nothing to it.
	check(Wake.sinking(Vector3(2.0, 0.8, 10.0), -5.0, 0.5) == 0.0, "a body in the air over the water pushes it")
	check(Wake.sinking(Vector3(2.0, -3.0, 10.0), -5.0, 0.5) == 0.0, "a body wholly under the water pushes the surface")
	check(Wake.sinking(Vector3(2.0, -0.5, 10.0), -2.0, 0.5) == 2.0, "a body sinking through the surface does not push it")
	w.free()
	finished += 1


func _test_still() -> void:
	var w := _new_wake()
	var float_still := func(_t: float) -> Vector3: return Vector3(20.0, -0.5, 10.0)
	_run(w, 0.0, 5.0, float_still, [])
	check(w._claimed.has("local"), "a player floating in the lake is not the patch's")
	check(w.ripples.is_asleep() and w.ripples.peak() == 0.0,
			"a player floating still makes waves: peak %.4f" % w.ripples.peak())
	w.free()
	finished += 1


func _test_splash_events() -> void:
	# Falling in from the bank's height into the lake, then floating.
	var w := _new_wake()
	var rec := Recorder.new()
	w.splashes = rec
	var fall := func(t: float) -> Vector3:
		var f := clampf((t - 0.5) / 0.4, 0.0, 1.0)
		return Vector3(20.0, lerpf(1.5, -0.5, f), 10.0)
	var t := _run(w, 0.0, 0.5, fall, [])
	check(rec.bursts.is_empty(), "a splash before anything went in")
	t = _run(w, t, 0.6, fall, [])
	var crowns: Array = rec.bursts.filter(func(b): return b[0] == "entry")
	check(crowns.size() == 1, "falling in threw %d crowns, not one" % crowns.size())
	if crowns.size() == 1:
		check(is_equal_approx((crowns[0][1] as Vector3).y, 0.5), "the crown is not on the surface")
		check(crowns[0][2] > 0.5, "a fall at 5 nodes a second threw a weak crown: %.2f" % crowns[0][2])
	var queued: int = w._landings.size()
	t = _run(w, t, 1.0, fall, [])
	check(queued > 0 and w._landings.is_empty(), "the crown's drops never came down")
	check(not w.ripples.is_asleep(), "the drops left no rings")
	# Floating still: nothing more.
	var before := rec.bursts.size()
	t = _run(w, t, 2.0, fall, [])
	check(rec.bursts.size() == before and rec.sprays.is_empty(), "floating still threw up water")
	# Climbing out fast: drips.
	var climb := func(tt: float) -> Vector3:
		var f := clampf((tt - t) / 0.4, 0.0, 1.0)
		return Vector3(20.0, lerpf(-0.5, 1.5, f), 10.0)
	_run(w, t, 0.6, climb, [])
	check(rec.bursts.any(func(b): return b[0] == "drip"), "climbing out fast did not drip")
	w.free()
	# Swimming at 3 nodes a second sprays; wading at 1 does not.
	for speed in [3.0, 1.0]:
		var w2 := _new_wake()
		var rec2 := Recorder.new()
		w2.splashes = rec2
		var swim := func(tt: float) -> Vector3: return Vector3(10.0 + speed * tt, -0.5, 10.0)
		_run(w2, 0.0, 2.0, swim, [])
		if speed > 2.0:
			check(not rec2.sprays.is_empty(), "swimming at 3 nodes a second threw no spray")
			if not rec2.sprays.is_empty():
				var last: Array = rec2.sprays[-1]
				check((last[2] as Vector3).dot(Vector3.RIGHT) > 0.9, "the spray is not off the bow")
		else:
			check(rec2.sprays.is_empty(), "wading at 1 node a second sprayed")
		w2.free()
	finished += 1


func _test_strike() -> void:
	var w := _new_wake()
	var rec := Recorder.new()
	w.splashes = rec
	# On the bank at x -2, eye 1.6 over the ground (y 0.5), looking down at
	# the lake 2.5 nodes out.
	var eye := Vector3(-2.0, 2.1, 10.0)
	var at := Vector3(0.5, 0.5, 10.0)
	check(w.strike(eye, (at - eye).normalized()), "a blow at the lake from the bank missed it")
	check(rec.bursts.size() == 1 and rec.bursts[0][0] == "strike", "a blow at the water threw no splash")
	check(not w.ripples.is_asleep(), "a blow at the water left it still")
	check(not w.strike(eye, (at - eye).normalized(), 1.0), "a blow reached the water through a block")
	var far := Vector3(6.0, 0.5, 10.0)
	check(not w.strike(eye, (far - eye).normalized()), "a blow reached water past the hand's reach")
	check(not w.strike(eye, Vector3(1.0, 0.0, 0.0)), "a level blow hit the water")
	# The patch settles on the struck water and draws it.
	var bank := func(_t: float) -> Vector3: return Vector3(-2.0, 0.5, 10.0)
	_run(w, 0.0, 1.0, bank, [])
	check(is_equal_approx(w._mask_plane, 0.5), "the patch is not on the struck water")
	var published: Dictionary = w.client.values
	check((published.get(&"goanna_ripple_state", Vector4.ZERO) as Vector4).x == 1.0,
			"the struck water's ripples are not drawn")
	w.free()
	finished += 1


func _test_splash_emitters() -> void:
	var sp: Node3D = load("res://ui/splashes.gd").new()
	root.add_child(sp)
	var small: int = sp.burst("entry", Vector3.ZERO, 0.1)
	var big: int = sp.burst("entry", Vector3.ZERO, 1.0)
	check(big > small and small >= int(sp.KINDS["entry"]["floor"]), "a harder fall threw no more drops")
	check(sp.burst("nonsense", Vector3.ZERO, 1.0) == 0, "an unknown splash was drawn")
	for i in 40:
		sp.burst("strike", Vector3.ZERO, 1.0)
	check(sp.counts()["bursts"] == sp.MAX_BURSTS, "the bursts overran their budget: %d" % sp.counts()["bursts"])
	for i in 10:
		sp.spray(i, Vector3.ZERO, Vector3.RIGHT, 4.0)
	check(sp.counts()["sprays"] == sp.MAX_SPRAYS, "the sprays overran their budget")
	# Stopped a moment after nobody asks, freed once their drops are down.
	sp.tick(2.0)
	check(sp.counts()["sprays"] == sp.MAX_SPRAYS, "sprays were freed with drops still in the air")
	sp.tick(1.5)
	check(sp.counts()["sprays"] == 0, "sprays nobody asked for kept going")
	check(sp.counts()["bursts"] == 0, "bursts outlived their drops")
	sp.queue_free()
	finished += 1


func _test_strokes() -> void:
	var w := _new_wake()
	var rec := Recorder.new()
	w.splashes = rec
	# A swimmer in the lake, the patch on it.
	var float_still := func(_t: float) -> Vector3: return Vector3(20.0, -0.5, 10.0)
	var t := _run(w, 0.0, 0.5, float_still, [])
	check(w._claimed.has("local") and w.ripples.is_asleep(), "the swimmer is not the patch's, or the water moves")
	var hand := {"local": true, "id": 5, "pos": Vector3(20.6, 0.45, 10.0), "limb": "hand", "into": true}
	var fast := hand.duplicate()
	fast["speed"] = 5.0
	w.strokes([fast], t)
	check(rec.bursts.size() == 1 and rec.bursts[0][0] == "stroke", "a hand going in threw no crown")
	check(not w.ripples.is_asleep(), "a hand going in left the water still")
	var slow := hand.duplicate()
	slow["speed"] = 0.5
	w.strokes([slow], t)
	check(rec.bursts.size() == 2 and rec.bursts[1][2] < rec.bursts[0][2], "a slow hand splashed as hard as a fast one")
	# Someone else's hand, not on the patch; and a hand far over the water.
	var other := fast.duplicate()
	other["local"] = false
	other["id"] = 77
	var high := fast.duplicate()
	high["pos"] = Vector3(20.6, 3.0, 10.0)
	w.strokes([other, high], t)
	check(rec.bursts.size() == 2, "a stroke off the patch, or far over the water, splashed")
	w.free()
	finished += 1
