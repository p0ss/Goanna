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

#endif
