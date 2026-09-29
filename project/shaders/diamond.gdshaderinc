// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Diamond's polished planes follow the art's colour plateaus. No animated
// noise: a glint moves because the eye or a real light moves. Keep the
// authored relief and add a small, constant tilt to each coloured plane.
uniform float diamond_strength : hint_range(0.0, 1.0) = 1.0;
uniform float diamond_interior_strength : hint_range(0.0, 1.0) = 1.0;
varying float v_diamond;
varying vec3 v_diamond_axis;
varying vec3 v_diamond_inner_normal;
varying vec3 v_diamond_scatter;
varying float v_diamond_interior;

// Refracted travel through a bounded crystal, measured in source texels.
// This is an apparent interior: its rear plane is material, not a hole in
// the world. In particular an ore never samples scenery behind its stone.
vec2 goanna_diamond_travel(vec3 eye, float thickness) {
	vec3 ray = refract(-normalize(eye), vec3(0.0, 0.0, 1.0), 1.0 / 2.42);
	return ray.xy * thickness / max(-ray.z, 0.25);
}

// Shared optical response; the caller samples two internal planes using
// the same texture and mask as its outer surface. Missing gem samples are
// backed with the original colour so a ray cannot drag wood or stone in.
// Returns the inner plane's tangent normal; all light still comes through
// light(), including the small scattering term.
vec3 goanna_diamond_interior(vec3 front, vec3 middle, vec3 rear,
		float thickness, float amount, float footprint, vec2 travel,
		inout vec3 colour, out vec3 scatter) {
	float resolved = 1.0 - smoothstep(0.5, 1.5, footprint);
	float weight = amount * diamond_strength * diamond_interior_strength * resolved;
	vec3 absorption = exp(-vec3(0.28, 0.07, 0.025) * thickness);
	// Distinct planes remain crisp. Absorption deepens the rear plane's
	// turquoise; the pale front contribution keeps a clear surface skin.
	vec3 inside = mix(middle, rear * absorption, 0.65);
	colour = mix(colour, mix(front, inside, 0.92), weight);
	float shade = dot(rear, vec3(0.2126, 0.7152, 0.0722));
	float angle = floor(shade * 12.0) * 2.39996 + 1.1;
	vec2 slope = vec2(cos(angle), sin(angle)) * 0.32;
	// Thickness controls transmitted light, independently of the surface
	// normal. Thin rims let more through than the darker crystal centres.
	scatter = absorption * vec3(0.24, 0.62, 0.70) * weight * sss_strength;
	return normalize(vec3((slope + travel * 0.04) * normal_strength, 1.0));
}

float goanna_diamond_mask(vec3 colour, int mode) {
	if (mode == 0)
		return 0.0;
	if (mode == 2)
		return 1.0;
	// Linear colour. Cyan diamonds stand apart from grey host stone and
	// brown handles. This is only evaluated on diamond-named textures,
	// including mineral overlays; unrelated blue materials never opt in.
	float cyan = min(colour.g, colour.b) - colour.r;
	return smoothstep(0.015, 0.055, cyan);
}

float goanna_diamond_surface(vec3 colour, float mask, float footprint,
		inout vec3 normal_map, inout float roughness, inout float metallic,
		inout float specular) {
	float amount = mask * diamond_strength;
	if (amount <= 0.001)
		return 0.0;
	// A colour plateau is one facet, however many source pixels it spans.
	// The twelve discrete slopes avoid a field of rounded bumps. Derivatives
	// soften unresolved facets instead of letting them sparkle at distance.
	float shade = dot(colour, vec3(0.2126, 0.7152, 0.0722));
	float facet = floor(shade * 12.0);
	float angle = mod(facet * 2.39996, TAU);
	vec2 slope = vec2(cos(angle), sin(angle)) * 0.16;
	float resolved = 1.0 - smoothstep(0.35, 1.25, footprint);
	vec3 n = normal_map * 2.0 - 1.0;
	n = normalize(n + vec3(slope * amount * resolved * normal_strength, 0.0));
	normal_map = n * 0.5 + 0.5;
	float polish = mix(1.0, mix(0.28, 0.13, resolved), roughness_strength);
	roughness = mix(roughness, polish, amount);
	metallic = mix(metallic, 0.0, amount);
	// Godot's direct BRDF uses F0 = 0.16 * SPECULAR squared. A diamond
	// is close to its upper dielectric limit; it is not coloured metal.
	specular = mix(specular, clamp(specular_strength, 0.0, 1.0), amount);
	return amount * resolved * roughness_strength * specular_strength;
}

// A restrained approximation of diamond fire: three neighbouring internal
// reflection directions separate the colours of a highlight. This is a
// bounded secondary lobe, not emission or screen refraction. It receives
// the same light colour, shadows, range and underground gates as the BRDF.
vec3 goanna_diamond_fire(vec3 n, vec3 l, vec3 v, vec3 axis) {
	vec3 h = normalize(l + v);
	vec3 tangent = axis - n * dot(axis, n);
	tangent /= max(length(tangent), 0.001);
	vec3 facet = normalize(n + tangent * 0.22);
	vec3 red = normalize(facet - tangent * 0.025);
	vec3 blue = normalize(facet + tangent * 0.025);
	vec3 alignment = clamp(vec3(dot(red, h), dot(facet, h), dot(blue, h)), 0.0, 1.0);
	vec3 fire = exp((alignment - 1.0) * 900.0);
	return fire * max(dot(n, l), 0.0) * 1.2;
}
