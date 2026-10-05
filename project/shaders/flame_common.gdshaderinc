// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// The flame material, shared by flame.gdshader (the flame itself) and
// flame_glow.gdshader (its halo and heat shimmer, a second pass).
// docs/fire-material.md.
//
// The game's own animated art is the flame. GoannaClient swaps albedo_tex
// to the frame a vanilla client shows (showAnimationFrame), and an
// entity's sheet moves its cell rectangle, so the frames and their timing
// are the game's. This file only modulates them: how opaque each texel is,
// how hot it reads, and a flicker that runs up the flame between frames.
#ifndef GOANNA_FLAME_COMMON
#define GOANNA_FLAME_COMMON

#include "res://shaders/underwater.gdshaderinc"

// The art's own ramp (goanna_flame.cpp, measureFlameRamp), linear colour:
// the luminance range heat is spread over, and the mean colour of its
// brightest and darkest texels. Soul fire's art is cyan, so its ramp is.
uniform vec2 heat_range = vec2(0.05, 0.6);
uniform vec3 core_colour = vec3(1.0, 0.85, 0.45);
uniform vec3 tip_colour = vec3(0.6, 0.12, 0.02);
uniform float flame_energy = 1.2;
// An entity sprite sheet: CUSTOM0 holds the cell's rectangle in UV, so
// heights and texel reads stay inside the frame shown. Node tiles are one
// frame per texture and leave this off.
uniform bool cell_rect = false;
// The upright sprite's two quads are culled from behind, as upstream draws
// them; a firelike or mesh flame is drawn from both sides.
uniform bool single_sided = false;

// The node animation clock, seconds in [0, 60) (step_node_animation). The
// flicker frequencies are whole cycles a minute, so it does not jump when
// the clock wraps, and pinning the clock for a capture pins the flicker.
global uniform float goanna_node_anim_time;

const float FLAME_TAU = 6.28318530718;

float flame_max3(vec3 c) {
	return max(max(c.r, c.g), max(c.b, 1e-4));
}

// A phase per fire, from where it stands, so a row of flames does not pulse
// in step.
float flame_phase(vec3 world) {
	vec3 node = floor(world + vec3(0.5));
	return fract(sin(dot(node, vec3(12.9898, 78.233, 37.719))) * 43758.5453) * FLAME_TAU;
}

// Brightness flicker at height h (0 at the base, 1 at the top of the
// frame): three waves travelling up the flame, larger at the tips. About
// one, never below 0.8.
float flame_flicker(float h, float phase) {
	float t = goanna_node_anim_time;
	float w = 0.09 * sin(t * FLAME_TAU * 59.0 / 60.0 - h * 5.0 + phase)
			+ 0.05 * sin(t * FLAME_TAU * 113.0 / 60.0 - h * 9.0 + phase * 1.9)
			+ 0.03 * sin(t * FLAME_TAU * 167.0 / 60.0 + phase * 0.6);
	return 1.0 + w * (0.35 + 0.65 * h);
}

// One texel's alpha, by its place in the cell; nothing outside it.
float flame_texel_alpha(ivec2 p, ivec2 origin, ivec2 dim) {
	if (p.x < 0 || p.y < 0 || p.x >= dim.x || p.y >= dim.y)
		return 0.0;
	return texelFetch(albedo_tex, origin + p, 0).a;
}

// The art's alpha read bilinearly at `local` (0 to 1 across the cell):
// where an opaque texel meets an empty one this falls to a half at the
// shared edge. Four reads of the base level, whatever the sampler.
float flame_soft_alpha(vec2 local, ivec2 origin, ivec2 dim) {
	vec2 tc = local * vec2(dim) - 0.5;
	ivec2 i = ivec2(floor(tc));
	vec2 f = fract(tc);
	float a00 = flame_texel_alpha(i, origin, dim);
	float a10 = flame_texel_alpha(i + ivec2(1, 0), origin, dim);
	float a01 = flame_texel_alpha(i + ivec2(0, 1), origin, dim);
	float a11 = flame_texel_alpha(i + ivec2(1, 1), origin, dim);
	return mix(mix(a00, a10, f.x), mix(a01, a11, f.x), f.y);
}

// Coverage: the cut-out's own shape, with each edge texel fading over its
// outer half instead of stopping at a hard step. Inside the flame every
// texel is whole, so close up it is still the art's pixels. Once a texel
// is smaller than a pixel the mip's own alpha takes over, which is soft
// already and does not sparkle.
float flame_coverage(vec2 local, ivec2 origin, ivec2 dim, float mip_alpha, float texels_per_px) {
	float soft = smoothstep(0.45, 0.95, flame_soft_alpha(local, origin, dim));
	return mix(soft, mip_alpha, smoothstep(0.75, 1.5, texels_per_px));
}

// How hot a texel reads: its own brightness against the art's range,
// cooling towards the top of the frame.
float flame_heat(vec3 art, float h) {
	float lum = dot(art, vec3(0.2126, 0.7152, 0.0722));
	float heat = clamp((lum - heat_range.x) / max(heat_range.y - heat_range.x, 1e-3), 0.0, 1.0);
	return clamp(heat * 1.1 - 0.3 * h + 0.12, 0.0, 1.0);
}

// The colour a texel is drawn with, in linear HDR. The art's own hue, pulled
// towards the tip colour where it is cool and towards a whitened core
// colour where it is hot; brightness rises steeply with heat, so the core
// blooms and the tips stay dim.
vec3 flame_colour(vec3 art, float heat) {
	vec3 art_hue = art / flame_max3(art);
	vec3 tip_hue = tip_colour / flame_max3(tip_colour);
	vec3 core_hue = mix(core_colour / flame_max3(core_colour), vec3(1.0), 0.35);
	vec3 hue = mix(tip_hue, art_hue, smoothstep(0.0, 0.5, heat));
	hue = mix(hue, core_hue, 0.65 * smoothstep(0.55, 1.0, heat));
	float value = flame_max3(art);
	return hue * value * mix(0.75, 2.8, heat * heat) * flame_energy;
}

// What the water between the eye and the flame leaves of its light, with
// Godot's fog share taken back out for a pass that has fog disabled.
vec3 flame_underwater(vec3 vertex, mat4 inv_view, vec3 eye, bool fogged) {
	vec3 keep = goanna_underwater_keep(vertex, inv_view, eye);
	if (!fogged && goanna_eye_underwater > 0.5)
		keep *= exp(-goanna_water_surface.y * min(length(vertex), 64.0));
	return keep;
}

#endif
