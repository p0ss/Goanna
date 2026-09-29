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

// Match CloudLayers.horizontal_scale: low/middle/high banks grow 1x/4x/9x.
// Their shape stays fixed while the camera travels through the layers.
float cloud_horizontal_scale(int layer) {
	float level = float(layer + 1);
	return level * level;
}

float cloud_cell_size(int layer) {
	return 384.0 * cloud_horizontal_scale(layer);
}

// Stagger each row independently so gaps cannot form long straight lanes.
float cloud_row_shift(float row) {
	return cloud_cell_hash(vec2(row, 17.7)) - 0.5;
}

vec2 cloud_cell_at(vec2 position, float size) {
	float row = floor(position.y / size);
	return vec2(floor(position.x / size - cloud_row_shift(row)), row);
}

vec2 cloud_cell_origin(vec2 cell, float size) {
	return (cell + vec2(cloud_row_shift(cell.y), 0.0)) * size;
}

// Bodies have independent widths and off-centre positions inside a coarse
// traversal cell. The grid bounds are empty space, not cloud surfaces.
vec4 cloud_cell_footprint(vec2 cell, float size) {
	vec2 width = size * mix(vec2(0.42), vec2(0.92),
		vec2(cloud_cell_hash(cell + vec2(5.2, 83.1)),
			cloud_cell_hash(cell + vec2(73.8, 15.7))));
	vec2 jitter = vec2(cloud_cell_hash(cell + vec2(29.1, 7.3)),
		cloud_cell_hash(cell + vec2(61.7, 49.2))) - 0.5;
	vec2 centre = cloud_cell_origin(cell, size) + size * 0.5 + jitter * (size - width) * 0.95;
	return vec4(centre, width * 0.5);
}

// Different bases break the tiled underside. Noise coordinates drift with
// the cells, never the eye.
float cloud_cell_base(vec2 cell, vec4 deck) {
	return deck.x + (cloud_cell_hash(cell + vec2(11.3, 57.9)) - 0.5)
		* deck.y * 1.5;
}

// Distance in normalised body coordinates, keeping wide clouds rounded.
float cloud_block_distance(vec3 p, vec3 midpoint, vec3 half_size) {
	vec3 q = abs((p - midpoint) / half_size) - vec3(0.42);
	return length(max(q, vec3(0.0)))
		+ min(max(q.x, max(q.y, q.z)), 0.0) - 0.58;
}
