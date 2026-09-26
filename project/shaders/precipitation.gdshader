// Goanna: rain and snow, drawn rather than simulated. docs/weather.md.
//
// The mesh is open cylinders nested around the camera (built in
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
// ground shaders do their own splashes from the same map); looking more
// than 60 degrees up the cylinders are edge on, so the rain fades out there
// rather than drawing a dense tangle (looking down, the two low layers carry
// it to 80 degrees); and the pattern moves with the camera rather than
// staying put in the world as you walk sideways (see `along` in fragment()
// for why).
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
// for visibility); these defaults only matter to a material nobody set, and
// the per layer arrays have none, since weather.gd always sets them.
// Radius of each layer, which the vertex colour names by index, nearest
// first. LAYERS must match weather.gd's LAYER_RADII.
const int LAYERS = 6;
uniform float layer_radius[LAYERS];
// How strongly each layer draws. The far ones are the haze of the storm and
// carry least; the first full layer carries the individual streak, and the
// two low ones inside it are fainter.
uniform float layer_alpha[LAYERS];
// Where each layer is drawn, in sines of the view's elevation: fading in
// with depression from x to y (a full layer has both below -1), and out as
// |elevation| goes from z to w, where the wall is seen edge on. weather.gd's
// LAYER_FADE has the values and the reasons.
uniform vec4 layer_fade[LAYERS];
uniform float rain_alpha = 0.85;
uniform float snow_alpha = 0.9;
// Streak half width in nodes: a base, and a growth with layer radius so a
// far streak keeps about a pixel rather than vanishing to a thread.
uniform vec2 streak_half_width = vec2(0.0015, 0.00075);
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
	v_layer = COLOR.r * float(LAYERS - 1);
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

// The streaks' lean along the tangent: horizontal drift per node of fall.
// The lean shears the column coordinate by height, and the shear changes
// round the turn with the wind's tangential part, by up to the lean times
// the height from the eye. Measured from world zero, as the first version
// did, that height is the camera's altitude, and the columns fold over a few
// tens of nodes up: the same squeeze, spread and smear as the camera term
// described in fragment(). From the eye, with the lean held to MAX_LEAN and
// the height the shear is taken at held to SHEAR_REACH radii (60 degrees
// above or below the eye), the change stays at 0.61 of a radius, so the
// column coordinate always runs forwards, at no less than 0.39 of its calm
// rate. The hold matters for the low layers, drawn to 88 degrees down,
// where the unclamped shear would fold them; past it a streak in wind turns
// upright, which on those layers is at or below the ground. The lean holds
// rain in the strongest wind main.gd derives (0.41) a little off its true
// lean; snow in a gale leans less than it should.
const float MAX_LEAN = 0.35;
const float SHEAR_REACH = 1.73;
float lean_along(vec2 tangent, float speed) {
	vec2 w = wind / max(speed, 0.1);
	float l = length(w);
	if (l > MAX_LEAN)
		w *= MAX_LEAN / l;
	return dot(w, tangent);
}

// Fade for a pattern whose cells are `cell_px` pixels across: below a few
// pixels a cell's drop is a speck, and a layer of specks reads as stars.
float minify(float cell_px) {
	return smoothstep(2.0, 5.0, cell_px);
}

void fragment() {
	int layer = clamp(int(round(v_layer)), 0, LAYERS - 1);
	float radius = layer_radius[layer];
	float strength = layer_alpha[layer];
	vec4 fade = layer_fade[layer];
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
	// Arc length along the layer. The pattern turns with the layer and so
	// moves with the camera sideways; it is anchored to the world only in
	// height. The first version added the camera's world position along the
	// tangent, dot(cam.xz, tangent), to anchor sideways motion too. That term
	// changes with the angle at a rate of the camera's distance from the
	// world origin, hundreds of nodes, against a radius of a few: the columns
	// were squeezed below a pixel in most directions (the sky full of white
	// specks), spread to normal size in the two directions square to the
	// camera's position (a narrow band of rain ahead at one yaw), and
	// stretched without limit at the points between (bright arcs, one
	// column smeared across the view). A shift that keeps every direction
	// right at once does not exist on a cylinder round a moving camera, so
	// there is none. Rain falls fast enough that it hardly shows; snow
	// drifting with the player may.
	float along = theta * radius;
	// Heights: from world zero for the fall, so a drop does not ride up and
	// down with the camera, and from the eye for the wind's shear below.
	float y = v_world.y;
	float y_eye = clamp(v_local.y, -SHEAR_REACH * radius, SHEAR_REACH * radius);

	// Where the layer is drawn (layer_fade): a low layer fades in going down
	// and has no rims of its own to hide, since its mesh ends where the fade
	// does; a full layer fades toward its rims. Every layer fades where its
	// wall is seen edge on, past which the columns crowd into a tangle (the
	// sine of the elevation is normalize(v_local).y).
	float s = normalize(v_local).y;
	float span = fade.x < -1.0
			? smoothstep(mesh_span.x, mesh_span.x + 6.0, v_local.y)
				* (1.0 - smoothstep(mesh_span.y - 6.0, mesh_span.y, v_local.y))
			: smoothstep(fade.x, fade.y, -s);
	float grazing = 1.0 - smoothstep(fade.z, fade.w, abs(s));

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
		float lean = lean_along(tangent, rain_speed);
		float u = (along + y_eye * lean) / spacing;
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
				// Minification. Columns closer than a few pixels, or a streak
				// under about eight pixels long, would draw as specks; fade
				// them instead, so a far layer thins out rather than fizzing.
				cover *= minify(1.0 / max(fw, 1e-4));
				cover *= smoothstep(4.0, 8.0, (len * rain_period) / max(dheight, 1e-4));
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
		float lean = lean_along(tangent, snow_speed);
		float u = (along + y_eye * lean) / spacing;
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
			float cover = line_cover(r, size, fw) * minify(1.0 / max(fw, 1e-4));
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
