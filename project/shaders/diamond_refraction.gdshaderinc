// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// The opaque scene behind a diamond item, sampled through a thin slab.
uniform sampler2D diamond_scene : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D diamond_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform float diamond_refraction : hint_range(0.0, 1.0) = 1.0;

vec2 goanna_diamond_screen_ray(vec3 position, vec3 eye, vec3 normal,
		float thickness, vec2 screen_uv, vec2 pixel, mat4 projection,
		mat4 inverse_projection, float eta) {
	vec3 ray = refract(-eye, normal, eta);
	vec3 bent = position + ray * thickness / max(-dot(ray, normal), 0.2);
	vec3 straight = position - eye * thickness / max(dot(eye, normal), 0.2);
	vec4 a = projection * vec4(bent, 1.0);
	vec4 b = projection * vec4(straight, 1.0);
	vec2 shift = (a.xy / a.w - b.xy / b.w) * 0.5;
	// Bound the approximation and fade near the screen edge rather than
	// smearing the last screen texel over the crystal.
	shift *= min(1.0, 0.035 / max(length(shift), 0.0001));
	vec2 edge = min(screen_uv, 1.0 - screen_uv);
	shift *= smoothstep(0.0, 0.04, min(edge.x, edge.y));
	vec2 uv = clamp(screen_uv + shift, pixel, 1.0 - pixel);
	float depth = textureLod(diamond_depth, uv, 0.0).r;
	vec4 scene = inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	// A bent lookup must not drag foreground objects behind the crystal.
	if (depth > 0.000001 && -scene.z / scene.w <= -position.z + 0.002)
		uv = screen_uv;
	return uv;
}
