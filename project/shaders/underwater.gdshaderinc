// Goanna: what the water between the eye and a surface takes out of its
// light, per colour, while the eye is under water. docs/water-optics.md.
//
// Looked down into from above, the water shader absorbs the bed by the
// water's absorption (goanna_water_absorption) over the water it is seen
// through: red goes first, and a bed a node or two down is already blue
// grey. From under the water there was only Godot's fog, one blend toward
// the murk colour at a few hundredths a node near the surface, and a bed
// three nodes away kept nearly all its dry colour: the same bed was
// noticeably brighter seen from in the water than from above it. Every
// opaque surface now takes the same absorption over the water its light
// crosses to reach the eye: the whole way, or, for a surface above the
// water seen up through it, only the part below the surface. The fog still
// adds the murk's own glow on top.
#ifndef GOANNA_UNDERWATER
#define GOANNA_UNDERWATER

// 1 while the eye is in water (GoannaClient.is_underwater).
global uniform float goanna_eye_underwater;
// The water's absorption per node, red, green, blue (water_optics.gd).
global uniform vec3 goanna_water_absorption;
// x the height of the water's surface over the eye, world space, set by
// main.gd while the eye is under water.
global uniform vec4 goanna_water_surface;

// The share of each colour of a surface's light that reaches the eye, for
// a fragment at view space `vertex`: 1 out of the water.
vec3 goanna_underwater_keep(vec3 vertex, mat4 inv_view, vec3 eye) {
	if (goanna_eye_underwater < 0.5)
		return vec3(1.0);
	vec3 world = (inv_view * vec4(vertex, 1.0)).xyz;
	float path = length(world - eye);
	float rise = world.y - eye.y;
	float surface = goanna_water_surface.x;
	// Seen up through the surface: only the stretch under it is water.
	if (world.y > surface && rise > 1e-4)
		path *= clamp((surface - eye.y) / rise, 0.0, 1.0);
	return exp(-goanna_water_absorption * min(path, 64.0));
}

#endif
