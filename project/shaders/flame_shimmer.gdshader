// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: a flame's heat shimmer, the next pass of flame_glow.gdshader.
// docs/fire-material.md.
//
// The shimmer bends what is seen through and just above the flame. It adds
// the difference between the opaque scene at a displaced point and at this
// pixel, never the opaque scene itself: Godot's screen texture is taken
// before the blended pass, so it holds no water and no glass, and drawing
// it would cut a window through a lake behind the fire. Added as a
// difference, water and glass behind the flame keep their colour and only
// the opaque detail through them wavers.
//
// A difference is only right once per pixel. A firelike node is six quads
// and a field of fire puts dozens behind one pixel, and each layer added
// its own difference, with its own waves, on top of the last: n layers
// moved a pixel n times as far as the bend, past black where the scene
// behind was bright and into cyan and green where only its red channel
// went under. So each pixel takes the shimmer of the first layer drawn
// there and no other: the stencil test passes only where this pass has
// not yet written, and the pass writes where it draws. Pixels the shimmer
// does not touch are discarded before they can claim the stencil.
//
// It is small (a few pixels at two nodes), fades out by 24 nodes, and is
// off where goanna_render_fire_shimmer is 0 (Lowest and Low): every quad
// is then collapsed to a point, so nothing is drawn and no pixel reads the
// screen. Godot still copies the screen for a material that could read it,
// as it already does for water and glass.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// 7 is this pass's own mark; nothing else in Goanna uses the stencil.
stencil_mode read, write, compare_not_equal, 7;

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

varying vec4 cell;
varying vec3 world_pos;

void vertex() {
	cell = cell_rect ? CUSTOM0 : vec4(0.0, 0.0, 1.0, 1.0);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (goanna_render_fire_shimmer < 0.5) {
		// Every vertex to one point: no area, so no fragment at all.
		VERTEX = vec3(0.0);
	} else if (shimmer_rise > 0.0 && UV.y < 0.5) {
		// The top edge of the frame goes up, its texture coordinate with
		// it, so the art stays where it was and the quad gains empty space
		// above the flame for the shimmer to bend.
		VERTEX.y += shimmer_rise;
		UV.y -= shimmer_rise;
		world_pos.y += shimmer_rise;
	}
}

void fragment() {
	float dist = length(VERTEX);
	if (dist >= shimmer_range || (single_sided && !FRONT_FACING))
		discard;
	vec2 local = (UV - cell.xy) / max(cell.zw, vec2(1e-6));
	float h = 1.0 - local.y;
	vec2 frame_uv = cell.xy + clamp(local, 0.0, 1.0) * cell.zw;
	// The flame's own body, soft: the shimmer is seen through it only as
	// much as it lets through.
	float body = local.y >= 0.0 ? textureLod(albedo_tex, frame_uv, 1.0).a : 0.0;
	// Where the shimmer is: above the base of the flame, under the top of
	// the stretched quad, and only in columns with flame below.
	float top = 1.0 + shimmer_rise;
	float w = smoothstep(0.1, 0.55, h) * (1.0 - smoothstep(top - 0.35, top, h));
	float below = max(textureLod(albedo_tex, cell.xy + clamp(local + vec2(0.0, 0.3), 0.0, 1.0) * cell.zw, 2.0).a,
			textureLod(albedo_tex, cell.xy + clamp(local + vec2(0.0, 0.65), 0.0, 1.0) * cell.zw, 2.0).a);
	w *= smoothstep(0.05, 0.35, below);
	w *= 1.0 - smoothstep(shimmer_range * 0.5, shimmer_range, dist);
	w *= 1.0 - body * 0.8;
	if (w <= 0.002)
		discard;
	float t = goanna_node_anim_time;
	float ph = flame_phase(world_pos);
	vec2 wave = vec2(
			sin(world_pos.y * 9.0 - t * FLAME_TAU * 71.0 / 60.0 + world_pos.x * 3.1 + ph),
			sin(world_pos.y * 6.5 - t * FLAME_TAU * 53.0 / 60.0 + world_pos.z * 3.7 + ph * 1.3));
	// The same bend in the world at any distance: a pixel offset that
	// shrinks as the flame does.
	vec2 offset = wave * shimmer_strength * w / max(dist, 0.75) * 2.0;
	vec3 bent = textureLod(screen_tex, SCREEN_UV + offset, 0.0).rgb;
	vec3 here = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	// Already seen through any water: no absorption on top.
	ALBEDO = bent - here;
	ALPHA = 1.0;
}
