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
	_run.call_deferred()

func apply(game: Node, profile: String) -> void:
	for key in Profiles.PROFILES[profile]:
		game.ui._apply_setting(key, float(Profiles.PROFILES[profile][key]))

func _run() -> void:
	OS.set_environment("GOANNA_NO_POINTER_CAPTURE", "1")
	OS.set_environment("GOANNA_NO_STORE", "1")
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "asset_updates", false)
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
			var grass: Dictionary = first.client.get_meta("goanna_grass_parameters")
			check(is_equal_approx(grass.density, float(Profiles.PROFILES[target].grass_density)),
					"Grass budget persists before terrain arrives")
	check(is_equal_approx(first.cam.fov, 83.0) and is_equal_approx(first.night_visibility, 0.7),
			"Profiles preserve player preferences")
	check(second.cloud_quality == 0 and not second.env.environment.ssao_enabled,
			"Other view retains Lowest")
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
	var shader: Shader = load("res://shaders/sky.gdshader")
	var uniforms: Array = shader.get_shader_uniform_list()
	check(uniforms.any(func(item: Dictionary) -> bool: return item.name == "cloud_quality"),
			"Sky shader compiles with its quality control")
	shell.free()
	await process_frame
	print("graphics profiles: %d failures" % failures)
	quit(1 if failures else 0)
