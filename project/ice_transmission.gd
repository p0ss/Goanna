# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
extends Node

# An opaque ice surface can sample this view without entering the sorted
# transparent pass. Water then sees ice in its own colour/depth buffers.
const ICE_LAYER := 4
var source_camera: Camera3D
var source_environment: Environment
var client: Node
var background: SubViewport
var camera: Camera3D
var capture_environment: Environment
var check_time := 0.0
var visible_ice := false
var fracture_texture: NoiseTexture3D
var cloud_texture: NoiseTexture3D

# Shared, deterministic volumes. Ice samples these in world space, including
# below its surface, so adjoining nodes share fractures and moving views see
# internal parallax. No per-frame generation or imported texture is needed.
func _make_volume(cellular: bool) -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.seed = 7319 if cellular else 1907
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR if cellular else FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.075 if cellular else 0.045
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE if cellular else FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	var volume := NoiseTexture3D.new()
	volume.width = 128 if cellular else 64
	volume.height = volume.width
	volume.depth = volume.width
	volume.seamless = true
	volume.normalize = false
	volume.noise = noise
	return volume

func initialise(view_camera: Camera3D, environment: Environment, game_client: Node) -> void:
	source_camera = view_camera
	source_environment = environment
	client = game_client
	fracture_texture = _make_volume(true)
	cloud_texture = _make_volume(false)
	RenderingServer.global_shader_parameter_set("goanna_ice_fractures", fracture_texture)
	RenderingServer.global_shader_parameter_set("goanna_ice_clouds", cloud_texture)
	background = SubViewport.new()
	background.name = "IceBackground"
	background.use_hdr_2d = true
	background.world_3d = source_camera.get_world_3d()
	background.render_target_update_mode = SubViewport.UPDATE_DISABLED
	background.handle_input_locally = false
	add_child(background)
	camera = Camera3D.new()
	camera.cull_mask = source_camera.cull_mask & ~(ICE_LAYER | 8)
	background.add_child(camera)
	camera.current = true
	capture_environment = source_environment.duplicate()
	camera.environment = capture_environment
	RenderingServer.global_shader_parameter_set("goanna_ice_background", background.get_texture())
	RenderingServer.global_shader_parameter_set("goanna_ice_transmission_ready", 0.0)
	process_priority = 100

func _process(delta: float) -> void:
	if not is_instance_valid(source_camera):
		return
	check_time -= delta
	if check_time <= 0.0:
		check_time = 0.2
		visible_ice = false
		if not client.solid_ice():
			var planes := source_camera.get_frustum()
			for ice in get_tree().get_nodes_in_group("goanna_ice"):
				if not ice.is_visible_in_tree() or not ice.mesh:
					continue
				var box: AABB = ice.global_transform * ice.get_aabb()
				var outside := false
				for plane in planes:
					var all_out := true
					for corner in 8:
						if not plane.is_point_over(box.get_endpoint(corner)):
							all_out = false
							break
					if all_out:
						outside = true
						break
				if not outside:
					visible_ice = true
					break
	background.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible_ice else SubViewport.UPDATE_DISABLED
	RenderingServer.global_shader_parameter_set("goanna_ice_transmission_ready", 1.0 if visible_ice else 0.0)
	if not visible_ice:
		return
	var size := source_camera.get_viewport().get_visible_rect().size
	background.size = Vector2i(maxi(1, roundi(size.x * 0.5)), maxi(1, roundi(size.y * 0.5)))
	camera.global_transform = source_camera.global_transform
	camera.fov = source_camera.fov
	camera.near = source_camera.near
	camera.far = source_camera.far
	camera.keep_aspect = source_camera.keep_aspect
	# Transmission is already lit. The main view owns grading and the fog
	# between the eye and the ice, so neither is baked into this texture.
	capture_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	capture_environment.tonemap_exposure = 1.0
	capture_environment.adjustment_enabled = false
	capture_environment.glow_enabled = false
	capture_environment.fog_enabled = false
	capture_environment.volumetric_fog_enabled = false
	capture_environment.sdfgi_enabled = false
	capture_environment.ssao_enabled = false
	capture_environment.ssil_enabled = false
	capture_environment.ssr_enabled = false
	capture_environment.ambient_light_energy = source_environment.ambient_light_energy
	capture_environment.ambient_light_color = source_environment.ambient_light_color
	capture_environment.background_energy_multiplier = source_environment.background_energy_multiplier

func _exit_tree() -> void:
	# Definitions belong to the application (project.godot); values belong to
	# this world. Unbind before freeing the viewport/volumes, but keep the
	# globals registered for shaders and materials retained across scene loads.
	RenderingServer.global_shader_parameter_set("goanna_ice_transmission_ready", 0.0)
	RenderingServer.global_shader_parameter_set("goanna_ice_background", null)
	RenderingServer.global_shader_parameter_set("goanna_ice_fractures", null)
	RenderingServer.global_shader_parameter_set("goanna_ice_clouds", null)
