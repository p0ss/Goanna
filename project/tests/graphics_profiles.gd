# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
# Actual settings transitions in two views, without connecting or rendering.
extends SceneTree

const Profiles := preload("res://graphics_profiles.gd")
const Features := preload("res://render_features.gd")
const Shell := preload("res://local_play.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	if preload("res://tests/scratch_profile.gd").refuse_real_profile():
		quit(2)
		return
	_run.call_deferred()

func apply(game: Node, profile: String) -> void:
	for key in Profiles.PROFILES[profile]:
		game.ui._apply_setting(key, float(Profiles.PROFILES[profile][key]))

func active_layers(game: Node) -> int:
	var active := 0
	for deck: Vector4 in game.sky_mat.get_shader_parameter("cloud_layers"):
		if deck.z > 0.0:
			active += 1
	return active

func _run() -> void:
	OS.set_environment("GOANNA_NO_POINTER_CAPTURE", "1")
	OS.set_environment("GOANNA_NO_STORE", "1")
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "material_updates", false)
	cfg.save("user://goanna.cfg")
	var shell := Shell.new()
	shell.automatic_launch = false
	shell.capture_mouse = false
	shell.graphics_profile = "lowest"
	shell.game_factory = func() -> Node:
		var game := preload("res://main.tscn").instantiate()
		game.connect_automatically = false
		return game
	root.add_child(shell)
	for i in 2:
		shell.add_player({"name": "tier_%d" % i, "device": i, "host": "127.0.0.1", "port": 39997})
	await process_frame
	await process_frame
	var first: Node = shell.slots[0].game
	var second: Node = shell.slots[1].game
	first.cloud_cov = 0.55
	second.cloud_cov = 0.55
	second._update_cloud_layers()
	check(first.cloud_body_texture == null and second.cloud_body_texture == null,
			"Block cloud startup does not allocate a volume")
	apply(first, "low")
	check(first.cloud_body_texture != null and second.cloud_body_texture == null,
			"Fluffy blocks allocate density only in the selected view")
	var fluffy_texture: NoiseTexture3D = first.cloud_body_texture
	apply(first, "medium")
	check(first.cloud_body_texture == fluffy_texture,
			"Fluffy blocks and full volume reuse the density texture")
	var keys: Array = Profiles.PROFILES.lowest.keys()
	for name in Profiles.ORDER:
		check(Profiles.PROFILES[name].size() == keys.size(), "Same key count: " + name)
		for key in keys:
			check(Profiles.PROFILES[name].has(key), "Complete profile: " + name + "/" + key)
		for key in Features.DEFAULTS:
			check(Profiles.PROFILES[name].has(key), "Feature is controlled: " + key)
	first.ui._apply_setting("fov", 83.0)
	first.ui._apply_setting("night_visibility", 0.7)
	for source in Profiles.ORDER:
		for target in Profiles.ORDER:
			apply(first, source)
			apply(first, target)
			var actual := {}
			for key in keys:
				actual[key] = first.ui._setting_value(key, -999.0)
				if key in ["far_distance", "view_range"]:
					continue # These getters need a connected session.
				check(is_equal_approx(float(actual[key]), float(Profiles.PROFILES[target][key])),
						"Transition %s -> %s: %s" % [source, target, key])
			actual.far_distance = Profiles.PROFILES[target].far_distance
			actual.view_range = Profiles.PROFILES[target].view_range
			check(Profiles.matches(actual) == target, "Profile identification: " + target)
			check(first.sky_mat.get_shader_parameter("cloud_quality") == Profiles.PROFILES[target].cloud_quality,
					"Cloud budget reaches the shader")
			check(first.sky_mat.get_shader_parameter("cloud_style") == Profiles.PROFILES[target].cloud_style,
					"Cloud style reaches the shader")
			check(active_layers(first) == int(Profiles.PROFILES[target].cloud_layer_count),
					"Cloud layer budget immediately reaches the sky")
			check(first.atmosphere_mat.get_shader_parameter("cloud_layers") == first.cloud_layers,
					"Local fog shares the selected layer budget")
			var grass: Dictionary = first.client.get_meta("goanna_grass_parameters")
			check(is_equal_approx(grass.density, float(Profiles.PROFILES[target].grass_density)),
					"Grass budget persists before terrain arrives")
	check(is_equal_approx(first.cam.fov, 83.0) and is_equal_approx(first.night_visibility, 0.7),
			"Profiles preserve player preferences")
	# Texture resolution: 128 on Lowest and Low, 256 on Medium and High, 512
	# on Ultra, reaching the client, which keeps it for the next join.
	var sizes := {"lowest": 128, "low": 128, "medium": 256, "high": 256, "ultra": 512}
	for name in sizes:
		check(int(Profiles.PROFILES[name].texture_size) == sizes[name], "Texture resolution: " + name)
		apply(first, name)
		check(first.client.texture_size() == sizes[name], "Texture resolution reaches the client: " + name)
	check(second.client.texture_size() == 128, "Other view keeps Lowest's texture resolution")
	first.ui._apply_setting("texture_size", 300.0)
	check(first.client.texture_size() == 256, "A size between the tiers snaps to the nearest")
	check(second.cloud_quality == 0 and not second.env.environment.ssao_enabled,
			"Other view retains Lowest")
	check(second.cloud_layer_count == 1.0 and active_layers(second) == 1,
			"Changing one view's layer budget leaves the other view alone")
	apply(first, "lowest")
	check(first.sun.shadow_enabled and first._lamp_budget() > 0 and first.headlight.visible,
			"Lowest retains readable lighting")
	check(not first.atmosphere_volume.visible and not first.shaft_quad.visible,
			"Lowest gates expensive air passes")
	check(first.render_features.render_ice_transmission and first.render_features.render_sky_clouds,
			"Lowest keeps transparent ice and a clouded sky")
	var bench := preload("res://local_bench.gd").new()
	bench.games = [first, second]
	bench.configure_scene({}, {})
	check(bench.set_feature_variant(["render_sky_clouds"]), "Diagnostic feature variant accepted")
	check(not first.render_features.render_sky_clouds, "Diagnostic variant disables its feature")
	bench.set_feature_variant([])
	check(first.render_features.render_sky_clouds and not first.render_features.render_atmosphere,
			"Feature control restores the actual preset, including its off settings")
	bench.free()
	# A live preset change reaches the renderer in stages, reductions first.
	var stage_of := func(stages: Array, key: String) -> int:
		for i in stages.size():
			if stages[i].has(key):
				return i
		return -1
	var down: Array = Profiles.transition_stages(Profiles.PROFILES.high, Profiles.PROFILES.medium)
	var changed := 0
	for key in Profiles.PROFILES.medium:
		if not is_equal_approx(float(Profiles.PROFILES.high[key]), float(Profiles.PROFILES.medium[key])):
			changed += 1
			check(stage_of.call(down, key) >= 0, "Staged change carries " + key)
	check(down.reduce(func(n: int, s: Dictionary) -> int: return n + s.size(), 0) == changed,
			"Staged change carries only what differs")
	check(stage_of.call(down, "light_sdfgi") == -1, "Unchanged SDFGI is not touched")
	check(stage_of.call(down, "view_range") < stage_of.call(down, "shadow_lamps")
			and stage_of.call(down, "shadow_lamps") < stage_of.call(down, "light_ssil"),
			"Distance, then lamps, then screen space")
	check(down.size() > 1, "High to Medium is more than one stage")
	var mixed: Dictionary = Profiles.PROFILES.high.duplicate()
	mixed.grass_density = 0.1
	var both: Array = Profiles.transition_stages(mixed, Profiles.PROFILES.medium)
	check(stage_of.call(both, "grass_density") > stage_of.call(both, "light_ssil"),
			"A raised key waits for every reduction")
	var up: Array = Profiles.transition_stages(Profiles.PROFILES.high, Profiles.PROFILES.ultra)
	check(up[stage_of.call(up, "far_distance")].far_distance == -1.0,
			"The server grant is reached as a raise")
	apply(first, "high")
	first.ui.change_profile("medium")
	check(first.ui.profile_changing and is_equal_approx(first.light_ssil, 1.4),
			"The screen space stage waits for drawn frames")
	for i in 60:
		if not first.ui.profile_changing:
			break
		await process_frame
	check(not first.ui.profile_changing, "Staged change finishes")
	for key in Profiles.PROFILES.medium:
		if key in ["far_distance", "view_range"]:
			continue
		check(is_equal_approx(first.ui._setting_value(key, -999.0), float(Profiles.PROFILES.medium[key])),
				"Staged change reaches " + key)
	var saved := ConfigFile.new()
	saved.load("user://goanna.cfg")
	check(saved.get_value("settings", "graphics_profile", "") == "medium"
			and is_equal_approx(float(saved.get_value("settings", "light_ssil", -1.0)), 0.0),
			"Staged change saves the preset")
	# Exercise saved custom counts and migration from a preset saved before
	# this key existed. Remove only the test slot's shared-preset override.
	var slot = first.player_slot
	first.player_slot = null
	first.ui._apply_setting("cloud_layer_count", 3.0)
	first.ui._save_setting("cloud_layer_count", 3.0)
	first.ui._apply_setting("cloud_layer_count", 1.0)
	first.ui._load_apply_settings()
	check(first.cloud_layer_count == 3.0 and active_layers(first) == 3,
			"Custom cloud layer count survives saving and loading")
	saved.load("user://goanna.cfg")
	saved.erase_section_key("settings", "cloud_layer_count")
	saved.erase_section_key("settings", "texture_size")
	saved.set_value("settings", "graphics_profile", "low")
	saved.save("user://goanna.cfg")
	first.ui._apply_setting("texture_size", 512.0)
	first.ui._load_apply_settings()
	check(first.cloud_layer_count == 1.0 and active_layers(first) == 1,
			"Old saved Low preset receives its new layer budget")
	check(first.client.texture_size() == 128,
			"Old saved Low preset receives its texture resolution")
	first.player_slot = slot
	first.ui._apply_setting("cloud_layer_count", 99.0)
	check(first.cloud_layer_count == 3.0, "Out-of-range counts are clamped")
	var shader: Shader = load("res://shaders/sky.gdshader")
	var uniforms: Array = shader.get_shader_uniform_list()
	check(uniforms.any(func(item: Dictionary) -> bool: return item.name == "cloud_quality"),
			"Sky shader compiles with its quality control")
	shell.free()
	await process_frame
	print("graphics profiles: %d failures" % failures)
	quit(1 if failures else 0)
