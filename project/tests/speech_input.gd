# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Voice typing (ui/voice_input.gd and GoannaSpeechInput). Always: the
# resampling, the cleaning of what Whisper marks as not speech, and T as a
# tap or a hold. With a model in GOANNA_TEST_WHISPER_MODEL and espeak-ng on
# the path: real transcription of synthesised sentences, which espeak-ng
# writes to a file, so nothing is played aloud.
#
#   GOANNA_TEST_WHISPER_MODEL=/path/ggml-base-q5_1.bin \
#   godot --headless --path project -s tests/speech_input.gd
extends SceneTree

const VoiceInput := preload("res://ui/voice_input.gd")

var failures := 0
var checks := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	# 48 kHz to 16 kHz: a third as many samples, each the mean of three.
	var tone := PackedFloat32Array()
	for i in 4800:
		tone.append(1.0 if (i / 3) % 2 == 0 else -1.0)
	var down := VoiceInput.to_16k(tone, 48000.0)
	check(down.size() == 1600, "48 kHz to 16 kHz gives a third of the samples: %d" % down.size())
	check(is_equal_approx(down[0], 1.0) and is_equal_approx(down[1], -1.0),
		"each sample is the mean of the three it covers")
	check(VoiceInput.to_16k(PackedFloat32Array(), 48000.0).is_empty(), "nothing in, nothing out")
	check(VoiceInput.clean(" [BLANK_AUDIO] ") == "", "a blank is not chat")
	check(VoiceInput.clean("(music) hello  there [laughs]") == "hello there",
		"marks for what is not speech are taken out: '%s'" % VoiceInput.clean("(music) hello  there [laughs]"))

	# T: a tap opens chat, a hold listens and does not.
	var voice: Node = VoiceInput.new()
	root.add_child(voice)
	await process_frame
	voice.key_down()
	voice._held = 0.1
	check(voice.key_up(), "a quick tap of T is a tap")
	voice.key_down()
	voice._held = VoiceInput.HOLD_S + 0.1
	check(not voice.key_up(), "a long hold of T is not a tap")
	check(not voice.key_up(), "a release with no press is nothing")

	var model := OS.get_environment("GOANNA_TEST_WHISPER_MODEL")
	var espeak := _which("espeak-ng")
	if model == "" or espeak == "" or not ClassDB.class_exists("GoannaSpeechInput"):
		print("speech input: transcription skipped (set GOANNA_TEST_WHISPER_MODEL and install espeak-ng)")
	else:
		await _transcribe(model, espeak)
	print("speech input: %d checks, %s" % [checks, "PASS" if failures == 0 else "FAIL (%d)" % failures])
	quit(0 if failures == 0 else 1)

func _transcribe(model: String, espeak: String) -> void:
	var speech: RefCounted = ClassDB.instantiate("GoannaSpeechInput")
	var t0 := Time.get_ticks_msec()
	check(speech.load_model(model), "a model load starts")
	while speech.state() == "loading":
		await process_frame
	check(speech.state() == "ready", "the model loads: %s" % speech.state())
	print("speech input: model loaded in %d ms" % (Time.get_ticks_msec() - t0))
	var lines := {"Meet me at the village store, I have bread for you.": ["village", "store", "bread"],
		"Can somebody help me find diamonds?": ["help", "find", "diamonds"]}
	for line in lines:
		var wav := ProjectSettings.globalize_path("user://speech_input_test.wav")
		OS.execute(espeak, ["-v", "en", "-s", "150", "-w", wav, line])
		var audio := _read_wav(wav)
		DirAccess.remove_absolute(wav)
		check(not audio.is_empty(), "espeak-ng wrote a sentence")
		var samples := VoiceInput.to_16k(audio.samples, float(audio.rate))
		check(speech.transcribe(samples, "en", "Sam. Meet me later."), "a transcription starts")
		var result := {}
		while result.is_empty():
			await process_frame
			result = speech.take_result()
		var heard := VoiceInput.clean(str(result.get("text", ""))).to_lower()
		print("speech input: heard '%s' in %d ms" % [heard, int(result.get("ms", -1))])
		for word in lines[line]:
			check(heard.contains(word), "'%s' heard in '%s'" % [word, heard])
	check(not speech.transcribe(PackedFloat32Array(), "en", ""), "nothing to hear is refused")

static func _which(program: String) -> String:
	var out := []
	if OS.execute("sh", ["-c", "command -v " + program], out) == 0 and not out.is_empty():
		return str(out[0]).strip_edges()
	return ""

# A 16 bit PCM WAV's samples as floats, and its rate; mono, or the first
# channel.
static func _read_wav(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return {}
	var at := 12
	var rate := 0
	var channels := 1
	while at + 8 <= bytes.size():
		var id := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := bytes.decode_u32(at + 4)
		if id == "fmt ":
			channels = bytes.decode_u16(at + 10)
			rate = bytes.decode_u32(at + 12)
		elif id == "data":
			var samples := PackedFloat32Array()
			var i := at + 8
			while i + 1 < at + 8 + size and i + 1 < bytes.size():
				samples.append(bytes.decode_s16(i) / 32768.0)
				i += 2 * channels
			return {"samples": samples, "rate": rate}
		at += 8 + size + (size % 2)
	return {}
