# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Rain and snow drawn by shader instead of by the server's particle spawners.
# Luanti has no weather in the protocol: a game that rains attaches particle
# spawners to the player, and particles.gd recognises those by texture name.
# With shader weather on, particles.gd hands each such spawner here instead
# of building an emitter for it, and this draws the weather the spawners
# describe: its kind (the texture), how hard (the amount, which Mineclonia
# raises in a thunderstorm) and how fast it falls (the velocity).
#
# Presentation only. The spawners arrive exactly as before, nothing sent to
# the server changes, and the rain cover map is built from map data the
# client already holds. docs/weather.md has the design and what is untested.
extends Node3D

const RainCover := preload("res://ui/rain_cover.gd")
const SHADER := preload("res://shaders/precipitation.gdshader")

# Mineclonia's own rates, as the unit of intensity. Its rain.lua loops over
# two raindrop textures and its snow.lua over two flake textures, but
# mcl_weather.add_spawner_player drops every spawner the player has before
# adding one under a new id, so only one is ever running: 500 a second for
# rain, 900 in a thunderstorm, 100 for snow. The first version assumed two
# and drew ordinary rain at half strength; a live client showed one rain
# spawner of 500. Other games' weather lands wherever its amount puts it,
# within the clamp.
const RAIN_REFERENCE := 500.0
const SNOW_REFERENCE := 100.0
const MAX_INTENSITY := 2.0
# The falling drops: a box of them round the eye, and a smaller, denser box
# inside it (precipitation.gdshader has the design). Sizes in nodes, and how
# far the eye is above each box's bottom: most of the far box is below the
# eye, so drops are seen falling all the way to the ground, and enough of it
# above that looking up meets drops falling toward the face. Checked by
# project/tests/weather.gd against rays from straight down to straight up.
const FAR_BOX := Vector3(24.0, 16.0, 24.0)
const FAR_BELOW := 10.0
const NEAR_BOX := Vector3(6.0, 6.0, 6.0)
const NEAR_BELOW := 3.5
# Drops in each box at intensity 1. At MAX_INTENSITY twice as many are
# drawn; the instances are built for that, and a drop is drawn when its hash
# is under intensity / MAX_INTENSITY. About 0.3 drops a cubic node in the far
# box and 9 in the near: the near box is what fills the node or two of air
# between the eye and the ground looking down.
const RAIN_FAR := 3000
const RAIN_NEAR := 2000
const SNOW_FAR := 1800
const SNOW_NEAR := 800
# The look. Pushed to the materials in _ready, so these are the values
# drawn, and project/tests/weather.gd holds them to a floor of visibility
# (see drop_peak_alpha). A streak is 6 mm wide, a drop and its blur; a
# flake is 5 cm across.
const RAIN_ALPHA := 0.85
const SNOW_ALPHA := 0.9
const RAIN_HALF_WIDTH := 0.003
const SNOW_RADIUS := 0.025
# Seconds of fall one streak shows: Mineclonia's 17.5 nodes a second makes
# streaks of 0.5 to 0.7 nodes, about the length the cylinders drew, which
# the owner found right.
const STREAK_TIME := 0.035
const MAX_LEAN := 0.6
# The shader's own constants, repeated for the copy of its maths below and
# checked against its source by text in the test.
const NEAR_CLIP := 0.3
const NEAR_FADE := 1.2
const EDGE_FADE := 1.5
# Seconds to ease in and out, so a storm starting or a spawner being
# replaced (Mineclonia swaps them when a storm turns to thunder) never pops.
const EASE_SECONDS := 2.5

var client: Object
var cover: RefCounted
var _spawners := {}          # server id -> {kind, rate, speed}
var _rain_mesh: MultiMeshInstance3D
var _snow_mesh: MultiMeshInstance3D
var _rain_material: ShaderMaterial
var _snow_material: ShaderMaterial
var _rain := 0.0
var _snow := 0.0
var _rain_speed := 17.0
var _snow_speed := 2.2
var _wind := Vector2.ZERO
var _eye := Vector3.ZERO
var _shader_text := {}       # path -> source, for ground_trace


func _ready() -> void:
	cover = RainCover.new(client)
	_rain_material = make_material(false)
	_snow_material = make_material(true)
	_rain_mesh = _make_drops(RAIN_FAR + RAIN_NEAR, _rain_material)
	_snow_mesh = _make_drops(SNOW_FAR + SNOW_NEAR, _snow_material)
	_publish_globals()


static func make_material(snow: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("snow", snow)
	m.set_shader_parameter("max_amount", MAX_INTENSITY)
	m.set_shader_parameter("far_box", FAR_BOX)
	m.set_shader_parameter("far_below", FAR_BELOW)
	m.set_shader_parameter("near_box", NEAR_BOX)
	m.set_shader_parameter("near_below", NEAR_BELOW)
	m.set_shader_parameter("near_instances", near_instances(snow))
	m.set_shader_parameter("drop_alpha", SNOW_ALPHA if snow else RAIN_ALPHA)
	m.set_shader_parameter("drop_half_width", SNOW_RADIUS if snow else RAIN_HALF_WIDTH)
	m.set_shader_parameter("streak_time", STREAK_TIME)
	m.set_shader_parameter("max_lean", MAX_LEAN)
	return m


# Instances numbered below this fall in the near box.
static func near_instances(snow: bool) -> int:
	return int((SNOW_NEAR if snow else RAIN_NEAR) * MAX_INTENSITY)


static func instance_count(snow: bool) -> int:
	return int(((SNOW_FAR + SNOW_NEAR) if snow else (RAIN_FAR + RAIN_NEAR)) * MAX_INTENSITY)


# One MultiMesh, one draw call, for a kind of weather.
func _make_drops(per_unit: int, material: ShaderMaterial) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = build_multimesh(int(per_unit * MAX_INTENSITY))
	mmi.material_override = material
	# Weather casts no shadow and should not feed global illumination; a
	# screen of rain lighting the ground would be a bright sheet round the
	# player.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# The node follows the eye, and this box holds both drop boxes with
	# room for the sway, so it is never culled while the eye is inside it.
	mmi.custom_aabb = AABB(Vector3(-16, -16, -16), Vector3(32, 32, 32))
	mmi.visible = false
	add_child(mmi)
	return mmi


# `count` unit quads. The shader places every one itself, from its instance
# number (skip_vertex_transform), so the instance transforms are identity
# and never change: nothing is uploaded per frame.
static func build_multimesh(count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	mm.instance_count = count
	var buf := PackedFloat32Array()
	buf.resize(count * 12)
	for i in count:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	mm.buffer = buf
	return mm


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set("goanna_rain", 0.0)
	RenderingServer.global_shader_parameter_set("goanna_rain_cover_area", Vector4.ZERO)


# The shader's placing of drops, mirrored so a test can check where the
# drops are without a GPU. The hash is PCG in 32 bit unsigned arithmetic,
# exactly as the shader has it; project/tests/weather.gd ties these lines to
# the source by text.
const _U32 := 0xffffffff


static func pcg(v: int) -> int:
	var state := (v * 747796405 + 2891336453) & _U32
	var word := (((state >> ((state >> 28) + 4)) ^ state) * 277803737) & _U32
	return ((word >> 22) ^ word) & _U32


static func unit(h: int) -> float:
	return float(h >> 8) / 16777216.0


# One drop as vertex() places it: `head` and `tail` in the world, `weight`
# its box edge fade, `near` which box, `pick` its intensity hash. Whether it
# is drawn at all is drop_shown's question.
static func drop(id: int, t: float, eye: Vector3, speed: float, wind: Vector2,
		snow: bool) -> Dictionary:
	var h0 := pcg(id)
	var h1 := pcg(h0)
	var h2 := pcg(h1)
	var h3 := pcg(h2)
	var h4 := pcg(h3)
	var seed_v := Vector3(unit(h0), unit(h1), unit(h2))
	var vary := unit(h4)
	var near := id < near_instances(snow)
	var box := NEAR_BOX if near else FAR_BOX
	var corner := eye - Vector3(box.x * 0.5, NEAR_BELOW if near else FAR_BELOW, box.z * 0.5)
	var fall := speed * ((0.75 + 0.5 * vary) if snow else (0.85 + 0.3 * vary))
	var w := wind
	var cap := 2.0 * fall if snow else MAX_LEAN * fall
	if w.length() > cap:
		w *= cap / w.length()
	var vel := Vector3(w.x, -fall, w.y)
	var q := seed_v * box + vel * t - corner
	var p := corner + Vector3(fposmod(q.x, box.x), fposmod(q.y, box.y), fposmod(q.z, box.z))
	if snow:
		var ph := vary * 6.2832
		p.x += sin(t * (0.7 + vary) + ph) * 0.2
		p.z += cos(t * (0.6 + 0.8 * vary) + ph * 1.7) * 0.2
	var lo := p - corner
	var hi := corner + box - p
	var edge := smoothstep(0.0, EDGE_FADE, minf(minf(lo.x, hi.x), minf(lo.z, hi.z))) \
			* smoothstep(0.0, EDGE_FADE, minf(lo.y, hi.y))
	var streak_len := 0.0 if snow else fall * STREAK_TIME * (0.8 + 0.4 * seed_v.x)
	return {"head": p, "tail": p - vel.normalized() * streak_len, "weight": edge,
		"near": near, "pick": unit(h3), "corner": corner, "box": box}


# Whether vertex() draws a drop, for a camera at `cam`: part of this
# intensity, inside its box's fade, clear of the lens, and open to the sky
# at its top. `open` is the cover lookup, a Callable taking a world position
# and answering 0 or 1.
static func drop_shown(d: Dictionary, cam: Vector3, amount: float, open: Callable) -> bool:
	if float(d["pick"]) * MAX_INTENSITY >= amount or float(d["weight"]) <= 0.001:
		return false
	if segment_distance(d["tail"], d["head"], cam) <= NEAR_CLIP:
		return false
	return float(open.call(d["tail"])) > 0.5


static func segment_distance(a: Vector3, b: Vector3, p: Vector3) -> float:
	var seg := b - a
	var l2 := seg.length_squared()
	var k := 1.0 if l2 <= 0.0 else clampf((p - a).dot(seg) / l2, 0.0, 1.0)
	return (a + seg * k).distance_to(p)


# Peak opacity of a drop `dist` nodes away on a screen `height` pixels tall
# with a vertical field of view of `fov` degrees: the chain vertex() and
# fragment() run at a streak's centre, before the box edge fade. A drop
# narrower than a pixel and a half is drawn that wide at the coverage it has.
static func drop_peak_alpha(snow: bool, dist: float, height: float, fov: float) -> float:
	var pixel := dist * 2.0 * tan(deg_to_rad(fov) * 0.5) / height
	var true_w := SNOW_RADIUS if snow else RAIN_HALF_WIDTH
	var cov := true_w / maxf(true_w, pixel * 0.75)
	if snow:
		cov *= cov
	return (SNOW_ALPHA if snow else RAIN_ALPHA) * cov * smoothstep(NEAR_CLIP, NEAR_FADE, dist)


# goanna_ground_rain in weather_common.gdshaderinc, the water level, the
# pool, the darkening and a splash ring, mirrored for the status trace and
# the test, which ties each to its source by text. The shader's floats are
# single and these are double, so a basin's edge can land a hair elsewhere;
# the gating is the same.
static func _fract(x: float) -> float:
	return x - floorf(x)


static func weather_hash(p: Vector2) -> float:
	var p3 := Vector3(_fract(p.x * 0.1031), _fract(p.y * 0.1031), _fract(p.x * 0.1031))
	var k := p3.dot(Vector3(p3.y, p3.z, p3.x) + Vector3(33.33, 33.33, 33.33))
	p3 += Vector3(k, k, k)
	return _fract((p3.x + p3.y) * p3.z)


static func weather_noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	var u := f * f * (Vector2(3, 3) - 2.0 * f)
	var a := weather_hash(i)
	var b := weather_hash(i + Vector2(1, 0))
	var c := weather_hash(i + Vector2(0, 1))
	var d := weather_hash(i + Vector2(1, 1))
	return lerpf(lerpf(a, b, u.x), lerpf(c, d, u.x), u.y)


# GOANNA_PUDDLE_DRY and GOANNA_PUDDLE_SOAKED; the test reads the shader's.
const PUDDLE_DRY := 0.98
const PUDDLE_SOAKED := 0.55
# GOANNA_POOL_FILL and GOANNA_BASIN_RISE, likewise.
const POOL_FILL := 0.45
const BASIN_RISE := 1.2


# The basins, goanna_puddle.
static func puddle(p: Vector2, wet: float) -> float:
	var n := 0.7 * weather_noise(p / 3.1) + 0.3 * weather_noise(p / 1.13 + Vector2(17, 5))
	var t := lerpf(PUDDLE_DRY, PUDDLE_SOAKED, clampf(wet, 0.0, 1.0))
	return smoothstep(t - 0.06, t + 0.1, n)


# goanna_water_level: how high water stands, on the relief's own height.
static func water_level(p: Vector2, wet: float) -> float:
	return POOL_FILL * smoothstep(0.35, 1.0, wet) + BASIN_RISE * puddle(p, wet)


# goanna_pool: (water, wet margin, depth) at a relief height h.
static func pool(level: float, weight: float, h: float) -> Vector3:
	var water := (1.0 - smoothstep(level - 0.04, level, h)) * weight
	var shore := (1.0 - smoothstep(level, level + 0.25, h)) * weight * (1.0 - water)
	var depth := clampf((level - h) * 4.0, 0.0, 1.0) * water
	return Vector3(water, shore, depth)


# GOANNA_SPLASH_PX_FULL and GOANNA_SPLASH_PX_GONE.
const SPLASH_PX_FULL := 0.012
const SPLASH_PX_GONE := 0.03


# (water level, how much of it the ground holds, splash) at a point, as
# goanna_ground_rain gives them. `open` is the cover map's answer there (or
# the sky light fallback), 0 or 1; `px` the world size of a pixel.
static func ground_terms(p: Vector3, normal_y: float, rain: float, wet: float, open: float,
		flatten: float, eye_d: float, px: float) -> Vector3:
	var t := Vector3.ZERO
	if (rain > 0.001 or wet > 0.35) and normal_y > 0.7:
		if wet > 0.35 and normal_y > 0.95:
			t.x = water_level(Vector2(p.x, p.z), wet)
			t.y = smoothstep(0.35, 0.45, wet) * open * (1.0 - flatten)
		t.z = minf(rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, eye_d)) \
				* (1.0 - smoothstep(SPLASH_PX_FULL, SPLASH_PX_GONE, px)) * (1.0 - flatten) * open
	return t


# The world size of a pixel at a distance, looking square on at 1080 lines
# and a 70 degree view: what the status trace takes for `px`, since it has
# no screen to measure.
static func pixel_at(dist: float) -> float:
	return dist * 2.0 * tan(deg_to_rad(35.0)) / 1080.0


# goanna_wet_darken: the factor rain puts on the ground's own colour.
static func wet_darken(pool_v: Vector3, mark: float, porosity: float) -> float:
	var soak := maxf(pool_v.y, mark) * (1.0 - pool_v.x)
	return (1.0 - pool_v.x * (0.28 + 0.12 * porosity + 0.2 * pool_v.z)) \
			* (1.0 - soak * (0.08 + 0.17 * porosity))


# GOANNA_SPLASH_CELL, _PERIOD, _LIFE and _WIDTH.
const SPLASH_CELL := 0.22
const SPLASH_PERIOD := 0.6
const SPLASH_LIFE := 0.6
const SPLASH_WIDTH := 0.06


# goanna_splash_ring: (slope, wet mark) at r cells from a drop, k of the way
# through its life, growing to rmax, half width w.
static func splash_ring(r: float, k: float, rmax: float, w: float) -> Vector2:
	var radius := rmax * (1.0 - (1.0 - k) * (1.0 - k))
	var x := (r - radius) / w
	var fade := (1.0 - k) * (1.0 - k) * (SPLASH_WIDTH / w)
	var slope := -1.2 * x * exp(-x * x) * fade
	var mark := (1.0 - smoothstep(radius, radius + 2.0 * w, r)) * (1.0 - k)
	return Vector2(slope, mark)


# What a live check needs to tell "not raining" from "raining but hidden":
# the eased intensities, the drops drawn, whether a cover map is up, and over
# the eye the cover height, whether the eye is open to the sky as the
# shaders see it, and the share of the map's columns open at eye height;
# and, under `ground`, every gate between the weather and a splash or a
# puddle on the ground below the eye (ground_trace). Read by the control
# channel's status.
func debug_state() -> Dictionary:
	var eye := _eye
	var out := {"rain": _rain, "snow": _snow, "spawners": _spawners.size(),
		"drops_visible": (_rain_mesh != null and _rain_mesh.visible)
				or (_snow_mesh != null and _snow_mesh.visible),
		"rain_drops": int(round((RAIN_FAR + RAIN_NEAR) * _rain)),
		"snow_flakes": int(round((SNOW_FAR + SNOW_NEAR) * _snow)),
		"cover_ready": cover != null and cover.ready,
		"cover_area": cover.area if cover != null else Vector4.ZERO}
	if cover != null and cover.ready:
		out["cover_over_eye"] = cover.height_at(eye.x, eye.z)
		out["eye_open"] = cover.exposed(eye)
		out["open_share"] = cover.open_share(eye.y)
	var m: Node = get_tree().get_first_node_in_group("goanna_main") if is_inside_tree() else null
	var wet := 0.0
	if m != null and m.get("wetness") != null:
		wet = float(m.get("wetness"))
	out["ground"] = ground_trace(eye, _rain, wet)
	return out


# Every gate from the globals to the splash and puddle terms, for the top
# face of the ground under the eye, and `failing`, the first that is shut
# ("" when all are open). Two live checks saw the ground go wet and never a
# splash or a puddle; the cause was the first gate here, the ground's
# shader, which had none of the terms. On a running client this says which
# gate it is now: the shader, the rain and the wetness, the facing, the
# cover map, the distance, and the terms themselves.
func ground_trace(eye: Vector3, rain: float, wet: float) -> Dictionary:
	var g := {"goanna_rain": rain, "goanna_wetness": wet}
	var surf := _ground_under(eye)
	if surf.is_empty():
		g["failing"] = "no ground found under the eye"
		return g
	var p: Vector3 = surf["point"]
	g["point"] = p
	g["node"] = surf.get("node", "")
	g["texture"] = surf.get("texture", "")
	var shader := String(surf.get("shader", "unknown"))
	g["shader"] = shader
	g["array_alpha"] = surf.get("array_alpha", false)
	# The face's own layer, which is what picks the shader on the near mesh;
	# array_alpha only says whether the far tiers use the scissor one.
	g["layer_alpha"] = surf.get("layer_alpha", false)
	g["shader_has_terms"] = shader_has_ground_terms(shader)
	# The top face of a node: its world normal is straight up.
	var normal_y := 1.0
	g["weather_on"] = rain > 0.001 or wet > 0.35
	g["up_facing"] = normal_y > 0.7
	g["flat"] = normal_y > 0.95
	g["wet_enough_to_puddle"] = wet > 0.35
	var open := 1.0
	if cover != null and cover.ready:
		open = 1.0 if cover.exposed(p) else 0.0
		g["cover_height"] = cover.height_at(p.x, p.z)
		g["open_by"] = "cover map"
	else:
		g["open_by"] = "sky light, no cover map; taken as open here"
	g["open"] = open
	# The ground under the eye is the near mesh, where lod_flatten is off;
	# the far tiers begin hundreds of nodes out.
	var eye_d := eye.distance_to(p)
	g["near_mesh"] = true
	g["eye_distance"] = eye_d
	g["splash_range"] = 1.0 - smoothstep(10.0, 22.0, eye_d)
	g["pixel"] = pixel_at(eye_d)
	var t := ground_terms(p, normal_y, rain, wet, open, 0.0, eye_d, g["pixel"])
	g["basin"] = puddle(Vector2(p.x, p.z), wet)
	g["water_level"] = t.x
	g["pool"] = t.y
	g["splash"] = t.z
	g["failing"] = first_shut_gate(g)
	return g


# The first gate in `g` (a ground_trace) that is shut, or "" if none is.
# Whether water stands at this exact point depends on the tile's relief and
# on where the noise puts basins, neither of which the trace knows, so the
# level is reported but is not a gate.
static func first_shut_gate(g: Dictionary) -> String:
	if not bool(g.get("shader_has_terms", false)):
		return "the ground's shader (%s) has no splash or puddle terms" % g.get("shader", "?")
	if not bool(g.get("weather_on", false)):
		return "no rain falling and the ground not wet enough to puddle"
	if not bool(g.get("up_facing", false)):
		return "not up facing"
	if float(g.get("open", 0.0)) < 0.5:
		return "covered: the cover map has something over this point"
	if float(g.get("splash_range", 0.0)) <= 0.001:
		return "too far from the eye to splash"
	if float(g.get("splash", 0.0)) <= 0.001:
		return "splash term is zero"
	return ""


# Whether a node array shader, by name, carries the ground terms.
func shader_has_ground_terms(shader: String) -> bool:
	if not shader.begins_with("nodes_array"):
		return false
	var path := "res://shaders/%s.gdshader" % shader
	if not _shader_text.has(path):
		_shader_text[path] = FileAccess.get_file_as_string(path)
	return String(_shader_text[path]).contains("goanna_ground_rain(")


# The ground under the eye: the first node down, within 12, whose top face
# a node array shader draws (so tall grass or a torch is looked through to
# the soil under it), else the first that is not air.
func _ground_under(eye: Vector3) -> Dictionary:
	if client == null or not client.has_method("top_surface_at"):
		return {}
	var first := {}
	var y0 := floori(eye.y + 0.5)
	for dy in 13:
		var y := float(y0 - dy)
		var s: Dictionary = client.top_surface_at(Vector3(eye.x, y, eye.z))
		var node_name := String(s.get("node", ""))
		if node_name == "" or node_name == "air" or node_name == "ignore":
			continue
		s["point"] = Vector3(eye.x, y + 0.5, eye.z)
		if String(s.get("shader", "")).begins_with("nodes_array"):
			return s
		if first.is_empty():
			first = s
	return first


# The spawner as particles.gd received it. Its texture has already said it is
# weather; this reads which kind, how much and how fast.
func add_spawner(id: int, ev: Dictionary, tex_name: String) -> void:
	_spawners[id] = describe(ev, tex_name)


func remove_spawner(id: int) -> void:
	_spawners.erase(id)


func has_spawner(id: int) -> bool:
	return _spawners.has(id)


func clear() -> void:
	_spawners.clear()


# kind, rate (spawned a second) and fall speed, from a spawner definition.
# Luanti's amount is a rate for an endless spawner and a total over `time`
# for a timed one.
static func describe(ev: Dictionary, tex_name: String) -> Dictionary:
	var amount := float(ev.get("amount", 0))
	var time := float(ev.get("time", 0.0))
	var rate := amount / time if time > 0.0 else amount
	var vmin: Vector3 = ev.get("vel_min", Vector3.ZERO)
	var vmax: Vector3 = ev.get("vel_max", Vector3.ZERO)
	var fall := absf((vmin.y + vmax.y) * 0.5)
	var snow := tex_name.contains("snow")
	return {"kind": "snow" if snow else "rain", "rate": rate,
		"speed": clampf(fall, 0.8, 5.0) if snow else clampf(fall, 6.0, 30.0)}


# Target intensity of each kind, 0 to MAX_INTENSITY, and its speed.
func targets() -> Dictionary:
	var rate := {"rain": 0.0, "snow": 0.0}
	var speed := {"rain": 0.0, "snow": 0.0}
	for s in _spawners.values():
		rate[s["kind"]] += float(s["rate"])
		speed[s["kind"]] += float(s["speed"]) * float(s["rate"])
	var out := {}
	for kind in ["rain", "snow"]:
		var ref := RAIN_REFERENCE if kind == "rain" else SNOW_REFERENCE
		var r: float = rate[kind]
		# A spawner that is running at all is weather worth seeing, however
		# small its amount, so the floor is well above zero.
		out[kind] = clampf(r / ref, 0.3, MAX_INTENSITY) if r > 0.0 else 0.0
		out[kind + "_speed"] = float(speed[kind]) / r if r > 0.0 else 0.0
	return out


func _process(delta: float) -> void:
	var t := targets()
	var k := clampf(delta / EASE_SECONDS, 0.0, 1.0)
	_rain = move_toward(_rain, float(t["rain"]), k * MAX_INTENSITY)
	_snow = move_toward(_snow, float(t["snow"]), k * MAX_INTENSITY)
	if float(t["rain_speed"]) > 0.0:
		_rain_speed = float(t["rain_speed"])
	if float(t["snow_speed"]) > 0.0:
		_snow_speed = float(t["snow_speed"])
	var active := _rain > 0.001 or _snow > 0.001
	_rain_mesh.visible = _rain > 0.001
	_snow_mesh.visible = _snow > 0.001
	var m := get_tree().get_first_node_in_group("goanna_main")
	if m != null and m.get("cam") != null:
		_eye = (m.cam as Node3D).global_position
	if active:
		_update_wind(m, delta)
		# The map is needed only while something is falling; in fair
		# weather this whole node costs a dictionary walk a frame.
		if cover.step(_eye, delta):
			RenderingServer.global_shader_parameter_set("goanna_rain_cover", cover.texture)
		_feed(_rain_mesh, _rain_material, _rain, _rain_speed)
		_feed(_snow_mesh, _snow_material, _snow, _snow_speed)
	elif cover.ready:
		cover.clear()
	_publish_globals()


func _feed(mmi: MultiMeshInstance3D, mat: ShaderMaterial, amount: float, speed: float) -> void:
	if not mmi.visible:
		return
	mmi.global_position = _eye
	mat.set_shader_parameter("amount", amount)
	mat.set_shader_parameter("speed", speed)
	mat.set_shader_parameter("wind", _wind)
	mat.set_shader_parameter("eye", _eye)


# There is no wind in the protocol either. main.gd drives the grass from the
# cloud drift and the storm (grass_wind, a direction scaled 0.25 to 1); the
# rain leans with the same air. On a main.gd without it, the same rule is
# worked out here from the clouds.
func _update_wind(m: Node, delta: float) -> void:
	var w := Vector2.ZERO
	if m != null:
		var gw = m.get("grass_wind")
		if gw is Vector2:
			w = gw
		elif m.get("cloud_speed") is Vector2:
			var cs: Vector2 = m.cloud_speed
			var storm := float(m.get("storm_cover")) if m.get("storm_cover") != null else 0.0
			var dir := -cs.normalized() if cs.length_squared() > 0.01 else Vector2.RIGHT
			w = dir * clampf(0.25 + cs.length() * 0.05 + storm * 0.65, 0.25, 1.0)
	# Strength 1 is a gale; call it 7 nodes a second, which leans heavy rain
	# about 20 degrees and blows snow well off the vertical.
	_wind = _wind.lerp(w * 7.0, 1.0 - exp(-delta / 2.0))


func _publish_globals() -> void:
	RenderingServer.global_shader_parameter_set("goanna_rain", _rain)
	RenderingServer.global_shader_parameter_set("goanna_rain_cover_area",
			cover.area if cover != null else Vector4.ZERO)
