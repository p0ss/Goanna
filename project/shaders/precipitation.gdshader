// Goanna: rain and snow, drawn rather than simulated. docs/weather.md.
//
// The mesh is a few open cylinders nested around the camera (built in
// project/ui/weather.gd, which moves it with the camera every frame), all
// in one surface, so the whole of the weather is one draw call. Each
// cylinder is a layer at one distance: the pattern on it is laid out in
// world units, so a far layer packs more, thinner streaks into the same
// angle than a near one, and the nesting gives the depth a single sheet
// cannot. Everything here is a function of where the fragment is in the
// world and the time: no state, nothing to simulate, nothing to cull.
//
// A drop is drawn only where the rain cover map says the sky reaches that
// point, so rain stops at a roof's edge and at a canopy, and still falls
// past the window of a house you stand in. The depth buffer does the rest:
// a layer behind a wall is behind the wall.
//
// Lit, not unshaded. The first version was unshaded and coloured with the
// sky gradient, which is a small number beside the sunlit ground once the
// exposure has been applied: grey streaks at a sixth opacity over bright
// sand, which on a live client at noon could not be seen at all. Lit by the
// same sun and sky as everything else, a drop is as bright as the scene
// around it by day and as dark by night, whatever the exposure. It receives
// no shadows, which would cost a shadow map read per streak pixel.
//
// What is not done: nothing splashes where a streak meets the ground (the
// ground shaders do their own splashes from the same map), and looking
// straight up or down the cylinders are edge on, so the rain fades out
// there rather than drawing a dense tangle.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

#include "res://shaders/weather_common.gdshaderinc"

// 0 to 2 each; weather.gd sets them from the server's spawners.
uniform float rain_amount = 0.0;
uniform float snow_amount = 0.0;
// Fall speed, nodes a second, from the spawners' own velocities.
uniform float rain_speed = 17.0;
uniform float snow_speed = 2.2;
// Horizontal wind, nodes a second, in world xz.
uniform vec2 wind = vec2(0.0);
// The look, owned by weather.gd's constants (which a headless test checks
// for visibility); these defaults only matter to a material nobody set.
// Radius of each layer, which the vertex colour names by index.
uniform vec4 layer_radius = vec4(3.0, 6.5, 12.0, 22.0);
// How strongly each layer draws. The far ones are the haze of the storm and
// carry least; the nearest carries the individual streak.
uniform vec4 layer_alpha = vec4(0.8, 0.65, 0.5, 0.4);
uniform float rain_alpha = 0.85;
uniform float snow_alpha = 0.9;
// Streak half width in nodes: a base, and a growth with layer radius so a
// far streak keeps about a pixel rather than vanishing to a thread.
uniform vec2 streak_half_width = vec2(0.003, 0.0006);
// Share of rain columns carrying a drop per period, per unit of intensity.
uniform float rain_density = 0.55;
uniform float snow_density = 0.5;
// Height of one rain cell along a column, in nodes.
uniform float rain_period = 1.8;
// Where the mesh ends above and below the eye; the layers fade out before
// their rims so a rim is never seen as an edge.
uniform vec2 mesh_span = vec2(-26.0, 34.0);

// The fill the terrain takes from the sky light channel (nodes_array's
// emission), so a drop in a storm's dim daylight is not lit by the
// environment's ambient alone.
global uniform vec3 goanna_sky_fill;
global uniform vec3 goanna_ground_fill;
global uniform float goanna_eye_underwater;

varying vec3 v_world;
varying vec3 v_local;
varying float v_layer;

void vertex() {
	v_local = VERTEX;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_layer = COLOR.r * 3.0;
}

// Coverage of a line of half width `half_w` at signed offset `x`, both in
// the same units, antialiased over `fw` (that unit's size in pixels, from
// the derivatives). A line thinner than a pixel is drawn a pixel wide at
// the coverage it really has, which is what keeps the far layers from
// sparkling.
float line_cover(float x, float half_w, float fw) {
	float w = max(half_w, fw * 0.5);
	float edge = 1.0 - smoothstep(w - fw * 0.5, w + fw * 0.5, abs(x));
	return edge * (half_w / w);
}

void fragment() {
	int layer = clamp(int(round(v_layer)), 0, 3);
	float radius = layer_radius[layer];
	float strength = layer_alpha[layer];
	// The angle round the camera, and the tangent there. Derivatives of the
	// angle are taken by hand from those of the position, because atan jumps
	// by a full turn behind the camera and fwidth of it would draw a wide
	// smear down that line.
	vec2 xz = v_local.xz;
	float theta = atan(xz.y, xz.x);
	vec2 tangent = vec2(-sin(theta), cos(theta));
	vec2 dx = dFdx(xz);
	vec2 dy = dFdy(xz);
	float rr = max(dot(xz, xz), 1e-4);
	float dtheta = (abs(xz.x * dx.y - xz.y * dx.x) + abs(xz.x * dy.y - xz.y * dy.x)) / rr;
	float dheight = abs(dFdx(v_world.y)) + abs(dFdy(v_world.y));
	// Arc length along the layer, anchored to the world along the tangent:
	// walking sideways moves the pattern past you rather than taking it with
	// you. Toward and away is not compensated; the layers move with you.
	vec3 cam = v_world - v_local;
	float along = theta * radius + dot(cam.xz, tangent);
	float wind_t = dot(wind, tangent);
	float y = v_world.y;

	// Fade toward the rims, and where the wall is seen edge on (looking
	// steeply up or down), where the pattern crowds into a dense tangle.
	float span = smoothstep(mesh_span.x, mesh_span.x + 6.0, v_local.y)
			* (1.0 - smoothstep(mesh_span.y - 6.0, mesh_span.y, v_local.y));
	float grazing = 1.0 - smoothstep(0.85, 0.97, abs(normalize(v_local).y));

	float open = goanna_rain_open(v_world, 1.0);
	float seen = 0.0;
	vec3 col = vec3(0.0);

	if (rain_amount > 0.001) {
		// Columns a whole number to the turn, so the pattern closes on
		// itself behind the camera with no seam.
		float cols = max(floor(TAU * radius / 0.16), 8.0);
		float spacing = TAU * radius / cols;
		// A drop moves along (wind, -speed), so along + y * lean is the
		// same all the way down its path: that is what leans the streaks.
		float lean = wind_t / rain_speed;
		float u = (along + y * lean) / spacing;
		float c = floor(u);
		float cid = mod(c, cols);
		vec3 h = goanna_weather_hash3(vec2(cid, float(layer) * 131.0));
		float speed = rain_speed * (0.85 + 0.3 * h.x);
		float v = (y + TIME * speed) / rain_period + h.y;
		float cell = floor(v);
		vec3 k = goanna_weather_hash3(vec2(cid * 3.7 + cell, float(layer) * 17.0 + 5.0));
		float density = clamp(rain_density * rain_amount, 0.0, 0.95);
		if (k.x < density) {
			float len = (0.45 + 0.4 * k.y) / rain_period;
			float at = fract(v) - k.z * (1.0 - len);
			float along_streak = at / len;
			if (along_streak > 0.0 && along_streak < 1.0) {
				float taper = smoothstep(0.0, 0.25, along_streak) * (1.0 - smoothstep(0.6, 1.0, along_streak));
				float fw = radius * dtheta / spacing;
				float x = fract(u) - (0.3 + 0.4 * k.y);
				float half_w = streak_half_width.x + streak_half_width.y * radius;
				float cover = line_cover(x, half_w / spacing, fw);
				// A streak shorter than a pixel is a dot; fade those out
				// rather than letting them fizz.
				cover *= smoothstep(0.0, 1.0, (len * rain_period) / max(dheight, 1e-4) * 0.25);
				float a = cover * taper * rain_alpha * strength;
				col += vec3(0.82, 0.86, 0.92) * a;
				seen += a;
			}
		}
	}

	if (snow_amount > 0.001) {
		float cell_w = 0.55;
		float cols = max(floor(TAU * radius / cell_w), 8.0);
		float spacing = TAU * radius / cols;
		float lean = wind_t / snow_speed;
		float u = (along + y * lean) / spacing;
		float v = (y + TIME * snow_speed) / cell_w;
		vec2 id = vec2(mod(floor(u), cols), floor(v));
		vec3 k = goanna_weather_hash3(id + vec2(float(layer) * 57.0, 11.0));
		float density = clamp(snow_density * snow_amount, 0.0, 0.95);
		if (k.x < density) {
			// Flakes flutter: a slow sideways sway of their own on top of
			// the wind's drift.
			float sway = sin(TIME * (0.8 + k.y) + k.z * TAU) * 0.18;
			vec2 at = vec2(fract(u) - 0.5 - sway, fract(v) - 0.5) - (k.yz - 0.5) * 0.5;
			// In the cell's own units: a cell is `spacing` wide and
			// `cell_w` tall, near enough square.
			float r = length(at);
			float size = (0.018 + 0.02 * k.y) / spacing;
			float fw = max(radius * dtheta, dheight) / spacing;
			float cover = line_cover(r, size, fw);
			float a = cover * snow_alpha * strength;
			col += vec3(0.95) * a;
			seen += a;
		}
	}

	// Underwater there is no rain to see; above, only where it falls.
	float keep = open * span * grazing * (1.0 - step(0.5, goanna_eye_underwater));
	ALPHA = clamp(seen * keep, 0.0, 1.0);
	if (ALPHA < 0.002)
		discard;
	ALBEDO = col / max(seen, 1e-4);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	EMISSION = ALBEDO * mix(goanna_ground_fill, goanna_sky_fill, 0.6) * 0.5;
}

// A drop has no facing that matters: it is lit from whichever side the light
// is on, and more with the light behind it, which is the silver rain shows
// against a low sun. Lambert's 1 / PI, as in direct_light.gdshaderinc.
void light() {
	float behind = max(dot(-LIGHT, VIEW), 0.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (0.45 + 0.55 * behind * behind) / PI;
}
