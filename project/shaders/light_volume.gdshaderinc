// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#ifndef GOANNA_LIGHT_VOLUME_INC
#define GOANNA_LIGHT_VOLUME_INC

// The light volume (GoannaClient::updateLightVolume): Luanti's block light
// flooded again with each source's colour carried along, in a box round
// the camera, decoded as the mesh's block light is. The box's w is the gain
// on that light, 0 when the volume is off and negative for the debug view.
// A face reads the cell in front of it, half a node out along its geometric
// normal, and the box fades back to the baked light over its last eight
// nodes.
//
// The flood says how much light arrives, not from where; the gradient of its
// brightness does, as the light falls off away from its source. `shade`
// (usually the relief-mapped normal) is turned against that direction, so
// a face turned from a lamp is darker than one facing it and brick relief
// reads, as it does under the lamp pool. Where the light is even, nothing
// changes. Returns the light in rgb and how much of it to use in a.
global uniform sampler3D goanna_light_volume : filter_linear, repeat_disable;
global uniform vec4 goanna_light_volume_box;
global uniform vec3 goanna_light_volume_size;
vec4 goanna_block_light_volume(vec3 world, vec3 normal, vec3 shade) {
	if (goanna_light_volume_box.w == 0.0)
		return vec4(0.0);
	vec3 p = world + normal * 0.5 - goanna_light_volume_box.xyz;
	vec3 edge = min(p, goanna_light_volume_size - p);
	float w = clamp(min(edge.x, min(edge.y, edge.z)) / 8.0, 0.0, 1.0);
	if (w <= 0.0)
		return vec4(0.0);
	vec3 uvw = p / goanna_light_volume_size;
	vec3 t = 1.0 / goanna_light_volume_size;
	const vec3 lum = vec3(0.2126, 0.7152, 0.0722);
	vec3 grad = vec3(
			dot(texture(goanna_light_volume, uvw + vec3(t.x, 0.0, 0.0)).rgb, lum) -
			dot(texture(goanna_light_volume, uvw - vec3(t.x, 0.0, 0.0)).rgb, lum),
			dot(texture(goanna_light_volume, uvw + vec3(0.0, t.y, 0.0)).rgb, lum) -
			dot(texture(goanna_light_volume, uvw - vec3(0.0, t.y, 0.0)).rgb, lum),
			dot(texture(goanna_light_volume, uvw + vec3(0.0, 0.0, t.z)).rgb, lum) -
			dot(texture(goanna_light_volume, uvw - vec3(0.0, 0.0, t.z)).rgb, lum));
	vec3 light = texture(goanna_light_volume, uvw).rgb;
	float g = length(grad);
	float facing = g > 1e-4 ? dot(normalize(shade), grad / g) : 0.0;
	float shaped = mix(1.0, clamp(0.6 + 0.6 * facing, 0.15, 1.2), clamp(g * 6.0, 0.0, 1.0));
	return vec4(light * shaped * abs(goanna_light_volume_box.w), w);
}

#endif
