// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// A crystal-filled recess below the existing ore face. The visible cyan
// mask defines its walls; all rays terminate in local rock, never scenery.
uniform float diamond_ore_transmission : hint_range(0.0, 1.0) = 1.0;
uniform float diamond_ore_depth : hint_range(0.0, 4.0) = 2.5;

vec3 goanna_ore_rock(vec2 uv, int layer, vec2 dx, vec2 dy, vec3 fallback) {
	vec3 here = textureGrad(albedo_array, vec3(uv, float(layer)), dx, dy).rgb;
	if (goanna_diamond_mask(here, 1) < 0.1)
		return here;
	// The combined ore art has no rock under its painted gems. Extend the
	// nearest surrounding stone into that hidden backing, preserving the
	// pack's stone colour and texel detail instead of another cyan plane.
	for (int radius = 1; radius <= 4; radius++) {
		for (int side = 0; side < 4; side++) {
			vec2 direction = side < 2 ? vec2(side == 0 ? -1.0 : 1.0, 0.0)
					: vec2(0.0, side == 2 ? -1.0 : 1.0);
			vec3 rock = textureGrad(albedo_array,
					vec3(uv + direction * float(radius) / 16.0, float(layer)), dx, dy).rgb;
			if (goanna_diamond_mask(rock, 1) < 0.1)
				return rock;
		}
	}
	// Nonstandard art with no nearby rock stays backed, never a hole.
	return vec3(dot(fallback, vec3(0.2126, 0.7152, 0.0722))) * 0.45;
}

vec3 goanna_ore_interior(vec2 uv, int layer, vec2 dx, vec2 dy,
		vec3 eye, vec3 normal, vec3 front, float footprint) {
	vec3 ray = refract(-normalize(eye), normalize(normal), 1.0 / 2.42);
	vec2 travel = ray.xy * diamond_ore_depth / max(-ray.z, 0.2) / 16.0;
	vec2 at = uv;
	float path = diamond_ore_depth;
	// Intersect the mask's side walls before the recessed rear plane.
	for (int step = 1; step <= 8; step++) {
		float fraction = float(step) / 8.0;
		at = uv + travel * fraction;
		vec3 wall = textureGrad(albedo_array, vec3(at, float(layer)), dx, dy).rgb;
		if (goanna_diamond_mask(wall, 1) < 0.1) {
			path *= fraction;
			break;
		}
	}
	vec3 rock = goanna_ore_rock(at, layer, dx, dy, front);
	vec3 transmitted = rock * exp(-vec3(0.55, 0.10, 0.035) * path);
	float fresnel = 0.17 + 0.83 * pow(1.0 - clamp(dot(normalize(eye), normalize(normal)), 0.0, 1.0), 5.0);
	float clear = (1.0 - fresnel) * diamond_ore_transmission
			* (1.0 - smoothstep(0.5, 1.5, footprint));
	return mix(front, transmitted, clear);
}
