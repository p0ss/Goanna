// Goanna: rain and snow, drawn rather than simulated. docs/systems/weather.md.
//
// Every drop is one instance of a MultiMesh (built in project/ui/weather.gd),
// so a kind of weather is one draw call. A drop has a place in a box around
// the eye, hashed from its instance number, and falls through it: its world
// position is the box's corner plus (seed + velocity * time - corner) wrapped
// into the box. A drop is therefore fixed in the world, not in the view: as
// the eye moves, the box moves round the drops, and one that leaves by a face
// comes back in by the opposite one, where it fades in and out so the wrap is
// not seen. Nothing is simulated and nothing is kept between frames.
//
// This replaced six cylinders nested round the camera. A cylinder is seen
// edge on above and below the eye, so looking up the streaks became radial
// lines round a clear circle, and looking down the nearest wall was a ring
// of rain rushing in under a dry disc ("a pillbox"). A volume has no angle
// it looks wrong from.
//
// Two boxes share the instances: a near box of a few nodes round the eye with
// many drops, and a larger one with fewer, whose drops fade out toward its
// sides and top. The near box is what is seen falling past the face and
// between the eye and the ground looking down, where the large box alone
// leaves a node or two of air with nothing in it.
//
// A drop is drawn only where the rain cover map says the sky reaches it, so
// there is no rain indoors or under a canopy, and rain still falls past the
// window of a house you stand in. The cover map also holds the ground, so a
// drop that has fallen below the surface of its column is not drawn either.
//
// Lit, not unshaded: by the same sun and sky as everything else, so a drop is
// as bright as the scene around it by day and as dark by night, whatever the
// exposure. It receives no shadows, which would cost a shadow map read per
// streak pixel.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

#include "res://shaders/weather_common.gdshaderinc"

// 0 to max_amount; weather.gd sets it from the server's spawners. A drop is
// drawn when its own hash is under amount / max_amount, so the number drawn
// follows the intensity and the ones drawn are always the same ones.
uniform float amount = 0.0;
uniform float max_amount = 2.0;
// Snow instead of rain: round flakes, slow, swaying.
uniform bool snow = false;
// Fall speed, nodes a second, from the spawners' own velocities.
uniform float speed = 17.0;
// Horizontal wind, nodes a second, in world xz.
uniform vec2 wind = vec2(0.0);
// The eye the boxes are placed round, set by weather.gd each frame. Drops do
// not move with it, only the boxes do, so a frame's lag costs nothing.
uniform vec3 eye = vec3(0.0);
// The boxes: size in nodes, and how far the eye is above the bottom. The
// first near_instances instances fall in the near box, the rest in the far.
uniform vec3 far_box = vec3(24.0, 16.0, 24.0);
uniform float far_below = 10.0;
uniform vec3 near_box = vec3(6.0, 6.0, 6.0);
uniform float near_below = 3.5;
uniform int near_instances = 0;
// The look, owned by weather.gd's constants, which a headless test checks.
// Peak opacity of a drop drawn at its true width.
uniform float drop_alpha = 0.85;
// Half width of a rain streak, or radius of a flake, in nodes. A real drop
// is a few millimetres across; one narrower than a pixel is drawn a pixel
// wide at the coverage it really has (drop_cover), so a far drop is a faint
// line rather than a sparkle.
uniform float drop_half_width = 0.002;
// Seconds of fall a streak shows, the motion blur of an eye's exposure.
uniform float streak_time = 0.035;
// Rain leans with the wind by no more than this much drift per node of fall.
uniform float max_lean = 0.6;
// How far snow may be blown, as a multiple of its fall: 2 in a flurry, up
// to 5 in a whiteout, when the wind lays the flakes over (weather.gd).
uniform float snow_lean = 2.0;
// The drop's colour, and for a flake whether it has the crystal's shape
// (1) or stays a soft grain (0, blowing sand and dust). weather.gd sets
// both per kind.
uniform vec3 tint = vec3(0.82, 0.86, 0.92);
uniform float crystal = 1.0;

// Nothing is drawn nearer the eye than NEAR_CLIP nodes, and a drop fades in
// from there to NEAR_FADE: a drop that close is out of focus, and drawn hard
// it reads as a scratch on the screen.
const float NEAR_CLIP = 0.3;
const float NEAR_FADE = 1.2;
// How far in from a box's faces a drop fades, sideways and at the top and
// bottom, so a drop wrapping from one face to the other is not seen to.
const float EDGE_FADE = 1.5;

// The fill the terrain takes from the sky light channel (nodes_array's
// emission), so a drop in a storm's dim daylight is not lit by the
// environment's ambient alone.
global uniform vec3 goanna_sky_fill;
global uniform vec3 goanna_ground_fill;
global uniform float goanna_eye_underwater;

varying vec3 v_world;
varying vec2 v_quad;
varying float v_weight;
// Snow only: the flake's turn about the view axis, how much of its shape a
// pixel can show (0 a dot, 1 the whole crystal) and how far the wind has
// smeared it (0 still, 1 a streak).
varying float v_spin;
varying float v_detail;
varying float v_blur;

// PCG hash (Jarzynski and Olano, "Hash functions for GPU rendering", 2020):
// a drop's seed from its instance number. weather.gd mirrors it exactly, in
// 32 bit arithmetic, so a test can place the same drops the GPU does.
uint goanna_pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float goanna_unit(uint h) {
	return float(h >> 8u) / 16777216.0;
}

void vertex() {
	uint id = uint(INSTANCE_ID);
	uint h0 = goanna_pcg(id);
	uint h1 = goanna_pcg(h0);
	uint h2 = goanna_pcg(h1);
	uint h3 = goanna_pcg(h2);
	uint h4 = goanna_pcg(h3);
	vec3 seed = vec3(goanna_unit(h0), goanna_unit(h1), goanna_unit(h2));
	float pick = goanna_unit(h3);
	float vary = goanna_unit(h4);
	// A flake's form, from a hash of its own: size and spin. Kept apart
	// from the five above, which weather.gd mirrors to place drops.
	float form = goanna_unit(goanna_pcg(h4));

	bool near = INSTANCE_ID < near_instances;
	vec3 box = near ? near_box : far_box;
	vec3 corner = eye - vec3(box.x * 0.5, near ? near_below : far_below, box.z * 0.5);

	// Velocity. Rain leans with the wind, held to max_lean; snow drifts
	// with it, up to snow_lean times its fall speed.
	float fall = speed * (snow ? 0.75 + 0.5 * vary : 0.85 + 0.3 * vary);
	vec2 w = wind;
	float cap = snow ? snow_lean * fall : max_lean * fall;
	if (length(w) > cap)
		w *= cap / length(w);
	vec3 vel = vec3(w.x, -fall, w.y);
	// The wrap. mod() is floored, so this is in [0, box) for any sign.
	vec3 p = corner + mod(seed * box + vel * TIME - corner, box);
	if (snow) {
		// Flakes flutter: a slow sway of their own on top of the drift. It
		// is added after the wrap, so it can take a flake a little over a
		// face, where it is already faded out.
		float ph = vary * 6.2832;
		p.xz += vec2(sin(TIME * (0.7 + vary) + ph), cos(TIME * (0.6 + 0.8 * vary) + ph * 1.7)) * 0.2;
	}

	// Fade toward the box's faces, sideways and at the top and bottom.
	vec3 lo = p - corner;
	vec3 hi = corner + box - p;
	float edge = smoothstep(0.0, EDGE_FADE, min(min(lo.x, hi.x), min(lo.z, hi.z)))
			* smoothstep(0.0, EDGE_FADE, min(lo.y, hi.y));

	// The drop as a segment: its head at p, its tail up the path it came
	// down. A flake is a point.
	vec3 dir = normalize(vel);
	float len = snow ? 0.0 : fall * streak_time * (0.8 + 0.4 * seed.x);
	vec3 tail = p - dir * len;
	vec3 cam = CAMERA_POSITION_WORLD;
	// Nearest point of the segment to the eye, to keep drops off the lens.
	vec3 seg = p - tail;
	float k = len > 0.0 ? clamp(dot(cam - tail, seg) / dot(seg, seg), 0.0, 1.0) : 1.0;
	float nearest = length(tail + seg * k - cam);

	// Covered, fallen below the ground, or not part of this intensity: the
	// quad collapses to a point and draws nothing. Cover is asked at the
	// tail, the streak's top; the fragment asks again, pixel by pixel.
	// With no map yet (the first scan of a storm) nothing falls, rather
	// than rain falling through every roof until the scan is whole.
	float open = goanna_rain_open(tail, 0.0);
	bool shown = pick * max_amount < amount && edge > 0.001 && nearest > NEAR_CLIP
			&& open > 0.5 && goanna_eye_underwater < 0.5;

	// Width: the drop's own, or a pixel and a half at its distance,
	// whichever is wider, with the coverage kept in the weight.
	vec3 mid = mix(p, tail, 0.5);
	float dist = max(length(mid - cam), 0.01);
	float pixel = dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	// Flakes are not all one size: most are small, a few are clumps of
	// several stuck together, which is most of what reads as snow rather
	// than as a field of identical dots.
	float flake = snow ? mix(0.45, 1.2, form * form) * (form > 0.96 ? 1.5 : 1.0) : 1.0;
	float half_w = max(drop_half_width * flake, pixel * 0.75);
	float cover = drop_half_width * flake / half_w;
	v_detail = clamp((drop_half_width * flake / pixel - 1.0) / 3.0, 0.0, 1.0);
	v_spin = form * 6.2832 + TIME * (0.4 + 1.2 * form) * (form > 0.5 ? 1.0 : -1.0);
	v_blur = 0.0;

	vec3 to_eye = normalize(cam - mid);
	vec3 world;
	if (snow) {
		// A flake faces the camera. Driven hard, it smears along its path,
		// as a flake does to the eye in a gale: the quad stretches along the
		// velocity seen across the view, up to three and a half times, and
		// its light spreads over the length.
		float lean = length(vel.xz) / max(fall, 0.01);
		float stretch = 1.0 + clamp((lean - 1.5) * 0.6, 0.0, 2.5);
		vec3 across_view = vel - dot(vel, to_eye) * to_eye;
		vec3 axis = length(across_view) > 1e-3 ? normalize(across_view) : INV_VIEW_MATRIX[1].xyz;
		vec3 side = normalize(cross(axis, to_eye));
		// Thinner as it lengthens, so a driven flake is a streak, not an oval.
		world = p + (side * VERTEX.x / sqrt(stretch) + axis * VERTEX.y * stretch) * 2.0 * half_w;
		cover *= cover;   // a flake's coverage is an area
		cover /= sqrt(stretch);
		v_blur = clamp(stretch - 1.0, 0.0, 1.0);
	} else {
		// A streak turns round its own axis to face the camera. Seen end on
		// the axis and the view agree and there is no side to take; the
		// camera's right is as good as any then, since the drop is a dot.
		vec3 side = cross(dir, to_eye);
		side = length(side) > 1e-3 ? normalize(side) : INV_VIEW_MATRIX[0].xyz;
		world = mix(tail, p, VERTEX.y + 0.5) + side * VERTEX.x * 2.0 * half_w;
	}
	if (!shown)
		world = p;
	v_world = world;
	v_quad = VERTEX.xy * 2.0;   // -1 to 1 across and along
	v_weight = shown ? edge * cover : 0.0;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(to_eye, 0.0)).xyz);
}

void fragment() {
	float a;
	if (snow) {
		// Close enough to have a shape, a flake is a small six armed
		// crystal turning as it falls; a pixel or two across, or smeared by
		// the wind, it is the soft dot it always was.
		float r = length(v_quad);
		float disc = 1.0 - smoothstep(0.5, 1.0, r);
		float th = atan(v_quad.y, v_quad.x) + v_spin;
		float arm = 1.0 - smoothstep(0.07, 0.2, abs(sin(3.0 * th)) * r);
		float star = max(1.0 - smoothstep(0.16, 0.3, r), arm * (1.0 - smoothstep(0.7, 1.0, r)));
		a = mix(disc, star, v_detail * (1.0 - v_blur) * crystal);
	} else {
		// Across: brightest on the axis. Along: v_quad.y runs from the tail
		// (-1) to the head (1); a streak is a blur of one drop, so it is
		// even along its length with soft ends.
		float across = 1.0 - abs(v_quad.x);
		float along = smoothstep(-1.0, -0.6, v_quad.y) * (1.0 - smoothstep(0.7, 1.0, v_quad.y));
		a = across * along;
	}
	// Off the lens (NEAR_CLIP and NEAR_FADE), and only where rain falls, at
	// the pixel: a streak that crosses a roof's edge stops at the edge.
	float d = length(v_world - CAMERA_POSITION_WORLD);
	float lens = smoothstep(NEAR_CLIP, NEAR_FADE, d);
	float open = goanna_rain_open(v_world, 0.0);
	ALPHA = clamp(a * drop_alpha * v_weight * lens * open, 0.0, 1.0);
	if (ALPHA < 0.002)
		discard;
	ALBEDO = tint;
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
