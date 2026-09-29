# SPDX-License-Identifier: LGPL-2.1-or-later
# Offline sky composition and visibility checks, using the production shader.
# From the developer control channel: add this node and await capture(path).
# The fixture owns its viewport and never connects to a server.
extends Node

var viewport: SubViewport
var material: ShaderMaterial
var camera: Camera3D


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	var sky := Sky.new()
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/sky.gdshader")
	sky.sky_material = material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 0.46
	environment.tonemap_white = 4.0
	environment.glow_enabled = true
	environment.glow_intensity = 0.3
	world.environment = environment
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.fov = 75.0
	viewport.add_child(camera)
	camera.look_at(Vector3(-0.48, 0.45, -0.60))
	camera.current = true
	# A silhouette makes the horizon legible without pretending to be a world.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 192:
		var angles := [i * TAU / 192.0, (i + 1) * TAU / 192.0]
		var points: Array[Vector3] = []
		for angle: float in angles:
			var height := 3.0 + sin(angle * 7.0) * 2.5 + sin(angle * 19.0) * 1.0
			points.append(Vector3(cos(angle) * 100.0, height, sin(angle) * 100.0))
		for point in [points[0], points[1], points[0] - Vector3(0, 100, 0),
				points[1], points[1] - Vector3(0, 100, 0), points[0] - Vector3(0, 100, 0)]:
			surface.add_vertex(point)
	var ridge := MeshInstance3D.new()
	ridge.mesh = surface.commit()
	var silhouette := StandardMaterial3D.new()
	silhouette.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	silhouette.cull_mode = BaseMaterial3D.CULL_DISABLED
	silhouette.albedo_color = Color(0.025, 0.035, 0.055)
	ridge.material_override = silhouette
	viewport.add_child(ridge)


func defaults() -> void:
	var parameters := {
		"sky_top": Color(0.27, 0.37, 0.51),
		"sky_horizon": Color(0.045, 0.065, 0.11),
		"ground_color": Color(0.015, 0.022, 0.04),
		"haze_color": Color(0.045, 0.065, 0.11),
		"haze_twilight": 0.0, "air_beam": Vector3.ZERO,
		"sun_dir": Vector3(0, -1, 0), "sun_visible": false,
		"moon_visible": false, "clouds_enabled": false,
		"star_opacity": 0.4117647, "star_color": Color(0.92, 0.92, 1.0),
		"star_density": 0.35, "star_scale": 1.0,
		"celestial_phase": 0.0, "celestial_time": 3.0, "night_sky_strength": 1.0,
		"galaxy_relief": 1.0, "constellation_strength": 1.0,
	}
	for key in parameters:
		material.set_shader_parameter(key, parameters[key])


func shot(path: String) -> Image:
	# Multiple frames let the radiance and glow buffers settle after a change.
	for i in 4:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(path)
	return image


func capture(directory: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(directory)
	camera.look_at(Vector3(-0.48, 0.45, -0.60))
	defaults()
	material.set_shader_parameter("galaxy_relief", 0.0)
	material.set_shader_parameter("constellation_strength", 0.0)
	await shot(directory.path_join("smooth.png"))
	material.set_shader_parameter("galaxy_relief", 1.0)
	await shot(directory.path_join("relief.png"))
	material.set_shader_parameter("constellation_strength", 1.0)
	await shot(directory.path_join("night.png"))
	material.set_shader_parameter("celestial_time", 4.0)
	await shot(directory.path_join("twinkle.png"))
	material.set_shader_parameter("star_opacity", 0.0)
	var hidden := await shot(directory.path_join("hidden.png"))
	material.set_shader_parameter("star_opacity", 1.0)
	material.set_shader_parameter("star_density", 0.0)
	var zero_count := await shot(directory.path_join("zero-count.png"))
	material.set_shader_parameter("star_density", 0.35)
	material.set_shader_parameter("star_scale", 0.0)
	var zero_scale := await shot(directory.path_join("zero-scale.png"))
	var gates_pass := hidden.get_data() == zero_count.get_data() \
			and hidden.get_data() == zero_scale.get_data()
	defaults()
	material.set_shader_parameter("sun_dir", Vector3(0.85, -0.15, -0.50).normalized())
	material.set_shader_parameter("sky_top", Color(0.20, 0.25, 0.42))
	material.set_shader_parameter("sky_horizon", Color(0.38, 0.24, 0.28))
	material.set_shader_parameter("haze_color", Color(0.42, 0.24, 0.18))
	material.set_shader_parameter("haze_twilight", 0.7)
	material.set_shader_parameter("air_beam", Vector3(0.26, 0.09, 0.025))
	material.set_shader_parameter("star_opacity", 0.32)
	await shot(directory.path_join("twilight.png"))
	defaults()
	material.set_shader_parameter("clouds_enabled", true)
	material.set_shader_parameter("cloud_style", 0)
	material.set_shader_parameter("cloud_coverage", 0.65)
	material.set_shader_parameter("cloud_layers", preload("res://cloud_layers.gd").build(
			120.0, 16.0, 0.65, 0.0, 0.0, 0))
	material.set_shader_parameter("cloud_color", Color(0.09, 0.11, 0.16))
	material.set_shader_parameter("cloud_ambient_color", Vector3(0.015, 0.02, 0.03))
	material.set_shader_parameter("cloud_beam", Vector3.ZERO)
	await shot(directory.path_join("clouds.png"))
	defaults()
	material.set_shader_parameter("sun_dir", Vector3.UP)
	material.set_shader_parameter("sky_top", Color(0.36, 0.55, 0.85))
	material.set_shader_parameter("sky_horizon", Color(0.72, 0.80, 0.90))
	material.set_shader_parameter("star_opacity", 0.0)
	var day := await shot(directory.path_join("day.png"))
	material.set_shader_parameter("night_sky_strength", 0.0)
	var day_without := await shot(directory.path_join("day-without.png"))
	var result := {"visibility_gates": gates_pass,
		"day_unchanged": day.get_data() == day_without.get_data(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"godot": Engine.get_version_info().string}
	var file := FileAccess.open(directory.path_join("checks.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t") + "\n")
	return result
