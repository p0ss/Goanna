# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Splashes: the droplets a body throws up out of the water, beside the waves
# the ripple patch draws. docs/weather.md, "Splashes", has the whole picture.
#
# wake.gd says when (falling or jumping in, climbing or jumping out, moving
# fast through the surface, striking at the water) and this draws it: a
# crown of droplets thrown up and out from where a body went in, drips off
# a body coming out, spray fanning off the bow of one running or swimming,
# and a burst where a blow landed on the water. Each is a GPUParticles3D of
# small lit droplets that fall back under gravity and fade as they land.
# wake.gd also puts a small ring on the ripple patch where they come down.
#
# Presentation only, like the waves; bounded (MAX_BURSTS, MAX_SPRAYS) so a
# crowd in the water cannot fill the screen with emitters.
extends Node3D

const MAX_BURSTS := 16
const MAX_SPRAYS := 6
# Seconds a spray keeps going after its body last asked for it.
const SPRAY_LINGER := 0.25
# Droplets: nodes across, and the colour of a drop of water catching light.
const DROP_SIZE := 0.07
const DROP_COLOUR := Color(0.86, 0.93, 1.0, 0.8)

# What each kind of burst throws: droplets at full strength (they scale
# down with it, to a floor), how fast up and outward, nodes a second, and
# how long they fly.
const KINDS := {
	"entry": {"amount": 48, "floor": 10, "up": Vector2(1.8, 3.8), "out": Vector2(0.8, 2.2),
		"lifetime": 0.9},
	"drip": {"amount": 20, "floor": 6, "up": Vector2(0.0, 0.4), "out": Vector2(0.0, 0.3),
		"lifetime": 0.6},
	"strike": {"amount": 22, "floor": 8, "up": Vector2(1.2, 3.0), "out": Vector2(0.4, 1.4),
		"lifetime": 0.7},
}

var _bursts := {}            # GPUParticles3D -> clock time its last drop is down
var _sprays := {}            # key -> {"node": GPUParticles3D, "seen": float}
var _clock := 0.0
var _draw_pass: QuadMesh


# One burst of `kind` at `pos` (the water's surface where a body went in, or
# where a blow landed; a body's feet for drips), `strength` 0 to 1. Returns
# the number of droplets thrown, 0 if the burst budget is spent.
func burst(kind: String, pos: Vector3, strength: float) -> int:
	if not KINDS.has(kind) or _bursts.size() >= MAX_BURSTS:
		return 0
	var k: Dictionary = KINDS[kind]
	var s := clampf(strength, 0.0, 1.0)
	var amount := maxi(int(k["floor"]), int(round(float(k["amount"]) * s)))
	var mat := _droplet_process()
	var up: Vector2 = k["up"]
	var out: Vector2 = k["out"]
	mat.direction = Vector3.DOWN if kind == "drip" else Vector3.UP
	mat.spread = 12.0 if kind == "drip" else 30.0
	mat.initial_velocity_min = up.x * lerpf(0.6, 1.0, s)
	mat.initial_velocity_max = up.y * lerpf(0.6, 1.0, s)
	mat.radial_velocity_min = out.x
	mat.radial_velocity_max = out.y
	match kind:
		"entry":
			# A crown: droplets from a ring round where the body went in.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			mat.emission_ring_axis = Vector3.UP
			mat.emission_ring_radius = 0.45
			mat.emission_ring_inner_radius = 0.25
			mat.emission_ring_height = 0.05
		"drip":
			# Off the whole body, falling back.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			mat.emission_box_extents = Vector3(0.25, 0.7, 0.25)
			pos += Vector3.UP * 0.9
		_:
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
			mat.emission_sphere_radius = 0.12
	var p := _emitter(mat, amount, float(k["lifetime"]))
	p.one_shot = true
	p.explosiveness = 0.9
	p.position = pos
	add_child(p)
	p.restart()
	p.emitting = true
	# One shot systems do not clean themselves up; tick() frees it once its
	# slowest drop (lifetime plus the randomness) is down.
	_bursts[p] = _clock + float(k["lifetime"]) * 1.6 + 0.2
	return amount


# Spray off the bow of body `key` moving along `dir` (horizontal) at `speed`
# nodes a second, from `pos` (the water's surface just ahead of it). Call
# every frame it should keep going; it stops SPRAY_LINGER after the last.
# Returns false if the spray budget is spent.
func spray(key, pos: Vector3, dir: Vector3, speed: float) -> bool:
	var s: Dictionary = _sprays.get(key, {})
	if s.is_empty():
		if _sprays.size() >= MAX_SPRAYS:
			return false
		var mat := _droplet_process()
		mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		mat.emission_box_extents = Vector3(0.25, 0.02, 0.25)
		# Up and forward, fanned wide: the two sheets either side of a bow.
		mat.spread = 65.0
		mat.radial_velocity_min = 0.3
		mat.radial_velocity_max = 1.2
		var p := _emitter(mat, 40, 0.6)
		p.one_shot = false
		p.explosiveness = 0.0
		add_child(p)
		s = {"node": p}
		_sprays[key] = s
	var node: GPUParticles3D = s["node"]
	var mat: ParticleProcessMaterial = node.process_material
	var fwd := Vector3(dir.x, 0.0, dir.z).normalized()
	mat.direction = (Vector3.UP * 1.2 + fwd * 0.6).normalized()
	var k := clampf((speed - 2.0) / 3.0, 0.15, 1.0)
	mat.initial_velocity_min = 0.8 + 1.2 * k
	mat.initial_velocity_max = 1.6 + 2.0 * k
	node.amount_ratio = k
	node.position = pos
	node.emitting = true
	s["seen"] = _clock
	return true


func _process(delta: float) -> void:
	tick(delta)


# Advances the clock, frees bursts whose drops are all down, and stops
# sprays no body asked for lately; a stopped spray is freed once its last
# droplets have landed.
func tick(delta: float) -> void:
	_clock += delta
	for p in _bursts.keys():
		if _clock >= float(_bursts[p]):
			_bursts.erase(p)
			if is_instance_valid(p):
				p.queue_free()
	for key in _sprays.keys():
		var s: Dictionary = _sprays[key]
		var node: GPUParticles3D = s["node"]
		if _clock - float(s["seen"]) > SPRAY_LINGER and node.emitting:
			node.emitting = false
			s["stopped"] = _clock
		if not node.emitting and _clock - float(s.get("stopped", _clock)) > 1.0:
			node.queue_free()
			_sprays.erase(key)


func counts() -> Dictionary:
	return {"bursts": _bursts.size(), "sprays": _sprays.size()}


func _droplet_process() -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.gravity = Vector3(0.0, -9.81, 0.0)
	mat.scale_min = 0.6
	mat.scale_max = 1.4
	# Full while they fly, fading over the last third as they come down.
	var fade := Gradient.new()
	fade.set_offset(0, 0.0)
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_offset(1, 1.0)
	fade.set_color(1, Color(1, 1, 1, 0))
	fade.add_point(0.65, Color(1, 1, 1, 1))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	mat.color_ramp = ramp
	return mat


func _emitter(mat: ParticleProcessMaterial, amount: int, lifetime: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.process_material = mat
	p.draw_pass_1 = _drop_mesh()
	p.amount = amount
	p.lifetime = lifetime
	p.randomness = 0.4
	p.local_coords = false
	# A one shot system fires on emitting going false to true; it starts
	# true, so it is set false here and true once in the tree.
	p.emitting = false
	# Droplets fly a couple of nodes; the default box would cull a burst
	# as soon as its emitter left the screen.
	p.visibility_aabb = AABB(Vector3(-3, -2, -3), Vector3(6, 5, 6))
	return p


# One droplet: a small round billboard, lit so it reads by day and catches a
# lamp at night, with a little shine.
func _drop_mesh() -> QuadMesh:
	if _draw_pass != null:
		return _draw_pass
	var dot := GradientTexture2D.new()
	dot.width = 16
	dot.height = 16
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(1.0, 0.5)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.55, Color(1, 1, 1, 0.9))
	dot.gradient = g
	var smat := StandardMaterial3D.new()
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.vertex_color_use_as_albedo = true
	smat.albedo_color = DROP_COLOUR
	smat.albedo_texture = dot
	smat.roughness = 0.08
	smat.metallic_specular = 0.9
	_draw_pass = QuadMesh.new()
	_draw_pass.size = Vector2(DROP_SIZE, DROP_SIZE)
	_draw_pass.material = smat
	return _draw_pass
