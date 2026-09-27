# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Wake ripples: rings on the water round the player and the animals moving
# through it. Each body whose height spans the water surface drops points
# on the water as it goes, spaced by its speed, and one every second or so
# while it stands still in the water; project/shaders/wake.gdshaderinc grows
# a ring from each. The points reach the water shader as a small texture,
# one texel a point, beside a clock and the box the rings can reach.
#
# Presentation only. Positions come from what the client already draws (the
# local player and the entities it has been sent), and the water from the
# map it already holds; nothing is asked of the server. docs/weather.md,
# "Wakes", has the design and what is untested.
extends Node

# The shader's constants, repeated for the copy of its maths below
# (ring()); project/tests/wake.gd checks them against the source by text.
const MAX_POINTS := 64
const MAX_AGE := 2.0
const SPREAD := 0.6
const START := 0.15
const WIDTH := 0.12
const WAVE := 0.24
const RANGE := 32.0

# Sources: the nearest this many bodies within RANGE of the eye, the local
# player first. More than that and the ring buffer is shared too thinly to
# show any of them.
const MAX_SOURCES := 16
# Seconds between samples of where the bodies are. Points are laid along
# the path between two samples at their own place and time, so this sets
# only how often entity_list and the map are asked, not the spacing.
const SAMPLE_INTERVAL := 0.1
# Spacing of the points along a path: never closer than MIN_SPACING, and
# SPACING_TIME seconds of travel apart at speed, so a boat or a sprinting
# swimmer drops about eight a second and one body cannot fill the buffer
# (16 live at MAX_AGE). The rings still overlap: at 4 nodes a second they
# are 0.5 apart and grow to 1.35 across.
const MIN_SPACING := 0.25
const SPACING_TIME := 0.12
# Below this horizontal speed, nodes a second, a body is standing still:
# it drops no trail, only the bob.
const STILL_SPEED := 0.3
# The bob of a body standing in the water: a small ring this often.
const BOB_PERIOD := 1.2
const BOB_STRENGTH := 0.3
# Coming into the water from out of it: one full strength ring.
const ENTRY_STRENGTH := 1.0
# Luanti's entity list carries no collision box, so a body is taken to span
# from half a node below its position to 1.7 above: the feet of a player or
# a mob standing in the water, up to a player's head. A body touches the
# water when a water surface lies in that span.
const BODY_BELOW := 0.5
const BODY_ABOVE := 1.7
# A jump further than this between two samples is a teleport, not a swim,
# and lays no trail across the gap.
const TELEPORT := 4.0
# Where main.gd has no walking position (the free camera), the feet are
# this far under the eye.
const EYE_HEIGHT := 1.6

var client: Object
# (Vector3) -> bool: whether the node at a world position is water. Left
# empty, it asks the client's map by node name (is_water_name); the test
# gives a fake lake.
var water_at: Callable

# The ring buffer: x, z, birth on the wake clock, strength. A new point
# overwrites the oldest once it is full.
var points: Array[Vector4] = []
var _next := 0
var _sources := {}           # key -> {pos, t, travel, bob_next, in_water}
var _live := 0               # points published as live at the last sample
var _clock0 := -1.0
var _since_sample := 0.0
var _image: Image
var _texture: ImageTexture


func _ready() -> void:
	_image = Image.create_empty(MAX_POINTS, 1, false, Image.FORMAT_RGBAF)
	_texture = ImageTexture.create_from_image(_image)
	RenderingServer.global_shader_parameter_set("goanna_wake_points", _texture)
	_publish_state(0.0)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set("goanna_wake_state", Vector4.ZERO)


# Seconds on the wake clock. Its own, from when this node started, rather
# than the shader's TIME, which rolls over; the shader reads it back from
# goanna_wake_state, so a point's age is the same on both sides.
func now() -> float:
	var s := Time.get_ticks_usec() / 1e6
	if _clock0 < 0.0:
		_clock0 = s
	return s - _clock0


func _process(delta: float) -> void:
	var t := now()
	_since_sample += delta
	if _since_sample >= SAMPLE_INTERVAL:
		_since_sample = 0.0
		var m: Node = get_tree().get_first_node_in_group("goanna_main")
		if m != null and m.get("cam") != null:
			var eye: Vector3 = (m.cam as Node3D).global_position
			step(gather_sources(m, eye), t)
			publish(t)
	if _live > 0:
		_publish_state(t)


# The local player and the nearest entities within RANGE of `eye`, as
# [{key, pos}], pos being the feet.
func gather_sources(m: Node, eye: Vector3) -> Array:
	var me := eye - Vector3(0.0, EYE_HEIGHT, 0.0)
	var lm = m.get("last_move")
	if not bool(m.get("fly_mode")) and lm is Dictionary and lm.has("pos"):
		me = lm["pos"]
	var others := []
	if client != null and client.has_method("entity_list"):
		for e in client.entity_list():
			var p: Vector3 = e.get("position", Vector3.ZERO)
			# The local player's own object, if the list carries it, is the
			# same body; one wake for it, not two.
			if Vector2(p.x - me.x, p.z - me.z).length() < 0.4 and absf(p.y - me.y) < 1.0:
				continue
			others.append({"key": int(e.get("id", -1)), "pos": p})
	var out := [{"key": "local", "pos": me}]
	out.append_array(nearest_sources(others, eye, MAX_SOURCES - 1, RANGE))
	return out


# The `count` of `sources` nearest `eye` and within `reach` of it.
static func nearest_sources(sources: Array, eye: Vector3, count: int, reach: float) -> Array:
	var near := sources.filter(func(s): return (s["pos"] as Vector3).distance_to(eye) <= reach)
	near.sort_custom(func(a, b): return (a["pos"] as Vector3).distance_squared_to(eye) \
			< (b["pos"] as Vector3).distance_squared_to(eye))
	return near.slice(0, count)


static func is_water_name(node_name: String) -> bool:
	# Every game checked names its water so (Mineclonia's water and river
	# water, Minetest Game's default:water and default:river_water, source
	# and flowing). Lava is left out on purpose: it has its own shader,
	# which draws no wake.
	return node_name.contains("water")


func _is_water(p: Vector3) -> bool:
	if water_at.is_valid():
		return bool(water_at.call(p))
	if client == null or not client.has_method("node_name_at"):
		return false
	return is_water_name(String(client.node_name_at(p)))


# The height of a water surface within a body at `feet` (the top of a water
# node with no water over it, in BODY_BELOW under the feet to BODY_ABOVE
# over them), or NAN if there is none: the body is out of the water, or
# wholly under it. Nodes are centred on whole numbers.
func water_surface(feet: Vector3) -> float:
	var y0 := ceili(feet.y - BODY_BELOW - 0.5)
	var y1 := floori(feet.y + BODY_ABOVE - 0.5)
	var below := _is_water(Vector3(feet.x, y0, feet.z))
	for y in range(y0, y1 + 1):
		var above := _is_water(Vector3(feet.x, y + 1, feet.z))
		if below and not above:
			return y + 0.5
		below = above
	return NAN


# How strong a point dropped at `speed` nodes a second is.
static func strength_for(speed: float) -> float:
	return clampf(0.35 + 0.2 * speed, 0.0, 1.0)


# Nodes between points on the path at `speed`.
static func spacing_for(speed: float) -> float:
	return maxf(MIN_SPACING, speed * SPACING_TIME)


func add_point(pos: Vector3, birth: float, strength: float) -> void:
	var v := Vector4(pos.x, pos.z, birth, strength)
	if points.size() < MAX_POINTS:
		points.append(v)
	else:
		points[_next] = v
	_next = (_next + 1) % MAX_POINTS


# One sample: where each source is at wake clock `t`. Lays the trail along
# each path since the last sample, the bob of any source standing in the
# water, and forgets sources no longer given.
func step(sources: Array, t: float) -> void:
	var seen := {}
	for s in sources:
		var key = s["key"]
		var pos: Vector3 = s["pos"]
		seen[key] = true
		var touching := not is_nan(water_surface(pos))
		if not _sources.has(key):
			# First sight: no path yet, and no splash either, since it may
			# have been in the water long before it came into range.
			_sources[key] = {"pos": pos, "t": t, "travel": 0.0, "in_water": touching,
				"bob_next": t + BOB_PERIOD * _jitter(key)}
			continue
		var st: Dictionary = _sources[key]
		var prev: Vector3 = st["pos"]
		var t0: float = st["t"]
		var dt := t - t0
		var dist := Vector2(pos.x - prev.x, pos.z - prev.z).length()
		if dist > TELEPORT or dt <= 0.0:
			st["pos"] = pos
			st["t"] = t
			st["travel"] = 0.0
			st["in_water"] = touching
			continue
		var speed := dist / dt
		if touching and not bool(st["in_water"]):
			add_point(pos, t, ENTRY_STRENGTH)
			st["travel"] = 0.0
			st["bob_next"] = t + BOB_PERIOD
		elif touching and speed >= STILL_SPEED:
			var spacing := spacing_for(speed)
			var strength := strength_for(speed)
			var along := spacing - float(st["travel"])
			while along <= dist:
				var f := along / dist
				add_point(prev.lerp(pos, f), lerpf(t0, t, f), strength)
				along += spacing
			st["travel"] = dist - (along - spacing)
			# A body that stops bobs soon after, not a whole period later.
			st["bob_next"] = t + BOB_PERIOD * 0.5
		elif touching:
			if t >= float(st["bob_next"]):
				add_point(pos, t, BOB_STRENGTH)
				st["bob_next"] = t + BOB_PERIOD
		else:
			st["travel"] = 0.0
		st["pos"] = pos
		st["t"] = t
		st["in_water"] = touching
	for key in _sources.keys():
		if not seen.has(key):
			_sources.erase(key)


# Spreads the bobs of bodies that arrive together, so a herd standing in a
# pond does not pulse in step.
static func _jitter(key) -> float:
	return 0.3 + 0.7 * float(hash(key) & 1023) / 1023.0


# The points still alive at `t`, in no particular order.
func live_points(t: float) -> Array[Vector4]:
	var out: Array[Vector4] = []
	for p in points:
		var age := t - p.z
		if age >= 0.0 and age <= MAX_AGE and p.w > 0.0:
			out.append(p)
	return out


# The xz box every live ring stays inside: each point's position grown by
# the largest a ring gets, plus its packet.
static func area_of(live: Array[Vector4]) -> Vector4:
	if live.is_empty():
		return Vector4.ZERO
	var reach := START + SPREAD * MAX_AGE + 3.0 * WIDTH
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in live:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return Vector4(lo.x - reach, lo.y - reach, hi.x + reach, hi.y + reach)


# Hands the live points to the shader. Dead points are left out, so the
# shader's loop runs over the live ones only, and none at all when the water
# is still.
func publish(t: float) -> void:
	var live := live_points(t)
	if live.is_empty() and _live == 0:
		return
	if _image != null:
		for i in MAX_POINTS:
			var p := live[i] if i < live.size() else Vector4.ZERO
			_image.set_pixel(i, 0, Color(p.x, p.y, p.z, p.w))
		_texture.update(_image)
	_live = live.size()
	RenderingServer.global_shader_parameter_set("goanna_wake_area", area_of(live))
	_publish_state(t)


func _publish_state(t: float) -> void:
	RenderingServer.global_shader_parameter_set("goanna_wake_state", Vector4(_live, t, 0.0, 0.0))


# goanna_wake_ring in wake.gdshaderinc, mirrored so a test can check the
# ring without a GPU; project/tests/wake.gd ties these lines to the source.
# In x and y the slope of the ring's height field at p, in z its crest.
static func ring(p: Vector2, pt: Vector4, t: float) -> Vector3:
	var age := t - pt.z
	if age < 0.0 or age > MAX_AGE:
		return Vector3.ZERO
	var d := p - Vector2(pt.x, pt.y)
	var r := d.length()
	var radius := START + SPREAD * age
	var u := r - radius
	var x := u / WIDTH
	if absf(x) > 3.0:
		return Vector3.ZERO
	var life := 1.0 - age / MAX_AGE
	var amp := pt.w * life * smoothstep(0.0, 0.1, age) / sqrt(1.0 + 2.0 * radius)
	var k := 6.2831853 / WAVE
	var env := exp(-x * x)
	var slope := amp * env * (-2.0 * x / (WIDTH * k) * cos(k * u) - sin(k * u))
	var crest := amp * env * maxf(cos(k * u), 0.0)
	var dir := d / r if r > 1e-4 else Vector2.ZERO
	return Vector3(dir.x * slope, dir.y * slope, crest)


# The sum of every live ring at p, as goanna_wake gives it for a pixel
# `eye_d` from the eye.
func wake_at(p: Vector2, t: float, eye_d: float) -> Vector3:
	if eye_d > RANGE:
		return Vector3.ZERO
	var acc := Vector3.ZERO
	for pt in live_points(t):
		acc += ring(p, pt, t)
	var fade := 1.0 - smoothstep(RANGE * 0.6, RANGE, eye_d)
	return Vector3(acc.x * fade, acc.y * fade, minf(acc.z, 1.0) * fade)


# For the control channel's status: how many bodies are being followed,
# how many of them touch water, and how many points are live.
func debug_state() -> Dictionary:
	var wet := 0
	for st in _sources.values():
		if bool(st["in_water"]):
			wet += 1
	return {"sources": _sources.size(), "in_water": wet, "live_points": _live}
