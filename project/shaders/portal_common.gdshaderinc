// SPDX-License-Identifier: LGPL-2.1-or-later
// World-anchored portal coordinates. Adjacent node faces share the field,
// including across mapblocks and regional batches; UV is only for artwork.
// Included by portal_nether.gdshader and portal_end.gdshader, which
// GoannaClient (src/goanna_client_materials.cpp) puts on Mineclonia's portal
// faces; docs/systems/portal-materials.md.
#include "res://shaders/underwater.gdshaderinc"

// The node animation clock, seconds in [0, 60), set by
// GoannaClient::step_node_animation.
global uniform float goanna_node_anim_time;
// A fixed clock for offline captures (project/studies/portal_study.gd); below 0,
// the default in play, the shared clock runs.
uniform float preview_time = -1.0;
varying vec3 portal_world;
varying vec3 portal_normal;
varying flat float portal_edges;

void vertex() {
	// Four bits, which in-plane sides of this face touch a full cube of the
	// frame (+u, -u, +v, -v), set by the mesher in GoannaClient because
	// UV2.x is spare on a single image tile; docs/systems/mesh-attributes.md.
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

// Dave Hoskins' hash without sine: two values in [0, 1) per 2D point.
vec2 portal_hash(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yzx + 33.33);
	return fract((q.xx + q.yz) * q.zy);
}

// Smooth value noise, 0 to 1, from the hash above.
float portal_noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(portal_hash(i).x, portal_hash(i + vec2(1.0, 0.0)).x, f.x),
		mix(portal_hash(i + vec2(0.0, 1.0)).x,
			portal_hash(i + vec2(1.0)).x, f.x), f.y);
}
