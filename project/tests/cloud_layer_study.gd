# SPDX-License-Identifier: LGPL-2.1-or-later
# Offline production-shader study, invoked inside a headless control client.
extends Node

const Layers := preload("res://cloud_layers.gd")
var viewport: SubViewport
var material: ShaderMaterial
var camera: Camera3D
var body: NoiseTexture3D


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(960, 540)
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
	environment.tonemap_exposure = 0.7
	world.environment = environment
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.fov = 85.0
	viewport.add_child(camera)
	camera.current = true
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.frequency = 0.02
	body = NoiseTexture3D.new()
	body.width = 128
	body.height = 96
	body.depth = 128
	body.seamless = true
	body.normalize = true
	body.noise = noise
	material.set_shader_parameter("cloud_body_tex", body)
	material.set_shader_parameter("sun_dir", Vector3(0.45, 0.7, -0.55).normalized())
	material.set_shader_parameter("cloud_beam", Vector3(0.8, 0.75, 0.65))
	material.set_shader_parameter("cloud_quality", 1)
	material.set_shader_parameter("star_opacity", 0.0)
	material.set_shader_parameter("moon_visible", false)


func shot(path: String) -> Image:
	for i in 4:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image()
	result.save_png(path)
	return result


func capture(directory: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(directory)
	if body.get_data().is_empty():
		await body.changed
	for style in 3:
		material.set_shader_parameter("cloud_style", style)
		for scenario in ["fair", "storm", "between", "above", "mountain"]:
			var ground := 2500.0 if scenario == "mountain" else 0.0
			var coverage := 0.85 if scenario == "storm" else 0.55
			var layers := Layers.build(128.0, 16.0, coverage,
					0.8 if scenario == "storm" else 0.0, ground, style)
			material.set_shader_parameter("cloud_coverage", coverage)
			material.set_shader_parameter("cloud_layers", layers)
			camera.position = Vector3(0.0, ground + 64.0, 0.0)
			var slope := 0.3
			if scenario == "between":
				camera.position.y = layers[1].x - 90.0
				slope = 0.02
			if scenario == "above":
				camera.position.y = layers[2].x + 300.0
				slope = -0.4
			camera.look_at(camera.position + Vector3(0.0, slope, -1.0))
			await shot(directory.path_join("%d-%s.png" % [style, scenario]))
	material.set_shader_parameter("clouds_enabled", false)
	var hidden := await shot(directory.path_join("hidden.png"))
	material.set_shader_parameter("clouds_enabled", true)
	material.set_shader_parameter("cloud_coverage", 0.0)
	var empty := await shot(directory.path_join("empty.png"))
	return {"hidden_matches_zero_coverage": hidden.get_data() == empty.get_data(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"godot": Engine.get_version_info().string}
