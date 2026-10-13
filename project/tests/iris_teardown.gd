# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## Frees a GoannaIrisEffect while its centre depth readback is in flight,
## several times over, resizes its geometry read textures and checks the
## process lives to say so. Needs a
## renderer that runs compositor effects, so it goes through the launcher:
## tools/goanna-headless fixture res://tests/iris_teardown.tscn (on the
## GPU: lavapipe crashes earlier, clearing one of the pack's targets)
## then look for "iris teardown: ok" in the log it names.
#
# The effect reads the centre pixel of depth back asynchronously, and Godot
# calls the callback on the main thread a frame or more later. Until
# 2026-10-12 that callback was bound to the effect, and checking it after
# the effect was freed crashed the client (signal 11, in
# custom_callable_mp_is_valid).
extends Node

const PACK := "res://tests/shaderpacks/proof"
const CYCLES := 4
const FRAMES_ON := 12
const FRAMES_OFF := 6


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	add_child(env)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 3)
	cam.compositor = Compositor.new()
	add_child(cam)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	add_child(box)
	await get_tree().process_frame

	for i in CYCLES:
		var iris := GoannaIrisEffect.new()
		if not iris.load_pack(ProjectSettings.globalize_path(PACK)):
			push_error("iris teardown: pack failed to load: %s" % iris.report())
			get_tree().quit(1)
			return
		iris.set_gbuffers_reads(PackedInt32Array([0, 1, 2]), 0)
		cam.compositor.compositor_effects = [iris.make_depth_capture(), iris]
		var initial_width := 0
		# One more frame each cycle, so some free lands while a readback
		# is in flight; it comes back every other frame or so.
		for f in FRAMES_ON + i:
			await get_tree().process_frame
			if iris.sync_gbuffers_reads():
				var read_texture: Texture2D = iris.gbuffers_read_texture(1)
				if f == 4:
					initial_width = read_texture.get_width()
					get_viewport().scaling_3d_scale = 0.5
				if f == FRAMES_ON - 1:
					if initial_width <= 0 or read_texture.get_width() != initial_width / 2:
						push_error("iris teardown: read texture did not follow the viewport resize")
						get_tree().quit(1)
						return
		if not iris.sync_gbuffers_reads():
			push_error("iris teardown: read textures were never bound")
			get_tree().quit(1)
			return
		if i == 0:
			print("iris teardown: ", iris.report())
		# Freed here, with the last frame's readback still pending. The
		# spray then reuses the freed memory, so a callback still pointing
		# at the effect reads garbage and crashes, where without it the
		# stale memory can look valid enough to pass.
		cam.compositor.compositor_effects = []
		iris = null
		get_viewport().scaling_3d_scale = 1.0
		var spray := []
		for n in range(256, 32768, 16):
			var b := PackedByteArray()
			b.resize(n)
			b.fill(0x41)
			spray.append(b)
		for f in FRAMES_OFF:
			await get_tree().process_frame
	print("iris teardown: ok")
	get_tree().quit(0)
