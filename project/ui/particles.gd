# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Particles. The server drives these: a spawner describes a box of positions
# with velocity, acceleration, size and lifetime ranges plus a texture, and
# runs for a time (or forever, until the server cancels it). Games use them
# for weather, smoke, sparks and so on; Mineclonia's rain and snow are
# spawners attached to the player.
#
# Each spawner becomes one GPUParticles3D with a box emission shape, which is
# what Godot is good at, rather than one node per particle.
extends Node3D

const MAX_SPAWNERS := 24

var client: Node
var follow: Node3D            # the player/camera, for spawners attached to us

var _spawners := {}           # server id -> GPUParticles3D
var _attached := {}           # server id -> offset, for spawners that follow us
var _weather := {}            # server id -> true, for rain and snow spawners
var _tex_cache := {}

func _ready() -> void:
	add_to_group("goanna_particles")  # main reads precipitation() through this group

# Luanti has no weather in the protocol; a game that rains does it with a
# particle spawner attached to the player (Mineclonia's mcl_weather sends
# weather_pack_rain_raindrop_N.png and weather_pack_snow_snowflake_N.png).
# So precipitation is "a rain or snow spawner is running": 1.0 or 0.0, with
# no strength in between. Shader packs read it as rainStrength.
func precipitation() -> float:
	return 1.0 if not _weather.is_empty() else 0.0

var _dbg := 0.0
var _test_done := false
func _process(_delta: float) -> void:
	if client == null:
		return
	if OS.get_environment("GOANNA_DEBUG_PARTICLES") != "":
		_dbg -= _delta
		if _dbg <= 0.0:
			_dbg = 1.0
			var m := get_tree().get_first_node_in_group("goanna_main")
			var here: Vector3 = _player_feet(m) if m != null else Vector3.ZERO
			var lines := []
			for id in _spawners:
				var n = _spawners[id]
				if is_instance_valid(n):
					lines.append("%d:%s emit=%s pos=%s tex=%s" % [id, str(n.is_inside_tree()), str(n.emitting),
						str(n.position.round()), str(n.draw_pass_1.material.albedo_texture != null)])
			print("particles: nodes=%d attached=%d player=%s | %s" % [_spawners.size(), _attached.size(),
				str(here.round()), ", ".join(lines.slice(0, 3))])
	# GOANNA_TEST_PARTICLES=1 injects a synthetic rain-like spawner, to test
	# the Godot side without needing a server storm.
	if not _test_done and OS.get_environment("GOANNA_TEST_PARTICLES") != "":
		var m0 := get_tree().get_first_node_in_group("goanna_main")
		if m0 != null and m0.get("cam") != null and m0.cam.position != Vector3.ZERO:
			_test_done = true
			_add_spawner({"id": 999999, "amount": 400, "time": 0.0,
				"pos_min": Vector3(-8, 12, -8), "pos_max": Vector3(8, 16, 8),
				"vel_min": Vector3(0, -8, 0), "vel_max": Vector3(0, -12, 0),
				"acc_min": Vector3.ZERO, "acc_max": Vector3.ZERO,
				"exp_min": 2.0, "exp_max": 3.0, "size_min": 1.0, "size_max": 2.0,
				"texture": "weather_pack_rain_raindrop_1.png", "vertical": true, "collision": false, "attached_id": 1})
			print("particles: injected synthetic spawner at player")
	for ev in client.take_particle_spawners():
		_add_spawner(ev)
	for id in client.take_deleted_spawners():
		_remove_spawner(int(id))
	for p in client.take_particles():
		_one_shot(p)
	# Weather and other attached spawners are sent in coordinates relative
	# to the player, so keep their emitters on the player.
	if not _attached.is_empty():
		var m := get_tree().get_first_node_in_group("goanna_main")
		if m != null:
			var here: Vector3 = _player_feet(m)
			for id in _attached:
				var node = _spawners.get(id)
				if node != null and is_instance_valid(node):
					node.position = here + _attached[id]

# Spawners sent relative to the player are relative to the player, whose
# origin is at the feet; the camera sits at eye height, so anchoring to it
# put ground effects (snow and dust steps) around the head.
func _player_feet(m: Node) -> Vector3:
	var mv = m.get("last_move")
	if mv is Dictionary and mv.has("pos"):
		return mv["pos"]
	if m.get("cam") != null:
		return m.cam.position - Vector3(0, 1.6, 0)
	return Vector3.ZERO

func _texture_for(name: String) -> Texture2D:
	if name == "":
		return null
	# a texture string can carry modifiers; the texture source resolves them
	if _tex_cache.has(name):
		return _tex_cache[name]
	var tex: Texture2D = client.texture(name) if client.has_method("texture") else null
	_tex_cache[name] = tex
	return tex

func _add_spawner(ev: Dictionary) -> void:
	var id := int(ev.get("id", 0))
	if OS.get_environment("GOANNA_DEBUG_PARTICLES") != "":
		print("spawner %d: amount=%s tex=%s box=%s..%s life=%s" % [id, str(ev.get("amount")),
			str(ev.get("texture")), str(ev.get("pos_min")), str(ev.get("pos_max")), str(ev.get("exp_max"))])
		print("   attached_id=%s size=%s..%s" % [str(ev.get("attached_id")), str(ev.get("size_min")), str(ev.get("size_max"))])
	_remove_spawner(id)
	if _spawners.size() >= MAX_SPAWNERS:
		return
	var amount := int(ev.get("amount", 0))
	if amount <= 0:
		return
	var pmin: Vector3 = ev.get("pos_min", Vector3.ZERO)
	var pmax: Vector3 = ev.get("pos_max", Vector3.ZERO)
	var vmin: Vector3 = ev.get("vel_min", Vector3.ZERO)
	var vmax: Vector3 = ev.get("vel_max", Vector3.ZERO)
	var amin: Vector3 = ev.get("acc_min", Vector3.ZERO)
	var amax: Vector3 = ev.get("acc_max", Vector3.ZERO)
	var life: float = maxf(float(ev.get("exp_max", 1.0)), 0.05)

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var half := (pmax - pmin) * 0.5
	mat.emission_box_extents = Vector3(maxf(absf(half.x), 0.01), maxf(absf(half.y), 0.01), maxf(absf(half.z), 0.01))
	# Godot gives a direction plus a spread; the server gives a velocity box,
	# so use the mid velocity as the direction and its span as randomness.
	var vmid := (vmin + vmax) * 0.5
	var vspan := (vmax - vmin) * 0.5
	mat.direction = vmid.normalized() if vmid.length() > 0.001 else Vector3.DOWN
	mat.initial_velocity_min = maxf(vmid.length() - vspan.length(), 0.0)
	mat.initial_velocity_max = vmid.length() + vspan.length()
	mat.spread = 0.0 if vspan.length() < 0.01 else 25.0
	mat.gravity = (amin + amax) * 0.5
	mat.scale_min = maxf(float(ev.get("size_min", 1.0)), 0.05)
	mat.scale_max = maxf(float(ev.get("size_max", 1.0)), 0.05)

	var p := GPUParticles3D.new()
	p.process_material = mat
	p.amount = clampi(amount, 1, 2000)
	p.lifetime = life
	p.one_shot = false
	# a spawner with time 0 runs until the server cancels it
	p.explosiveness = 0.0
	p.local_coords = false
	var quad := QuadMesh.new()
	# Luanti draws a particle as a quad of `size` in BS units (10 per
	# node), so a size of 10 is one node across.
	quad.size = Vector2(0.1, 0.1)
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	smat.albedo_texture = _texture_for(str(ev.get("texture", "")))
	smat.albedo_color = Color(1, 1, 1, 1) if smat.albedo_texture != null else Color(0.75, 0.85, 1.0, 0.85)
	smat.disable_receive_shadows = true
	quad.material = smat
	p.draw_pass_1 = quad
	p.position = (pmin + pmax) * 0.5
	add_child(p)
	_spawners[id] = p
	if int(ev.get("attached_id", 0)) != 0 or pmin.length() + pmax.length() < 200.0:
		# centred on the origin means player-relative, as weather is
		_attached[id] = (pmin + pmax) * 0.5
		var tex_name := str(ev.get("texture", "")).to_lower()
		if tex_name.contains("rain") or tex_name.contains("snow"):
			_weather[id] = true
	# a finite spawner cleans itself up
	var life_time := float(ev.get("time", 0.0))
	if life_time > 0.0:
		get_tree().create_timer(life_time + life).timeout.connect(func() -> void: _remove_spawner(id))

func _remove_spawner(id: int) -> void:
	var p = _spawners.get(id)
	if p != null and is_instance_valid(p):
		p.queue_free()
	_spawners.erase(id)
	_attached.erase(id)
	_weather.erase(id)

# A single particle: cheap enough to draw as a one-shot emitter.
func _one_shot(ev: Dictionary) -> void:
	if _spawners.size() >= MAX_SPAWNERS:
		return
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	var vel: Vector3 = ev.get("velocity", Vector3.ZERO)
	mat.direction = vel.normalized() if vel.length() > 0.001 else Vector3.UP
	mat.initial_velocity_min = vel.length()
	mat.initial_velocity_max = vel.length()
	mat.gravity = ev.get("acceleration", Vector3.ZERO)
	var size := maxf(float(ev.get("size", 1.0)), 0.05)
	mat.scale_min = size
	mat.scale_max = size
	var p := GPUParticles3D.new()
	p.process_material = mat
	p.amount = 1
	p.lifetime = maxf(float(ev.get("expirationtime", 1.0)), 0.05)
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.1, 0.1)
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	smat.albedo_texture = _texture_for(str(ev.get("texture", "")))
	quad.material = smat
	p.draw_pass_1 = quad
	p.position = ev.get("position", Vector3.ZERO)
	add_child(p)
	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.5).timeout.connect(func() -> void:
		if is_instance_valid(p):
			p.queue_free())
