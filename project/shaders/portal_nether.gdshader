// SPDX-License-Identifier: LGPL-2.1-or-later
// Translucent Nether membrane. Only the already visible opaque frame is
// refracted; a depth check rejects foreground silhouettes at the offset.
shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never;

#include "res://shaders/portal_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float refraction : hint_range(0.0, 0.05) = 0.014;
global uniform sampler3D goanna_lamp_occlusion_grid : filter_nearest, repeat_disable;
global uniform vec4 goanna_lamp_occlusion_box;

bool portal_solid(vec3 p) {
	float edge = goanna_lamp_occlusion_box.w;
	ivec3 cell = ivec3(floor(p - goanna_lamp_occlusion_box.xyz));
	if (edge < 1.0 || any(lessThan(cell, ivec3(0)))
			|| any(greaterThanEqual(cell, ivec3(int(edge))))) return false;
	return texelFetch(goanna_lamp_occlusion_grid, cell, 0).r < -0.5;
}

// Distance to neighbouring full cubes in the portal plane. An internal
// tile edge has no solid neighbour and therefore no bright grid seam.
float portal_border(vec3 p, vec3 u, vec3 v) {
	vec3 centre = floor(p + vec3(0.5));
	vec2 f = vec2(dot(p - centre, u), dot(p - centre, v));
	float d = 1.0;
	int edges = int(portal_edges + 0.5);
	if ((edges & 1) != 0 || portal_solid(centre + u)) d = min(d, 0.5 - f.x);
	if ((edges & 2) != 0 || portal_solid(centre - u)) d = min(d, 0.5 + f.x);
	if ((edges & 4) != 0 || portal_solid(centre + v)) d = min(d, 0.5 - f.y);
	if ((edges & 8) != 0 || portal_solid(centre - v)) d = min(d, 0.5 + f.y);
	return max(d, 0.0);
}

void fragment() {
	vec3 u, v;
	portal_axes(portal_normal, u, v);
	vec2 p = vec2(dot(portal_world, u), dot(portal_world, v));
	// Integer cycles in the client's 60 second animation clock, so wrapping
	// it does not make the field jump. Pinning that clock also pins the glow.
	float phase = portal_time() * 0.104719755;
	vec2 orbit = vec2(cos(phase * 3.0), sin(phase * 3.0));
	vec2 warp = vec2(portal_noise(p * 0.8 + orbit),
		portal_noise(p * 0.8 - orbit + vec2(13.7))) - 0.5;
	vec2 q = p + warp * 1.4;
	float veil = portal_noise(q * 2.4 + orbit * 0.6);
	float ribbon = pow(0.5 + 0.5 * sin(q.y * 5.0 + q.x * 2.0
		+ veil * 6.0 - phase * 12.0), 7.0);
	float border = portal_border(portal_world, u, v);
	float pulse = 0.75 + 0.25 * sin(phase * 18.0 + p.y * 1.5 + veil * 2.0);
	float rim = exp(-border * (14.0 + 3.0 * pulse)) * pulse;
	vec4 source = texture(albedo_tex, UV);
	// Keep the artwork's actual coverage, including completely clear texels.
	float opacity = source.a;
	if (opacity <= 0.0) discard;
	vec3 tint = mix(vec3(0.045, 0.003, 0.14), vec3(0.29, 0.025, 0.57), veil);
	tint = mix(tint, source.rgb, 0.18);
	vec3 glow = vec3(0.40, 0.065, 0.95) * ribbon * 0.24
		+ vec3(0.85, 0.20, 1.65) * rim;
	vec3 bend = (VIEW_MATRIX * vec4(u * warp.x + v * warp.y, 0.0)).xyz;
	vec2 offset = bend.xy * refraction * (1.0 - rim * 0.6)
		* smoothstep(0.0, 0.2, opacity);
	vec2 sample_uv = SCREEN_UV + offset;
	vec2 margin = vec2(1.5) / VIEWPORT_SIZE;
	sample_uv = clamp(sample_uv, margin, vec2(1.0) - margin);
	float depth = texture(depth_tex, sample_uv).r;
	vec4 hit = INV_PROJECTION_MATRIX * vec4(sample_uv * 2.0 - 1.0, depth, 1.0);
	// Reverse Z sky has zero depth; divide only for finite geometry.
	if (depth > 0.000001 && -hit.z / hit.w < -VERTEX.z + 0.03)
		sample_uv = SCREEN_UV;
	vec3 behind = texture(screen_tex, sample_uv).rgb;
	vec3 straight = texture(screen_tex, SCREEN_UV).rgb;
	vec3 keep = goanna_underwater_keep(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD);
	// Blend against the actual framebuffer, which includes earlier transparent
	// draws. Replacing it with the screen copy would erase those objects. Only
	// the difference between bent and straight opaque samples is added here;
	// at zero refraction this is ordinary alpha blending. Transparent objects
	// transmit without distortion because the screen copy does not hold them.
	// Both screen samples are already absorbed. Attenuate only the sheet's
	// own radiance, not that difference or the framebuffer behind it.
	vec3 distortion = (behind - straight) * (1.0 - opacity);
	// Unshaded radiance goes through ALBEDO; Godot ignores EMISSION here.
	ALBEDO = (tint + glow) * keep + distortion / max(opacity, 0.0001);
	ALPHA = opacity;
}
