# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Voice typing: hold T, say the chat line, let go. The words go into the chat
# box unsent, read back when read aloud is on, and Enter sends them. A quick
# tap of T still opens the chat box to type, as before.
#
# Speech is turned into text on this computer by a Whisper model through
# GoannaSpeechInput (src/goanna_speech_input.cpp). The microphone is open
# only while T is held, and the audio is transcribed and dropped: nothing is
# recorded to disk or sent anywhere. The model (Whisper, MIT licence) is
# downloaded the first time voice typing is used, from a pinned revision,
# and checked against its SHA-256 before it is loaded.
extends Node

# Hugging Face revision of ggerganov/whisper.cpp the models are taken from.
const REVISION := "5359861c739e955e79d9a303bcbc70fb988958b1"
const MODELS := {
	"base": {"file": "ggml-base-q5_1.bin", "bytes": 59707625,
		"sha256": "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"},
	"small": {"file": "ggml-small-q5_1.bin", "bytes": 190085487,
		"sha256": "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"},
}
const MODEL_DIR := "user://models/whisper"
# A press held longer than this is speech; shorter is a tap that opens chat.
const HOLD_S := 0.35
# Whisper hears thirty seconds at a time; a longer hold stops there.
const MAX_S := 30.0
# Less than this much speech is a slip of the finger, not a line of chat.
const MIN_S := 0.4
const BUS := "GoannaVoice"
const RATE := 16000

var client: Node
var ui: Node                          # game_ui.gd
var enabled := true
var model_size := "base"
var language := "auto"
# What it is doing, for the indicator and for tests: "idle", "downloading",
# "loading", "listening", "transcribing".
var state := "idle"

var _speech: RefCounted               # GoannaSpeechInput
var _loaded := ""                     # the model size in memory
var _key_down := false
var _held := 0.0
var _heard := PackedFloat32Array()    # mono, at the mix rate
var _mic: AudioStreamPlayer
var _capture: AudioEffectCapture
var _http: HTTPRequest
var _download_size := ""
var _indicator: Label

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://goanna.cfg") == OK:
		var size := str(cfg.get_value("settings", "voice_model", "base"))
		model_size = size if MODELS.has(size) else "base"
		language = str(cfg.get_value("settings", "voice_language", "auto"))
	if ClassDB.class_exists("GoannaSpeechInput"):
		_speech = ClassDB.instantiate("GoannaSpeechInput")
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_indicator = Label.new()
	_indicator.visible = false
	_indicator.add_theme_font_size_override("font_size", 18)
	_indicator.add_theme_color_override("font_outline_color", Color.BLACK)
	_indicator.add_theme_constant_override("outline_size", 6)
	_indicator.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_indicator.position.y -= 160
	_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_indicator)

func available() -> bool:
	return enabled and _speech != null

# --- the key ---------------------------------------------------------------------

# game_ui.gd calls these for T when no window or chat is open.
func key_down() -> void:
	_key_down = true
	_held = 0.0

# True if the press was a tap, which game_ui answers by opening chat.
func key_up() -> bool:
	if not _key_down:
		return false
	_key_down = false
	if state == "listening":
		_finish_listening()
		return false
	return _held < HOLD_S

func _process(delta: float) -> void:
	if _key_down:
		_held += delta
		if _held >= HOLD_S and state == "idle":
			_begin()
	if state == "listening":
		_collect()
		if _heard.size() >= int(MAX_S * AudioServer.get_mix_rate()):
			_finish_listening()
	elif state == "downloading":
		_show_download()
	elif state == "loading" and _speech.state() != "loading":
		state = "idle"
		_hide()
		if _speech.state() == "failed":
			_loaded = ""
			_speech.take_result()
			_say("Voice typing could not start: the speech model did not load.")
		elif _key_down:
			_start_listening()
	elif state == "transcribing":
		var result: Dictionary = _speech.take_result()
		if not result.is_empty():
			state = "idle"
			_hide()
			_on_result(result)

# --- getting ready -----------------------------------------------------------------

# A hold with the model not yet here downloads it; with it here but not in
# memory, loads it; with both, listens.
func _begin() -> void:
	var path := model_path(model_size)
	if not FileAccess.file_exists(path):
		_download()
	elif _loaded != model_size:
		state = "loading"
		_loaded = model_size
		_speech.load_model(ProjectSettings.globalize_path(path))
		_show("Voice typing is getting ready...")
	else:
		_start_listening()

static func model_path(size: String) -> String:
	return MODEL_DIR.path_join(str(MODELS[size].file))

func _download() -> void:
	var spec: Dictionary = MODELS[model_size]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MODEL_DIR))
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_downloaded)
	_http.download_file = ProjectSettings.globalize_path(model_path(model_size) + ".part")
	var url := "https://huggingface.co/ggerganov/whisper.cpp/resolve/%s/%s" % [REVISION, spec.file]
	if _http.request(url) != OK:
		_say("Voice typing could not start its download.")
		return
	state = "downloading"
	_download_size = model_size
	_say("Voice typing is downloading its speech model, %d megabytes. This happens once." \
		% roundi(float(spec.bytes) / 1048576.0))

func _show_download() -> void:
	var total := float(MODELS[_download_size].bytes)
	_show("Downloading voice typing: %d%%" % roundi(100.0 * _http.get_downloaded_bytes() / total))

func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var part := ProjectSettings.globalize_path(model_path(_download_size) + ".part")
	var final := ProjectSettings.globalize_path(model_path(_download_size))
	state = "idle"
	_hide()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(part)
		_say("Voice typing could not download its speech model. Check the connection and hold T to try again.")
		return
	if FileAccess.get_sha256(part) != str(MODELS[_download_size].sha256):
		DirAccess.remove_absolute(part)
		_say("Voice typing's download was damaged and has been thrown away. Hold T to try again.")
		return
	DirAccess.rename_absolute(part, final)
	_say("Voice typing is ready. Hold T and speak.")

# --- listening --------------------------------------------------------------------

func _start_listening() -> void:
	if not _open_microphone():
		_say("Voice typing cannot hear a microphone.")
		return
	_heard = PackedFloat32Array()
	_capture.clear_buffer()
	_mic.play()
	state = "listening"
	_show("Listening... let go of T when you are done")

# A muted bus with a capture on it, so what the microphone hears is read
# but never played back. Godot opens the input device only while the
# microphone stream plays.
func _open_microphone() -> bool:
	if _mic != null:
		return true
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		return false
	var bus := AudioServer.get_bus_index(BUS)
	if bus < 0:
		AudioServer.add_bus()
		bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, BUS)
		AudioServer.set_bus_mute(bus, true)
		AudioServer.add_bus_effect(bus, AudioEffectCapture.new())
	_capture = AudioServer.get_bus_effect(bus, 0)
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = BUS
	add_child(_mic)
	return true

func _collect() -> void:
	var frames := _capture.get_frames_available()
	if frames <= 0:
		return
	for f in _capture.get_buffer(frames):
		_heard.append((f.x + f.y) * 0.5)

func _finish_listening() -> void:
	_collect()
	_mic.stop()
	var samples := to_16k(_heard, AudioServer.get_mix_rate())
	_heard = PackedFloat32Array()
	if samples.size() < int(MIN_S * RATE):
		state = "idle"
		_hide()
		return
	state = "transcribing"
	_show("Working out what you said...")
	if not _speech.transcribe(samples, language, prompt()):
		state = "idle"
		_hide()

# Mono samples at `rate` to 16 kHz, Whisper's rate: each output sample is the
# mean of the input samples it covers, which is enough of a low pass for
# speech going down from 44.1 or 48 kHz.
static func to_16k(samples: PackedFloat32Array, rate: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if samples.is_empty() or rate <= 0.0:
		return out
	var step := rate / RATE
	var count := int(samples.size() / step)
	out.resize(count)
	for i in count:
		var from := int(i * step)
		var to := maxi(from + 1, mini(int((i + 1) * step), samples.size()))
		var sum := 0.0
		for j in range(from, to):
			sum += samples[j]
		out[i] = sum / (to - from)
	return out

# Words the speech is likely to hold, so the model spells them as the game
# does: the player's own name, the names over players in view, and the last
# few chat lines.
func prompt() -> String:
	var parts := []
	if OS.get_environment("GOANNA_NAME") != "":
		parts.append(OS.get_environment("GOANNA_NAME"))
	if client != null and client.has_method("entity_list"):
		for e in client.entity_list():
			var tag := str(e.get("nametag", "")).strip_edges()
			if tag != "" and not tag in parts:
				parts.append(tag)
	if ui != null and ui.get("chat_lines") != null:
		var lines: Array = ui.chat_lines
		for i in range(maxi(0, lines.size() - 3), lines.size()):
			parts.append(str(lines[i].get("text", "")))
	return ". ".join(parts).left(400)

# --- the words -------------------------------------------------------------------

# Whisper marks what is not speech in brackets ([BLANK_AUDIO], (music));
# those are not chat.
static var _not_speech := RegEx.create_from_string("\\[[^\\]]*\\]|\\([^)]*\\)")

static func clean(text: String) -> String:
	text = _not_speech.sub(text, "", true)
	while text.contains("  "):
		text = text.replace("  ", " ")
	return text.strip_edges()

func _on_result(result: Dictionary) -> void:
	if result.has("error"):
		_say("Voice typing did not work that time. Hold T and try again.")
		return
	var text := clean(str(result.get("text", "")))
	if text == "":
		_say("I did not catch that. Hold T and try again.")
		return
	if ui != null and ui.has_method("_open_chat"):
		ui._open_chat(text)
	var narrator = ui.get("narrator") if ui != null else null
	if narrator != null and narrator.enabled:
		var stop := "" if text.right(1) in [".", "?", "!"] else "."
		narrator.say("Heard: %s%s Press Enter to send." % [text, stop], true)

# --- telling the player -------------------------------------------------------------

func _show(text: String) -> void:
	_indicator.text = text
	_indicator.visible = true

func _hide() -> void:
	_indicator.visible = false

# Shown, and spoken when read aloud is on.
func _say(text: String) -> void:
	_show(text)
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if _indicator.text == text:
			_hide())
	var narrator = ui.get("narrator") if ui != null else null
	if narrator != null and narrator.enabled:
		narrator.say(text, true)
