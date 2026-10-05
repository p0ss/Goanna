// SPDX-License-Identifier: LGPL-2.1-or-later
// An opaque aperture onto eight virtual star planes. Depth remains at the
// real sheet: neither parallax nor dark pixels expose geometry underneath.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

#include "res://shaders/portal_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float parallax_depth : hint_range(0.0, 6.0) = 2.8;

void fragment() {
	vec4 source = texture(albedo_tex, UV);
	if (source.a < 0.5) discard;
	vec3 u, v;
	portal_axes(portal_normal, u, v);
	vec2 p = vec2(dot(portal_world, u), dot(portal_world, v));
	vec3 eye = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	// Ray/plane intersections, the same tangent-space displacement as the
	// relief march. A bounded grazing slope avoids an unstable horizon.
	vec2 ray = vec2(dot(eye, u), dot(eye, v)) / max(abs(dot(eye, portal_normal)), 0.18);
	float phase = portal_time() * 0.104719755;
	vec3 space = vec3(0.001, 0.004, 0.008);
	for (int i = 0; i < 8; i++) {
		float layer = float(i);
		float depth = (0.12 + layer * layer * 0.065) * parallax_depth;
		vec2 plane = p - ray * depth;
		float angle = layer * 2.399963;
		mat2 rotation = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle)));
		vec2 field = rotation * plane * (3.5 + layer * 1.65) + vec2(layer * 37.1);
		vec2 cell = floor(field), local = fract(field);
		vec2 seed = portal_hash(cell + layer * 17.0);
		vec2 centre = 0.18 + 0.64 * seed;
		float distance_to_star = length(local - centre);
		float radius = mix(0.024, 0.075, seed.x * seed.x);
		float footprint = max(length(fwidth(field)), 0.001);
		float star = 1.0 - smoothstep(max(0.0, radius - footprint * 0.5),
			radius + footprint * 0.5, distance_to_star);
		// Preserve energy as a star gets smaller than a pixel, then fade
		// unresolved cells instead of turning the far field into glitter.
		star *= min(1.0, radius * radius * 4.0 / (footprint * footprint));
		star *= 1.0 - smoothstep(0.4, 1.2, footprint);
		star *= step(0.48, seed.y);
		float halo = exp(-distance_to_star * distance_to_star / 0.018) * 0.075;
		halo *= step(0.9, seed.y) * (1.0 - smoothstep(0.4, 1.2, footprint));
		float twinkle = 0.82 + 0.18 * sin(phase * (4.0 + layer) + seed.x * 6.283185);
		vec3 colour = mix(vec3(0.15, 0.65, 0.70), vec3(0.80, 0.95, 0.57), seed.x);
		colour = mix(colour, vec3(0.68, 0.50, 1.0), step(0.86, seed.x) * 0.6);
		space += colour * (star + halo) * twinkle * (1.8 / (1.0 + layer * 0.32));
		if (i == 3) {
			float cloud = portal_noise(plane * 0.6 + vec2(cos(phase), sin(phase)) * 0.2);
			space += vec3(0.008, 0.025, 0.035) * pow(cloud, 3.0);
		}
	}
	ALBEDO = space * goanna_underwater_keep(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD);
}
