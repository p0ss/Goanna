// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// The opaque scene behind a diamond item, sampled through a thin slab.
// Included by entity_common.gdshaderinc only under
// GOANNA_DIAMOND_TRANSMISSION, which entity_diamond.gdshader and
// entity_diamond_double_sided.gdshader define; goanna_entities.cpp gives
// those to gem items and armour. See docs/systems/materials.md, "Diamond
// surfaces".

// Godot's opaque scene colour and depth, read through the bent ray.
uniform sampler2D diamond_scene : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D diamond_depth : hint_depth_texture, filter_nearest, repeat_disable;
// 0 keeps the plain alpha blended gem, 1 composes the refracted scene in
// fully. Default only in play; project/studies/diamond_study.gd sets it to compare.
uniform float diamond_refraction : hint_range(0.0, 1.0) = 1.0;

// The screen UV to read the scene through. A ray refracted by eta and one
// straight through are both run thickness deep into the gem and projected;
// the difference between their screen positions is the shift. Cheap, and
// right enough for a slab a few texels thick.

vec2 goanna_diamond_screen_ray(vec3 position, vec3 eye, vec3 normal,
		float thickness, vec2 screen_uv, vec2 pixel, mat4 projection,
		mat4 inverse_projection, float eta) {
	vec3 ray = refract(-eye, normal, eta);
	// Each leg is divided by its cosine to the normal, so both reach the
	// same back face; the floor of 0.2 stops a grazing ray running away.
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
