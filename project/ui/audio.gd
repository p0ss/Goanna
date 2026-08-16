# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Sound. Two sources feed it:
#   - the server, through PLAY_SOUND / STOP_SOUND / FADE_SOUND, which covers
#     ambience, music, mob noises and anything a mod plays;
#   - the client itself, for the sounds Luanti's own client makes locally from
#     node definitions: footsteps while walking, and digging and placing.
#
# Luanti names a sound without its extension and may ship numbered variants
# (dirt_footstep.1.ogg, .2.ogg); a name is resolved against the media the
# server sent us and one variant is picked at random, as the vanilla client
# does. Streams are decoded once from the received bytes and cached.
extends Node

const MAX_VOICES := 24
const FOOTSTEP_INTERVAL := 0.42

var client: Node                      # GoannaClient
var listener: Node3D                  # the camera, for positional sounds

var volume := 0.8
var muted := false

var _stream_cache := {}               # resolved name -> AudioStream (or null)
var _variants := {}                   # base name -> [media names]
var _media_indexed := false
var _players: Array = []              # free 3D voices
var _players_flat: Array = []         # free non-positional voices
var _by_server_id := {}               # server sound id -> player (for stop)
var _foot_timer := 0.0
var _was_digging := false

func _ready() -> void:
	for i in MAX_VOICES:
		var p3 := AudioStreamPlayer3D.new()
		p3.unit_size = 8.0
		p3.max_distance = 48.0
		p3.finished.connect(_on_finished.bind(p3))
		add_child(p3)
		_players.append(p3)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.finished.connect(_on_finished.bind(p))
		add_child(p)
		_players_flat.append(p)

func _on_finished(p: Node) -> void:
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
		pos, server_id: int = 0) -> void:
	if muted or volume <= 0.0:
		return
	var stream := _stream_for(sound_name)
	if OS.get_environment("GOANNA_DEBUG_SOUND") != "":
		print("sound: %s gain=%.2f %s -> %s" % [sound_name, gain,
			("at " + str(pos)) if pos != null else "local",
			"ok" if stream != null else "MISSING"])
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		stream.loop = loop
	var db := linear_to_db(clampf(gain * volume, 0.0001, 4.0))
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
		if bool(ev.get("positional", false)):
			pos = ev["position"]
		play(str(ev.get("name", "")), float(ev.get("gain", 1.0)), float(ev.get("pitch", 1.0)),
			bool(ev.get("loop", false)), pos, int(ev.get("id", 0)))
	for id in client.take_stopped_sounds():
		stop_server_sound(int(id))

# Footsteps, and the sounds of digging and finishing a dig: the vanilla client
# makes these itself from the node's definition, so Goanna does too.
func step_local(delta: float, moving: bool, on_ground: bool, stand_node: String,
		pointed: Dictionary) -> void:
	if moving and on_ground and stand_node != "":
		_foot_timer -= delta
		if _foot_timer <= 0.0:
			_foot_timer = FOOTSTEP_INTERVAL
			_play_node_sound(stand_node, "footstep", 1.0)
	else:
		_foot_timer = 0.0
	var digging := bool(pointed.get("digging", false))
	var node_name := str(pointed.get("node_name", ""))
	if digging and not _was_digging and node_name != "":
		_play_node_sound(node_name, "dig", 0.8)
	_was_digging = digging

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
		float(s.get("pitch", 1.0)), false, null)
