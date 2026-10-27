# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Where the feet of the bodies round the player come down on land. Fed the
## same sources as wake.gd (Wake.gather_sources), it keeps how far each body
## has gone since its last step and gives back a footfall every STRIDE of
## travel along the ground, and a landing when a body comes down from a fall.
## Used by game/effects/climate_particles.gd, which puts dust or splashes
## where they land. Checked by tests/footfalls.gd.
#
# wake.gd lays its points on the water by the same reckoning (spacing by
# travel between two samples), but only while a body spans the surface;
# this is the land half of it, kept apart so neither needs the other's
# bookkeeping. Presentation only: positions are what the client draws.
extends RefCounted

# Nodes of travel between two footfalls: a walking stride, a little under a
# node, so a walk puts one down every fifth of a second or so.
const STRIDE := 0.8
# Slower than this, nodes a second along the ground, a body is standing.
const MIN_SPEED := 0.6
# A drop of more than this between two samples, ending on the ground, is a
# landing, which throws up more than a step.
const LANDING_DROP := 1.2
# Forget a body not seen for this long, seconds.
const FORGET := 2.0

var _bodies := {}  # key -> {pos, travel, seen, fall}
# Why samples gave no step, for the control channel: the body off its
# footing, and too slow to step.
var off_ground := 0
var standing := 0


# One sample of `sources` ([{key, pos}], pos the feet) taken `dt` seconds
# after the last, at time `t`. `ground` is a Callable(Vector3) -> bool, true
# when there is footing under a body's feet that is not water. Returns the
# footfalls since the last sample as [{key, pos, speed, landing}], `speed`
# in nodes a second along the ground.
func step(sources: Array, dt: float, t: float, ground: Callable) -> Array:
	var out := []
	for s in sources:
		var key = s["key"]
		var pos: Vector3 = s["pos"]
		var b: Dictionary = _bodies.get(key, {})
		if b.is_empty():
			_bodies[key] = {"pos": pos, "travel": 0.0, "seen": t, "fall": 0.0}
			continue
		var last: Vector3 = b["pos"]
		var flat := Vector2(pos.x - last.x, pos.z - last.z).length()
		var drop := last.y - pos.y
		b["pos"] = pos
		b["seen"] = t
		# A jump between samples longer than a sprint is a teleport, not a
		# walk: no trail of steps along it.
		if flat > 12.0 * maxf(dt, 0.05):
			b["travel"] = 0.0
			b["fall"] = 0.0
			continue
		var footing := bool(ground.call(pos))
		if not footing:
			off_ground += 1
			b["fall"] = float(b["fall"]) + maxf(drop, 0.0)
			continue
		var speed := flat / maxf(dt, 0.001)
		if float(b["fall"]) + maxf(drop, 0.0) > LANDING_DROP:
			out.append({"key": key, "pos": pos, "speed": speed, "landing": true})
			b["travel"] = 0.0
		elif speed < MIN_SPEED:
			standing += 1
		else:
			b["travel"] = float(b["travel"]) + flat
			if float(b["travel"]) >= STRIDE:
				b["travel"] = fmod(float(b["travel"]), STRIDE)
				out.append({"key": key, "pos": pos, "speed": speed, "landing": false})
		b["fall"] = 0.0
	for key in _bodies.keys():
		if t - float(_bodies[key]["seen"]) > FORGET:
			_bodies.erase(key)
	return out


func tracked() -> int:
	return _bodies.size()
