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
// The gem's inner highlight colour in rgb and its dispersion in a, for
// light(); set from goanna_gem_optics in each fragment. Flat, because an
// interpolated constant comes back a bit off, and the fire lobe's
// exponent of 900 turns that into visible pixels.
varying flat vec4 v_gem_optics;

// Gems other than diamond. A tile or item's code is mode | kind << 2: mode
// 1 masks gem pixels out of a host (ore, tool, armour), mode 2 is a solid
// gem block; kind indexes these tables. Kind 0 is diamond, whose constants
// are the ones this file had before the table existed, so a diamond renders
// as it did. The C++ side that names a texture's kind is gemTextureCode.
//
// Masks were measured on the games' own art in linear colour
// (docs/materials.md): emerald, amethyst and mese project the pixel's
// chroma onto the gem's own direction; quartz is white on red netherrack,
// so it is bright and colourless instead. Optics are the real stones where
// there is one: refractive index, dispersion as a share of diamond's, and
// absorption that leaves each gem its body colour. Mese is fictional and
// borrows citrine's.
const int GEM_KINDS = 5;
const vec3 GEM_KEY[5] = { vec3(0.0), vec3(-0.654, 0.266, -0.708),
		vec3(0.533, -0.24, 0.811), vec3(0.074, 0.078, -0.994), vec3(0.0) };
const vec2 GEM_MASK[5] = { vec2(0.0), vec2(0.015, 0.055),
		vec2(0.02, 0.08), vec2(0.10, 0.18), vec2(0.0, 0.08) };
// The refractive indices 2.42, 1.58, 1.54, 1.55 and 1.54, stored as the
// ratio refract() takes. Written as divisions so the compiler folds them
// exactly as it folded diamond's old literal 1.0 / 2.42: a table lookup
// divided at run time differs in the last bit, and the ore recess's wall
// march turns that into different steps.
const float GEM_ETA[5] = { 1.0 / 2.42, 1.0 / 1.58, 1.0 / 1.54, 1.0 / 1.55, 1.0 / 1.54 };
const float GEM_SPREAD[5] = { 0.025, 0.008, 0.008, 0.009, 0.008 };
// Godot's F0 is 0.16 * SPECULAR squared: diamond sits at the dielectric
// ceiling, the others near 0.05, which is SPECULAR 0.56.
const float GEM_SPECULAR[5] = { 1.0, 0.56, 0.53, 0.54, 0.53 };
const vec3 GEM_ABSORB[5] = { vec3(0.28, 0.07, 0.025), vec3(0.30, 0.05, 0.28),
		vec3(0.10, 0.30, 0.06), vec3(0.03, 0.05, 0.40), vec3(0.04, 0.04, 0.035) };
const vec3 GEM_SCATTER[5] = { vec3(0.24, 0.62, 0.70), vec3(0.10, 0.60, 0.25),
		vec3(0.55, 0.25, 0.70), vec3(0.70, 0.62, 0.10), vec3(0.60, 0.60, 0.62) };
const vec3 GEM_INNER[5] = { vec3(0.45, 0.8, 1.0), vec3(0.45, 1.0, 0.55),
		vec3(0.85, 0.5, 1.0), vec3(1.0, 0.9, 0.4), vec3(0.9, 0.9, 1.0) };
// How much of what lies behind the gem it lets through: in the ore recess,
// between its inner planes, and as an item's transparency. Diamond is clear;
// mese and nether quartz are nearly opaque, milky stones, and letting the
// rock through turned them the colour of the rock.
const float GEM_CLARITY[5] = { 1.0, 0.6, 0.55, 0.35, 0.25 };
const vec3 GEM_ORE_ABSORB[5] = { vec3(0.55, 0.10, 0.035), vec3(0.55, 0.08, 0.45),
		vec3(0.20, 0.50, 0.10), vec3(0.05, 0.08, 0.60), vec3(0.08, 0.08, 0.07) };

int goanna_gem_mode(int code) {
	return code & 3;
}

int goanna_gem_kind(int code) {
	return clamp(code >> 2, 0, GEM_KINDS - 1);
}

vec4 goanna_gem_optics(int code) {
	int kind = goanna_gem_kind(code);
	return vec4(GEM_INNER[kind], GEM_SPREAD[kind]);
}

// Refracted travel through a bounded crystal, measured in source texels.
// This is an apparent interior: its rear plane is material, not a hole in
// the world. In particular an ore never samples scenery behind its stone.
vec2 goanna_diamond_travel(vec3 eye, float thickness, int code) {
	vec3 ray = refract(-normalize(eye), vec3(0.0, 0.0, 1.0), GEM_ETA[goanna_gem_kind(code)]);
	return ray.xy * thickness / max(-ray.z, 0.25);
}

// Shared optical response; the caller samples two internal planes using
// the same texture and mask as its outer surface. Missing gem samples are
// backed with the original colour so a ray cannot drag wood or stone in.
// Returns the inner plane's tangent normal; all light still comes through
// light(), including the small scattering term.
vec3 goanna_diamond_interior(int code, vec3 front, vec3 middle, vec3 rear,
		float thickness, float amount, float footprint, vec2 travel,
		inout vec3 colour, out vec3 scatter) {
	float resolved = 1.0 - smoothstep(0.5, 1.5, footprint);
	float weight = amount * diamond_strength * diamond_interior_strength * resolved;
	int kind = goanna_gem_kind(code);
	vec3 absorption = exp(-GEM_ABSORB[kind] * thickness);
	// Distinct planes remain crisp. Absorption deepens the rear plane's
	// turquoise; the pale front contribution keeps a clear surface skin.
	vec3 inside = mix(middle, rear * absorption, 0.65);
	colour = mix(colour, mix(front, inside, 0.92 * GEM_CLARITY[kind]), weight);
	float shade = dot(rear, vec3(0.2126, 0.7152, 0.0722));
	float angle = floor(shade * 12.0) * 2.39996 + 1.1;
	vec2 slope = vec2(cos(angle), sin(angle)) * 0.32;
	// Thickness controls transmitted light, independently of the surface
	// normal. Thin rims let more through than the darker crystal centres.
	scatter = absorption * GEM_SCATTER[kind] * weight * sss_strength;
	return normalize(vec3((slope + travel * 0.04) * normal_strength, 1.0));
}

float goanna_diamond_mask(vec3 colour, int code) {
	int mode = goanna_gem_mode(code);
	if (mode == 0)
		return 0.0;
	if (mode == 2)
		return 1.0;
	// Linear colour, and only ever evaluated on a gem-named texture, so an
	// unrelated material of the same colour never opts in.
	int kind = goanna_gem_kind(code);
	if (kind == 0) {
		// Cyan diamonds stand apart from grey host stone and brown handles.
		// Literal edges, as before the table: folded at compile time, where
		// edges read from it are divided at run time and differ in the last
		// bit, which moves the ore recess's wall march.
		float cyan = min(colour.g, colour.b) - colour.r;
		return smoothstep(0.015, 0.055, cyan);
	}
	vec2 edge = GEM_MASK[kind];
	float luma = dot(colour, vec3(0.2126, 0.7152, 0.0722));
	vec3 chroma = colour - luma;
	if (kind == 4)
		return smoothstep(edge.x, edge.y, luma - 2.0 * length(chroma));
	return smoothstep(edge.x, edge.y, dot(chroma, GEM_KEY[kind]));
}

float goanna_diamond_surface(int code, vec3 colour, float mask, float footprint,
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
	specular = mix(specular, clamp(specular_strength, 0.0, 1.0)
			* GEM_SPECULAR[goanna_gem_kind(code)], amount);
	return amount * resolved * roughness_strength * specular_strength;
}

// A restrained approximation of diamond fire: three neighbouring internal
// reflection directions separate the colours of a highlight. This is a
// bounded secondary lobe, not emission or screen refraction. It receives
// the same light colour, shadows, range and underground gates as the BRDF.
vec3 goanna_diamond_fire(vec3 n, vec3 l, vec3 v, vec3 axis, float spread) {
	vec3 h = normalize(l + v);
	vec3 tangent = axis - n * dot(axis, n);
	tangent /= max(length(tangent), 0.001);
	vec3 facet = normalize(n + tangent * 0.22);
	vec3 red = normalize(facet - tangent * spread);
	vec3 blue = normalize(facet + tangent * spread);
	vec3 alignment = clamp(vec3(dot(red, h), dot(facet, h), dot(blue, h)), 0.0, 1.0);
	vec3 fire = exp((alignment - 1.0) * 900.0);
	return fire * max(dot(n, l), 0.0) * 1.2;
}
