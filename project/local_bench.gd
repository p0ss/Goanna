# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
# Development-only recorder, installed through the control channel.
extends "res://bench.gd"

var games: Array = []
var views: Array = []
var scene := {}
var moving := false
var travel_speed := 8.0
var _travel_start := 0
var origins: Array[Vector3] = []
var directions: Array[Vector3] = []

func _ready() -> void:
	super._ready()
	views.append(get_tree().root)
	for game in games:
		game.profile_frame_work = true
		if game.ice_capture != null:
			views.append(game.ice_capture.background)
		if not views.has(game.get_viewport()):
			views.append(game.get_viewport())
	for view in views:
		RenderingServer.viewport_set_measure_render_time(view.get_viewport_rid(), true)

func start(args: Dictionary) -> Dictionary:
	if args.get("phase", "") == "move_full":
		start_travel()
	for game in games:
		game.take_work_worst()
	return super.start(args)

func _process(delta: float) -> void:
	if moving:
		var distance := float(Time.get_ticks_usec() - _travel_start) / 1000000.0 * travel_speed
		for i in games.size():
			games[i].cam.position = origins[i] + directions[i] * distance
		route_travelled = distance
	var before := _n
	super._process(delta)
	if _n > before:
		var cpu := RenderingServer.get_frame_setup_time_cpu()
		var gpu := 0.0
		for view in views:
			# Disabled auxiliary views retain their last timer value.
			if view is SubViewport and view.render_target_update_mode == SubViewport.UPDATE_DISABLED:
				continue
			var rid: RID = view.get_viewport_rid()
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		_cpu_ms[_n - 1] = cpu
		_gpu_ms[_n - 1] = gpu

func _sample_counters() -> void:
	var before := _samples.size()
	super._sample_counters()
	if _samples.size() > before:
		_samples[-1]["players"] = snapshot()
		for i in games.size():
			_samples[-1]["players"][i]["work_worst_usec"] = games[i].take_work_worst()
		_samples[-1]["video_memory_bytes"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
		_samples[-1]["draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)

func _hold_pose() -> void:
	super._hold_pose()
	if moving:
		_hold = false

func snapshot() -> Array:
	var result := []
	for game in games:
		var settings := {}
		for entry in game.ui.SETTINGS:
			if entry[2] not in game.ui.TEXT_SETTING_KINDS:
				settings[entry[1]] = game.ui._setting_value(entry[1], -1.0)
		result.append({"status": game.client.status(), "render": game.client.render_stats(),
			"features": game.render_feature_state(),
			"work_usec": game.frame_work_usec.duplicate(),
			"poll_budget_ms": game.get_meta("benchmark_poll_budget_ms",
				game.player_slot.poll_budget_ms if game.player_slot != null else -1),
			"underwater": game.underwater, "wetness": game.wetness,
			"time_of_day": scene.get("time", 0.5),
			"settings": settings, "msaa": game.get_viewport().msaa_3d,
			"screen_aa": game.get_viewport().screen_space_aa,
			"position": [game.cam.position.x, game.cam.position.y, game.cam.position.z],
			"viewport": [game.get_viewport().get_visible_rect().size.x,
				game.get_viewport().get_visible_rect().size.y]})
	return result

# Read outside measured frames. Weather tracing and material inspection can
# be appreciably more expensive than the ordinary counter snapshot.
func scene_evidence() -> Array:
	var result := []
	for game in games:
		var entry := {"eye_node": game.client.node_name_at(game.cam.position),
			"centre_node": game.client.node_name_at(Vector3(-72, float(scene.get("probe_y", 61)), 378)),
			"carried_light_energy": game.headlight.light_energy,
			"sun_in_view": false,
			"grass_material": game.client.has_meta("goanna_grass_material"),
			"cloud_height": game.cloud_height,
			"cloud_style": game.sky_mat.get_shader_parameter("cloud_style"),
			"cloud_volume_allocated": game.cloud_body_texture != null,
			"grass_parameters": game.client.get_meta("goanna_grass_parameters", {})}
		var sun_dir: Vector3 = game.sky_mat.get_shader_parameter("sun_dir")
		var sun_point: Vector3 = game.cam.global_position + sun_dir * 1000.0
		entry["sun_in_view"] = not game.cam.is_position_behind(sun_point) and game.get_viewport().get_visible_rect().has_point(game.cam.unproject_position(sun_point))
		var particles = preload("res://player_context.gd").find(game, "goanna_particles")
		if particles != null:
			entry["precipitation"] = particles.precipitation()
			entry["weather"] = particles.weather.debug_state()
		result.append(entry)
	return result

var feature_baselines: Array = []

func set_feature_variant(disabled: Array) -> bool:
	var defaults: Dictionary = preload("res://render_features.gd").DEFAULTS
	for key in disabled:
		if not defaults.has(key):
			return false
	for i in games.size():
		var game: Node = games[i]
		for key in defaults:
			game.ui._apply_setting(key, 0.0 if key in disabled else float(feature_baselines[i][key]))
		if scene.has("msaa"):
			game.get_viewport().msaa_3d = int(scene.msaa)
		if scene.has("screen_aa"):
			game.get_viewport().screen_space_aa = int(scene.screen_aa)
	return true

func configure_scene(config: Dictionary, settings: Dictionary) -> void:
	scene = config
	feature_baselines.clear()
	travel_speed = float(scene.get("travel_speed", 8))
	for game in games:
		for key in settings:
			game.ui._apply_setting(key, float(settings[key]))
		feature_baselines.append(game.render_features.duplicate())
		if scene.has("msaa"):
			game.get_viewport().msaa_3d = int(scene.msaa)
		if scene.has("screen_aa"):
			game.get_viewport().screen_space_aa = int(scene.screen_aa)
		if scene.has("poll_budget_ms"):
			var budget: float = float(scene.poll_budget_ms) / games.size()
			game.client.set_poll_budget_ms(budget)
			game.set_meta("benchmark_poll_budget_ms", budget)
		if scene.has("mesh_workers"):
			game.client.set_mesh_threads(maxi(1, int(scene.mesh_workers) / games.size()))
		if scene.has("wetness"):
			game.set_meta("benchmark_wetness", scene.wetness)
		if scene.get("rain", false):
			var particles = preload("res://player_context.gd").find(game, "goanna_particles")
			particles.inject_test_spawner("rain")

func prepare(spread := false) -> bool:
	moving = false
	origins.clear()
	directions.clear()
	for i in games.size():
		var game: Node = games[i]
		var angle := TAU * i / games.size() + deg_to_rad(float(scene.get("angle_degrees", 0)))
		var direction := Vector3(sin(angle), 0, cos(angle))
		var centre := Vector3(-72, float(scene.get("eye_y", 64)), 378)
		var origin := centre + direction * (float(scene.get("spread_radius", 192)) if spread else float(scene.get("radius", 8)))
		origins.append(origin)
		directions.append(direction)
		game.fly_mode = true
		if not await game.teleport_to(origin):
			return false
		game.cam.position = origin
		game.cam.look_at(origin + direction * 100.0 + Vector3(0, -35, 0) if spread else Vector3(centre.x, float(scene.get("target_y", 64)), centre.z))
		game.pitch = game.cam.rotation_degrees.x
		game.yaw = game.cam.rotation_degrees.y
		game.client.set_time_of_day_override(float(scene.get("time", 0.5)))
		game.client.set_player_pose(origin, game.pitch, game.yaw)
		if game.player_slot != null:
			game.player_slot.waiting.hide()
	if scene.get("face_sun", false):
		await get_tree().process_frame
		await get_tree().process_frame
		for game in games:
			var sun_dir: Vector3 = game.sky_mat.get_shader_parameter("sun_dir")
			game.cam.look_at(game.cam.position + sun_dir * 1000.0)
			game.pitch = game.cam.rotation_degrees.x
			game.yaw = game.cam.rotation_degrees.y
			game.client.set_player_pose(game.cam.position, game.pitch, game.yaw)
	return true

func start_travel() -> void:
	_travel_start = Time.get_ticks_usec()
	moving = true
	_hold = false
