// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// One droplet of a splash (project/ui/splashes.gd): a short streak along the
// way it is flying, turned about that line to face the eye. The particles
// are aligned with their velocity (align_y), so the particle's own y axis
// is the line. Round billboards read as white bubbles coming out of the
// body, not as water thrown up off it.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, specular_schlick_ggx;

uniform vec4 colour : source_color = vec4(0.86, 0.93, 1.0, 0.8);
// Across and along, nodes, at a particle scale of 1.
uniform vec2 size = vec2(0.025, 0.1);

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	vec3 along = MODEL_MATRIX[1].xyz;
	float scale = length(along);
	along = scale > 1e-5 ? along / scale : vec3(0.0, 1.0, 0.0);
	vec3 to_eye = normalize(CAMERA_POSITION_WORLD - centre);
	vec3 side = cross(along, to_eye);
	// Flying straight at the eye: a dot, facing it.
	if (dot(side, side) < 1e-6)
		side = INV_VIEW_MATRIX[0].xyz;
	side = normalize(side);
	vec3 facing = normalize(cross(side, along));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(side * size.x * scale, 0.0),
			vec4(along * size.y * scale, 0.0),
			vec4(facing, 0.0),
			vec4(centre, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	// A rounded streak, solid down the middle and soft at the sides and the
	// ends, the tail fainter than the head.
	vec2 p = UV * 2.0 - 1.0;
	float across = 1.0 - smoothstep(0.35, 1.0, abs(p.x));
	float ends = 1.0 - smoothstep(0.6, 1.0, abs(p.y));
	float head = mix(0.55, 1.0, 1.0 - UV.y);
	ALBEDO = colour.rgb * COLOR.rgb;
	ALPHA = colour.a * COLOR.a * across * ends * head;
	ROUGHNESS = 0.08;
	SPECULAR = 0.9;
}
