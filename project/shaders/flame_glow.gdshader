// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: a flame's halo and heat shimmer, the next pass of flame.gdshader.
// docs/fire-material.md.
//
// Added, not blended, so two flames and a flame over water or glass keep
// what is under them. The halo is a soft fringe of the core's colour
// around the art, from a coarser mip of its alpha.
//
// The shimmer bends what is seen through and just above the flame. It adds
// the difference between the opaque scene at a displaced point and at this
// pixel, never the opaque scene itself: Godot's screen texture is taken
// before the blended pass, so it holds no water and no glass, and drawing
// it would cut a window through a lake behind the fire. Added as a
// difference, water and glass behind the flame keep their colour and only
// the opaque detail through them wavers. It is small (a few pixels at two
// nodes), fades out by 24 nodes, and is off where
// goanna_render_fire_shimmer is 0 (Lowest and Low): the quads are then not
// stretched and no pixel reads the screen, though the halo is still drawn.
// Godot still copies the screen for a material that could read it, as it
// already does for water and glass.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

#include "res://shaders/flame_common.gdshaderinc"

global uniform float goanna_render_fire_shimmer;

// How far the quads are stretched up for the shimmer above the flame, in
// nodes. Only for node flames whose frame spans one node (firelike); 0
// keeps the geometry as the game made it.
uniform float shimmer_rise = 0.0;
uniform float shimmer_strength = 0.0045;
uniform float shimmer_range = 24.0;
uniform float halo_strength = 0.3;

varying vec4 cell;
varying vec3 world_pos;
varying float rise;

void vertex() {
	cell = cell_rect ? CUSTOM0 : vec4(0.0, 0.0, 1.0, 1.0);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	rise = 0.0;
	bool shimmer = goanna_render_fire_shimmer > 0.5
			&& distance(world_pos, CAMERA_POSITION_WORLD) < shimmer_range + 2.0;
	if (shimmer && shimmer_rise > 0.0 && UV.y < 0.5) {
		// The top edge of the frame goes up, its texture coordinate with
		// it, so the art stays where it was and the quad gains empty space
		// above the flame for the shimmer to bend.
		VERTEX.y += shimmer_rise;
		UV.y -= shimmer_rise;
		world_pos.y += shimmer_rise;
	}
	rise = shimmer ? shimmer_rise : 0.0;
}

void fragment() {
	ivec2 size = textureSize(albedo_tex, 0);
	ivec2 origin = ivec2(cell.xy * vec2(size) + 0.5);
	ivec2 dim = max(ivec2(cell.zw * vec2(size) + 0.5), ivec2(1));
	vec2 local = (UV - cell.xy) / max(cell.zw, vec2(1e-6));
	bool in_frame = local.y >= 0.0;
	vec2 px = local * vec2(dim);
	float texels_per_px = max(length(dFdx(px)), length(dFdy(px)));
	// After the derivatives, which need every pixel of the quad.
	if (single_sided && !FRONT_FACING)
		discard;
	vec2 frame_uv = cell.xy + clamp(local, 0.0, 1.0) * cell.zw;
	float mip_alpha = in_frame ? textureLod(albedo_tex, frame_uv, 0.0).a : 0.0;
	float coverage = in_frame ? flame_coverage(local, origin, dim, mip_alpha, texels_per_px) : 0.0;
	float h = 1.0 - local.y;
	float flicker = flame_flicker(clamp(h, 0.0, 1.0), flame_phase(world_pos));
	vec3 keep = flame_underwater(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD, false);
	vec3 core_hue = core_colour / flame_max3(core_colour);

	// Halo: where the blurred art reaches past the sharp art.
	float halo = in_frame ? textureLod(albedo_tex, frame_uv, 1.6).a : 0.0;
	vec3 add = core_hue * max(halo - coverage, 0.0) * halo_strength * flame_energy * flicker * keep;

	float dist = length(VERTEX);
	if (goanna_render_fire_shimmer > 0.5 && dist < shimmer_range) {
		// Where the shimmer is: above the base of the flame, under the top
		// of the stretched quad, and only in columns with flame below.
		float top = 1.0 + rise;
		float w = smoothstep(0.1, 0.55, h) * (1.0 - smoothstep(top - 0.35, top, h));
		float below = max(textureLod(albedo_tex, cell.xy + clamp(local + vec2(0.0, 0.3), 0.0, 1.0) * cell.zw, 2.0).a,
				textureLod(albedo_tex, cell.xy + clamp(local + vec2(0.0, 0.65), 0.0, 1.0) * cell.zw, 2.0).a);
		w *= smoothstep(0.05, 0.35, below);
		w *= 1.0 - smoothstep(shimmer_range * 0.5, shimmer_range, dist);
		// Seen through the flame body only as much as the body lets through.
		w *= 1.0 - coverage * 0.8;
		if (w > 0.002) {
			float t = goanna_node_anim_time;
			float ph = flame_phase(world_pos);
			vec2 wave = vec2(
					sin(world_pos.y * 9.0 - t * FLAME_TAU * 71.0 / 60.0 + world_pos.x * 3.1 + ph),
					sin(world_pos.y * 6.5 - t * FLAME_TAU * 53.0 / 60.0 + world_pos.z * 3.7 + ph * 1.3));
			// The same bend in the world at any distance: a pixel offset
			// that shrinks as the flame does.
			vec2 offset = wave * shimmer_strength * w / max(dist, 0.75) * 2.0;
			vec3 bent = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
			vec3 here = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
			// Already seen through any water: no absorption on top.
			add += bent - here;
		}
	}
	ALBEDO = add;
	ALPHA = 1.0;
}
