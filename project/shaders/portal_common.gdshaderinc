// SPDX-License-Identifier: LGPL-2.1-or-later
// World-anchored portal coordinates. Adjacent node faces share the field,
// including across mapblocks and regional batches; UV is only for artwork.
#include "res://shaders/underwater.gdshaderinc"

global uniform float goanna_node_anim_time;
uniform float preview_time = -1.0;
varying vec3 portal_world;
varying vec3 portal_normal;
varying flat float portal_edges;

void vertex() {
	portal_edges = UV2.x;
	portal_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	portal_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float portal_time() {
	return preview_time >= 0.0 ? preview_time : goanna_node_anim_time;
}

// The in-plane axes do not flip with face winding. Looking through the
// back sees the same field, not a second pattern reflected at every tile.
void portal_axes(vec3 n, out vec3 u, out vec3 v) {
	vec3 a = abs(n);
	if (a.y > a.x && a.y > a.z) {
		u = vec3(1.0, 0.0, 0.0); v = vec3(0.0, 0.0, 1.0);
	} else if (a.x > a.z) {
		u = vec3(0.0, 0.0, 1.0); v = vec3(0.0, 1.0, 0.0);
	} else {
		u = vec3(1.0, 0.0, 0.0); v = vec3(0.0, 1.0, 0.0);
	}
}

vec2 portal_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.xx + q.yz) * q.zy);
}

float portal_noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(portal_hash(i).x, portal_hash(i + vec2(1.0, 0.0)).x, f.x),
		mix(portal_hash(i + vec2(0.0, 1.0)).x,
			portal_hash(i + vec2(1.0)).x, f.x), f.y);
}
