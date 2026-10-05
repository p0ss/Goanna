# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
# Exercise real player scenes, settings and environment state without a GPU.
extends SceneTree

const Shell := preload("res://local_play.gd")
const Main := preload("res://main.tscn")
const Features := preload("res://render_features.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func _run() -> void:
	OS.set_environment("GOANNA_NO_POINTER_CAPTURE", "1")
	OS.set_environment("GOANNA_NO_STORE", "1")
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "material_updates", false)
	for key in Features.DEFAULTS:
		cfg.set_value("settings", key, false)
	cfg.save("user://goanna.cfg")
	# Standalone saved settings still permit diagnostic all-off startup.
	OS.set_environment("GOANNA_NO_HW_DEFAULTS", "1")
	var standalone := Main.instantiate()
	standalone.connect_automatically = false
	root.add_child(standalone)
	await process_frame
	check(standalone.cloud_body_texture == null, "Disabled clouds skip volume generation at startup")
	for key in Features.DEFAULTS:
		check(standalone.ui._setting_value(key, -1) == 0.0, "Saved off setting loads: " + key)
	standalone.ui._apply_setting("render_sky_clouds", 1.0)
	check(standalone.cloud_body_texture != null, "Enabling clouds creates the volume lazily")
	standalone.free()
	await process_frame
	var shell := Shell.new()
	shell.automatic_launch = false
	shell.capture_mouse = false
	shell.game_factory = func() -> Node:
		var game := Main.instantiate()
		game.connect_automatically = false
		return game
	root.add_child(shell)
	for i in 2:
		shell.add_player({"name": "feature_%d" % i, "device": i, "host": "127.0.0.1", "port": 39997})
	await process_frame
	await process_frame
	var first: Node = shell.slots[0].game
	var second: Node = shell.slots[1].game
	# Local profiles now set every feature explicitly. Establish an isolated
	# all-off diagnostic control after applying the profile.
	for key in Features.DEFAULTS:
		first.ui._apply_setting(key, 0.0)
		second.ui._apply_setting(key, 0.0)
	for key in Features.DEFAULTS:
		check(first.ui._setting_value(key, -1) == 0.0, "Saved off setting loads: " + key)
		first.ui._apply_setting(key, 1.0)
		check(first.ui._setting_value(key, -1) == 1.0, "UI enables: " + key)
		check(second.ui._setting_value(key, -1) == 0.0, "Other player remains off: " + key)
		first.ui._apply_setting(key, 0.0)
		check(not first.render_feature_state().active[key], "Actual pass is disabled: " + key)
	first.ui._apply_setting("cloud_style", 2.0)
	first.ui._apply_setting("render_sky_clouds", 1.0)
	check(first.cloud_body_texture != null, "Volume style creates its texture lazily")
	check(not first.set_render_feature("unknown_feature", true), "Reject unknown switches")
	first.light_ssao = 2.5
	first.bloom_strength = 0.7
	first.light_shafts = 1.3
	for key in Features.DEFAULTS:
		first.ui._apply_setting(key, 1.0)
	check(first.sun.shadow_enabled and first.moon.shadow_enabled, "Both directional shadows restore")
	check(first.env.environment.ssao_enabled, "SSAO restores independently of intensity")
	check(first.env.environment.glow_enabled, "Bloom restores")
	check(first.shaft_quad.visible, "Shaft geometry restores")
	check(first.atmosphere_volume.visible, "Local volume restores")
	check(first.light_ssao == 2.5 and first.bloom_strength == 0.7 and first.light_shafts == 1.3,
			"Strengths survive off/on comparisons")
	first.ui._apply_setting("render_dynamic_lights", 0.0)
	check(first._lamp_budget() == 0 and first.client.render_stats().light_pool == 0,
			"Dynamic-light off frees the pool immediately")
	first.ui._apply_setting("render_dynamic_lights", 1.0)
	check(first._lamp_budget() > 0, "Dynamic lights restore the configured budget")
	first.ui._apply_setting("render_ice_transmission", 0.0)
	check(first.ice_capture.background.render_target_update_mode == SubViewport.UPDATE_DISABLED,
			"Ice transmission off stops the auxiliary viewport")
	first.ui._apply_setting("render_ice_transmission", 1.0)
	var viewport: Viewport = first.get_viewport()
	first.set_procedural_grass(false)
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	first.grass_antialiasing = 3.0
	first.set_procedural_grass(true)
	check(viewport.msaa_3d == Viewport.MSAA_4X, "Grass enables its usual AA")
	first.ui._apply_setting("render_grass_aa", 0.0)
	check(first.client.procedural_grass() and viewport.msaa_3d == Viewport.MSAA_DISABLED,
			"AA can be disabled without removing grass")
	first.set_procedural_grass(false)
	# An underwater setting change must work without a new water transition.
	first.underwater = true
	first.env.environment.fog_enabled = true
	first.env.environment.fog_density = 0.12
	first.ui._apply_setting("render_atmosphere", 0.0)
	check(not first.env.environment.volumetric_fog_enabled, "Underwater volume turns off immediately")
	check(first.env.environment.fog_enabled and first.env.environment.fog_density > 0.1,
			"Ordinary underwater murk remains")
	first.ui._apply_setting("render_atmosphere", 1.0)
	check(first.env.environment.volumetric_fog_enabled, "Underwater volume restores without resurfacing")
	check(not first.atmosphere_volume.visible, "Air volume stays hidden underwater")
	first.ui._apply_setting("render_underwater_volume", 0.0)
	check(not first.env.environment.volumetric_fog_enabled and first._atmosphere_enabled(),
			"Underwater volume is independent of the air-volume preference")
	first.ui._apply_setting("render_underwater_volume", 1.0)
	check(first.env.environment.volumetric_fog_enabled, "Independent underwater volume restores")
	first.ui._apply_setting("atmosphere_quality", 0.0)
	check(not first.env.environment.volumetric_fog_enabled, "Quality zero also disables underwater volume")
	first.ui._apply_setting("bloom_strength", 0.0)
	check(not first.env.environment.glow_enabled, "Bloom zero stops its pass")
	first.ui._apply_setting("light_shafts", 0.0)
	check(not first.shaft_quad.visible, "Shaft zero removes its draw")
	first.ui._save_setting("render_ssao", 0.0)
	cfg.load("user://goanna.cfg")
	check(float(cfg.get_value("settings", "render_ssao", -1)) == 0.0, "Feature switch persists")
	shell.free()
	await process_frame
	print("render features: %d failures" % failures)
	quit(1 if failures else 0)
