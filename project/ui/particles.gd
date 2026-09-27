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
# what Godot is good at, rather than one node per particle. The exception is
# weather: with shader weather on (the default), a rain or snow spawner that
# follows the player is handed to weather.gd, which draws it by shader and
# builds no emitter at all. Lightning is recognised the same way, by its
# texture, and handed to lightning.gd. docs/weather.md.
extends Node3D

const PlayerContext := preload("res://player_context.gd")

const Weather := preload("res://ui/weather.gd")
const Lightning := preload("res://ui/lightning.gd")
const Wake := preload("res://ui/wake.gd")

const MAX_SPAWNERS := 24

var client: Node
var follow: Node3D            # the player/camera, for spawners attached to us
var shader_weather := true
var weather: Node3D           # weather.gd, drawing the spawners it was handed
var lightning: Node3D         # lightning.gd, drawing the strikes it was handed
var wake: Node                # wake.gd, the rings round bodies in water

var _spawners := {}           # server id -> GPUParticles3D
var _paused := {}             # attached spawners whose object is not known
const PLAYER_OBJECT := -1     # the synthetic test spawner's stand in for the player
var _attached := {}           # server id -> [object id, offset], for spawners that follow an object
var _weather := {}            # server id -> true, for rain and snow spawners
# server id -> the spawner as it arrived, for weather only, so switching
# shader weather on or off mid storm can rebuild it the other way.
var _weather_ev := {}
var _tex_cache := {}
# One shot break bursts, capped so a fast dig cannot pile up emitters.
const MAX_PIECES := 32
var _pieces := {}

func _ready() -> void:
	add_to_group("goanna_particles")  # main reads precipitation() through this group
	weather = Weather.new()
	weather.client = client
	add_child(weather)
	lightning = Lightning.new()
	add_child(lightning)
	# Not weather, and not gated by the shader weather setting: rings round
	# a swimmer are wanted in fair weather most of all. Here only because
	# this node already holds the client and lives as long as the game.
	wake = Wake.new()
	wake.client = client
	add_child(wake)

# How bright the lightning drawn now makes the sky, 0 to 1, for main.gd.
func lightning_flash() -> float:
	return lightning.flash_strength() if lightning != null else 0.0

# Shader weather on or off. The storm already running is rebuilt the other
# way at once, from the spawners as they arrived.
func set_shader_weather(on: bool) -> void:
	if on == shader_weather:
		return
	shader_weather = on
	var running := _weather_ev.duplicate()
	for id in running:
		_remove_spawner(int(id))
	for id in running:
		_add_spawner(running[id])

# Luanti has no weather in the protocol; a game that rains does it with a
# particle spawner attached to the player (Mineclonia's mcl_weather sends
# weather_pack_rain_raindrop_N.png and weather_pack_snow_snowflake_N.png).
# So precipitation is "a rain or snow spawner is running": 1.0 or 0.0, with
# no strength in between. Shader packs read it as rainStrength.
func precipitation() -> float:
	return 1.0 if not _weather.is_empty() else 0.0


# Which of the two is falling, each 1.0 or 0.0, from the weather spawners
# as they arrived (shader weather on or off). Rain wets the ground and snow
# settles on it; a player at a snowline, where Mineclonia swaps one spawner
# for the other a step at a time, gets some of both.
func rainfall() -> float:
	return 1.0 if _weather_kind("rain") else 0.0


func snowfall() -> float:
	return 1.0 if _weather_kind("snow") else 0.0


func _weather_kind(kind: String) -> bool:
	for ev in _weather_ev.values():
		var tex := str(ev.get("texture", ""))
		var pool: Array = ev.get("texpool", [])
		if tex == "" and pool.size() > 0:
			tex = str(pool[0])
		if tex.to_lower().contains(kind):
			return true
	return false


const TEST_SPAWNER_ID := 999999

# A synthetic precipitation spawner, for exercising the Godot side without a
# server storm: GOANNA_TEST_PARTICLES=1 at startup, or the control channel's
# weather command with fake set. It is the texture name that makes a spawner
# count as weather, here exactly as for a real one, so a fake storm reads
# through precipitation() and reaches a shader pack as rainStrength.
func inject_test_spawner(kind: String) -> void:
	var snow := kind == "snow"
	_add_spawner({"id": TEST_SPAWNER_ID, "amount": 400, "time": 0.0,
		"pos_min": Vector3(-8, 12, -8), "pos_max": Vector3(8, 16, 8),
		"vel_min": Vector3(0, -1.5 if snow else -8, 0),
		"vel_max": Vector3(0, -2.5 if snow else -12, 0),
		"acc_min": Vector3.ZERO, "acc_max": Vector3.ZERO,
		"exp_min": 6.0 if snow else 2.0, "exp_max": 8.0 if snow else 3.0,
		"size_min": 1.0, "size_max": 2.0,
		"texture": "weather_pack_snow_snowflake_1.png" if snow else "weather_pack_rain_raindrop_1.png",
		"vertical": not snow, "collision": false, "attached_id": PLAYER_OBJECT})
	print("particles: injected synthetic %s spawner at player" % kind)

func clear_test_spawner() -> void:
	_remove_spawner(TEST_SPAWNER_ID)

var _dbg := 0.0
var _test_done := false
func _process(_delta: float) -> void:
	if client == null:
		return
	if OS.get_environment("GOANNA_DEBUG_PARTICLES") != "":
		_dbg -= _delta
		if _dbg <= 0.0:
			_dbg = 1.0
			var m := PlayerContext.find(self, "goanna_main")
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
		var m0 := PlayerContext.find(self, "goanna_main")
		if m0 != null and m0.get("cam") != null and m0.cam.position != Vector3.ZERO:
			_test_done = true
			inject_test_spawner("rain")
	for ev in client.take_particle_spawners():
		_add_spawner(ev)
	for id in client.take_deleted_spawners():
		_remove_spawner(int(id))
	for p in client.take_particles():
		_one_shot(p)
	if client.has_method("take_dug_nodes"):
		for ev in client.take_dug_nodes():
			_node_pieces(ev)
	# An attached spawner's positions are relative to the object it is
	# attached to, and turn with it, as in the vanilla client. Weather is
	# attached to the player; a glow squid's glints to the squid. Following
	# the player whatever the object was put every squid's glints on the
	# player (reported 2026-10-01). While the object is not known, the
	# spawner pauses, as upstream's skips its step.
	if not _attached.is_empty():
		var m := PlayerContext.find(self, "goanna_main")
		for id in _attached:
			var node = _spawners.get(id)
			if node == null or not is_instance_valid(node):
				continue
			var object: int = _attached[id][0]
			var offset: Vector3 = _attached[id][1]
			var anchor: Dictionary = {} if object == PLAYER_OBJECT else client.entity_anchor(object)
			if object == PLAYER_OBJECT or bool(anchor.get("local", false)):
				# The predicted feet, which the camera follows, not the body.
				if m != null:
					node.transform = Transform3D(Basis(), _player_feet(m) + offset)
					_resume(id, node)
			elif anchor.has("transform"):
				node.transform = (anchor["transform"] as Transform3D) * Transform3D(Basis(), offset)
				_resume(id, node)
			elif not _paused.has(id):
				_paused[id] = true
				node.emitting = false

func _resume(id: int, node: GPUParticles3D) -> void:
	if _paused.erase(id):
		node.emitting = true

# A spawner box round the player, from above: centred within 12 nodes of
# the feet horizontally, at least 6 nodes across, and its middle above the
# head. A burst of weather, not an effect at the player's hand or a
# fountain beside them.
static func _centred_on_player(ev: Dictionary, feet: Vector3) -> bool:
	var pmin: Vector3 = ev.get("pos_min", Vector3.ZERO)
	var pmax: Vector3 = ev.get("pos_max", Vector3.ZERO)
	var c := (pmin + pmax) * 0.5
	var span := Vector2(absf(pmax.x - pmin.x), absf(pmax.z - pmin.z))
	return Vector2(c.x - feet.x, c.z - feet.z).length() <= 12.0 \
			and minf(span.x, span.y) >= 6.0 and c.y >= feet.y + 2.0


# Falls like rain, whatever its texture is called: short lived, facing the
# viewer on a vertical axis, removed where it lands, and falling at least
# 6 nodes a second, well more steeply than it drifts. A game's own name for
# its drops (kythen_water.png) says nothing a rule can read.
static func rain_burst(ev: Dictionary) -> bool:
	if not bool(ev.get("vertical", false)) or not bool(ev.get("collision_removal", false)):
		return false
	var time := float(ev.get("time", 0.0))
	if time <= 0.0 or time > 3.0:
		return false
	var vmin: Vector3 = ev.get("vel_min", Vector3.ZERO)
	var vmax: Vector3 = ev.get("vel_max", Vector3.ZERO)
	var v := (vmin + vmax) * 0.5
	# Climate API adds the wind to its drops, so rain may lean a good way.
	return -v.y >= 6.0 and Vector2(v.x, v.z).length() <= -v.y * 0.6


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
	var amount := int(ev.get("amount", 0))
	if amount <= 0:
		return
	var pmin: Vector3 = ev.get("pos_min", Vector3.ZERO)
	var pmax: Vector3 = ev.get("pos_max", Vector3.ZERO)
	var tex_path := str(ev.get("texture", ""))
	var pool: Array = ev.get("texpool", [])
	if tex_path == "" and pool.size() > 0:
		tex_path = str(pool[0])
	var tex_name := tex_path.to_lower()
	# A strike, with shader weather on: lightning.gd draws the bolt, its
	# light and its flash, from this one spawner, and it needs no emitter.
	# It runs for its own time and removes itself; the server's delete for
	# it, when it comes, finds nothing to remove.
	var is_bolt := Lightning.is_bolt(ev, tex_name)
	if is_bolt and shader_weather and lightning != null:
		lightning.strike(ev, _texture_for(tex_path))
		return
	var is_weather := not is_bolt and (tex_name.contains("rain") or tex_name.contains("snow")
			or tex_name.contains("flake"))
	# A bolt is fixed in the world, never the player's own effect, even one
	# struck near the world's origin.
	# Attached only when the server says so, as in the vanilla client. This
	# once also guessed that any spawner within about 100 nodes of the world's
	# origin was the player's own and carried it about at the player's feet,
	# a leftover from the first particle work that a setting hid by default.
	# Removing that setting on 2026-10-01 put such spawners on every player
	# near spawn, so the guess went too.
	var is_attached := not is_bolt and int(ev.get("attached_id", 0)) != 0
	# Weather a game spawns in short bursts round the player rather than on
	# one attached spawner (Kythen: a 0.55 s burst every half second while
	# the player is outdoors, at world coordinates, textured as water). It
	# follows the player as surely as an attached spawner does, so it is
	# weather if its name says so, or if it falls like rain whatever it is
	# called (rain_burst).
	if not is_bolt and not is_attached:
		var m_here := PlayerContext.find(self, "goanna_main")
		if m_here != null and _centred_on_player(ev, _player_feet(m_here)):
			if (is_weather or rain_burst(ev)) and not tex_name.contains("hail"):
				is_attached = true
				is_weather = true
	if is_weather and is_attached:
		_weather_ev[id] = ev
		# Only weather that follows the player: the shader draws round the
		# camera, so a rain spawner fixed somewhere in the world (a fountain
		# that happens to use a rain texture) keeps its particles.
		if shader_weather and weather != null:
			weather.add_spawner(id, ev, tex_name)
			_weather[id] = true
			var timed := float(ev.get("time", 0.0))
			if timed > 0.0:
				# Counted only while it spawns. Bursts that follow one another
				# are steady weather because weather.gd eases over seconds;
				# held past their time as well, Climate API's, which start a
				# new half second burst every server step, piled up 85 deep
				# and drew five times the rain they make.
				get_tree().create_timer(timed).timeout.connect(func() -> void:
					if weather.has_spawner(id): _remove_spawner(id))
			return
	# The cap is on emitters; shader weather above builds none.
	if _spawners.size() >= MAX_SPAWNERS:
		return
	var vmin: Vector3 = ev.get("vel_min", Vector3.ZERO)
	var vmax: Vector3 = ev.get("vel_max", Vector3.ZERO)
	var amin: Vector3 = ev.get("acc_min", Vector3.ZERO)
	var amax: Vector3 = ev.get("acc_max", Vector3.ZERO)
	var life: float = maxf(float(ev.get("exp_max", 1.0)), 0.05)

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	var half := (pmax - pmin) * 0.5
	if is_weather:
		# Server weather is player-local, but its small vanilla box assumes a
		# much shorter view. Broaden it enough to read as a weather front and
		# extend it down toward the ground so slow snow does not hover only over
		# the player's head. Keep one GPU emitter and the same total population.
		half.x = maxf(absf(half.x), 24.0)
		half.z = maxf(absf(half.z), 24.0)
		half.y = maxf(absf(half.y), 9.0)
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
	# Drag is a per axis vector; Godot damps along the velocity instead, so the
	# magnitude is used and a drag that differs per axis loses its direction.
	var drag: Vector3 = ev.get("drag", Vector3.ZERO)
	if drag.length() > 0.001:
		mat.damping_min = drag.length()
		mat.damping_max = drag.length()
	# Jitter is a random acceleration each step. Godot has no per step random
	# force, so it becomes a spread on the initial velocity, which looks similar
	# for short lived particles and diverges for long lived ones.
	var jmin: Vector3 = ev.get("jitter_min", Vector3.ZERO)
	var jmax: Vector3 = ev.get("jitter_max", Vector3.ZERO)
	if jmax.length() > 0.001 or jmin.length() > 0.001:
		mat.spread = maxf(mat.spread, 15.0)
		mat.initial_velocity_max += maxf(jmin.length(), jmax.length())
	# Godot's particle collision only meets GPUParticlesCollision nodes, and
	# the world has none, so it cannot stand in for Luanti's collision with
	# nodes. Worse, a spawner asking for collision_removal came out as
	# HIDE_ON_CONTACT, which removed every raindrop where it was spawned:
	# measured on a live client, Mineclonia's rain occupied only its spawn box,
	# 13 nodes above the ground, and never fell. GOANNA_PARTICLE_COLLISION=1
	# keeps the old mapping for when colliders exist.
	if bool(ev.get("collision", false)) and OS.get_environment("GOANNA_PARTICLE_COLLISION") != "":
		mat.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
		mat.collision_bounce = clampf(float(ev.get("bounce_max", 0.0)), 0.0, 1.0)
		if bool(ev.get("collision_removal", false)):
			mat.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT

	var p := GPUParticles3D.new()
	p.process_material = mat
	# Luanti's amount is a rate, not a population, and it means different
	# things either side of time == 0. ParticleSpawner sizes its pool as
	# amount * longest_life for an endless spawner, and amount / (time /
	# shortest_life) for a timed one; Godot's amount is the number alive at
	# once, so the conversion is not optional. Mineclonia's snow asks for 100
	# with a five second life, which is five hundred flakes in the air at once
	# and was being drawn as one hundred.
	var spawner_time := float(ev.get("time", 0.0))
	var alive := float(amount) * life
	if spawner_time > 0.0:
		alive = float(amount) * life / spawner_time
	# Weather must never consume an unbounded particle population. Density is
	# traded for coverage above; 1500 flakes/rain streaks are ample at this
	# scale, while ordinary short-lived effects retain their existing ceiling.
	p.amount = clampi(int(ceil(alive)), 1, 1500 if is_weather else 8000)
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
	# A vertical particle stays upright and only turns about its own axis,
	# which is what makes rain and snow read as falling rather than as discs
	# facing you. Luanti's rain and snow both ask for it.
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y if bool(ev.get("vertical", false)) \
			else BaseMaterial3D.BILLBOARD_PARTICLES
	# BILLBOARD_FIXED_Y rebuilds the particle's basis and throws its scale
	# away unless told to keep it, so every rain streak was drawn at the
	# quad's 0.1 node instead of Mineclonia's size 4 to 8. Its raindrop is a
	# one texel streak, which at that size was a few millimetres wide:
	# measured on a live client, a size 6 particle drew 104 pixels without
	# this and 4080 with it. That was the rain nobody could see.
	smat.billboard_keep_scale = true
	smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# A spawner may carry a pool of textures and pick one per particle. Godot
	# draws one pass with one material, so the first is used and the rest are
	# not; a pool of one, which is the ordinary case, is exact.
	smat.albedo_texture = _texture_for(tex_path)
	smat.albedo_color = Color(1, 1, 1, 1) if smat.albedo_texture != null else Color(0.75, 0.85, 1.0, 0.85)
	smat.disable_receive_shadows = true
	# Blend mode. Luanti has one Godot does not: screen has no equivalent, so
	# it borrows add, which is the closest of the ones that exist. clip is
	# alpha testing rather than a blend.
	match int(ev.get("blend_mode", 0)):
		1: smat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		2: smat.blend_mode = BaseMaterial3D.BLEND_MODE_SUB
		3: smat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		4:
			smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			smat.alpha_scissor_threshold = 0.5
		_: smat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	# Texture animation. A vertical strip gives its frame aspect rather than a
	# count, so the count only falls out once the texture's own size is known.
	var anim_type := int(ev.get("anim_type", 0))
	if anim_type != 0 and smat.albedo_texture != null:
		var a := int(ev.get("anim_a", 1))
		var b := int(ev.get("anim_b", 1))
		var frames := 0
		if anim_type == 1:
			var tw := smat.albedo_texture.get_width()
			var th := smat.albedo_texture.get_height()
			if tw > 0 and b > 0:
				frames = int(round(float(th) * float(a) / (float(tw) * float(b))))
			smat.particles_anim_h_frames = 1
			smat.particles_anim_v_frames = maxi(frames, 1)
		else:
			frames = maxi(a, 1) * maxi(b, 1)
			smat.particles_anim_h_frames = maxi(a, 1)
			smat.particles_anim_v_frames = maxi(b, 1)
		smat.particles_anim_loop = true
		var frame_len := float(ev.get("anim_frame_length", 0.0))
		if frame_len > 0.0 and frames > 0:
			# Godot counts animation in whole runs over a particle's life.
			var runs := life / (frame_len * float(frames))
			mat.anim_speed_min = runs
			mat.anim_speed_max = runs
	quad.material = smat
	p.draw_pass_1 = quad
	p.position = (pmin + pmax) * 0.5
	# Godot culls the whole system by this box, and its default is eight units
	# around the emitter. A weather spawner emits across fifty and its flakes
	# fall for another fifty, so nearly all of them live outside the default
	# and the entire snowfall blinks out as soon as that small box leaves the
	# screen. The engine's own note on the property is that you grow it when
	# particles suddenly appear or disappear, which is exactly the symptom.
	# The quad's own half size counts too. A lightning particle is 100 nodes
	# tall and does not move, and the box was a node round its centre, 50
	# nodes up: with the centre off the top of the screen the whole bolt was
	# culled while its lower half was in view.
	var reach := mat.initial_velocity_max * life + 0.5 * mat.gravity.length() * life * life
	reach += maxf(mat.scale_min, mat.scale_max) * quad.size.x * 0.5
	reach = clampf(reach, 1.0, 256.0)
	var ext := mat.emission_box_extents
	var corner := Vector3(ext.x + reach, ext.y + reach, ext.z + reach)
	p.visibility_aabb = AABB(-corner, corner * 2.0)
	if OS.get_environment("GOANNA_DEBUG_PARTICLES") != "":
		print("   pool=%d (server asked %d over %s) reach=%.1f aabb=%s billboard=%s" % [p.amount,
			amount, "forever" if spawner_time <= 0.0 else str(spawner_time) + "s", reach,
			str(p.visibility_aabb.size.round()), str(smat.billboard_mode)])
	add_child(p)
	_spawners[id] = p
	if is_attached:
		# an attached spawner's positions are relative to what it follows
		_attached[id] = [int(ev.get("attached_id", 0)), (pmin + pmax) * 0.5]
		if is_weather:
			_weather[id] = true
	# a finite spawner cleans itself up
	var life_time := spawner_time
	if life_time > 0.0:
		get_tree().create_timer(life_time + life).timeout.connect(func() -> void: _remove_spawner(id))

# A bounded burst of subcube-sized chips at each mining contact. Use a patch
# of the struck face's tile, node tint and actual impact normal.
func _node_pieces(ev: Dictionary) -> void:
	var count := int(ev.get("count", 1))
	if count <= 0 or _pieces.size() >= MAX_PIECES:
		return
	var tex := _texture_for(str(ev.get("texture", "")))
	if OS.get_environment("GOANNA_DEBUG_PARTICLES") != "":
		print("pieces: %d at %s tex=%s (%s)" % [count, str(ev.get("pos")),
			str(ev.get("texture")), "loaded" if tex != null else "MISSING"])
	if tex == null:
		return

	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# Keep the burst at the contact, just outside the struck face.
	mat.emission_box_extents = Vector3(0.035, 0.035, 0.035)
	mat.direction = ((ev.get("normal", Vector3.UP) as Vector3) + Vector3.UP * 0.6).normalized()
	# Vanilla throws each piece up to 3 up and 1.5 sideways, drawn separately
	# per axis. A cone is not the same distribution but covers the same ground.
	mat.spread = 45.0
	mat.initial_velocity_min = 0.5
	mat.initial_velocity_max = 3.4
	mat.gravity = Vector3(0.0, -9.81, 0.0)
	mat.scale_min = 0.8
	mat.scale_max = 1.3
	mat.angle_min = 0.0
	mat.angle_max = 360.0
	mat.angular_velocity_min = 90.0
	mat.angular_velocity_max = 260.0
	mat.particle_flag_rotate_y = true

	var chip := BoxMesh.new()
	chip.size = Vector3.ONE / 16.0
	var smat := StandardMaterial3D.new()
	smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	smat.albedo_texture = tex
	smat.albedo_color = ev.get("colour", Color.WHITE)
	smat.roughness = 1.0
	smat.uv1_scale = Vector3(0.0625, 0.0625, 1.0)
	smat.uv1_offset = Vector3(randi_range(0,15)/16.0, randi_range(0,15)/16.0, 0)
	chip.material = smat

	var p := GPUParticles3D.new()
	p.process_material = mat
	p.draw_pass_1 = chip
	p.amount = count
	p.lifetime = 1.0
	p.randomness = 1.0            # vanilla gives each piece 0 to 1 second
	p.one_shot = true
	p.explosiveness = 1.0         # a break is a burst, not a trickle
	# A one shot system fires on emitting going false to true. It defaults to
	# true, so setting it true again after building the node is not a
	# transition and nothing is ever emitted.
	p.emitting = false
	p.local_coords = false
	# Pieces travel about a metre and fall; the default culling box would drop
	# the burst as soon as the emitter left the screen.
	p.visibility_aabb = AABB(Vector3(-4, -8, -4), Vector3(8, 12, 8))
	p.position = ev.get("pos", Vector3.ZERO)
	add_child(p)
	p.restart()
	p.emitting = true
	_pieces[p] = true
	# One shot systems do not clean themselves up.
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		_pieces.erase(p)
		if is_instance_valid(p):
			p.queue_free())


func _remove_spawner(id: int) -> void:
	var p = _spawners.get(id)
	if p != null and is_instance_valid(p):
		p.queue_free()
	_spawners.erase(id)
	_attached.erase(id)
	_paused.erase(id)
	_weather.erase(id)
	_weather_ev.erase(id)
	if weather != null:
		weather.remove_spawner(id)

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
