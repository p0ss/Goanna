// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#ifndef GOANNA_CLIMATE_INC
#define GOANNA_CLIMATE_INC

// The server's temperature and wetness field (docs/systems/climate.md),
// sampled into a grid round the camera by GoannaClient::updateClimate from
// what a paired server mod sends (DorfCraft's kindred seasons field). Off
// against any other server: goanna_climate_size.w is 0 and every reader
// gets nothing known.
//
// The grid is in Luanti's coordinates, z the other way to Godot's.
// goanna_climate_box is its low corner and, in w, the nodes per texel (0
// before there is a grid); goanna_climate_size its size in texels and, in
// w, 1 while the field is on. A texel holds the temperature (from -60 C,
// 170 C across the byte), the wetness and the air's humidity (0 to 1), each
// multiplied by its alpha, which is how much of it the server has sent.
global uniform sampler3D goanna_climate : filter_linear, repeat_disable;
global uniform vec4 goanna_climate_box;
global uniform vec4 goanna_climate_size;

// x the temperature in C, y the wetness, z the humidity, w how known, 0
// to 1. Off the grid, or with the field off, w is 0 and the rest a mild,
// middling day, so a reader that forgets to weigh by w draws nothing much.
vec4 goanna_climate_at(vec3 world) {
	vec4 mild = vec4(15.0, 0.5, 0.5, 0.0);
	if (goanna_climate_size.w < 0.5 || goanna_climate_box.w <= 0.0)
		return mild;
	vec3 p = vec3(world.x, world.y, -world.z);
	vec3 uvw = (p - goanna_climate_box.xyz) / (goanna_climate_box.w * goanna_climate_size.xyz);
	if (any(lessThan(uvw, vec3(0.0))) || any(greaterThan(uvw, vec3(1.0))))
		return mild;
	vec4 t = textureLod(goanna_climate, uvw, 0.0);
	if (t.a <= 0.0)
		return mild;
	// Premultiplied by how known (goanna_climate.h), so a texel filtered
	// against an unknown one keeps its own value once divided back out.
	vec3 v = t.rgb / t.a;
	return vec4(v.r * 170.0 - 60.0, v.g, v.b, t.a);
}

// The readers below are for the node shaders, which include
// weather_common.gdshaderinc first. A shader that wants only the field
// (atmosphere_volume.gdshader) defines GOANNA_CLIMATE_FIELD_ONLY.
#ifndef GOANNA_CLIMATE_FIELD_ONLY

// The field round a face at `world` with world normal `n`, sampled half a
// node out, in the air the face looks into. What goanna_climate_at gives;
// the node shaders take it once and hand it to the three readers below.
vec4 goanna_climate_face(vec3 world, vec3 n) {
	return goanna_climate_at(world + n * 0.5);
}

// The field's wetness as the rain block takes it: x a damp film, 0 to 1, y
// a rain wetness for goanna_ground_rain's standing water, 0 where none.
//
// The bands are the server's (Kythen's shared bands.json). Open ground in a
// rainy biome settles "humid", about 0.76, and rain alone cannot lift it
// past 0.9: only water near does. So the film begins in "humid", is whole
// at "saturated" (0.95), and water stands only from there.
vec2 goanna_climate_ground(vec4 c) {
	float film = smoothstep(0.74, 0.95, c.y) * c.w;
	float pool = 0.75 * smoothstep(0.93, 0.99, c.y) * c.w;
	return vec2(film, pool);
}

// The two axes of the face's own plane, in nodes, so a pattern drawn on
// them lies on the art's grid of sixteen texels a node on floors and walls
// alike.
vec2 goanna_climate_plane(vec3 p, vec3 n) {
	vec3 a = abs(n);
	if (a.y >= max(a.x, a.z))
		return p.xz;
	return a.x > a.z ? p.zy : p.xy;
}

// The texel of the face at `uv` (goanna_climate_plane), as whole numbers.
vec2 goanna_climate_texel(vec2 uv) {
	return floor((uv + 0.5) * 16.0 + 1e-3);
}

// Cracks in drying soil: about one texel wide, between plates a node or so
// across, drawn on the texel grid so they read as part of the pixel art.
// 1 on a crack, 0 off it.
float goanna_climate_cracks(vec2 texel, float width) {
	vec2 s = (texel + 0.5) / 16.0 * 0.9;
	vec2 i = floor(s);
	vec2 f = fract(s);
	float d1 = 8.0;
	float d2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 r = g + goanna_weather_hash3(i + g).xy - f;
			float d = dot(r, r);
			if (d < d1) {
				d2 = d1;
				d1 = d;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}
	return 1.0 - step(width, sqrt(d2) - sqrt(d1));
}

// What the field's wetness and warmth do to a surface before rain's film
// lands on it, graded across every band rather than switched on at one:
//
// - parching to dry: soil, sand and gravel go pale and matt, stone dusty;
//   grass and leaves turn toward straw; soil cracks, finer and wider as it
//   dries further;
// - comfortable: as drawn;
// - humid to damp: darker and a little richer in colour, porous ground
//   most;
// - damp and cool or warm, not freezing: moss on stone and gravel, first
//   in the hollows, most where the light is dim, so a cave fall grows a
//   green rim and an open bank only a little;
// - saturated and condensing: glistening, smoother, with beads of water
//   texel by texel, ceilings and walls included.
//
// `sky` is the vertex sky light, `porosity` the _s channel's, `h` the
// relief height at the drawn texel when `relief_known`.
void goanna_climate_tint(vec4 c, vec3 p, vec3 n, int cls, float sky, float porosity,
		float h, bool relief_known, inout vec3 albedo, inout float rough, inout float spec) {
	float k = c.w;
	if (k < 0.01)
		return;
	float t = c.x;
	float w = c.y;
	vec2 uv = goanna_climate_plane(p, n);
	vec2 texel = goanna_climate_texel(uv);
	float grain = goanna_weather_hash(texel + vec2(17.0, 3.0));
	float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	bool loose = cls == 5 || cls == 6 || cls == 9;
	bool rock = cls == 1 || cls == 6;

	float dry = k * smoothstep(0.42, 0.08, w);
	if (dry > 0.001) {
		vec3 pale = mix(albedo, vec3(lum), 0.45) * 1.3 + 0.04;
		if (loose) {
			albedo = mix(albedo, pale, dry * 0.6);
			rough = mix(rough, 1.0, dry * 0.7);
			spec *= 1.0 - 0.35 * dry;
		} else if (cls == 3) {
			albedo = mix(albedo, vec3(lum * 1.2, lum * 1.05, lum * 0.55), dry * 0.5);
		} else if (rock) {
			albedo = mix(albedo, pale, dry * 0.22);
			rough = mix(rough, 1.0, dry * 0.3);
		}
		// Soil only, and only where it can lie: cracks open from "dry" and
		// widen to two texels when parching.
		if (cls == 9 && n.y > 0.5 && dry > 0.25) {
			float open = smoothstep(0.25, 0.9, dry);
			float crack = goanna_climate_cracks(texel, mix(0.03, 0.12, open));
			albedo *= 1.0 - crack * open * 0.55;
			rough = mix(rough, 1.0, crack * open);
		}
	}

	float moist = k * smoothstep(0.48, 0.85, w);
	if (moist > 0.001) {
		// Wet ground is a good deal darker than dry: soil by up to a third,
		// stone by a tenth.
		albedo *= 1.0 - moist * (0.08 + 0.32 * porosity) * (loose ? 1.0 : 0.6);
		float l2 = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		albedo = max(mix(vec3(l2), albedo, 1.0 + 0.25 * moist), vec3(0.0));
	}

	float moss = k * smoothstep(0.8, 0.96, w) * smoothstep(0.5, 8.0, t)
			* mix(0.3, 1.0, 1.0 - smoothstep(0.35, 0.85, sky));
	if (rock && moss > 0.01 && n.y > -0.4) {
		float blob = goanna_weather_noise(uv * 0.9) * 0.65 + goanna_weather_noise(uv * 2.7 + 5.0) * 0.35;
		float rank = mix(blob, grain, 0.3);
		if (relief_known)
			rank = mix(rank, h, 0.4);
		float cover = smoothstep(rank - 0.02, rank + 0.02, moss * 1.1 - 0.08);
		vec3 green = vec3(0.10, 0.19, 0.045) * (0.7 + 0.6 * grain) + albedo * 0.15;
		albedo = mix(albedo, green, cover * 0.9);
		rough = mix(rough, 0.85, cover);
	}

	float glisten = k * smoothstep(0.9, 0.99, w);
	if (glisten > 0.001) {
		rough = mix(rough, 0.2, glisten * (0.85 - 0.4 * porosity));
		spec = mix(spec, 0.5, glisten * 0.5);
		// Beads: one texel in six or so holds a drop, mirror smooth.
		float bead = step(0.84, grain) * glisten;
		rough = mix(rough, 0.04, bead);
		albedo *= 1.0 - 0.15 * bead;
	}
}

// Frost, grown texel by texel like settled snow: from just above 0 C it
// takes a scattering of texels, more as it gets colder and the air more
// humid, the hollows of an authored relief first, and up facing surfaces
// more than walls. Below -20 C nearly everything is rimed. On glass it
// grows in from the pane's edges.
void goanna_climate_frost(vec4 c, vec3 p, vec3 n, int cls, float h, bool relief_known,
		inout vec3 albedo, inout float rough, inout float spec) {
	float k = c.w;
	if (k < 0.01 || c.x > 1.0)
		return;
	float cold = smoothstep(1.0, -10.0, c.x) * mix(0.45, 1.0, c.z) + 0.35 * smoothstep(-20.0, -35.0, c.x);
	float amount = k * min(cold, 1.0) * mix(0.55, 1.0, clamp(n.y, 0.0, 1.0)) * (n.y < -0.5 ? 0.4 : 1.0);
	if (amount < 0.01)
		return;
	vec2 uv = goanna_climate_plane(p, n);
	vec2 texel = goanna_climate_texel(uv);
	float grain = goanna_weather_hash(texel + vec2(41.0, 7.0));
	float rank = relief_known ? mix(h, grain, 0.4) : grain;
	if (cls == 4) {
		vec2 f = abs(fract(uv + 0.5) - 0.5);
		rank = mix(grain, 1.0 - 2.0 * max(f.x, f.y), 0.65);
	}
	float cover = smoothstep(rank - 0.03, rank + 0.03, amount * 1.2 - 0.1);
	albedo = mix(albedo, vec3(0.78, 0.84, 0.9) * (0.92 + 0.16 * grain), cover * 0.85);
	rough = mix(rough, 0.55, cover);
	spec = mix(spec, 0.45, cover);
}

#endif

#endif
