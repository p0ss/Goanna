# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Sound. Two sources feed it:
#   - the server, through PLAY_SOUND / STOP_SOUND / FADE_SOUND, which covers
#     ambience, music, mob noises and anything a mod plays;
#   - the client itself, for the sounds Luanti's own client makes locally
#     (SoundMaker): footsteps, landing and jumping here; digging, placing,
#     item use, damage and other objects' footsteps queued by the session.
#
# Positional sounds follow upstream's OpenAL set up (sound/playing_sound.cpp):
# inverse distance, full gain out to three nodes and clamped inside one, no
# distance limit of its own (the server decides who hears), and a sound
# attached to an object moves with it. Directions are panned at full
# strength; Godot does no HRTF, which OpenAL Soft can on headphones.
#
# Luanti names a sound without its extension and may ship numbered variants
# (dirt_footstep.1.ogg, .2.ogg); a name is resolved against the media the
# server sent us and one variant is picked at random, as the vanilla client
# does. Streams are decoded once from the received bytes and cached.
extends Node

const MAX_VOICES := 24
# PlayingSound::setGain triples a positional sound's gain and
# updatePosVel clamps it inside one node: inverse distance with three nodes
# at full gain, so Godot's unit_size 3, and at most 3x (9.54 dB).
const UNIT_SIZE := 3.0
const MAX_DB := 9.54
# Godot halves 3D panning by default (audio/general/3d_panning_strength);
# twice that per voice pans fully, as OpenAL does.
const PANNING := 2.0

# Every sound that is actually played, before volume and mute: name, gain,
# kind ("" for the server's, else what the client made it for), loop, and
# position (Godot axes) or null for one local to the listener. The player
# agent hears through this.
signal played(info: Dictionary)

var client: Node                      # GoannaClient
var listener: Node3D                  # the camera, for positional sounds

var local_mix_gain := 1.0

var volume := 0.8
var muted := false

var _stream_cache := {}               # resolved name -> AudioStream (or null)
var _variants := {}                   # base name -> [media names]
var _media_indexed := false
var _players: Array = []              # free 3D voices
var _players_flat: Array = []         # free non-positional voices
var _by_server_id := {}               # server sound id -> player (for stop)
var _following := {}                  # 3D voice -> object id it is attached to
# SoundMaker and Camera::step's view bobbing, for the local player.
var _step_timer := 0.0
var _jump_timer := 0.0
var _bobbing := false
var _bob_anim := 0.0
var _was_on_ground := true

func _ready() -> void:
	for i in MAX_VOICES:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = UNIT_SIZE
		p3.max_db = MAX_DB
		p3.max_distance = 0.0
		p3.panning_strength = PANNING
		p3.finished.connect(_on_finished.bind(p3))
		add_child(p3)
		_players.append(p3)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.finished.connect(_on_finished.bind(p))
		add_child(p)
		_players_flat.append(p)

func _on_finished(p: Node) -> void:
	_following.erase(p)
	for id in _by_server_id.keys():
		if _by_server_id[id] == p:
			_by_server_id.erase(id)
	if p is AudioStreamPlayer3D:
		if not _players.has(p):
			_players.append(p)
	elif not _players_flat.has(p):
		_players_flat.append(p)

# --- media lookup ------------------------------------------------------------

# Luanti sends "foo" and ships foo.ogg, or foo.1.ogg / foo.2.ogg variants.
func _index_media() -> void:
	if _media_indexed or client == null or not client.has_method("media_names"):
		_media_indexed = true
		return
	for n in client.media_names():
		var name: String = n
		if not name.ends_with(".ogg"):
			continue
		var base := name.substr(0, name.length() - 4)
		# strip a trailing .<digits> variant marker
		var dot := base.rfind(".")
		if dot > 0 and base.substr(dot + 1).is_valid_int():
			base = base.substr(0, dot)
		if not _variants.has(base):
			_variants[base] = []
		_variants[base].append(name)
	_media_indexed = true

func _stream_for(sound_name: String) -> AudioStream:
	if sound_name == "":
		return null
	_index_media()
	var file := sound_name
	if _variants.has(sound_name):
		var list: Array = _variants[sound_name]
		file = list[randi() % list.size()]
	elif not sound_name.ends_with(".ogg"):
		file = sound_name + ".ogg"
	if _stream_cache.has(file):
		return _stream_cache[file]
	var bytes: PackedByteArray = client.media_bytes(file)
	var stream: AudioStream = null
	if bytes.size() > 0:
		stream = AudioStreamOggVorbis.load_from_buffer(bytes)
	_stream_cache[file] = stream
	return stream

# --- playback ----------------------------------------------------------------

func play(sound_name: String, gain: float, pitch: float, loop: bool,
		pos, server_id: int = 0, kind := "", object_id := 0) -> void:
	if sound_name == "":
		return
	var stream := _stream_for(sound_name)
	if OS.get_environment("GOANNA_DEBUG_SOUND") != "":
		print("sound: %s gain=%.2f %s %s -> %s" % [sound_name, gain, kind,
			("at " + str(pos)) if pos != null else "local",
			"ok" if stream != null else "MISSING"])
	if stream == null:
		return
	played.emit({"name": sound_name, "gain": gain, "kind": kind, "loop": loop,
		"position": pos, "object_id": object_id})
	if muted or volume <= 0.0:
		return
	if stream is AudioStreamOggVorbis:
		stream.loop = loop
	var db := linear_to_db(clampf(gain * volume * local_mix_gain, 0.0001, 4.0))
	if pos == null:
		if _players_flat.is_empty():
			return
		var p: AudioStreamPlayer = _players_flat.pop_back()
		p.stream = stream
		p.volume_db = db
		p.pitch_scale = maxf(pitch, 0.01)
		p.play()
		if server_id != 0:
			_by_server_id[server_id] = p
	else:
		if _players.is_empty():
			return
		var p3: AudioStreamPlayer3D = _players.pop_back()
		p3.stream = stream
		p3.volume_db = db
		p3.pitch_scale = maxf(pitch, 0.01)
		p3.global_position = pos
		p3.play()
		if server_id != 0:
			_by_server_id[server_id] = p3
		if object_id != 0:
			_following[p3] = object_id

func stop_server_sound(server_id: int) -> void:
	var p = _by_server_id.get(server_id)
	if p != null and is_instance_valid(p):
		p.stop()
		_on_finished(p)

# --- per frame ---------------------------------------------------------------

func _process(delta: float) -> void:
	if client == null:
		return
	for ev in client.take_sounds():
		var pos = null
		var object_id := int(ev.get("object_id", 0))
		if bool(ev.get("positional", false)):
			pos = ev["position"]
			# Client::handleCommand_PlaySound starts an object's sound where
			# the object is now, not where the server last saw it.
			var at = _object_position(object_id)
			if at != null:
				pos = at
		play(str(ev.get("name", "")), float(ev.get("gain", 1.0)), float(ev.get("pitch", 1.0)),
			bool(ev.get("loop", false)), pos, int(ev.get("id", 0)), str(ev.get("kind", "")),
			object_id if pos != null else 0)
	for id in client.take_stopped_sounds():
		stop_server_sound(int(id))
	# Client::step moves a sound attached to an object with it; one whose
	# object has gone stays where it was last heard.
	for p3 in _following.keys():
		var at = _object_position(int(_following[p3]))
		if at != null:
			(p3 as AudioStreamPlayer3D).global_position = at

func _object_position(object_id: int) -> Variant:
	if object_id == 0 or client == null or not client.has_method("entity_anchor"):
		return null
	var anchor: Dictionary = client.entity_anchor(object_id)
	return (anchor["transform"] as Transform3D).origin if anchor.has("transform") else null

# The local player's own footsteps, landing and jump, from the last movement
# step (main.gd's last_move). Upstream fires these from LocalPlayer events,
# which the transplanted LocalPlayer does not raise, so they are recognised
# here from the same state: Camera::step's view bobbing (a step at the start
# and at each half cycle, the cycle quickening with speed), landing
# (PLAYER_REGAIN_GROUND) and leaving the ground upwards (PLAYER_JUMP).
func step_local(delta: float, move: Dictionary) -> void:
	if client == null or not move.has("pos"):
		return
	_step_timer -= delta
	_jump_timer -= delta
	var speed: Vector3 = move.get("speed", Vector3.ZERO)
	var on_ground := bool(move.get("on_ground", false))
	var in_liquid := bool(move.get("in_liquid", false))
	var climbing := bool(move.get("climbing", false))
	var flying := bool(move.get("free_move", false))
	var across := Vector2(speed.x, speed.z).length() > 1.0
	var upright := absf(speed.y) > 1.0
	var walking := across and on_ground
	var swimming := (across or upright) and in_liquid
	var climb := upright and climbing
	if (walking or swimming or climb) and not flying:
		var was := _bob_anim if _bobbing else 0.0
		_bobbing = true
		# m_view_bobbing_speed is the speed in BS units, at most 70.
		_bob_anim = fposmod(was + delta * minf(speed.length() * 10.0, 70.0) * 0.030, 1.0)
		if was == 0.0 or (was < 0.5 and _bob_anim >= 0.5) or (was > 0.5 and _bob_anim <= 0.5):
			_player_step(move)
	else:
		_bobbing = false
		_bob_anim = 0.0
	if on_ground and not _was_on_ground and not flying:
		_player_step(move)
	if _was_on_ground and not on_ground and speed.y > 1.0 \
			and not in_liquid and not climbing and not flying and _jump_timer <= 0.0:
		_jump_timer = 0.2
		play("player_jump", 0.5, 1.0, false, null, 0, "jump")
	_was_on_ground = on_ground

# SoundMaker::playPlayerStep, with LocalPlayer::getFootstepNodePos: the node
# at the feet while swimming, just under them on the ground, half a node under
# them in the air (the node about to be landed on).
func _player_step(move: Dictionary) -> void:
	if _step_timer > 0.0:
		return
	_step_timer = 0.03
	var feet: Vector3 = move["pos"]
	var below := 0.0
	if not bool(move.get("in_liquid", false)):
		below = 0.05 if bool(move.get("on_ground", false)) else 0.5
	_play_node_sound(client.node_name_at(feet - Vector3(0, below, 0)), "footstep", 1.0)

func node_dug(node_name: String) -> void:
	_play_node_sound(node_name, "dug", 1.0)

func _play_node_sound(node_name: String, kind: String, scale: float) -> void:
	if client == null or not client.has_method("node_sound"):
		return
	var s: Dictionary = client.node_sound(node_name, kind)
	if s.is_empty():
		return
	# local to the player, so no position: these follow the listener anyway
	play(str(s.get("name", "")), float(s.get("gain", 1.0)) * scale,
		float(s.get("pitch", 1.0)), false, null, 0, "step" if kind == "footstep" else kind)
