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

void fragment() {
	vec4 tile = texture(albedo_tex, UV);
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
	// A second, shallow layer of the authored inclusions moves within the
	// block as the view changes. It never distorts the silhouette or water.
	vec2 parallax = vec2(dot(VIEW, tu), dot(VIEW, tv)) * 0.06;
	vec3 inclusions = texture(albedo_tex, UV + parallax).rgb;
	ALBEDO = mix(tile.rgb, inclusions, 0.25) * COLOR.rgb;
	ROUGHNESS = mix(1.0, clamp(1.0 - smoothness + 0.12 * frost, 0.12, 0.65), roughness_strength);
	// Ice's dielectric response is weaker than glass. Frost broadens it.
	SPECULAR = 0.23 * specular_strength;
	AO = mix(1.0, pack.b, ao_strength * 0.35);
	BACKLIGHT = ALBEDO * (0.22 + 0.25 * frost) * sss_strength;
	// Grazing paths cross more ice. Frost keeps a denser scattering body,
	// while the clearer patches admit a restrained view of what is behind.
	float facing = abs(dot(geometric_normal, VIEW));
	float coverage = mix(0.68, 0.9, frost);
	coverage = 1.0 - pow(1.0 - coverage, 1.0 / max(facing, 0.3));
	float transmission = solid ? 0.0 : (1.0 - coverage) * goanna_ice_transmission_ready;
	// The capture is HDR and ungraded. It is incident light, so adding it
	// through emission avoids lighting a photographed surface for a second time.
	EMISSION = texture(goanna_ice_background, SCREEN_UV).rgb * transmission;
	ALBEDO *= 1.0 - transmission;
}
