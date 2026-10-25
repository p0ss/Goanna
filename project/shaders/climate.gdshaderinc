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

// The field's wetness as the ground shaders take it, for the face at
// `world` with world normal `n`: x a damp film, 0 to 1, y a rain wetness
// for goanna_ground_rain's standing water, 0 where there is none.
//
// The bands are the server's (Kythen's shared bands.json). Open ground in
// a rainy biome settles "humid", about 0.76, and rain alone cannot lift it
// past 0.9: only water near does. So the film starts at the edge of
// "damp" (0.8), is whole at "saturated" (0.95), and water stands only from
// there. Ordinary ground is left as it is, and the banks of ponds, streams
// and falls, and rooms with water in them, go wet. Sampled half a node out
// from the face, in the air the face looks into.
vec2 goanna_climate_ground(vec3 world, vec3 n) {
	if (goanna_climate_size.w < 0.5)
		return vec2(0.0);
	vec4 c = goanna_climate_at(world + n * 0.5);
	float film = smoothstep(0.8, 0.95, c.y) * c.w;
	float pool = 0.75 * smoothstep(0.93, 0.99, c.y) * c.w;
	return vec2(film, pool);
}

#endif
