// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Ice stays in the opaque depth pass. A separate background view supplies
// transmission, including water, without depending on transparent sorting.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D spec_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
uniform bool solid = false;
uniform float normal_strength = 1.0;
uniform float roughness_strength = 1.0;
uniform float specular_strength = 1.0;
uniform float sss_strength = 1.0;
uniform float ao_strength = 1.0;
global uniform sampler2D goanna_ice_background;
global uniform float goanna_ice_transmission_ready;
global uniform sampler3D goanna_ice_fractures : repeat_enable, filter_linear;
global uniform sampler3D goanna_ice_clouds : repeat_enable, filter_linear;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float cloud(vec3 p) {
	return texture(goanna_ice_clouds, p / 11.0).r;
}

float fracture(vec3 p) {
	// Distance between the two nearest cells is smallest at their boundary.
	// A slow warp breaks up straight polygon edges without tile repetitions.
	vec3 warp = vec3(cloud(p), cloud(p + 3.7), cloud(p - 4.1)) - 0.5;
	return texture(goanna_ice_fractures, (p + warp * 0.65) / 12.0).r;
}

vec3 cell_hash(vec3 p) {
	return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
			dot(p, vec3(269.5, 183.3, 246.1)),
			dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
}

float bubbles(vec3 p) {
	// Small, sparse ellipsoids: trapped air, anchored inside the ice.
	vec3 q = p * vec3(9.0, 5.0, 9.0);
	vec3 seed = cell_hash(floor(q));
	vec3 centre = 0.25 + seed * 0.5;
	float radius = mix(0.045, 0.115, seed.y);
	return (1.0 - smoothstep(radius * 0.45, radius,
			length(fract(q) - centre))) * step(0.82, seed.x);
}

void fragment() {
	vec3 geometric_normal = NORMAL;
	// Recover the face's frame; Luanti's non-array meshes have no tangents.
	vec2 dx = dFdx(UV), dy = dFdy(UV);
	float det = dx.x * dy.y - dx.y * dy.x;
	vec3 tu = vec3(0.0), tv = vec3(0.0);
	if (abs(det) > 1e-10) {
		tu = normalize((dFdx(VERTEX) * dy.y - dFdy(VERTEX) * dx.y) / det);
		tv = normalize((dFdy(VERTEX) * dx.x - dFdx(VERTEX) * dy.x) / det);
	}
	vec4 pack = has_normal ? texture(normal_tex, UV) : vec4(0.5, 0.5, 1.0, 1.0);
	vec2 slope = (pack.rg * 2.0 - 1.0) * normal_strength;
	// Keep the large facets tied to the visible tile as well as the pack's
	// fine normals. A companion may be much smoother than the jagged albedo.
	vec2 texel = 1.0 / vec2(textureSize(albedo_tex, 0));
	vec3 luminance = vec3(0.2126, 0.7152, 0.0722);
	float left = dot(texture(albedo_tex, UV - vec2(texel.x, 0.0)).rgb, luminance);
	float right = dot(texture(albedo_tex, UV + vec2(texel.x, 0.0)).rgb, luminance);
	float up = dot(texture(albedo_tex, UV - vec2(0.0, texel.y)).rgb, luminance);
	float down = dot(texture(albedo_tex, UV + vec2(0.0, texel.y)).rgb, luminance);
	vec2 facets = clamp(vec2(left - right, up - down) / (2.0 * texel)
			* 0.09, vec2(-0.45), vec2(0.45));
	slope += facets * normal_strength;
	NORMAL = normalize(geometric_normal * sqrt(max(1.0 - dot(slope, slope), 0.1))
			+ tu * slope.x + tv * slope.y);
	float smoothness = has_spec ? texture(spec_tex, UV).r : 0.72;
	float frost = 1.0 - smoothstep(0.65, 0.92, smoothness);
	// Sample a bounded optical layer along a refracted ray, rather than
	// sliding a second copy of a painted tile. This is internal structure,
	// not a measurement of the full thickness of a connected ice formation.
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(geometric_normal, 0.0)).xyz);
	vec3 incident = normalize(world_pos - CAMERA_POSITION_WORLD);
	vec3 ray = refract(incident, world_normal, 1.0 / 1.31);
	float facing = max(abs(dot(world_normal, ray)), 0.35);
	float path = 1.15 / facing;
	float step_length = path / 24.0;
	float remaining = 1.0;
	vec3 scattered = vec3(0.0);
	float footprint = max(length(dFdx(world_pos)), length(dFdy(world_pos)));
	float crack_width = 0.012 + min(footprint * 0.04, 0.035);
	for (int i = 0; i < 24; i++) {
		float depth = (float(i) + 0.5) * step_length;
		vec3 p = world_pos + ray * depth;
		float c = cloud(p);
		float cracks = 1.0 - smoothstep(crack_width, crack_width + 0.024, fracture(p));
		// Some stress planes are clear and others contain air. Breaking
		// their visibility avoids outlining every cell like a paving slab.
		cracks *= smoothstep(0.40, 0.57, cloud(p * 1.9 + 7.3));
		float mist = smoothstep(0.48, 0.61, c);
		float air = bubbles(p) * (1.0 - smoothstep(0.03, 0.12, footprint));
		float density = 0.95 + mist * 1.1 + cracks * 7.0 + air * 8.0;
		float opacity = 1.0 - exp(-density * step_length);
		vec3 ice_colour = mix(vec3(0.055, 0.23, 0.32), vec3(0.52, 0.76, 0.82),
				clamp(cracks * 0.8 + mist * 0.45 + air, 0.0, 1.0));
		scattered += remaining * opacity * ice_colour;
		remaining *= 1.0 - opacity;
	}
	float surface_crack = 1.0 - smoothstep(0.012, 0.042, fracture(world_pos));
	float surface_frost = smoothstep(0.5, 0.64, cloud(world_pos)) * 0.6;
	float skin = 0.24 + surface_frost * 0.32 + surface_crack * 0.05;
	ALBEDO = (mix(scattered, vec3(0.42, 0.65, 0.73), skin)) * COLOR.rgb;
	ROUGHNESS = mix(1.0, clamp(1.0 - smoothness + 0.12 * frost + surface_frost * 0.25,
			0.12, 0.65), roughness_strength);
	SPECULAR = 0.23 * specular_strength;
	AO = mix(1.0, pack.b, ao_strength * 0.35);
	BACKLIGHT = ALBEDO * (0.22 + 0.25 * frost) * sss_strength;
	// Red light is absorbed sooner. The background remains screen-aligned:
	// arbitrary offsets would drag foreground objects across the ice edge.
	vec3 transmittance = exp(-vec3(0.65, 0.19, 0.1) * path) * remaining * (1.0 - skin);
	if (solid) {
		ALBEDO += vec3(0.24, 0.44, 0.52) * remaining;
		transmittance = vec3(0.0);
	}
	EMISSION = texture(goanna_ice_background, SCREEN_UV).rgb * transmittance
			* goanna_ice_transmission_ready;
}
