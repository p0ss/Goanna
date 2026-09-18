// SPDX-License-Identifier: LGPL-2.1-or-later
// One world-space material across sources, sloping tops and vertical falls.
// Near lava's UV contains a continuous projected velocity, not per-face tiles.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float emission_energy : hint_range(0.0, 8.0) = 4.8;
uniform float flow_speed : hint_range(0.0, 1.0) = 0.32;
uniform float crust_height : hint_range(0.0, 0.3) = 0.14;
uniform float texture_scale : hint_range(0.25, 2.0) = 0.65;
uniform bool surface_geometry = false;
uniform float preview_time = -1.0;
uniform vec2 crust_range = vec2(0.025, 0.50);
uniform float crust_strength = 1.0;

varying vec3 surface_pos;
varying vec3 world_normal;
varying vec2 flow;
varying float crust_weight;
varying vec3 displacement_direction;
varying vec3 displaced_pos;
varying float geometric_crust;

vec2 project_surface(vec3 p) {
	// A single oblique projection stays continuous around a sharp corner.
	// Switching planar axes, or rotating every block's UVs, tears the crust.
	return (p.xz + p.y * vec2(0.43, 0.71)) * texture_scale;
}

vec3 lava_colour(vec3 p, vec2 velocity, float t, float lod) {
	vec2 uv = project_surface(p);
	vec2 eddy = vec2(sin(p.x * 0.83 + p.z * 0.67 - t * 0.18),
			cos(p.z * 0.79 - p.x * 0.53 + t * 0.16)) * 0.035;
	// Two overlapping advection cycles prevent unbounded stretching as time
	// increases. Both phases and their weights are shared across every block.
	float cycle = t / 12.0;
	float a = fract(cycle);
	float b = fract(cycle + 0.5);
	float weight = abs(2.0 * a - 1.0);
	vec2 drift = (velocity * flow_speed + vec2(0.009, 0.006)) * texture_scale;
	vec3 first = textureLod(albedo_tex, uv + eddy - drift * a * 12.0, lod).rgb;
	vec3 second = textureLod(albedo_tex, uv + eddy - drift * b * 12.0, lod).rgb;
	return mix(first, second, weight);
}

float crust_at(vec3 p, vec2 velocity, float t, float lod) {
	vec3 colour = lava_colour(p, velocity, t, lod);
	// Saturated red and yellow can both have R=1. One luminance ramp
	// preserves their relief without turning blended flow phases all solid.
	float brightness = dot(colour, vec3(0.2126, 0.7152, 0.0722));
	return crust_strength * (1.0 - smoothstep(crust_range.x, crust_range.y, brightness));
}

void vertex() {
	surface_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	flow = surface_geometry ? UV : vec2(0.0);
	crust_weight = surface_geometry ? COLOR.a : 1.0;
	displacement_direction = length(CUSTOM1.xyz) > 0.1 ? normalize(CUSTOM1.xyz) : vec3(0.0, 1.0, 0.0);
	float t = preview_time >= 0.0 ? preview_time : TIME;
	// Match the height mask's bandwidth to the mesh (eight segments/node).
	// Sampling full-resolution artwork on a coarse mesh aliases peaks into
	// valleys. Carry this exact mask into the colour pass as well.
	float geometry_lod = max(0.0, log2(float(textureSize(albedo_tex, 0).x) * texture_scale / 8.0));
	geometric_crust = crust_at(surface_pos, flow, t, geometry_lod);
	displaced_pos = surface_pos;
	if (surface_geometry) {
		float fade = 1.0 - smoothstep(32.0, 80.0, length(surface_pos - CAMERA_POSITION_WORLD));
		float height = crust_height * geometric_crust * fade * crust_weight;
		displaced_pos += displacement_direction * height;
		// The map supplies one direction at a shared position, including
		// corners. Falling crust can stand out from the vertical surface too.
		VERTEX += (inverse(MODEL_MATRIX) * vec4(displacement_direction * height, 0.0)).xyz;
	}
}

void fragment() {
	float t = preview_time >= 0.0 ? preview_time : TIME;
	vec2 projected = project_surface(surface_pos);
	float size = float(textureSize(albedo_tex, 0).x);
	float footprint = max(length(dFdx(projected)), length(dFdy(projected))) * size;
	float lod = max(0.0, log2(max(footprint, 1.0)));
	vec3 tile = lava_colour(surface_pos, flow, t, lod);
	vec3 n = normalize(world_normal);
	if (surface_geometry) {
		// Smooth the normals using the SAME filtered height field as the
		// mesh. Raw texel normals invert small details; triangle derivatives
		// expose the tessellation as glittering facets on a dark cave fall.
		float height_lod = max(0.0, log2(size * texture_scale / 8.0));
		float e = 0.125;
		vec3 gradient = vec3(
			crust_at(surface_pos+vec3(e,0,0),flow,t,height_lod)-crust_at(surface_pos-vec3(e,0,0),flow,t,height_lod),
			crust_at(surface_pos+vec3(0,e,0),flow,t,height_lod)-crust_at(surface_pos-vec3(0,e,0),flow,t,height_lod),
			crust_at(surface_pos+vec3(0,0,e),flow,t,height_lod)-crust_at(surface_pos-vec3(0,0,e),flow,t,height_lod)) * (crust_height/(2.0*e));
		vec3 dx = dFdx(surface_pos), dy = dFdy(surface_pos);
		vec3 rx = cross(dy,n), ry = cross(n,dx);
		float determinant = dot(dx,rx);
		vec3 shore_gradient = vec3(0.0);
		if (abs(determinant)>1e-10)
			shore_gradient = (rx*dFdx(crust_weight)+ry*dFdy(crust_weight))/determinant;
		gradient = gradient*crust_weight + crust_height*geometric_crust*shore_gradient;
		float fade = 1.0-smoothstep(32.0,80.0,length(surface_pos-CAMERA_POSITION_WORLD));
		n = normalize(n-(gradient-n*dot(gradient,n))*abs(dot(n,normalize(displacement_direction)))*fade);
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	if (!FRONT_FACING)
		NORMAL = -NORMAL;
	vec3 colour = tile * COLOR.rgb;
	// Raised material is dark crust even where fine bright texels cross a
	// coarse triangle. The same interpolated mask drives height and glow.
	float rock = surface_geometry ? clamp(geometric_crust, 0.0, 1.0) : crust_at(surface_pos, flow, t, lod);
	float melt = 1.0 - rock;
	ALBEDO = colour * mix(0.28, 0.12, rock);
	EMISSION = colour * emission_energy * melt * melt;
	ROUGHNESS = mix(0.72, 0.96, rock);
	SPECULAR = mix(0.18, 0.12, rock);
	METALLIC = 0.0;
}
