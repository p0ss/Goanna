// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: a flame's halo, the next pass of flame.gdshader.
// docs/systems/fire-material.md.
//
// Added, not blended, so two flames and a flame over water or glass keep
// what is under them. The halo is a soft fringe of the core's colour
// around the art, from a coarser mip of its alpha. It is never negative,
// so halos that overlap only add up to a brighter glow.
//
// The heat shimmer is flame_shimmer.gdshader, this pass's own next pass.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;

#include "res://shaders/flame_common.gdshaderinc"

uniform float halo_strength = 0.3;

varying vec4 cell;
varying vec3 world_pos;

void vertex() {
	cell = cell_rect ? vec4(CUSTOM0.xy, CUSTOM0.zw - CUSTOM0.xy) : vec4(0.0, 0.0, 1.0, 1.0);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ivec2 size = textureSize(albedo_tex, 0);
	ivec2 origin = ivec2(cell.xy * vec2(size) + 0.5);
	ivec2 dim = max(ivec2(cell.zw * vec2(size) + 0.5), ivec2(1));
	vec2 local = (UV - cell.xy) / max(cell.zw, vec2(1e-6));
	vec2 px = local * vec2(dim);
	float texels_per_px = max(length(dFdx(px)), length(dFdy(px)));
	// After the derivatives, which need every pixel of the quad.
	if (single_sided && !FRONT_FACING)
		discard;
	vec2 frame_uv = cell.xy + clamp(local, 0.0, 1.0) * cell.zw;
	float mip_alpha = textureLod(albedo_tex, frame_uv, 0.0).a;
	float coverage = flame_coverage(local, origin, dim, mip_alpha, texels_per_px);
	float h = 1.0 - local.y;
	float flicker = flame_flicker(clamp(h, 0.0, 1.0), flame_phase(world_pos));
	vec3 keep = flame_underwater(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD, false);
	vec3 core_hue = core_colour / flame_max3(core_colour);

	// Where the blurred art reaches past the sharp art.
	float halo = textureLod(albedo_tex, frame_uv, 1.6).a;
	// On a sprite sheet that coarse read also reaches the next frame up,
	// whose base is solid flame: without this the top of every frame
	// glowed as a flat box (seen 2026-10-10 on a burning zombie). The
	// halo fades out over the five texels at the cell's top and bottom.
	if (cell_rect)
		halo *= smoothstep(1.0, 5.0, min(local.y, 1.0 - local.y) * float(dim.y));
	float glow = max(halo - coverage, 0.0) * halo_strength * flame_energy * flicker;
	if (glow < 0.002)
		discard;
	ALBEDO = core_hue * glow * keep;
	ALPHA = 1.0;
}
