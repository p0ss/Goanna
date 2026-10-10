// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: a flame, drawn from the game's own animated art. docs/systems/fire-material.md.
//
// Blended, not cut out: each edge texel fades over its outer half, and the
// cooler tips let some of what is behind them through. Unshaded, because a
// flame is its own light; the light it casts on the world is the node
// lamp's, which keeps its own flicker. Godot's fog applies as to any
// blended surface. No depth is written and no shadow is
// cast, so the depth prepass, SSAO and the shadow maps never see a flame:
// before this material the cut-out flame cast a sun shadow of its own.
//
// The halo and the heat shimmer are flame_glow.gdshader, this material's
// next pass, which adds rather than blends.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_disable;

#include "res://shaders/flame_common.gdshaderinc"

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
	vec4 art = texture(albedo_tex, UV);
	float coverage = flame_coverage(local, origin, dim, art.a, texels_per_px);
	// After the reads that take derivatives, which need the whole quad.
	if (coverage < 0.004 || (single_sided && !FRONT_FACING))
		discard;
	float h = clamp(1.0 - local.y, 0.0, 1.0);
	float flicker = flame_flicker(h, flame_phase(world_pos));
	float heat = clamp(flame_heat(art.rgb, h) + (flicker - 1.0) * 0.6, 0.0, 1.0);
	vec3 colour = flame_colour(art.rgb, heat) * flicker;
	ALBEDO = colour * COLOR.rgb * flame_underwater(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD, true);
	// The hot core hides what is behind it; the cool tips let a third of it
	// through.
	ALPHA = coverage * mix(0.65, 0.97, heat);
}
