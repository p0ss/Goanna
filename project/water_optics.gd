# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# What the water round the eye is like, one description for both sides of
# its surface. docs/water-optics.md has the whole picture.
#
# Looked down into from above, the water shader absorbed the bed by its own
# constants; from inside, main.gd drew a fixed cyan fog tuned by eye. The two
# never agreed: shallows were glass from above and milky from in them. Now a
# region's optics are set here and both read them. The water shader takes
# its absorption and body tint (goanna_water_absorption, goanna_water_tint);
# the underwater fog takes its density and colour from murk(), which runs
# from clear near the surface to the region's murk in the depths, over a
# depth that is the region's own.
#
# Which region: what a player can see of the water round them. The bed
# under it (sand, gravel and stone read clear, like a beach or a reef; dirt
# and clay a lake; mud a swamp), lily pads on it (a swamp), and whether it
# is river water. Nothing is asked of the server: biomes are not sent, and
# these are the cues a vanilla player reads them by. Columns round the eye
# are looked down a few a frame, and the optics ease towards what they find
# over a couple of seconds, so wading out of a beach into a swamp is a
# gradual change, not a switch.
extends Node

const PlayerContext := preload("res://player_context.gd")

# Each region's optics.
#   absorption  Beer-Lambert absorption per node looked through from above,
#               red, green, blue; "clear" is what the water shader always
#               had, which reads right on a beach or a reef.
#   tint        the body's own colour, on the water tile's, for the little
#               light the column throws back, and on the murk's (murk_hue).
#   shallow     the underwater fog's density with the eye at the surface,
#   deep        and far down;
#   depth       the depth, in nodes, over which it goes most of the way from
#               one to the other (1 - 1/e of it).
#   volume      the scattering volume's density, shallow and deep.
# "clear" deep is the density of the fog main.gd drew everywhere before,
# which the owner found right for a lake or deeper water and too murky just
# under the surface.
const REGIONS := {
	"clear": {"absorption": Vector3(0.45, 0.11, 0.05), "tint": Vector3(1.0, 1.0, 1.0),
		"shallow": 0.012, "deep": 0.05, "depth": 16.0,
		"volume": Vector2(0.006, 0.03)},
	"lake": {"absorption": Vector3(0.55, 0.17, 0.12), "tint": Vector3(0.85, 1.0, 0.8),
		"shallow": 0.025, "deep": 0.07, "depth": 8.0,
		"volume": Vector2(0.012, 0.035)},
	"river": {"absorption": Vector3(0.6, 0.24, 0.2), "tint": Vector3(0.9, 1.0, 0.7),
		"shallow": 0.035, "deep": 0.08, "depth": 5.0,
		"volume": Vector2(0.018, 0.04)},
	"swamp": {"absorption": Vector3(1.0, 0.55, 0.7), "tint": Vector3(0.65, 0.75, 0.35),
		"shallow": 0.1, "deep": 0.2, "depth": 2.5,
		"volume": Vector2(0.04, 0.07)},
}
# With no water in view, or none classified, the optics stay as they were;
# a world starts clear.
const DEFAULT_REGION := "clear"

# Columns looked down: a GRID by GRID square round the eye, SPACING nodes
# apart, this many a frame. A column looks from REACH_UP over the eye down to
# REACH_DOWN under it for water, and then past the water to its bed.
const GRID := 7
const SPACING := 2
const COLUMNS_PER_FRAME := 4
const REACH_UP := 4
const REACH_DOWN := 24
# Seconds for the optics to go most of the way to a new region's.
const EASE := 2.0
# How big the water is: along FETCH_RAYS directions from the eye, stepping
# FETCH_STEP nodes out to FETCH_REACH, how far the open water goes before
# the first node at its surface that is not water, a few samples a frame.
# The mean of those is the fetch, the stretch wind has to raise waves on:
# a pond's few nodes lie flat, the sea's full reach is open.
const FETCH_RAYS := 16
const FETCH_STEP := 4
const FETCH_REACH := 64
const FETCH_SAMPLES_PER_FRAME := 8
# The background waves for a fetch: their strength, as a scale on the water
# shader's own (1 is what it always drew everywhere, which is a lake's). A
# pond almost flat, the open sea half again as strong. Their length is left
# alone: scaled with the fetch, the shader's phase swept with every change
# in it, and near a shore the whole sea strobed (water.gdshader).
const SEA_POND := 0.25
const SEA_OPEN := 1.6
const FETCH_POND := 6.0
const FETCH_OPEN := 48.0
# How far up from the eye to look for the surface, nodes.
const SURFACE_REACH := 48

var client: Object
# (Vector3) -> String: the name of the node at a world position. Left empty
# it asks the client's map; the test gives a fake world.
var node_at: Callable

# The optics now, eased: the keys of a REGIONS entry.
var current: Dictionary = REGIONS[DEFAULT_REGION].duplicate(true)
# What the last full sweep found: region -> share of the water columns.
var found := {}
# How far the eye is under the surface, nodes; 0 when it is not in water.
var eye_depth := 0.0
# The water most of the last sweep's columns held, by node name: whose tile
# colour the murk is.
var water_name := ""
# The height of the water's surface round the eye, from the last column
# that found water; NAN before any has.
var surface_y := NAN
# How far the open water reaches round the eye, nodes (FETCH_*), and the
# background waves' strength scale for it, eased.
var fetch := 24.0
var sea := 1.0
var _fetch_ray := 0
var _fetch_dist := 0
var _fetch_reach := PackedFloat32Array()

var _target: Dictionary = REGIONS[DEFAULT_REGION].duplicate(true)
var _sweep := {}
var _sweep_water := {}
var _column := 0
var _published := {}


# The underwater murk's colour at full daylight: daylight after MURK_PATH
# nodes through the water (the region's absorption, so red goes first, as it
# does to the bed seen from above), times the region's tint, scaled so a
# beach's is MURK_PEAK at its brightest. That puts a beach's murk at (0.22,
# 0.62, 0.74), within a hundredth of the fixed cyan the owner found right
# for a lake or deeper; a swamp's comes out a dark green. main.gd lights it
# by the light actually falling on the water and darkens it with depth.
#
# The fixed cyan this stands in for was replaced once already, by deep
# water's colour seen from above (the tile times the column's small body
# share, lit): right for a pool seen from the bank, and nearly black as the
# glow of daylit water all round the eye, which drew the underside of the
# surface and the sky beyond it as a void.
const MURK_PATH := 3.0
const MURK_PEAK := 0.74

static func murk_hue(o: Dictionary) -> Color:
	var a: Vector3 = o["absorption"]
	var t: Vector3 = o["tint"]
	var clear: Vector3 = REGIONS["clear"]["absorption"]
	var top := maxf(exp(-clear.x * MURK_PATH), maxf(exp(-clear.y * MURK_PATH), exp(-clear.z * MURK_PATH)))
	var k := MURK_PEAK / top
	return Color(exp(-a.x * MURK_PATH) * t.x * k, exp(-a.y * MURK_PATH) * t.y * k,
			exp(-a.z * MURK_PATH) * t.z * k)


# The background waves' strength scale for a fetch in nodes.
static func sea_for(reach: float) -> float:
	return lerpf(SEA_POND, SEA_OPEN, smoothstep(FETCH_POND, FETCH_OPEN, reach))


static func is_water_name(node_name: String) -> bool:
	# Lily pads are named waterlily and float on the water, not in it.
	return node_name.contains("water") and not node_name.contains("lily")


# The region a bed node reads as, or "" for no opinion (air, plants, a node
# named for nothing here). By name, like the water itself.
static func bed_region(node_name: String) -> String:
	var n := node_name.to_lower()
	for word in ["mud", "peat", "swamp", "bog", "marsh"]:
		if n.contains(word):
			return "swamp"
	for word in ["clay", "dirt", "soil", "podzol", "mycelium", "grass"]:
		if n.contains(word):
			return "lake"
	for word in ["sand", "gravel", "stone", "coral", "prismarine", "reef", "granite",
			"andesite", "diorite", "deepslate", "tuff", "calcite", "basalt"]:
		if n.contains(word):
			return "clear"
	return ""


# One column's region, from its water's name, what floats on its surface
# and its bed: lily pads make a swamp whatever the bed, river water a river
# unless the bed is a swamp's.
static func column_region(water_name: String, surface_name: String, bed_name: String) -> String:
	var bed := bed_region(bed_name)
	if bed == "swamp" or surface_name.to_lower().contains("lily"):
		return "swamp"
	if water_name.to_lower().contains("river"):
		return "river"
	return bed


# The optics of a mix of regions, each weighted by its share.
static func blend(shares: Dictionary) -> Dictionary:
	var total := 0.0
	for k in shares:
		total += float(shares[k])
	if total <= 0.0:
		return REGIONS[DEFAULT_REGION].duplicate(true)
	var out := {"absorption": Vector3.ZERO, "tint": Vector3.ZERO, "shallow": 0.0, "deep": 0.0, "depth": 0.0, "volume": Vector2.ZERO}
	for k in shares:
		var w := float(shares[k]) / total
		var r: Dictionary = REGIONS[k]
		for key in out:
			out[key] += r[key] * w
	return out


# Eases optics `a` towards `b` by `f`, 0 to 1.
static func ease_to(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out := {}
	for key in a:
		out[key] = a[key].lerp(b[key], f) if not (a[key] is float) else lerpf(a[key], b[key], f)
	return out


# The underwater murk for optics `o` with the eye `depth` nodes down: the fog
# density, the scattering volume's density, and how much of the region's
# full murk colour there is (1 at the surface, darker further down, where
# less of the daylight reaches). Clear near the surface, the region's murk
# in the depths, the region's own depth setting how fast.
static func murk(o: Dictionary, depth: float) -> Dictionary:
	var down := 1.0 - exp(-maxf(depth, 0.0) / maxf(float(o["depth"]), 0.1))
	var volume: Vector2 = o["volume"]
	return {
		"density": lerpf(float(o["shallow"]), float(o["deep"]), down),
		"volume": lerpf(volume.x, volume.y, down),
		"light": lerpf(1.0, 0.45, down),
	}


func _name_at(p: Vector3) -> String:
	if node_at.is_valid():
		return String(node_at.call(p))
	if client == null or not client.has_method("node_name_at"):
		return ""
	return String(client.node_name_at(p))


func _process(delta: float) -> void:
	var m: Node = PlayerContext.find(self, "goanna_main")
	if m == null or m.get("cam") == null:
		return
	step((m.cam as Node3D).global_position, delta)


# One frame: look down the next few columns round `eye`, measure how deep the
# eye is, ease the optics and hand them to the water shader.
func step(eye: Vector3, delta: float) -> void:
	for i in COLUMNS_PER_FRAME:
		_look_down(eye, _column)
		_column += 1
		if _column >= GRID * GRID:
			_column = 0
			if not _sweep.is_empty():
				found = _sweep
				_target = blend(found)
			if not _sweep_water.is_empty():
				var most := 0
				for w in _sweep_water:
					if int(_sweep_water[w]) > most:
						most = int(_sweep_water[w])
						water_name = w
			_sweep = {}
			_sweep_water = {}
	eye_depth = depth_under(eye)
	_measure_fetch(eye)
	var f := 1.0 - exp(-delta / EASE)
	current = ease_to(current, _target, f)
	sea = lerpf(sea, sea_for(fetch), f)
	_publish()


# Takes the next few samples along the fetch rays, and when every ray has
# ended, the fetch is their mean.
func _measure_fetch(eye: Vector3) -> void:
	if is_nan(surface_y):
		return
	if _fetch_reach.size() != FETCH_RAYS:
		_fetch_reach.resize(FETCH_RAYS)
	for i in FETCH_SAMPLES_PER_FRAME:
		_fetch_dist += FETCH_STEP
		var a := TAU * _fetch_ray / FETCH_RAYS
		var p := Vector3(eye.x + cos(a) * _fetch_dist, surface_y - 0.5, eye.z + sin(a) * _fetch_dist)
		if _fetch_dist >= FETCH_REACH or not is_water_name(_name_at(p)):
			_fetch_reach[_fetch_ray] = minf(_fetch_dist, FETCH_REACH)
			_fetch_dist = 0
			_fetch_ray += 1
			if _fetch_ray >= FETCH_RAYS:
				_fetch_ray = 0
				var total := 0.0
				for r in _fetch_reach:
					total += r
				fetch = total / FETCH_RAYS


# How far `eye` is under the water's surface, 0 if it is not in water: up
# through the water it is in to the first node that is not.
func depth_under(eye: Vector3) -> float:
	var y := roundi(eye.y)
	if not is_water_name(_name_at(Vector3(eye.x, y, eye.z))):
		return 0.0
	for up in SURFACE_REACH:
		if not is_water_name(_name_at(Vector3(eye.x, y + up + 1, eye.z))):
			return (y + up + 0.5) - eye.y
	return float(SURFACE_REACH)


func _look_down(eye: Vector3, index: int) -> void:
	var half := GRID / 2
	var x := roundi(eye.x) + (index % GRID - half) * SPACING
	var z := roundi(eye.z) + (index / GRID - half) * SPACING
	var y := roundi(eye.y) + REACH_UP
	var above := _name_at(Vector3(x, y, z))
	var water := ""
	var water_top := y
	while y > roundi(eye.y) - REACH_DOWN:
		y -= 1
		var here := _name_at(Vector3(x, y, z))
		if water == "":
			if is_water_name(here):
				water = here
				water_top = y
			else:
				above = here
			continue
		if is_water_name(here):
			continue
		_sweep_water[water] = int(_sweep_water.get(water, 0)) + 1
		surface_y = water_top + 0.5
		var region := column_region(water, above, here)
		if region != "":
			_sweep[region] = int(_sweep.get(region, 0)) + 1
		return


func _publish() -> void:
	var a: Vector3 = current["absorption"]
	var t: Vector3 = current["tint"]
	if _published.get("a") != a:
		_published["a"] = a
		PlayerContext.shader_parameter(client, "goanna_water_absorption", a)
	if _published.get("t") != t:
		_published["t"] = t
		PlayerContext.shader_parameter(client, "goanna_water_tint", t)
	if _published.get("s") != sea:
		_published["s"] = sea
		# A vec4: the per view globals (goanna_render_scope.cpp) take no vec2.
		PlayerContext.shader_parameter(client, "goanna_water_sea", Vector4(sea, 1.0, 0.0, 0.0))


# For the control channel's status.
func debug_state() -> Dictionary:
	return {"found": found, "water": water_name, "eye_depth": eye_depth, "fetch": fetch, "sea": sea,
		"murk": murk(current, eye_depth),
		"absorption": current["absorption"]}
