# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Splashes: the droplets a body throws up out of the water, beside the waves
# the ripple patch draws. docs/weather.md, "Splashes", has the whole picture.
#
# wake.gd says when (falling or jumping in, climbing or jumping out, moving
# fast through the surface, striking at the water, a hand or a foot going
# through the surface in a stroke) and this draws it: a
# crown of droplets thrown up and out from where a body went in, drips off
# a body coming out, spray fanning off the bow of one running or swimming,
# and a burst where a blow landed on the water. Each is a GPUParticles3D of
# small lit droplets that fall back under gravity and fade as they land.
# Going in hard, or a blow, also throws up a crown (crown()): a sheet of
# water standing up in a ring, its lip breaking into fingers, taller on
# the side it was pushed (shaders/splash_crown.gdshader).
# wake.gd also puts a small ring on the ripple patch where they come down.
#
# Presentation only, like the waves; bounded (MAX_BURSTS, MAX_SPRAYS) so a
# crowd in the water cannot fill the screen with emitters.
extends Node3D

const MAX_BURSTS := 16
const MAX_CROWNS := 8
const CROWN_SHADER := preload("res://shaders/splash_crown.gdshader")
# A crown's ring: quads round it and up it.
const CROWN_AROUND := 144
const CROWN_UP := 8
# How far through its life a crown's fingers shed their drops.
const CROWN_SHED := 0.35
const MAX_SPRAYS := 6
# Seconds a spray keeps going after its body last asked for it.
const SPRAY_LINGER := 0.25
# Droplets: a streak along the way each flies (shaders/droplet.gdshader),
# nodes across and along, and the colour of water catching light. Round
# billboards 0.07 across, the first version, read as white bubbles coming
# out of the body, from a chest and hands a hand's breadth from the eye.
const DROP_SIZE := Vector2(0.022, 0.09)
const DROP_COLOUR := Color(0.86, 0.93, 1.0, 0.75)
const DROPLET_SHADER := preload("res://shaders/droplet.gdshader")

# What each kind of burst throws: droplets at full strength (they scale
# down with it, to a floor), how fast up and outward, nodes a second, and
# how long they fly.
const KINDS := {
	"entry": {"amount": 96, "floor": 20, "up": Vector2(1.8, 3.8), "out": Vector2(0.8, 2.2),
		"lifetime": 0.9},
	"drip": {"amount": 28, "floor": 8, "up": Vector2(0.0, 0.4), "out": Vector2(0.0, 0.3),
		"lifetime": 0.6},
	"strike": {"amount": 36, "floor": 12, "up": Vector2(1.2, 3.0), "out": Vector2(0.4, 1.4),
		"lifetime": 0.7},
	# Off the lip of a crown as its fingers break up (crown()).
	"rim": {"amount": 36, "floor": 10, "up": Vector2(0.5, 1.6), "out": Vector2(0.6, 1.5),
		"lifetime": 0.6},
	# A hand going into the water in a stroke, or a foot breaking the
	# surface in a kick: a small crown.
	"stroke": {"amount": 24, "floor": 8, "up": Vector2(1.0, 2.4), "out": Vector2(0.3, 1.0),
		"lifetime": 0.6},
}

var _bursts := {}            # GPUParticles3D -> clock time its last drop is down
var _sprays := {}            # key -> {"node": GPUParticles3D, "seen": float}
var _crowns := {}            # MeshInstance3D -> [born, lifetime, size, strength, shed]
var _clock := 0.0
var _draw_pass: QuadMesh
var _crown_mesh: ArrayMesh
var _crown_material: ShaderMaterial


# A crown at `pos` (the water's surface), `strength` 0 to 1, pushed along
# `push` (world xz; its length, up to 1, is how hard): its foot spreads to
# `size.x` nodes round and it stands up to `size.y`. Returns false if the
# crown budget is spent.
func crown(pos: Vector3, strength: float, push: Vector2, size: Vector2) -> bool:
	if _crowns.size() >= MAX_CROWNS:
		return false
	var s := clampf(strength, 0.0, 1.0)
	var m := MeshInstance3D.new()
	m.mesh = _crown()
	m.material_override = _crown_mat()
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.position = pos
	add_child(m)
	var dir := push.normalized() if push.length() > 1e-3 else Vector2.ZERO
	var sized := size * lerpf(0.6, 1.0, s)
	m.set_instance_shader_parameter("crown_size", sized)
	m.set_instance_shader_parameter("crown_push",
			Vector4(dir.x, dir.y, clampf(push.length(), 0.0, 1.0), randf() * 10.0))
	m.set_instance_shader_parameter("crown_age", 0.0)
	# Bigger crowns stand longer: a hand's is up and gone in under half a
	# second, a body's in about three quarters.
	_crowns[m] = [_clock, lerpf(0.4, 0.75, s) * sqrt(maxf(size.y, 0.1) / 0.8), sized, s, false]
	return true


# One burst of `kind` at `pos` (the water's surface where a body went in, or
# where a blow landed; a body's feet for drips), `strength` 0 to 1. Returns
# the number of droplets thrown, 0 if the burst budget is spent.
func burst(kind: String, pos: Vector3, strength: float, ring := 0.0) -> int:
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
			# Off the crown's lip as it rises (crown()).
			mat.emission_ring_radius = 0.6
			mat.emission_ring_inner_radius = 0.4
			mat.emission_ring_height = 0.05
		"rim":
			# Round the lip, `ring` nodes out.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			mat.emission_ring_axis = Vector3.UP
			mat.emission_ring_radius = ring
			mat.emission_ring_inner_radius = ring * 0.85
			mat.emission_ring_height = 0.05
		"drip":
			# Off the sides of the body, below the eye, falling back. A box
			# through the whole body threw them out of the chest, which in
			# first person is in front of the lens.
			mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
			mat.emission_ring_axis = Vector3.UP
			mat.emission_ring_radius = 0.36
			mat.emission_ring_inner_radius = 0.3
			mat.emission_ring_height = 0.6
			pos += Vector3.UP * 0.6
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
	for m in _crowns.keys():
		var c: Array = _crowns[m]
		var age := (_clock - float(c[0])) / float(c[1])
		if age >= 1.0 or not is_instance_valid(m):
			_crowns.erase(m)
			if is_instance_valid(m):
				m.queue_free()
		else:
			(m as MeshInstance3D).set_instance_shader_parameter("crown_age", age)
			# As the lip breaks into fingers, they shed their beads: drops
			# off the rim, where it stands then, round and a little out.
			if not bool(c[4]) and age >= CROWN_SHED:
				c[4] = true
				var sz: Vector2 = c[2]
				var top := sz.y * sin(PI * pow(CROWN_SHED, 0.55))
				burst("rim", (m as Node3D).position + Vector3.UP * top * 0.9,
						float(c[3]), sz.x * 0.9 + top * 0.5)
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
	return {"bursts": _bursts.size(), "sprays": _sprays.size(), "crowns": _crowns.size()}


# The ring every crown is drawn on: UV.x round it, UV.y from its foot to its
# lip. The shader places every vertex, so the box is the most any crown
# reaches.
func _crown() -> ArrayMesh:
	if _crown_mesh != null:
		return _crown_mesh
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in CROWN_UP + 1:
		for i in CROWN_AROUND + 1:
			var u := float(i) / CROWN_AROUND
			var v := float(j) / CROWN_UP
			verts.append(Vector3(cos(u * TAU), v, sin(u * TAU)))
			uvs.append(Vector2(u, v))
	for j in CROWN_UP:
		for i in CROWN_AROUND:
			var a := j * (CROWN_AROUND + 1) + i
			var b := a + CROWN_AROUND + 1
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	_crown_mesh = ArrayMesh.new()
	_crown_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_crown_mesh.custom_aabb = AABB(Vector3(-3, -0.5, -3), Vector3(6, 3.5, 6))
	return _crown_mesh


func _crown_mat() -> ShaderMaterial:
	if _crown_material == null:
		_crown_material = ShaderMaterial.new()
		_crown_material.shader = CROWN_SHADER
	return _crown_material


func _droplet_process() -> ParticleProcessMaterial:
	var mat := ParticleProcessMaterial.new()
	mat.gravity = Vector3(0.0, -9.81, 0.0)
	# The particle's y axis along its flight, which the streak lies on.
	mat.particle_flag_align_y = true
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


# One droplet: a streak along its flight, turned to face the eye
# (shaders/droplet.gdshader), lit, with a little shine.
func _drop_mesh() -> QuadMesh:
	if _draw_pass != null:
		return _draw_pass
	var smat := ShaderMaterial.new()
	smat.shader = DROPLET_SHADER
	smat.set_shader_parameter("colour", DROP_COLOUR)
	smat.set_shader_parameter("size", DROP_SIZE)
	_draw_pass = QuadMesh.new()
	_draw_pass.size = Vector2(1.0, 1.0)
	_draw_pass.material = smat
	return _draw_pass
