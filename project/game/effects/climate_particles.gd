# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## What the climate field throws into the air round the player: dust kicked
## up by feet on dry ground, a spatter on soaked ground, breath in the cold,
## drips off a saturated roof, motes hanging in dry air that show where
## light falls through them, and grit blown low over dry ground in a wind. Made by game/effects/particles.gd beside wake.gd,
## whose sources it walks (footfalls.gd finds the steps); reads the field
## through GoannaClient.climate_at and the map through node_name_at, on the
## main thread. Checked by tests/footfalls.gd. docs/systems/climate.md, "In
## the air", has the design.
#
# The field's surface and fog shaders draw what lies on the ground and fills
# the air at large; these are the small things a body does to it, and the
# few things too fine for a froxel. Each is bounded (MAX_PUFFS, MAX_DRIPS),
# and all of it is presentation: nothing is asked of the server.
extends Node3D

const PlayerContext := preload("res://game/player_context.gd")
const Wake := preload("res://game/effects/wake.gd")
const Footfalls := preload("res://game/effects/footfalls.gd")
const DROPLET_SHADER := preload("res://shaders/droplet.gdshader")

# Seconds between samples of where the bodies are; the steps between two
# samples are laid at the later one, which a stride of 0.8 hides.
const SAMPLE_INTERVAL := 0.1
const MAX_PUFFS := 24
const MAX_DRIPS := 16
# Field wetness, 0 to 1, below which the ground gives up dust (all of it at
# DRY_FULL), and above which a step spatters (all of it at SOAKED_FULL). The
# same bands as the dust in shaders/atmosphere_volume.gdshader and the pools
# in shaders/climate.gdshaderinc.
const DRY_START := 0.5
const DRY_FULL := 0.25
const SOAKED_START := 0.88
const SOAKED_FULL := 0.97
# Breath shows below BREATH_START C, fully at BREATH_FULL, one breath every
# BREATH_PERIOD seconds.
const BREATH_START := 4.0
const BREATH_FULL := -8.0
const BREATH_PERIOD := 3.4
# A roof drips where the field there is wetter than DRIP_WET; DRIP_TRIES
# places round the eye are tried every sample, within DRIP_REACH nodes
# across and DRIP_ROOF up.
const DRIP_WET := 0.9
const DRIP_TRIES := 3
const DRIP_REACH := 9.0
const DRIP_ROOF := 8
# Motes: a box this big round the eye, and this many at most in it, scaled
# down by how dry the air at the eye is.
const MOTE_BOX := Vector3(7.0, 3.5, 7.0)
const MOTE_COUNT := 1600
const MOTE_ROOF := 24
# Cave air settles damper than open ground (a mesa's dry cave reads about
# 0.42), so motes start at a wetter field than dust does; the same band as
# the cave haze in shaders/atmosphere_volume.gdshader.
const MOTE_DRY_START := 0.58
const MOTE_DRY_FULL := 0.32
# Blown grit: a box this big round the feet, its floor this far under them,
# this many at most, from a wind of GRIT_WIND (main.gd's grass wind, 0.25
# to 1) and up, all of it at 1.
const GRIT_BOX := Vector3(12.0, 0.9, 12.0)
const GRIT_COUNT := 900
const GRIT_WIND := 0.45
# Dust takes the colour of the ground it rises from (client.ground_dust, the
# face under the surface, so dry grass gives soil): a puff the column under
# the foot, the grit and the fog's dust (climate_dust_albedo in
# atmosphere_volume.gdshader) the ground round the player, eased over a few
# seconds. DUST_COLOUR until the ground answers.
const DUST_COLOUR := Color(0.78, 0.68, 0.52)
const DUST_EASE := 2.5
const BREATH_COLOUR := Color(0.92, 0.94, 0.97)

var client: Node
var wake: Node                # wake.gd: its sources, and its splashes
var footfalls := Footfalls.new()

var _since_sample := 0.0
var _since_breath := 0.0
var _clock := 0.0
var _puffs := {}              # GPUParticles3D -> clock to free it at
var _drips := {}
var _motes: GPUParticles3D
var _grit: GPUParticles3D
var _grit_ratio := 0.0
var _puff_pass: QuadMesh
var _drip_pass: QuadMesh
var _rng := RandomNumberGenerator.new()
var _counts := {"steps": 0, "dust": 0, "spatter": 0, "breaths": 0, "drips": 0}
var _mote_ratio := 0.0
var dust_colour := DUST_COLOUR
var _dust_target := DUST_COLOUR


func _ready() -> void:
	_rng.seed = 2310
	_motes = _mote_emitter()
	add_child(_motes)
	_grit = _grit_emitter()
	add_child(_grit)


func _process(delta: float) -> void:
	_clock += delta
	for pool in [_puffs, _drips]:
		for p in pool.keys():
			if _clock >= float(pool[p]):
				pool.erase(p)
				if is_instance_valid(p):
					p.queue_free()
	var m: Node = PlayerContext.find(self, "goanna_main")
	if m == null or m.get("cam") == null or client == null or not client.has_method("climate_at") \
			or (client.has_method("climate_enabled") and not client.climate_enabled()):
		_set_motes(0.0)
		if _grit != null:
			_grit.emitting = false
		return
	var eye: Vector3 = (m.cam as Node3D).global_position
	_motes.global_position = eye
	_grit.global_position = Wake.local_feet(m, eye) + Vector3.UP * (GRIT_BOX.y - 0.1)
	_since_sample += delta
	_since_breath += delta
	if _since_sample < SAMPLE_INTERVAL:
		return
	var dt := _since_sample
	_since_sample = 0.0
	var sources: Array = wake.gather_sources(m, eye) if wake != null else []
	if bool(m.get("fly_mode")) and not sources.is_empty() and str(sources[0]["key"]) == "local":
		sources = sources.slice(1)
	for f in footfalls.step(sources, dt, _clock, _footing):
		_footfall(f, _wind(m))
	_ease_dust(m, Wake.local_feet(m, eye), dt)
	var here := field(eye)
	_set_motes(motes_for(here) if _roofed(eye) else 0.0)
	_set_grit(m, grit_for(field(Wake.local_feet(m, eye) + Vector3.UP * 0.5), _wind(m).length()))
	if _since_breath >= BREATH_PERIOD:
		_since_breath = 0.0
		var b := breath_for(here)
		if b > 0.02:
			var fwd := -(m.cam as Node3D).global_transform.basis.z
			_breath(eye + fwd * 0.45 - Vector3.UP * 0.2, fwd, b, _wind(m))
	for _i in DRIP_TRIES:
		_try_drip(eye)


# Fine dust is paler than the ground it lifts from: the solid's colour a
# little greyed and lifted toward white.
static func dust_tint(ground: Color) -> Color:
	var lum := ground.get_luminance()
	var c := ground.lerp(Color(lum, lum, lum), 0.15).lerp(Color.WHITE, 0.15)
	return Color(c.r, c.g, c.b, 1.0)


# The ground's dust colour under `feet`, or round them when `wide`, or
# Color(0, 0, 0, 0) when the ground there does not answer. The column
# walk starts 8 nodes over the point it is given, so the point is put 8
# under the feet: under a roof it would find the roof first.
func ground_dust(feet: Vector3, wide: bool) -> Color:
	if client == null or not client.has_method("ground_dust"):
		return Color(0, 0, 0, 0)
	var g: Color = client.ground_dust(feet - Vector3(0.0, 8.0, 0.0), wide)
	if g.a < 0.2:
		return Color(0, 0, 0, 0)
	return dust_tint(g)


func _ease_dust(m: Node, feet: Vector3, dt: float) -> void:
	var g := ground_dust(feet, true)
	if g.a > 0.0:
		_dust_target = g
	dust_colour = dust_colour.lerp(_dust_target, 1.0 - exp(-dt / DUST_EASE))
	var gm := _grit.process_material as ParticleProcessMaterial
	gm.color = dust_colour
	((_grit.draw_pass_1 as QuadMesh).material as ShaderMaterial).set_shader_parameter(
			"colour", Color(dust_colour, 0.7))
	var am = m.get("atmosphere_mat")
	if am is ShaderMaterial:
		am.set_shader_parameter("climate_dust_albedo", dust_colour)


# The field at `p`, or {} while it is being rebuilt or where nothing is known.
func field(p: Vector3) -> Dictionary:
	var c: Dictionary = client.climate_at(p)
	if c.is_empty() or float(c.get("known", 0.0)) < 0.05:
		return {}
	return c


static func dust_for(c: Dictionary) -> float:
	if c.is_empty():
		return 0.0
	return smoothstep(DRY_START, DRY_FULL, float(c["wet"])) * float(c["known"])


static func spatter_for(c: Dictionary) -> float:
	if c.is_empty():
		return 0.0
	return smoothstep(SOAKED_START, SOAKED_FULL, float(c["wet"])) * float(c["known"])


static func breath_for(c: Dictionary) -> float:
	if c.is_empty():
		return 0.0
	return smoothstep(BREATH_START, BREATH_FULL, float(c["temp"])) \
			* lerpf(0.5, 1.0, float(c["hum"])) * float(c["known"])


# Motes hang in dry air out of the weather, under a roof (_roofed), where a
# beam of light through a door or a shaft shows them against the dark; they
# are drawn at this share of MOTE_COUNT. In the open every speck is in the
# sun, and a thousand of them read as snow.
static func motes_for(c: Dictionary) -> float:
	if c.is_empty():
		return 0.0
	return smoothstep(MOTE_DRY_START, MOTE_DRY_FULL, float(c["wet"])) * float(c["known"])


# Grit blows over dry ground in a wind, none in still air.
static func grit_for(c: Dictionary, wind: float) -> float:
	return dust_for(c) * smoothstep(GRIT_WIND, 1.0, wind)


# A roof over the eye within MOTE_ROOF nodes.
func _roofed(eye: Vector3) -> bool:
	for dy in range(1, MOTE_ROOF + 1):
		var name := String(client.node_name_at(eye + Vector3(0.0, dy, 0.0)))
		if name == "" or name == "ignore":
			return false
		if name != "air":
			return true
	return false


func _footing(p: Vector3) -> bool:
	var name := String(client.node_name_at(p - Vector3(0.0, 0.3, 0.0)))
	return name != "" and name != "air" and name != "ignore" and not Wake.is_water_name(name)


func _wind(m: Node) -> Vector2:
	var w = m.get("grass_wind")
	return w if w is Vector2 else Vector2.ZERO


func _footfall(f: Dictionary, wind: Vector2) -> void:
	_counts["steps"] += 1
	var pos: Vector3 = f["pos"]
	var c := field(pos + Vector3.UP * 0.5)
	var strength := clampf(float(f["speed"]) / 5.6, 0.35, 1.0)
	if bool(f["landing"]):
		strength = 1.0
	var dust := dust_for(c)
	if dust > 0.03:
		if _puff(pos, dust * strength, bool(f["landing"]), wind):
			_counts["dust"] += 1
	var wet := spatter_for(c)
	if wet > 0.05 and wake != null and wake.get("splashes") != null:
		if wake.splashes.burst("step", pos + Vector3.UP * 0.05, wet * strength) > 0:
			_counts["spatter"] += 1


# A puff of dust off the ground at `pos`, `s` 0 to 1, drifting downwind and
# settling. Lit, so it shows in torchlight and a sunbeam and not in the dark.
func _puff(pos: Vector3, s: float, landing: bool, wind: Vector2) -> bool:
	if _puffs.size() >= MAX_PUFFS:
		return false
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING if landing \
			else ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.2
	mat.emission_ring_axis = Vector3.UP
	mat.emission_ring_radius = 0.45
	mat.emission_ring_inner_radius = 0.2
	mat.emission_ring_height = 0.05
	mat.direction = Vector3.UP
	mat.spread = 75.0
	mat.initial_velocity_min = 0.3
	mat.initial_velocity_max = 1.1 if landing else 0.8
	mat.radial_velocity_min = 0.2
	mat.radial_velocity_max = 0.9 if landing else 0.5
	mat.damping_min = 1.2
	mat.damping_max = 2.0
	# Fine dust settles slowly and goes where the wind takes it.
	mat.gravity = Vector3(wind.x * 0.5, -0.25, wind.y * 0.5)
	mat.scale_min = 0.6
	mat.scale_max = 1.2
	mat.scale_curve = _grow(0.5, 2.6)
	mat.color_ramp = _fade(0.45, 0.08)
	var under := ground_dust(pos, false)
	mat.color = under if under.a > 0.0 else dust_colour
	var lifetime := 2.6 if landing else 2.0
	var p := _one_shot(mat, _puff_mesh(), maxi(6, int(round((40.0 if landing else 22.0) * s))), lifetime)
	p.position = pos + Vector3.UP * 0.1
	add_child(p)
	p.restart()
	p.emitting = true
	_puffs[p] = _clock + lifetime * 1.5 + 0.2
	return true


func _breath(at: Vector3, fwd: Vector3, s: float, wind: Vector2) -> void:
	if _puffs.size() >= MAX_PUFFS:
		return
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = 0.04
	mat.direction = fwd
	mat.spread = 18.0
	mat.initial_velocity_min = 0.35
	mat.initial_velocity_max = 0.7
	mat.damping_min = 0.6
	mat.damping_max = 1.0
	mat.gravity = Vector3(wind.x * 0.2, 0.06, wind.y * 0.2)
	mat.scale_curve = _grow(0.25, 1.8)
	mat.color_ramp = _fade(0.3 * s, 0.1)
	mat.color = BREATH_COLOUR
	var p := _one_shot(mat, _puff_mesh(), 10, 1.6)
	p.explosiveness = 0.5
	p.position = at
	add_child(p)
	p.restart()
	p.emitting = true
	_puffs[p] = _clock + 1.6 * 1.5 + 0.2
	_counts["breaths"] += 1


# One place near the eye: up to the roof over it, and a drop off that roof
# if the field there is saturated.
func _try_drip(eye: Vector3) -> void:
	if _drips.size() >= MAX_DRIPS:
		return
	var x := floorf(eye.x + _rng.randf_range(-DRIP_REACH, DRIP_REACH)) + _rng.randf_range(0.1, 0.9) - 0.5
	var z := floorf(eye.z + _rng.randf_range(-DRIP_REACH, DRIP_REACH)) + _rng.randf_range(0.1, 0.9) - 0.5
	var y0 := roundf(eye.y)
	var roof := NAN
	for dy in DRIP_ROOF:
		var name := String(client.node_name_at(Vector3(x, y0 + dy, z)))
		if name == "" or name == "ignore":
			return
		if name != "air":
			if Wake.is_water_name(name):
				return
			roof = y0 + dy - 0.5
			break
	if is_nan(roof) or roof - eye.y < 1.0:
		return
	var c := field(Vector3(x, roof - 0.5, z))
	if c.is_empty() or float(c["wet"]) < DRIP_WET:
		return
	if _rng.randf() > smoothstep(DRIP_WET, 1.0, float(c["wet"])) * float(c["known"]):
		return
	var mat := ParticleProcessMaterial.new()
	mat.gravity = Vector3(0.0, -9.81, 0.0)
	mat.particle_flag_align_y = true
	mat.direction = Vector3.DOWN
	mat.spread = 0.0
	mat.initial_velocity_min = 0.0
	mat.initial_velocity_max = 0.1
	mat.color_ramp = _fade(1.0, 0.05)
	var fall := sqrt(2.0 * (roof - eye.y + 1.6) / 9.81)
	var p := _one_shot(mat, _drip_mesh(), 1, fall)
	p.position = Vector3(x, roof - 0.02, z)
	add_child(p)
	p.restart()
	p.emitting = true
	_drips[p] = _clock + fall + 0.3
	_counts["drips"] += 1


func _set_motes(ratio: float) -> void:
	_mote_ratio = ratio
	if _motes == null:
		return
	_motes.amount_ratio = clampf(ratio, 0.0, 1.0)
	_motes.emitting = ratio > 0.02


func _set_grit(m: Node, ratio: float) -> void:
	_grit_ratio = ratio
	_grit.amount_ratio = clampf(ratio, 0.0, 1.0)
	_grit.emitting = ratio > 0.02
	if ratio > 0.02:
		var w := _wind(m)
		var mat := _grit.process_material as ParticleProcessMaterial
		mat.direction = Vector3(w.x, 0.08, w.y).normalized()
		mat.initial_velocity_min = 3.0 * w.length()
		mat.initial_velocity_max = 6.0 * w.length()


# Grit: small streaks along the wind, low over the ground, lit, the colour
# of the dust. It is emitted all through a box round the feet, so the
# player stands in it rather than watching it arrive from upwind.
func _grit_emitter() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = GRIT_BOX
	mat.direction = Vector3.RIGHT
	mat.spread = 8.0
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 6.0
	mat.gravity = Vector3(0.0, -0.4, 0.0)
	mat.particle_flag_align_y = true
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.8
	mat.turbulence_noise_scale = 3.0
	mat.turbulence_influence_min = 0.05
	mat.turbulence_influence_max = 0.15
	mat.color = DUST_COLOUR
	mat.color_ramp = _fade(0.8, 0.15)
	var p := GPUParticles3D.new()
	p.process_material = mat
	p.amount = GRIT_COUNT
	p.lifetime = 1.6
	p.randomness = 0.5
	p.local_coords = false
	p.emitting = false
	p.visibility_aabb = AABB(-GRIT_BOX - Vector3(8, 2, 8), (GRIT_BOX + Vector3(8, 2, 8)) * 2.0)
	var smat := ShaderMaterial.new()
	smat.shader = DROPLET_SHADER
	smat.set_shader_parameter("colour", Color(DUST_COLOUR, 0.7))
	smat.set_shader_parameter("size", Vector2(0.018, 0.16))
	smat.set_shader_parameter("roughness", 1.0)
	smat.set_shader_parameter("specular", 0.1)
	var q := QuadMesh.new()
	q.size = Vector2(1.0, 1.0)
	q.material = smat
	p.draw_pass_1 = q
	return p


# Motes: specks hanging in a box round the eye, drifting, added to what is
# behind them by the light that reaches them, so they are seen only in a
# beam or by a torch, as in a dusty room.
func _mote_emitter() -> GPUParticles3D:
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = MOTE_BOX
	mat.direction = Vector3.UP
	mat.spread = 180.0
	mat.initial_velocity_min = 0.0
	mat.initial_velocity_max = 0.06
	mat.gravity = Vector3(0.0, -0.004, 0.0)
	mat.turbulence_enabled = true
	mat.turbulence_noise_strength = 0.4
	mat.turbulence_noise_scale = 6.0
	mat.turbulence_influence_min = 0.02
	mat.turbulence_influence_max = 0.06
	mat.scale_min = 0.5
	mat.scale_max = 1.3
	mat.color_ramp = _fade(1.0, 0.2)
	var p := GPUParticles3D.new()
	p.process_material = mat
	p.amount = MOTE_COUNT
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.randomness = 0.5
	p.local_coords = false
	p.emitting = false
	p.visibility_aabb = AABB(-MOTE_BOX - Vector3.ONE, (MOTE_BOX + Vector3.ONE) * 2.0)
	var q := QuadMesh.new()
	q.size = Vector2(0.022, 0.022)
	var smat := StandardMaterial3D.new()
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	smat.vertex_color_use_as_albedo = true
	smat.albedo_color = Color(1.0, 0.9, 0.74, 1.0)
	# Not the sky's ambient light, which reaches into a cave and lit every
	# speck in it; only lamps and the sun, so they show in the beam alone.
	smat.disable_ambient_light = true
	# None within a node of the lens, where a speck is a blurred disc
	# across a tenth of the screen.
	smat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	smat.distance_fade_min_distance = 0.8
	smat.distance_fade_max_distance = 2.0
	smat.albedo_texture = _soft_disc()
	smat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	smat.cull_mode = BaseMaterial3D.CULL_DISABLED
	q.material = smat
	p.draw_pass_1 = q
	return p


func _one_shot(mat: ParticleProcessMaterial, mesh: Mesh, amount: int, lifetime: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.process_material = mat
	p.draw_pass_1 = mesh
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 0.85
	p.randomness = 0.4
	p.local_coords = false
	# A one shot system fires on emitting going false to true (splashes.gd).
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-4, -12, -4), Vector3(8, 16, 8))
	return p


# Soft round billboards, lit, faded at the ground so they do not cut a line
# where they meet it.
func _puff_mesh() -> QuadMesh:
	if _puff_pass != null:
		return _puff_pass
	var smat := StandardMaterial3D.new()
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.vertex_color_use_as_albedo = true
	smat.albedo_texture = _soft_disc()
	smat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	smat.proximity_fade_enabled = true
	smat.proximity_fade_distance = 0.3
	smat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_puff_pass = QuadMesh.new()
	_puff_pass.size = Vector2(0.45, 0.45)
	_puff_pass.material = smat
	return _puff_pass


# A falling drop: the splashes' streak (shaders/droplet.gdshader).
func _drip_mesh() -> QuadMesh:
	if _drip_pass != null:
		return _drip_pass
	var smat := ShaderMaterial.new()
	smat.shader = DROPLET_SHADER
	smat.set_shader_parameter("colour", Color(0.86, 0.93, 1.0, 0.8))
	smat.set_shader_parameter("size", Vector2(0.02, 0.12))
	_drip_pass = QuadMesh.new()
	_drip_pass.size = Vector2(1.0, 1.0)
	_drip_pass.material = smat
	return _drip_pass


static func _soft_disc() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 32
	t.height = 32
	return t


# Grows from `a` to `b` times its size over its life.
static func _grow(a: float, b: float) -> CurveTexture:
	var c := Curve.new()
	c.max_value = maxf(a, b)
	c.add_point(Vector2(0.0, a))
	c.add_point(Vector2(1.0, b))
	var t := CurveTexture.new()
	t.curve = c
	return t


# Fades in over the first `rise` of its life to `peak` opacity and out to
# nothing by the end.
static func _fade(peak: float, rise: float) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(rise, Color(1, 1, 1, peak))
	g.add_point(lerpf(rise, 1.0, 0.45), Color(1, 1, 1, peak * 0.7))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


# What the control channel reports (inspect, through particles.gd).
func debug_state() -> Dictionary:
	var s := _counts.duplicate()
	s["puffs"] = _puffs.size()
	s["live_drips"] = _drips.size()
	s["motes"] = _mote_ratio
	s["grit"] = _grit_ratio
	s["tracked"] = footfalls.tracked()
	s["off_ground"] = footfalls.off_ground
	s["standing"] = footfalls.standing
	var m: Node = PlayerContext.find(self, "goanna_main")
	if m != null and client != null and m.get("cam") != null:
		var feet := Wake.local_feet(m, (m.cam as Node3D).global_position)
		s["feet"] = feet
		s["under_feet"] = String(client.node_name_at(feet - Vector3(0.0, 0.3, 0.0)))
	return s
