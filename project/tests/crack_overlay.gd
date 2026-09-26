# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Headless: --headless --path project --script res://tests/crack_overlay.gd
#
# The dig crack's second pass (shaders/crack_overlay.gdshader) is loaded only
# when a block is first dug, so a shader error would pass unnoticed until
# then, and a uniform renamed on one side of it silently draws the wrong
# frame. The headless renderer runs Godot's shader front end in full (a type
# error fails the compile and leaves no uniforms), so this checks that the
# shader compiles and declares every uniform GoannaClient::crackOverlayMaterial
# sets. It renders nothing: how the crack looks is not tested here.
extends SceneTree

const SHADER := "res://shaders/crack_overlay.gdshader"
# What crackOverlayMaterial sets by name, besides the <channel>_strength
# uniforms it shares with nodes_array.gdshader.
const SET_BY_CLIENT := ["crack_tex", "crack_frames", "crack_frame", "crack_scale",
		"base_alpha_test", "albedo_array", "layer_anim"]
# The node light strengths the crack is lit with, which the settings
# sliders reach through set_material_strength.
const LIGHT_STRENGTHS := ["sky_light_strength", "vertex_ao_strength",
		"vertex_ao_light_strength", "sky_fill_strength"]

var failures := 0


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _initialize() -> void:
	var shader: Shader = load(SHADER)
	check(shader != null, "cannot load " + SHADER)
	if shader:
		var names := {}
		for u in shader.get_shader_uniform_list(true):
			names[u["name"]] = true
		check(not names.is_empty(), SHADER + " did not compile")
		for n in SET_BY_CLIENT + LIGHT_STRENGTHS:
			check(names.has(n), SHADER + " has no uniform " + n)
	print("crack_overlay: ", "ok" if failures == 0 else "%d failure(s)" % failures)
	quit(1 if failures else 0)
