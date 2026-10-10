# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Lightning, drawn from the server's strike. Luanti has no lightning in the
# protocol any more than it has rain: Mineclonia's mcl_lightning sends, per
# strike, one particle spawner (texture lightning_lightning_N.png, N 1 to 3,
# amount 1, time 0.2, vertical, glow LIGHT_MAX, size 1000, which is 100
# nodes, centred 50 nodes above the struck node so its bottom edge meets the
# ground), a white sky for about a tenth of a second, and a thunder sound.
# The vanilla client draws the spawner as one flat textured particle.
#
# With shader weather on, particles.gd hands a spawner it recognises as a
# bolt here instead of building an emitter, and this draws it: the bolt,
# additive and several times white so it blooms, flickering through a few
# return strokes; a strong short lived light at the strike point, so the
# ground and anything near it are lit; and a flash strength, read by
# main.gd through particles.gd's lightning_flash(), for the sky, clouds and
# fog. main.gd also follows the server's own white sky, so a strike seen by
# both paths is one flash.
#
# Presentation only. Nothing here happens without the server's spawner, and
# nothing is asked of the server. docs/systems/weather.md.
extends Node3D

const SHADER := preload("res://shaders/lightning.gdshader")

# Seconds the last stroke and the afterglow run past the spawner's own time.
const TAIL := 0.25
# The light at the strike point. Range in nodes: Mineclonia strikes up to 50
# nodes from a player, so at that range a strike lights the ground round it
# and a little of the ground round the player. No shadow: an omni light's
# shadow is six more passes over everything in range, for a light that
# lives a fifth of a second, so it reaches into a house near the strike.
const LIGHT_ENERGY := 16.0
const LIGHT_RANGE := 48.0
const LIGHT_COLOUR := Color(0.8, 0.86, 1.0)
# How many times white the bolt's core is drawn.
const BOLT_ENERGY := 6.0

# Each strike: {node, mesh, light, material, age, life, strokes}.
var _bolts: Array = []
var _flash := 0.0


# A spawner is a bolt when its texture says lightning, as the weather's is
# rain or snow by texture name, and it is a handful of particles: a strike,
# not a storm of sparks from some other mod's texture.
static func is_bolt(ev: Dictionary, tex_name: String) -> bool:
	return tex_name.to_lower().contains("lightning") and int(ev.get("amount", 0)) <= 4


# True for a sky colour set that is white through day, dawn and night: the
# lightning layer of mcl_weather's skycolor, and nothing a game uses as a
# real sky for long. main.gd holds such a set out of its sky easing and
# flashes instead.
static func is_flash_sky(sky: Dictionary) -> bool:
	for key in ["day_sky", "day_horizon", "dawn_sky", "night_sky", "night_horizon"]:
		var c = sky.get(key)
		if not (c is Color) or minf(minf(c.r, c.g), c.b) < 0.94:
			return false
	return true


# The strokes of a strike, from a seed: a first stroke at once and up to two
# return strokes along the same channel through the spawner's time, each
# weaker. Times as shares of the time, then strengths.
static func strokes(seed_value: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return PackedFloat32Array([0.0, rng.randf_range(0.3, 0.45), rng.randf_range(0.65, 0.85),
			1.0, rng.randf_range(0.55, 0.9), rng.randf_range(0.0, 0.8)])


# 0 to 1: how bright the strike is `age` seconds in, for a spawner time of
# `life`. Each stroke is a sharp rise and a fall over a few hundredths of a
# second; past `life` everything dies away over TAIL.
static func flicker(age: float, life: float, s: PackedFloat32Array) -> float:
	if age < 0.0:
		return 0.0
	var k := 0.0
	for i in 3:
		var t0 := s[i] * life
		if age >= t0:
			k = maxf(k, s[3 + i] * exp(-(age - t0) / 0.05))
	if age > life:
		k *= exp(-(age - life) / (TAIL * 0.3))
	return clampf(k, 0.0, 1.0)


# The flash for the sky, 0 to 1: the brightest strike now running, weighed
# by how far it is from the camera.
func flash_strength() -> float:
	return _flash


func bolt_count() -> int:
	return _bolts.size()


# Draws the strike a spawner describes. `tex` is the server's texture, or
# null, for the drawn bolt. Returns the strike's node.
func strike(ev: Dictionary, tex: Texture2D) -> Node3D:
	var pmin: Vector3 = ev.get("pos_min", Vector3.ZERO)
	var pmax: Vector3 = ev.get("pos_max", Vector3.ZERO)
	var centre := (pmin + pmax) * 0.5
	# Luanti's particle size is in tenths of a node.
	var size := maxf(maxf(float(ev.get("size_min", 0.0)), float(ev.get("size_max", 0.0))) * 0.1, 1.0)
	var life := maxf(maxf(float(ev.get("time", 0.0)), float(ev.get("exp_max", 0.0))), 0.1)
	var node := Node3D.new()
	node.position = centre
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("use_texture", tex != null)
	if tex != null:
		mat.set_shader_parameter("bolt_texture", tex)
	var seed_value := randi()
	mat.set_shader_parameter("seed", float(seed_value % 1000))
	mat.set_shader_parameter("energy", BOLT_ENERGY)
	mat.set_shader_parameter("flash", 0.0)
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mesh := MeshInstance3D.new()
	mesh.mesh = quad
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# It turns to face the camera in the shader, so its box has to hold it
	# at any turn.
	mesh.custom_aabb = AABB(Vector3(-size, -size, -size) * 0.5, Vector3(size, size, size))
	node.add_child(mesh)
	var light := OmniLight3D.new()
	# A few nodes above the struck node, so the ground round it is lit from
	# above rather than grazed.
	light.position = Vector3(0.0, -size * 0.5 + minf(6.0, size * 0.25), 0.0)
	light.omni_range = LIGHT_RANGE
	light.omni_attenuation = 1.0
	light.light_color = LIGHT_COLOUR
	light.light_energy = 0.0
	light.shadow_enabled = false
	node.add_child(light)
	add_child(node)
	_bolts.append({"node": node, "mesh": mesh, "light": light, "material": mat,
		"age": 0.0, "life": life, "strokes": strokes(seed_value)})
	_step(0.0)
	return node


func clear() -> void:
	for b in _bolts:
		if is_instance_valid(b["node"]):
			b["node"].queue_free()
	_bolts.clear()
	_flash = 0.0


func _process(delta: float) -> void:
	if not _bolts.is_empty() or _flash > 0.0:
		_step(delta)


func _step(delta: float) -> void:
	var eye := Vector3.ZERO
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		eye = cam.global_position
	var flash := 0.0
	var keep: Array = []
	for b in _bolts:
		b["age"] = float(b["age"]) + delta
		var node: Node3D = b["node"]
		if float(b["age"]) > float(b["life"]) + TAIL or not is_instance_valid(node):
			if is_instance_valid(node):
				node.queue_free()
			continue
		keep.append(b)
		var k := flicker(float(b["age"]), float(b["life"]), b["strokes"])
		(b["material"] as ShaderMaterial).set_shader_parameter("flash", k)
		(b["light"] as OmniLight3D).light_energy = LIGHT_ENERGY * k
		# A strike overhead whitens the whole sky; one far off is a glow.
		var d := Vector2(node.global_position.x - eye.x, node.global_position.z - eye.z).length() \
				if node.is_inside_tree() else 0.0
		flash = maxf(flash, k * clampf(1.2 - d / 250.0, 0.3, 1.0))
	_bolts = keep
	_flash = flash
