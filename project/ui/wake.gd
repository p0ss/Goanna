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
# Round the eye the rings give way to ripples: a patch of water 32 nodes
# across that keeps what is done to it (GoannaRipples, goanna_ripples.h),
# stepped every frame with the bodies on it pressing and shoving it, so a
# swimmer pushes a bow wave and leaves a V, and waves meet and reflect off
# the banks. The patch lies on one water surface, the one the local player
# is in (or else the nearest wet body's); bodies on that surface and inside
# the patch are drawn by it, and every other body keeps its rings.
#
# Presentation only. Positions come from what the client already draws (the
# local player and the entities it has been sent), and the water from the
# map it already holds; nothing is asked of the server. docs/weather.md,
# "Wakes" and "Ripples", has the design and what is untested.
extends Node

const PlayerContext := preload("res://player_context.gd")
const Splashes := preload("res://ui/splashes.gd")

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

# The ripple patch. Its side in nodes is GoannaRipples.get_nodes() (32).
# The patch follows the eye in whole nodes once the eye is this far from
# its middle, so the waves stay put in the world while it moves.
const RIPPLE_RECENTRE := 4
# Bodies within this many nodes of the patch's edge are left to the rings:
# the sponge round the edge would swallow their waves.
const RIPPLE_MARGIN := 3
# A body is on the patch's surface when its own water surface is within
# this of it.
const RIPPLE_PLANE := 0.35
# Seconds between re-reading which nodes of the patch are open water, while
# it is moving; also re-read whenever the patch moves or changes surface.
# A read is two map lookups a node, a couple of thousand for the patch, so
# it is spread over frames, this many rows of nodes a frame; until it is
# done the patch keeps the mask it had, moved with it.
const RIPPLE_MASK_REFRESH := 4.0
const RIPPLE_MASK_ROWS := 4
# What a body does to the water, the water it shoves aside moving and the
# water it pushes out sinking into it and lets back rising, is
# RippleField::swimmer's (goanna_ripples.h), tuned and tested there; a body
# is handed over as a position, a velocity across, how fast it is sinking
# into the water (sinking(): nothing while it is in the air over the water,
# or wholly under it) and a scale. Holding still, it leaves the water
# still. Animals are smaller than the player, and their positions arrive
# ten times a second rather than every frame.
const RIPPLE_ENTITY_SCALE := 0.7
# Past this, nodes a second, a jump between frames is a teleport.
const RIPPLE_TOO_FAST := 12.0

# Splashes (splashes.gd), from the bodies the patch draws. A body throws up
# a crown going in faster than SPLASH_SINK nodes a second, and drips coming
# out as fast; one of each at most every SPLASH_COOLDOWN. Moving through the
# surface faster than SPRAY_SPEED across, it sprays off its bow. Burst
# strength is the speed over SPLASH_FULL.
const SPLASH_SINK := 1.2
const SPLASH_COOLDOWN := 0.3
const SPLASH_FULL := 3.0
const SPRAY_SPEED := 2.2
# Crowns (splashes.crown): going in at CROWN_MIN of a full splash or more
# throws up a sheet of water round the body, CROWN_BODY across its foot and
# up; leaning towards how the body was moving across, fully lopsided at
# CROWN_LEAN nodes a second. A blow throws a smaller one, CROWN_STRIKE,
# leaning the way the blow went.
const CROWN_MIN := 0.5
const CROWN_BODY := Vector2(0.55, 0.9)
const CROWN_LEAN := 4.0
const CROWN_STRIKE := Vector2(0.22, 0.45)
# Where the droplets come down, small kicks on the patch: how hard, how
# many a burst throws at full strength, and how far out and how late they
# land. Spray lands beside the bow, SPRAY_LANDINGS a second.
const DROP_KICK := 0.25
const DROP_LANDINGS := 8
const DROP_REACH := Vector2(0.5, 1.5)
const DROP_DELAY := Vector2(0.3, 0.8)
const SPRAY_LANDINGS := 6.0
# A blow at the water: how far the view ray reaches, like the hand, and the
# kick where it lands.
const STRIKE_REACH := 4.0
const STRIKE_KICK := 1.2
# Strokes (goanna_limbs.h): a hand or foot of a body the patch draws going
# into or out of the water (GoannaClient.take_stroke_events). The kick on
# the patch and the splash scale with the limb's speed over STROKE_FULL
# nodes a second; a foot kicks at FOOT_SHARE of a hand. Only within
# STROKE_NEAR of the patch's surface.
const STROKE_KICK := 0.5
const STROKE_FULL := 4.0
const FOOT_SHARE := 0.6
const STROKE_NEAR := 0.6

var client: Object
# GoannaRipples, when the extension has it; without it every body keeps the
# rings.
var ripples: Object
var _plane := NAN            # the surface the patch lies on, NAN when none
var _claimed := {}           # source keys the patch draws, not the rings
var _mask_at := -INF         # wake clock time the water mask was read
var _mask_plane := NAN
var _mask_build := {}        # a read in progress: origin, surface, row, bytes
var _feet_prev := Vector3(NAN, NAN, NAN)
var _ripples_shown := false
# splashes.gd, drawing the droplets; null leaves the waves alone.
var splashes: Object
var _splash := {}            # key -> {"sink": last sinking, "next": cooldown end}
var _landings := []          # [time, Vector2 where, kick], droplets on their way down
var _last_t := 0.0           # the wake clock at the last ripple frame
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
	PlayerContext.shader_parameter(client, "goanna_wake_points", _texture)
	_publish_state(0.0)
	if ripples == null and ClassDB.class_exists("GoannaRipples"):
		ripples = ClassDB.instantiate("GoannaRipples")
	if ripples != null:
		PlayerContext.shader_parameter(client, "goanna_ripple_height", ripples.get_texture())
		if splashes == null:
			splashes = Splashes.new()
			add_child(splashes)
	_publish_ripples(false)


func _exit_tree() -> void:
	PlayerContext.shader_parameter(client, "goanna_wake_state", Vector4.ZERO)
	PlayerContext.shader_parameter(client, "goanna_ripple_state", Vector4.ZERO)


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
		var m: Node = PlayerContext.find(self, "goanna_main")
		if m != null and m.get("cam") != null:
			var eye: Vector3 = (m.cam as Node3D).global_position
			var sources := gather_sources(m, eye)
			claim(sources)
			step(sources, t)
			publish(t)
	if ripples != null and client != null and client.has_method("take_stroke_events"):
		strokes(client.take_stroke_events(), t)
	if ripples != null:
		var m: Node = PlayerContext.find(self, "goanna_main")
		if m != null and m.get("cam") != null:
			var feet := local_feet(m, (m.cam as Node3D).global_position)
			# The player's own velocity from the movement step, where there is
			# one; differencing positions instead needs smoothing, and the
			# smoothing lags.
			var lm = m.get("last_move")
			var vel := Vector3(NAN, NAN, NAN)
			if not bool(m.get("fly_mode")) and lm is Dictionary and lm.has("speed"):
				vel = lm["speed"]
			ripple_frame(feet, delta, t, vel)
	if _live > 0:
		_publish_state(t)


# The local player and the nearest entities within RANGE of `eye`, as
# [{key, pos}], pos being the feet.
func gather_sources(m: Node, eye: Vector3) -> Array:
	var me := local_feet(m, eye)
	var others := []
	var mine := {}
	if client != null and client.has_method("entity_list"):
		for e in client.entity_list():
			var p: Vector3 = e.get("position", Vector3.ZERO)
			# The local player's own object, if the list carries it, is the
			# same body; one wake for it, not two.
			if bool(e.get("local", false)) or (Vector2(p.x - me.x, p.z - me.z).length() < 0.4 and absf(p.y - me.y) < 1.0):
				mine = e
				continue
			others.append({"key": int(e.get("id", -1)), "pos": p, "hands": e.get("hands", []),
				"feet": e.get("feet", []), "water_pose": int(e.get("water_pose", 0))})
	var out := [{"key": "local", "pos": me, "hands": mine.get("hands", []),
		"feet": mine.get("feet", []), "water_pose": int(mine.get("water_pose", 0))}]
	out.append_array(nearest_sources(others, eye, MAX_SOURCES - 1, RANGE))
	return out


# The local player's feet: its walking position, or under the eye with the
# free camera.
static func local_feet(m: Node, eye: Vector3) -> Vector3:
	var lm = m.get("last_move")
	if not bool(m.get("fly_mode")) and lm is Dictionary and lm.has("pos"):
		return lm["pos"]
	return eye - Vector3(0.0, EYE_HEIGHT, 0.0)


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
	# which draws no wake. Lily pads, named waterlily, float on the water
	# and are not it.
	return node_name.contains("water") and not node_name.contains("lily")


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
		var surface: float = s["surface"] if s.has("surface") else water_surface(pos)
		var touching := not is_nan(surface)
		var drawn := _claimed.has(key)
		if not _sources.has(key):
			# First sight: no path yet, and no splash either, since it may
			# have been in the water long before it came into range.
			_sources[key] = {"pos": pos, "t": t, "travel": 0.0, "in_water": touching,
				"bob_next": t + BOB_PERIOD * _jitter(key), "vel": Vector3.ZERO}
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
			st["vel"] = Vector3.ZERO
			st["in_water"] = touching
			continue
		var speed := dist / dt
		st["vel"] = (pos - prev) / dt
		if touching and not bool(st["in_water"]):
			# A body the patch draws splashes there by sinking into it.
			if not drawn:
				add_point(pos, t, ENTRY_STRENGTH)
			st["travel"] = 0.0
			st["bob_next"] = t + BOB_PERIOD
		elif drawn:
			# The patch draws this one: its trail and its sway are there.
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
	PlayerContext.shader_parameter(client, "goanna_wake_area", area_of(live))
	_publish_state(t)


func _publish_state(t: float) -> void:
	PlayerContext.shader_parameter(client, "goanna_wake_state", Vector4(_live, t, 0.0, 0.0))


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
	var state := {"sources": _sources.size(), "in_water": wet, "live_points": _live}
	if ripples != null:
		# JSON has no NaN; no surface is null.
		state["ripples"] = {"surface": null if is_nan(_plane) else _plane, "bodies": _claimed.size(),
			"moving": not ripples.is_asleep(), "peak": ripples.peak()}
	if splashes != null:
		state["splashes"] = splashes.counts()
	return state


# Which sources the ripple patch draws, and the surface it lies on: the local
# player's (the first source) if it is in the water, or else that of the
# nearest wet source inside the patch. Each source's water surface is left
# on it as "surface", so step() need not look it up again.
func claim(sources: Array) -> void:
	_claimed.clear()
	for s in sources:
		s["surface"] = water_surface(s["pos"])
	if ripples == null or sources.is_empty():
		_plane = NAN
		return
	var me: Vector3 = sources[0]["pos"]
	_plane = sources[0]["surface"]
	if is_nan(_plane):
		var best := INF
		for s in sources:
			if not is_nan(float(s["surface"])) and _inside_patch(s["pos"], me):
				var d := Vector2(s["pos"].x - me.x, s["pos"].z - me.z).length()
				if d < best:
					best = d
					_plane = s["surface"]
	if is_nan(_plane):
		return
	for s in sources:
		if not is_nan(float(s["surface"])) and absf(float(s["surface"]) - _plane) < RIPPLE_PLANE \
				and _inside_patch(s["pos"], me):
			_claimed[s["key"]] = true


# Whether `pos` is well inside a patch centred on `me`: out of reach of the
# sponge at its edge.
func _inside_patch(pos: Vector3, me: Vector3) -> bool:
	var half := float(ripples.get_nodes()) * 0.5 - RIPPLE_MARGIN
	return absf(pos.x - me.x) < half and absf(pos.z - me.z) < half


# One frame of the ripple patch, the local player's feet at `feet` moving at
# `vel` (NAN: work it out from the last frame): follow the eye, keep the
# water mask current, hand every claimed body to the patch, step, and give
# the heights to the water shader.
func ripple_frame(feet: Vector3, delta: float, t: float, vel := Vector3(NAN, NAN, NAN)) -> void:
	_last_t = t
	if is_nan(vel.x):
		vel = Vector3.ZERO
		if delta > 0.0 and not is_nan(_feet_prev.x):
			vel = (feet - _feet_prev) / delta
	if vel.length() > RIPPLE_TOO_FAST:
		vel = Vector3.ZERO
	_feet_prev = feet
	if is_nan(_plane) and ripples.is_asleep() and _landings.is_empty():
		_publish_ripples(false)
		return
	var n: int = ripples.get_nodes()
	var want := Vector2i(roundi(feet.x), roundi(feet.z)) - Vector2i(n / 2, n / 2)
	var have: Vector2i = ripples.get_origin()
	var moved := absi(want.x - have.x) > RIPPLE_RECENTRE or absi(want.y - have.y) > RIPPLE_RECENTRE
	if moved:
		ripples.set_origin(want)
	# The surface to read: the one the bodies are on, or, with none in the
	# water, the one last struck or last drawn.
	var surface := _plane if not is_nan(_plane) else _mask_plane
	if not is_nan(surface) and (moved or t - _mask_at > RIPPLE_MASK_REFRESH
			or is_nan(_mask_plane) or absf(_mask_plane - surface) > 0.25):
		if _mask_build.is_empty() or _mask_build["origin"] != ripples.get_origin() \
				or absf(float(_mask_build["surface"]) - surface) > 0.25:
			var bytes := PackedByteArray()
			bytes.resize(n * n)
			_mask_build = {"origin": ripples.get_origin(), "surface": surface, "row": 0, "bytes": bytes}
		# The surface the waves are drawn on is the one being read, from the
		# first row: the patch has changed surface, so the old one is done.
		_mask_plane = surface
	if not _mask_build.is_empty():
		_continue_mask(n, t)
	var bodies := PackedFloat32Array()
	for key in _claimed:
		if key is String and key == "local":
			var sink := sinking(feet, vel.y, _mask_plane)
			bodies.append_array([feet.x, feet.z, vel.x, vel.z, sink, 1.0])
			_splash_body(key, feet, vel, sink, 1.0, delta, t)
		elif _sources.has(key):
			var st: Dictionary = _sources[key]
			var v: Vector3 = st.get("vel", Vector3.ZERO)
			# Carried on from the last sample along its velocity, so an
			# animal shoves the water every frame, not ten times a second.
			var ahead := clampf(t - float(st["t"]), 0.0, SAMPLE_INTERVAL * 2.0)
			var p: Vector3 = st["pos"]
			var at := p + v * ahead
			var sink := sinking(at, v.y, _mask_plane)
			bodies.append_array([at.x, at.z, v.x, v.z, sink, RIPPLE_ENTITY_SCALE])
			_splash_body(key, at, v, sink, RIPPLE_ENTITY_SCALE, delta, t)
	_land_droplets(t)
	ripples.step(delta, bodies)
	_publish_ripples(not ripples.is_asleep())


# What body `key` at `pos` (feet), moving at `vel` and sinking into the
# water at `sink` nodes a second, throws up this frame: a crown going in, drips
# coming out, spray moving fast through the surface.
func _splash_body(key, pos: Vector3, vel: Vector3, sink: float, scale: float,
		delta: float, t: float) -> void:
	if splashes == null or is_nan(_mask_plane):
		return
	var st: Dictionary = _splash.get(key, {"sink": 0.0, "next": -INF})
	var surface := Vector3(pos.x, _mask_plane, pos.z)
	if t >= float(st["next"]):
		if sink > SPLASH_SINK and float(st["sink"]) <= SPLASH_SINK:
			var s := clampf(sink / SPLASH_FULL, 0.2, 1.0) * scale
			splashes.burst("entry", surface, s)
			if s >= CROWN_MIN * scale:
				splashes.crown(surface, s / scale, Vector2(vel.x, vel.z) / CROWN_LEAN,
						CROWN_BODY * scale)
			_drop(surface, s, t)
			st["next"] = t + SPLASH_COOLDOWN
		elif sink < -SPLASH_SINK and float(st["sink"]) >= -SPLASH_SINK:
			var s := clampf(-sink / SPLASH_FULL, 0.2, 1.0) * scale
			splashes.burst("drip", pos, s)
			_drop(surface, s * 0.5, t)
			st["next"] = t + SPLASH_COOLDOWN
	var across := Vector2(vel.x, vel.z)
	var straddling := pos.y < _mask_plane and pos.y + BODY_ABOVE > _mask_plane
	if straddling and across.length() > SPRAY_SPEED:
		var fwd := Vector3(across.x, 0.0, across.y).normalized()
		splashes.spray(key, surface + fwd * 0.35 * scale, fwd, across.length() * scale)
		if randf() < SPRAY_LANDINGS * delta:
			var side := Vector3(-fwd.z, 0.0, fwd.x) * (1.0 if randf() < 0.5 else -1.0)
			var at := surface + fwd * randf_range(0.2, 0.8) + side * randf_range(0.4, 1.0)
			_landings.append([t + randf_range(DROP_DELAY.x, DROP_DELAY.y), Vector2(at.x, at.z),
				DROP_KICK * 0.6 * scale])
	st["sink"] = sink
	_splash[key] = st


# Droplets thrown from `at` at strength `s` coming down round it later.
func _drop(at: Vector3, s: float, t: float) -> void:
	for i in maxi(1, int(round(DROP_LANDINGS * s))):
		var a := randf() * TAU
		var r := randf_range(DROP_REACH.x, DROP_REACH.y)
		_landings.append([t + randf_range(DROP_DELAY.x, DROP_DELAY.y),
			Vector2(at.x + cos(a) * r, at.z + sin(a) * r), DROP_KICK * clampf(s, 0.3, 1.0)])


# Kicks the patch where droplets have come down by now.
func _land_droplets(t: float) -> void:
	var still := []
	for d in _landings:
		if float(d[0]) <= t:
			ripples.impulse(d[1], float(d[2]), 0.12)
		else:
			still.append(d)
	_landings = still


# A blow at the water: along the view ray from `origin` in `dir`, within
# STRIKE_REACH and short of `blocked_at` (what the blow hit, if anything),
# the first open water surface. There it kicks the patch and throws up a
# burst. From the bank too: with no body in the water the patch moves to
# the eye and lies on the struck surface. Returns whether it hit water.
func strike(origin: Vector3, dir: Vector3, blocked_at := INF) -> bool:
	if ripples == null or dir.y >= -0.01:
		return false
	var d := 0.25
	var reach := minf(STRIKE_REACH, blocked_at)
	while d <= reach:
		var p := origin + dir * d
		var ny := roundi(p.y)
		if _is_water(Vector3(p.x, ny, p.z)) and not _is_water(Vector3(p.x, ny + 1, p.z)):
			var surface := ny + 0.5
			# Back along the ray to where it meets that surface.
			var hit := origin + dir * ((surface - origin.y) / dir.y)
			if hit.distance_to(origin) > reach:
				return false
			if is_nan(_plane):
				var n: int = ripples.get_nodes()
				var want := Vector2i(roundi(origin.x), roundi(origin.z)) - Vector2i(n / 2, n / 2)
				if want != ripples.get_origin() and ripples.is_asleep():
					ripples.set_origin(want)
				if is_nan(_mask_plane) or absf(_mask_plane - surface) > 0.25:
					_mask_plane = surface
					_mask_at = -INF
			ripples.impulse(Vector2(hit.x, hit.z), STRIKE_KICK, 0.2)
			if splashes != null:
				splashes.burst("strike", hit, 0.8)
				splashes.crown(hit, 0.8, Vector2(dir.x, dir.z), CROWN_STRIKE)
			_drop(hit, 0.5, _last_t)
			return true
		d += 0.25
	return false


# Reads the next RIPPLE_MASK_ROWS rows of the mask in progress, and hands it
# to the patch once every row is in; a read begun for another place or
# surface is dropped when the patch has moved on from it.
func _continue_mask(n: int, t: float) -> void:
	var b := _mask_build
	if b["origin"] != ripples.get_origin():
		_mask_build = {}
		_mask_at = -INF
		return
	var bytes: PackedByteArray = b["bytes"]
	var row: int = b["row"]
	var last := mini(row + RIPPLE_MASK_ROWS, n)
	for j in range(row, last):
		_mask_row(bytes, b["origin"], n, float(b["surface"]), j)
	b["bytes"] = bytes
	b["row"] = last
	if last >= n:
		ripples.set_water(bytes)
		_mask_at = t
		_mask_build = {}


func _mask_row(mask: PackedByteArray, origin: Vector2i, n: int, surface: float, j: int) -> void:
	for i in n:
		var x := float(origin.x + i)
		var z := float(origin.y + j)
		var open := _is_water(Vector3(x, surface - 0.5, z)) \
				and not _is_water(Vector3(x, surface + 0.5, z))
		mask[j * n + i] = 1 if open else 0


# How fast a body with its feet at `feet`, moving up at `vy`, is sinking
# into water whose surface is at `surface`: its submerged depth grows as it
# goes down, but only while the surface is somewhere up its body. A body
# jumping in the air over the water, or swimming wholly under it, pushes no
# water out of the way by going up or down.
static func sinking(feet: Vector3, vy: float, surface: float) -> float:
	if is_nan(surface) or feet.y >= surface or feet.y + BODY_ABOVE <= surface:
		return 0.0
	return -vy


# Which nodes of a patch of `n` by `n` nodes from `origin` are open water at
# `surface`: water in the node under it, and none in the node over it. One
# byte a node, x fastest, the layout GoannaRipples.set_water takes.
func water_mask(origin: Vector2i, n: int, surface: float) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(n * n)
	for j in n:
		_mask_row(mask, origin, n, surface, j)
	return mask


func _publish_ripples(moving: bool) -> void:
	if not moving and not _ripples_shown:
		return
	_ripples_shown = moving
	if not moving:
		PlayerContext.shader_parameter(client, "goanna_ripple_state", Vector4.ZERO)
		return
	# get_texture uploads this frame's heights into the same texture the
	# shader was handed in _ready.
	ripples.get_texture()
	var corner: Vector2 = ripples.get_corner()
	# The surface the mask was read on, which outlives _plane: waves still
	# settling after the player climbs out stay on the water they were on.
	PlayerContext.shader_parameter(client, "goanna_ripple_area",
			Vector4(corner.x, corner.y, float(ripples.get_nodes()), _mask_plane))
	PlayerContext.shader_parameter(client, "goanna_ripple_state", Vector4(1.0, 0.0, 0.0, 0.0))


# Hands and feet of bodies the patch draws going through its surface this
# frame (GoannaClient.take_stroke_events): a hand going in kicks the water
# and throws a small crown, coming out flicks a few drops; a foot breaking
# the surface does the same, softer.
func strokes(events: Array, t: float) -> void:
	if is_nan(_mask_plane):
		return
	for ev in events:
		var key = "local" if bool(ev.get("local", false)) else int(ev.get("id", -1))
		if not _claimed.has(key):
			continue
		var pos: Vector3 = ev.get("pos", Vector3.ZERO)
		if absf(pos.y - _mask_plane) > STROKE_NEAR:
			continue
		var share := 1.0 if str(ev.get("limb", "hand")) == "hand" else FOOT_SHARE
		var s := clampf(float(ev.get("speed", 0.0)) / STROKE_FULL, 0.15, 1.0) * share
		if key is int:
			s *= RIPPLE_ENTITY_SCALE
		var at := Vector3(pos.x, _mask_plane, pos.z)
		var into := bool(ev.get("into", true))
		ripples.impulse(Vector2(at.x, at.z), STROKE_KICK * s * (1.0 if into else -0.5), 0.12)
		if splashes != null:
			splashes.burst("stroke", at, s if into else s * 0.5)
		_drop(at, s * 0.4, t)

