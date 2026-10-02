// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Hair drawn by the shader, on a skin's hair texels (_s green byte 12, see
// entity_common.gdshaderinc). Six rounds of authored _n and _s for the
// player's hair read as wood, decking, bevels, grubby fibre or plastic: at
// sixteen map pixels per art texel a strand is two map pixels wide, the
// mipmaps average it away, and what is left is grain. Here the strands are
// made per fragment at the screen's own frequency, so close up they are as
// fine as the pixels allow and at a distance they fade, by the UV
// derivatives, to the plain texel and the anisotropic sheen
// (direct_light.gdshaderinc), never to aliasing.
//
// The strand runs along the image's vertical on every face of these
// atlases (entity_common.gdshaderinc), so across a strand is U and along it
// is V, the tip toward plus V on a side face and minus V on a top. What this
// gives back is shading only, every term a multiplier with a mean near 1 that
// fades to exactly 1: the art's texel colours stay the base.
//
// - Strands, hair_strand_density across an art texel, each a small
//   cylinder (its normal tilts across it), with its own brightness and
//   shine, and a darker gap beside it. A column of art texels is a lock:
//   its strands bend together along a slow wave, and are seeded by the
//   column, so the locks differ.
// - Clumps, two to a texel, a coarser bulge and gap over the strands.
// - Fibres, finer again and faint, between the strands.
// - Ragged tips: where the texel next along the strand is not hair, or is
//   hair standing lower, each strand stops at its own length short of the
//   texel's tip edge, thinning as it goes, and the gaps show the shadow
//   inside the hair.
// - The shadow under a lock: where the texel toward the root is hair
//   standing higher, a ragged shadow falls from that edge.
// - Per strand jitter of the highlight's shift, so the band breaks up.

// Strands across one art texel.
uniform float hair_strand_density : hint_range(2.0, 24.0) = 10.0;
// How far the strands' brightness swings, and how dark their gaps are.
uniform float hair_strand_contrast : hint_range(0.0, 1.0) = 0.5;
// How far a lock's strands bend sideways along it, in texels.
uniform float hair_strand_wave : hint_range(0.0, 0.2) = 0.01;
// How far back from a tip edge the shortest strand stops, in texels.
uniform float hair_tip_depth : hint_range(0.0, 1.0) = 0.45;
// The darkness past a strand's end.
uniform float hair_tip_shadow : hint_range(0.0, 1.0) = 0.3;
// The drop in stored height below which a step between two hair texels
// is no tip: the player's hair has levels 0.14 and 0.28 apart, and with
// every step a tip each texel ended in a dark ragged band, like bark.
uniform float hair_tip_step : hint_range(0.0, 0.5) = 0.1;
// The darkness of the shadow under a higher lock, at its edge.
uniform float hair_lock_shadow : hint_range(0.0, 1.0) = 0.3;

// pcg3d (Jarzynski and Olano, "Hash Functions for GPU Rendering", 2020).
float goanna_hair_hash(ivec3 p) {
	uvec3 v = uvec3(p) * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return float(v.x & 16777215u) / 16777216.0;
}

// Smooth value noise along one axis, 0 to 1.
float goanna_hair_noise(float x, int seed) {
	float i = floor(x);
	float f = x - i;
	float a = goanna_hair_hash(ivec3(int(i), seed, 91));
	float b = goanna_hair_hash(ivec3(int(i) + 1, seed, 91));
	return mix(a, b, f * f * (3.0 - 2.0 * f));
}

bool goanna_hair_is_hair(vec2 uv) {
	return abs(textureLod(spec_tex, uv, 0.0).g * 255.0 - 12.0) < 0.5;
}

// uv is the drawn (marched) UV, dx and dy its derivatives, rect the face's
// UV rectangle, cap whether this is a top or bottom face. Out: shade, the
// multiplier on the albedo; tilt, the strand's normal tilt across it in
// tangent space X; shift, radians added to the highlight's tilt; shine,
// the multiplier on the hair highlight.
void goanna_hair_strands(vec2 uv, vec2 dx, vec2 dy, vec4 rect, bool cap,
		out float shade, out float tilt, out float shift, out float shine) {
	vec2 a = uv * art_texels;
	vec2 cell = floor(a);
	vec2 f = a - cell;
	float tip_v = cap ? -1.0 : 1.0;
	// 0 at the texel's root edge, 1 at its tip edge.
	float along = cap ? 1.0 - f.y : f.y;
	int col = int(cell.x);
	int row = int(cell.y);
	float cs = goanna_hair_hash(ivec3(col, 7, 3));

	// The size of a pixel, in art texels across and along the strand, and
	// from that how much of each layer survives: a layer fades out as its
	// period nears two pixels, so nothing finer than the screen is drawn.
	float px_across = length(vec2(dx.x, dy.x)) * art_texels.x;
	float px_along = length(vec2(dx.y, dy.y)) * art_texels.y;
	float density = hair_strand_density;
	float fade_s = 1.0 - smoothstep(0.18, 0.45, px_across * density);
	float fade_f = 1.0 - smoothstep(0.18, 0.45, px_across * density * 2.3);
	float fade_c = 1.0 - smoothstep(0.18, 0.45, px_across * 2.0);
	// Tips and lock shadows are shaped along the strand at about a fifth of
	// a texel.
	float fade_t = 1.0 - smoothstep(0.12, 0.4, px_along);

	// The lock's bend, shared by its strands.
	float wave = hair_strand_wave * sin(a.y * 1.7 + cs * 6.2832);

	// Strands.
	float xs = (a.x + wave) * density;
	float sid = floor(xs);
	float s = xs - sid - 0.5;
	int id = int(sid);
	float r_bright = goanna_hair_hash(ivec3(id, 1, 0));
	float r_shift = goanna_hair_hash(ivec3(id, 2, 0));
	float r_shine = goanna_hair_hash(ivec3(id, 3, 0));
	float r_len = goanna_hair_hash(ivec3(id, row, 4));
	float r_shadow = goanna_hair_hash(ivec3(id, row, 5));
	// Brightness changes along a strand too, or every strand is a ruled
	// line and the whole reads as grain.
	float run = goanna_hair_noise(a.y * 1.3 + r_bright * 17.0, id);

	// The neighbours along the strand, at their texel centres.
	vec2 here = (cell + 0.5) / art_texels;
	vec2 tip_uv = (cell + vec2(0.5, 0.5 + tip_v)) / art_texels;
	vec2 root_uv = (cell + vec2(0.5, 0.5 - tip_v)) / art_texels;
	float own_h = textureLod(normal_tex, here, 0.0).a;
	bool tip_in = all(greaterThanEqual(tip_uv, rect.xy)) && all(lessThanEqual(tip_uv, rect.zw));
	bool root_in = all(greaterThanEqual(root_uv, rect.xy)) && all(lessThanEqual(root_uv, rect.zw));
	// A side face's tip edge with no face below it in the image is the end
	// of the hair; a top's runs on over the back of the head.
	float tip = cap ? 0.0 : 1.0;
	if (tip_in) {
		tip = goanna_hair_is_hair(tip_uv)
				? clamp((own_h - textureLod(normal_tex, tip_uv, 0.0).a - hair_tip_step) / 0.12, 0.0, 1.0)
				: 1.0;
	}
	float under = 0.0;
	if (root_in && goanna_hair_is_hair(root_uv))
		under = clamp((textureLod(normal_tex, root_uv, 0.0).a - own_h - hair_tip_step) / 0.12, 0.0, 1.0);

	// Each strand stops at its own length short of a tip edge, thinning
	// over its last part, and past its end is the gap's shadow.
	float len = 1.0 - hair_tip_depth * r_len * tip;
	float end = smoothstep(len, len - 0.18, along);
	float taper = mix(1.0, mix(0.15, 1.0, end), tip * fade_t);
	float half_w = 0.5 * taper;
	float gap = smoothstep(half_w - 0.17, half_w, abs(s));
	float c = hair_strand_contrast;
	float strand = mix(1.0 - 0.5 * c, 1.0 + 0.4 * c, r_bright) * mix(1.0 - 0.15 * c, 1.0 + 0.1 * c, run);
	strand *= 1.0 - 0.75 * c * gap;
	// Its mean over a texel with no tip, so the layer fades to 1, not to a
	// darker or lighter texel.
	float strand_mean = (1.0 - 0.05 * c) * (1.0 - 0.025 * c) * (1.0 - 0.75 * c * 0.2);

	// Fibres between the strands, faint.
	float xf = (a.x + wave) * density * 2.3 + cs * 5.0;
	float fid = floor(xf);
	float fibre = 1.0 + 0.12 * c * (goanna_hair_hash(ivec3(int(fid), 6, 0)) - 0.5)
			- 0.1 * c * smoothstep(0.3, 0.5, abs(xf - fid - 0.5));
	float fibre_mean = 1.0 - 0.1 * c * 0.2;

	// Clumps, two to a texel, offset per column.
	float xc = (a.x + wave * 1.5) * 2.0 + cs;
	float cid = floor(xc);
	float cc = xc - cid - 0.5;
	float clump = (1.0 + 0.16 * c * (goanna_hair_hash(ivec3(int(cid), 8, 0)) - 0.5))
			* (1.0 - 0.4 * c * smoothstep(0.36, 0.5, abs(cc)));
	float clump_mean = 1.0 - 0.4 * c * 0.14;

	// The ragged shadow under a higher lock, from the root edge down.
	float reach = mix(0.22, 0.5, r_shadow);
	float lock_shadow = 1.0 - hair_lock_shadow * under * fade_t * (1.0 - smoothstep(0.0, reach, along));

	shade = mix(1.0, strand / strand_mean, fade_s)
			* mix(1.0, fibre / fibre_mean, fade_f)
			* mix(1.0, clump / clump_mean, fade_c)
			* lock_shadow;
	// Past a strand's end, the deeper hair's shadow even where the strands
	// themselves have faded out.
	shade *= mix(1.0, mix(1.0 - hair_tip_shadow, 1.0, end), tip * fade_t * (1.0 - fade_s * (1.0 - gap)));

	// Each strand a cylinder across, each clump a broader bulge.
	tilt = fade_s * 0.6 * (2.0 * s / max(taper, 0.15)) * (1.0 - gap)
			+ fade_c * 0.25 * (2.0 * cc);
	tilt = clamp(tilt, -0.8, 0.8);
	shift = (r_shift - 0.5) * 0.35 * fade_s;
	shine = mix(1.0, mix(0.3, 1.7, r_shine) * mix(0.6, 1.4, run) * (1.0 - gap), fade_s);
	shine *= mix(1.0, end, tip * fade_t);
	shine *= lock_shadow;
}
