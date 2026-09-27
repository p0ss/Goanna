// SPDX-License-Identifier: LGPL-2.1-or-later
// Coarse node-lamp visibility, using only this player's received full cubes.
global uniform sampler3D goanna_lamp_occlusion_grid : filter_nearest, repeat_disable;
global uniform sampler2D goanna_lamp_occlusion_sources : filter_nearest, repeat_disable;
global uniform vec4 goanna_lamp_occlusion_box;
varying vec3 v_lamp_world;

float goanna_lamp_visibility(vec3 world, vec3 direction) {
	float edge = goanna_lamp_occlusion_box.w;
	if (edge < 1.0) return 1.0;
	vec3 start = world + direction * 0.06 - goanna_lamp_occlusion_box.xyz;
	ivec3 cell = ivec3(floor(start));
	vec3 stride = 1.0 / max(abs(direction), vec3(0.000001));
	vec3 step_dir = mix(vec3(-1.0), vec3(1.0), greaterThanEqual(direction, vec3(0.0)));
	vec3 crossing = (vec3(cell) + step(vec3(0.0), direction) - start)
		* step_dir * stride;
	float blocked = 0.0;
	float travelled = 0.0;
	for (int i = 0; i < 56; i++) {
		if (travelled > 16.0 || any(lessThan(cell, ivec3(0)))
				|| any(greaterThanEqual(cell, ivec3(int(edge))))) break;
		float voxel = texelFetch(goanna_lamp_occlusion_grid, cell, 0).r;
		if (voxel < -0.5) blocked = 1.0;
		if (voxel > 0.5) {
			vec3 source = texelFetch(goanna_lamp_occlusion_sources,
				ivec2(int(voxel) - 1, 0), 0).xyz;
			vec3 delta = source - world;
			// A ray can pass another lamp's cell. Only stop at a source on
			// this light's ray; otherwise a wall behind it still matters.
			if (dot(normalize(delta), direction) > 0.999999)
				return 1.0 - blocked;
		}
		if (crossing.x <= crossing.y && crossing.x <= crossing.z) {
			travelled = crossing.x; crossing.x += stride.x; cell.x += int(step_dir.x);
		} else if (crossing.y <= crossing.z) {
			travelled = crossing.y; crossing.y += stride.y; cell.y += int(step_dir.y);
		} else {
			travelled = crossing.z; crossing.z += stride.z; cell.z += int(step_dir.z);
		}
	}
	// No matching source in the received grid: retain ordinary lighting.
	// This also covers lights supplied by a shader pack or another system.
	return 1.0;
}
