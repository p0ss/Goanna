# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
## A shader pack's second outputs: the colortex targets its translated
## geometry programs write besides the colour, which its screen space chain
## reads (docs/design/iris-compat.md, rung 6). Godot draws one colour per
## pass, so each such target gets a SubViewport of its own, sharing the
## world, whose camera follows the player's and sees only the node surfaces.
## The translated shaders read that camera's cull mask (the five bits from
## PASS_SHIFT carry the colortex plus one) and draw that output, raw, in
## place of their colour; GoannaIrisEffect copies each viewport into its
## colortex where it would otherwise clear it. One more geometry pass per
## target is the cost. game/main.gd makes one when a pack has both halves.
extends Node

# NODE_SURFACE_LAYER in src/goanna_client_internal.h: the node meshes, near
# and far, carry it beside layer 1.
const NODE_LAYER := 1 << 14
# iris::kGbuffersPassShift in src/iris/iris_gbuffers.h.
const PASS_SHIFT := 15
# Past this many targets the frame is mostly second outputs.
const MAX_TARGETS := 8

var source_camera: Camera3D
var effect: GoannaIrisEffect
# colortex -> [SubViewport, Camera3D, optional low SubViewport, Camera3D]
var targets := {}


## The colortex numbers given second outputs, for report().
func colortex_list() -> PackedInt32Array:
	var out := PackedInt32Array()
	for ct in targets:
		out.push_back(ct)
	return out


func initialise(view_camera: Camera3D, iris_effect: GoannaIrisEffect, gbuffers: GoannaIrisGbuffers) -> void:
	source_camera = view_camera
	effect = iris_effect
	# Raw values: no sky, fog, glow or exposure, a linear tonemap and an HDR
	# target, so what the pack wrote is what the chain reads. The clear is
	# (0, 0, 0, 0), as the effect clears a colortex.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	var attributes := CameraAttributesPractical.new()
	attributes.auto_exposure_enabled = false
	attributes.dof_blur_far_enabled = false
	attributes.dof_blur_near_enabled = false
	# The world's Compositor runs the pack's chain; these must not.
	var no_effects := Compositor.new()
	for ct in gbuffers.second_targets():
		if not effect.reads_colortex(ct):
			continue
		var packed := gbuffers.packed_target(ct)
		var passes := 0
		for existing in targets.values():
			passes += 2 if existing[2] != null else 1
		if passes + (2 if packed else 1) > MAX_TARGETS:
			push_warning("Goanna Iris: more than %d second outputs, colortex%d left cleared" % [MAX_TARGETS, ct])
			continue
		var viewport := SubViewport.new()
		viewport.name = "IrisColortex%d" % ct
		viewport.use_hdr_2d = true
		viewport.transparent_bg = true
		viewport.world_3d = source_camera.get_world_3d()
		viewport.positional_shadow_atlas_size = 0
		viewport.handle_input_locally = false
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(viewport)
		var camera := Camera3D.new()
		camera.cull_mask = NODE_LAYER | ((ct + 1) << PASS_SHIFT)
		camera.environment = env
		camera.attributes = attributes
		camera.compositor = no_effects
		viewport.add_child(camera)
		camera.current = true
		var low_viewport: SubViewport
		var low_camera: Camera3D
		if packed:
			low_viewport = SubViewport.new()
			low_viewport.name = "IrisColortex%dLow" % ct
			low_viewport.use_hdr_2d = true
			low_viewport.transparent_bg = true
			low_viewport.world_3d = source_camera.get_world_3d()
			low_viewport.positional_shadow_atlas_size = 0
			low_viewport.handle_input_locally = false
			low_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			add_child(low_viewport)
			low_camera = Camera3D.new()
			# Bit 13 selects the other eleven-bit groups; no meshes use it.
			low_camera.cull_mask = camera.cull_mask | (1 << 13)
			low_camera.environment = env
			low_camera.attributes = attributes
			low_camera.compositor = no_effects
			low_viewport.add_child(low_camera)
			low_camera.current = true
		targets[ct] = [viewport, camera, low_viewport, low_camera]
	# A target only the water program writes is kept only where water is
	# in front: opaque terrain cannot leave it clear in its pass, as
	# Minecraft's masked write would.
	for ct in gbuffers.translucent_targets():
		if targets.has(ct):
			effect.set_gbuffers_translucent(ct, true)
	# After the player's camera has moved this frame.
	process_priority = 100


func _process(_delta: float) -> void:
	if not is_instance_valid(source_camera) or targets.is_empty():
		return
	var main_viewport := source_camera.get_viewport()
	var size := main_viewport.get_visible_rect().size * main_viewport.scaling_3d_scale
	var pixels := Vector2i(maxi(1, roundi(size.x)), maxi(1, roundi(size.y)))
	for ct in targets:
		for offset in [0, 2]:
			var viewport: SubViewport = targets[ct][offset]
			if viewport == null:
				continue
			var camera: Camera3D = targets[ct][offset + 1]
			viewport.size = pixels
			camera.global_transform = source_camera.global_transform
			camera.projection = source_camera.projection
			camera.fov = source_camera.fov
			camera.size = source_camera.size
			camera.near = source_camera.near
			camera.far = source_camera.far
			camera.keep_aspect = source_camera.keep_aspect
			camera.h_offset = source_camera.h_offset
			camera.v_offset = source_camera.v_offset
			# Looked up every frame: a resize makes a new texture.
			var texture := RenderingServer.texture_get_rd_texture(viewport.get_texture().get_rid())
			if offset == 0:
				effect.set_gbuffers_target(ct, texture)
			else:
				effect.set_gbuffers_low_target(ct, texture)


func _exit_tree() -> void:
	if effect != null:
		for ct in targets:
			effect.set_gbuffers_target(ct, RID())
			effect.set_gbuffers_low_target(ct, RID())
