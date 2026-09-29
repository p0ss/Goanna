// SPDX-License-Identifier: LGPL-2.1-or-later
// World-space base, depth, coverage and extinction, shared with local fog.
uniform vec4 cloud_layers[3];

vec2 cloud_layer_offset(vec2 offset, int layer) {
	return offset * (1.0 + float(layer) * 0.17)
		+ vec2(19.7, 43.1) * float(layer);
}

float cloud_cell_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

float cloud_layer_noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(cloud_cell_hash(i), cloud_cell_hash(i + vec2(1, 0)), f.x),
		mix(cloud_cell_hash(i + vec2(0, 1)), cloud_cell_hash(i + vec2(1, 1)), f.x), f.y);
}

float cloud_layer_weather(vec2 p) {
	float value = 0.0, weight = 0.5;
	for (int i = 0; i < 4; i++) {
		value += weight * cloud_layer_noise(p);
		p = p * 2.03 + vec2(7.3, 1.7);
		weight *= 0.5;
	}
	return value / 0.9375;
}

float cloud_cell_size(int layer) {
	return 64.0 * (1.0 + float(layer) * 0.75);
}

// Different bases break the tiled underside without changing the rounded
// square footprint. Noise coordinates drift with the cells, never the eye.
float cloud_cell_base(vec2 cell, vec4 deck) {
	return deck.x + (cloud_cell_hash(cell + vec2(11.3, 57.9)) - 0.5)
		* deck.y * 1.5;
}
