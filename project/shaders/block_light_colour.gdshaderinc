// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#ifndef GOANNA_BLOCK_LIGHT_COLOUR_INC
#define GOANNA_BLOCK_LIGHT_COLOUR_INC

// Where the light pool's real lamps end, in view distance, set per frame by
// GoannaClient::update_lights. Past it the near mesh fades in the same
// baked block-light emission the far tiers use, so a village keeps its
// glow through the middle distance where its lamps have not made the pool
// instead of going dark between the far bake and the near pool.
global uniform float goanna_lamp_reach;

// The colour of block light (GoannaClient::updateLightHue): a coarse grid
// round the camera holding the colour of the lamps within reach of each
// cell, and in alpha how near a glowing liquid is. goanna_light_hue_box is the grid's low corner and, in w, its
// cell size in nodes (0 before the grid exists); goanna_light_hue_size is
// its size in cells and, in w, how much of the coloured light shows under
// the lamp pool, negative while the Coloured block light setting is off.
// Brightness stays the baked light's, which is Luanti's own level with its
// occlusion; only the colour, and how much of it to use, comes from here.
global uniform sampler3D goanna_light_hue : filter_linear, repeat_disable;
global uniform vec4 goanna_light_hue_box;
global uniform vec4 goanna_light_hue_size;

// The grid at a world position: the light's colour and its nearness to a
// glowing liquid, white and none outside the grid or where no lamp reaches.
vec4 goanna_block_light_grid(vec3 world) {
	if (goanna_light_hue_box.w <= 0.0)
		return vec4(1.0, 1.0, 1.0, 0.0);
	vec3 uvw = (world - goanna_light_hue_box.xyz) / (goanna_light_hue_box.w * goanna_light_hue_size.xyz);
	if (any(lessThan(uvw, vec3(0.0))) || any(greaterThan(uvw, vec3(1.0))))
		return vec4(1.0, 1.0, 1.0, 0.0);
	return texture(goanna_light_hue, uvw);
}

// 1 while the setting is on, for surfaces that take block light only then.
float goanna_block_light_colour_on() {
	return goanna_light_hue_box.w > 0.0 && goanna_light_hue_size.w >= 0.0 ? 1.0 : 0.0;
}

// The block light a surface adds as emission: its baked level, in full past
// the pool's reach (`bake` 1) and beside a glowing liquid, since the pool's
// point lamps over a lava pool graze its banks rather than light them; the
// light beside a liquid is in the liquid's colour whatever the setting.
// With the setting on all of it is coloured, and the rest shows as a fill
// under the pool's lamps; with it off the rest is not added, as before.
vec3 goanna_block_light(float baked, float bake, vec3 world) {
	vec4 grid = goanna_block_light_grid(world);
	float on = goanna_block_light_colour_on();
	float full = max(bake, grid.a);
	float fill = on * max(goanna_light_hue_size.w, 0.0);
	return baked * mix(vec3(1.0), grid.rgb, max(on, grid.a)) * (full + (1.0 - full) * fill);
}

#endif
