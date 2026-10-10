// Goanna: liquids (Luanti TILE_MATERIAL_LIQUID_TRANSPARENT / WAVING_LIQUID_*).
//
// Waves are normal-only. Displacing the surface vertically tore it away from
// the land it meets and from the water below a waterfall, because neighbouring
// blocks are separate meshes whose shared edges cannot be kept in step; the
// ripple is carried entirely in the shading normal instead.
//
// The field is a sum of octaves that drag each other sideways, so a large body
// of water does not repeat on the node grid the way a fixed pair of sine
// trains does, and it carries swell, chop and ripple at once. The method is
// afl_ext's "Very fast procedural ocean", https://www.shadertoy.com/view/MdXyzX
// (MIT), by way of Glimmer, https://github.com/jbritain/glimmer-shaders (MIT,
// Copyright (c) 2024 Josh Britain). The octave constants are theirs; the rest
// is written against Godot. See THIRD-PARTY.md.
//
// Depth-dependent absorption from the opaque depth buffer (shallow water is
// clear, deep water converges to the water colour), and refraction that is
// validated against depth so it can only ever sample geometry that is really
// behind the surface: an unvalidated offset both doubles the image and drags
// haloes onto blocks that are not behind the water at all.
//
// Reflections are marched in screen space against the same depth buffer, and
// fall back to the sky where the ray leaves the screen. That is what puts
// the far bank and its trees into the water; the sky is most of what a
// water surface reflects anyway, so the fallback is not a poor relation.
// The sky answer itself has two rungs: where the reflected direction's sky
// is on screen, the frame's own sky pixels (clouds, discs, haze, already
// rendered by the opaque pass) are sampled by direction; where it is not,
// a gradient plus a drawn sun disc and halo (goanna_sun_*) stands in, so
// the sun on the water at dawn and dusk survives the fallback's fallback.
//
// The near mesh and the far tiers run this same shader with the same
// parameters, and everything that must differ between near and far (octave
// count, wave strength, the reflection march, absorption, the texture
// flatten) is a continuous function of view distance, never of which mesh a
// pixel came from. That is the whole hand-off strategy: two materials that
// agree at every distance cannot draw a seam, wherever the near mesh ends.
shader_type spatial;
#include "feature_flags.gdshaderinc"
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float wave_speed = 0.6;
// Wavelength of the longest train, in nodes. Each octave is 1.18 times the
// frequency of the one before, so nine octaves span roughly 9 nodes down to 2.
uniform float wave_length = 9.0;
uniform float wave_strength = 0.5;
// Slope of the summed field, before wave_strength blends it against the flat
// face normal. Relief rather than height: nothing is displaced.
uniform float wave_relief = 0.75;
// How hard each octave pulls the ones after it sideways. This is what breaks
// the grid: without it the sum is still periodic, however many trains it has.
uniform float wave_drag = 0.28;
uniform int wave_octaves : hint_range(3, 16) = 9;
// The screen space march stops past this distance and the sky answer stands
// alone. Out there a reflected bank subtends a few pixels; the march is all
// cost and no picture, and the far tiers would otherwise pay it across the
// whole sea.
uniform float reflect_range : hint_range(0.0, 4096.0) = 512.0;
// How far the bed seen through the water shifts where a wave tilts the
// surface, as a screen offset per unit of tilt, node of depth and node of
// distance. Through a surface tilted by s over water d deep the bed seen
// straight down moves about s d (1 - 1/1.33), a quarter of s d; a quarter
// over the 1.4 of a 70 degree view is 0.18. This is what shows a ripple
// from above in the shallows, where the surface reflects only a fiftieth of
// the sky: real shallow water is clear looking down, and its waves are seen
// by how they bend the bed. The old offset, the whole view space normal
// times 0.006 times the ray's length through the water, moved the bed of a
// shallow pool about a pixel, and a ripple looked down on did not show.
// The full 0.18 over depths up to 4 nodes then swung the bed of any deep
// pool about under the background waves until it was queasy to look at, so
// it is 0.12, and only the first REFRACT_DEPTH nodes of depth count.
uniform float refraction = 0.12;
const float REFRACT_DEPTH = 1.5;
// Beer-Lambert absorption per node, and the body's own tint on the tile's
// colour: the optics of the water round the eye, which the underwater fog is
// made from too (project/water_optics.gd, docs/systems/water-optics.md). Red dies
// first, like real water. A beach's or a reef's is (0.45, 0.11, 0.05),
// which keeps a bed visible ten or so nodes down through a teal shift; the
// old (0.55, 0.24, 0.16) went opaque within a few nodes, so every lake read
// as a bottomless blue void. A swamp's is far higher, and browner.
global uniform vec3 goanna_water_absorption;
global uniform vec3 goanna_water_tint;
// The underwater murk as main.gd sets the fog now: its colour, and in w its
// density, for the underside of the surface's mirror past the critical
// angle to fade into.
global uniform vec4 goanna_water_fog;
// How big the water round the eye is, as a scale on the background waves'
// strength in x (water_optics.gd, sea_for): a pond lies nearly flat, the
// open sea runs higher; 1 is what was drawn everywhere before, a lake's.
// Only the strength: scaling their length and speed too multiplied the
// world position and TIME, both large, so every small change in the
// measured size of the water (which there is near a shore, as the eye
// moves) swept the whole pattern's phase, and the sea strobed as if in fast
// forward.
global uniform vec4 goanna_water_sea;
// How much of the tile's colour the water column itself throws back, as an
// albedo the sun and sky then light. Water is dark: a clear column returns
// a few percent of what falls on it, and everything else you see in it is
// either the bed, transmitted, or the sky, reflected. The old body was the
// tile at half strength, lit by the full sun, which made every lake a
// painted blue floor brighter than the reflection could ever be, and the
// bed seen through it was lit a second time on the way out. Measured on
// project/water_ramp.tscn, 2026-09-15: deep water sat at 0.7 of the dry
// sand's luma and 0.45 saturation against the sand's 0.27.
uniform float body_gain : hint_range(0.0, 1.0) = 0.35;
uniform bool waving = true;
uniform bool reflections = true;
// Goanna: 1.0 while the eye is in a liquid, set by GoannaClient. Seen from
// above, the undersides of sloped flowing tops and of neighbouring faces
// draw through the surface as overlapping translucent squares, so back faces
// are dropped unless the eye is under the water, where they are the surface.
global uniform float goanna_eye_underwater;
// The sky gradient main.gd hands the sky shader, so a reflected ray that
// leaves the screen can be answered with the sky it would really have hit.
global uniform vec3 goanna_sky_top;
global uniform vec3 goanna_sky_horizon;
// The sun the same fallback ray would have hit: its direction, and a colour
// already scaled by how much sun there is to reflect (zero at night and when
// a weather sky hides the disc). Set beside the gradient in _apply_sky.
global uniform vec3 goanna_sun_dir;
global uniform vec3 goanna_sun_glow;
// goanna_rain and the rain cover map, for the rings rain draws on the water.
#include "res://shaders/weather_common.gdshaderinc"
// The rings round swimmers and animals moving through the water.
#include "res://shaders/wake.gdshaderinc"
// The ripple patch round the eye (project/ui/wake.gd, src/goanna_ripples.h):
// the surface's height, one float a cell, eight cells a node.
global uniform sampler2D goanna_ripple_height : filter_linear, repeat_disable;
// x, y the world xz of the patch's corner, z its side in nodes, w the
// height of the water surface it lies on.
global uniform vec4 goanna_ripple_area;
// x 1 while the patch's water is moving, 0 when it is still or there is none.
global uniform vec4 goanna_ripple_state;

// Far tiers use the same near sample at the hand-off, then converge on the
// tile average only in the deep far field. Switching immediately to the last
// mip made otherwise flat water change colour at the near/far boundary.
uniform bool lod_flatten = false;
uniform float lod_flatten_near : hint_range(0.0, 2048.0) = 384.0;
uniform float lod_flatten_far : hint_range(0.0, 4096.0) = 1024.0;

// How hard a wake bends the normal (its slope is about 1 at full strength),
// and how much of the surface its crest turns white. Constants, not
// uniforms: every water material is built in C++ and nothing sets them.
const float WAKE_RELIEF = 0.6;
const float WAKE_FOAM = 0.18;
// How hard the ripple patch's slope bends the normal. Its crests are not
// whitened: they are not breaking, and whitening every crest over a few
// centimetres drew a jump into the water as a soft white smoke ring, all
// bright and no dark. A ripple shows the way water shows it, in the bent
// reflection and refraction and, in sunlight, the caustics below.
const float RIPPLE_RELIEF = 0.8;
// Looked down on: how much a ripple's slope towards the sun brightens the
// water (and away from it darkens it); where the patch churns into foam,
// from slope x to y; and the most of the surface the foam covers.
const float RIPPLE_SHADE = 0.6;
const vec2 FOAM_SLOPE = vec2(0.35, 1.0);
const float FOAM_COVER = 0.85;
// Caustics of the ripple patch on the bed: sunlight through a crest is
// focused, and through a trough spread, by about the surface's curvature
// times the depth times (1 - 1/1.33), a quarter. The bed's light is scaled
// by the result, clamped to CAUSTIC_RANGE, and blended in by
// CAUSTIC_STRENGTH at full sun. The curvature is taken over CAUSTIC_SPAN
// texels of the patch either side, which smooths the cell grid out of it.
const float CAUSTIC_FOCUS = 0.25;
const vec2 CAUSTIC_RANGE = vec2(0.3, 2.5);
const float CAUSTIC_STRENGTH = 0.7;
const float CAUSTIC_SPAN = 2.0;

varying vec3 world_pos;

// View-space distance of whatever opaque geometry is at this screen uv.
// inv_proj is passed in: shader built-ins are only in scope in fragment().
float scene_distance(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -(v.z / v.w);
}

// View-space position of that same geometry.
vec3 scene_position(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return v.xyz / v.w;
}

// How much to trust the screen for a reflected ray at screen x: fully on
// screen, and still fully a little way past either side, where the column
// at the edge stands in for what is just off it. On water the reflection of
// a point runs almost straight up the screen from it, so the edge column is
// nearly always the right neighbourhood. Fading to the sky at the sides
// instead drew a band of sky down each edge of the screen that turned with
// the camera, bright at night against a black far bank, where the moonlit
// horizon glow stood in for trees.
float foam_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 foam_hash2(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3))))
			* 43758.5453);
}

float foam_value(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(foam_hash(i), foam_hash(i + vec2(1.0, 0.0)), f.x),
			mix(foam_hash(i + vec2(0.0, 1.0)), foam_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Bubbles on a grid of `cell` nodes at world `p`: each cell may hold one,
// of its own size and place, there with chance `fill`. A bubble is a bright
// rim round a clearer middle. Each lives a second or so, at its own phase,
// then pops and the cell draws again, so froth seethes rather than sits.
float foam_bubbles(vec2 p, float cell, float fill, float t) {
	vec2 g = p / cell;
	vec2 i = floor(g);
	vec2 f = fract(g);
	float best = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 c = i + o;
			float era = floor(t * 0.8 + foam_hash(c + 7.1));
			if (foam_hash(c + era * 3.1) > fill)
				continue;
			vec2 h = foam_hash2(c + era * 5.3);
			vec2 centre = o + 0.2 + 0.6 * h;
			float d = length(f - centre) / mix(0.3, 0.6, h.y);
			float rim = (1.0 - smoothstep(0.75, 1.0, d))
					* mix(0.45, 1.0, smoothstep(0.3, 0.85, d));
			best = max(best, rim);
		}
	}
	return best;
}

float edge_keep(float x) {
	float past = max(-x, x - 1.0);
	return 1.0 - smoothstep(0.15, 0.6, past);
}

// One train and its slope. exp(sin(x) - 1) has sharper crests and flatter
// troughs than a sine, which is how real water sits.
vec2 wave_train(vec2 pos, vec2 dir, float freq, float phase) {
	float x = mod(dot(dir, pos) * freq + phase, TAU);
	float w = exp(sin(x) - 1.0);
	return vec2(w, -w * cos(x));
}

// Sum of octaves, each one shifted by the slope of the ones before it.
float wave_height(vec2 pos, float t, int octaves, float base_freq) {
	// Without this every octave shares a phase at the origin, and the shared
	// phase is a visible seam running through the water.
	float phase_shift = length(pos) * 0.1;
	float iter = 0.0;
	float freq = base_freq;
	float t_mul = 2.0;
	float weight = 1.0;
	float sum = 0.0;
	float sum_w = 0.0;
	for (int i = 0; i < octaves; i++) {
		float a = mod(iter, TAU);
		vec2 dir = vec2(sin(a), cos(a));
		vec2 r = wave_train(pos, dir, freq, t * t_mul + phase_shift);
		pos += dir * r.y * weight * wave_drag;
		sum += r.x * weight;
		sum_w += weight;
		weight *= 0.8;
		freq *= 1.18;
		t_mul *= 1.07;
		// A large irrational step, so no two octaves share a direction.
		iter += 1232.399963;
	}
	return sum / sum_w;
}

// Central differences on the height field. Cheaper than it looks: the octave
// count is already down to a handful by the time a surface is far enough away
// for the cost to be spread over many pixels.
vec3 wave_normal(vec2 pos, float t, int octaves, float base_freq, float amp) {
	float e = 0.09;
	float h = wave_height(pos, t, octaves, base_freq);
	float hx = wave_height(pos + vec2(e, 0.0), t, octaves, base_freq);
	float hz = wave_height(pos + vec2(0.0, e), t, octaves, base_freq);
	return normalize(vec3((h - hx) * amp, e, (h - hz) * amp));
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (!FRONT_FACING && goanna_eye_underwater < 0.5)
		discard;
	// Godot hands a back face its normal already turned to face the eye
	// (DO_SIDE_CHECK in its scene shader). Everything below bends the
	// surface's own normal, the one pointing out of the water, and turns it
	// to the eye at the end. Taken as it came, the underside's normal
	// pointed down: the waves were mixed into the opposite of their own
	// normal, and the check below that this is the top of the water failed
	// for the underside, which lost its ripples and its mirror.
	if (!FRONT_FACING)
		NORMAL = -NORMAL;
	// The face's own up, before any wave bends it: whether this is the top
	// of the water or the side of a fall (reflect() below needs to know).
	float face_up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
	// And the face's normal itself, so the refraction can take only what the
	// waves, rain, rings and ripples did to it.
	vec3 flat_normal = NORMAL;
	float flatten = lod_flatten ? smoothstep(lod_flatten_near, lod_flatten_far,
			length(world_pos - CAMERA_POSITION_WORLD)) : 0.0;
	vec4 tex = mix(texture(albedo_tex, UV),
			textureLod(albedo_tex, vec2(0.5), 24.0), flatten) * COLOR;
	float here = -VERTEX.z;

	if (waving && goanna_render_water_waves > 0.5) {
		// Drop octaves with distance. The fine ones are below a pixel long
		// out there and only alias; dropping them is also most of the cost
		// back on a screen that is all ocean.
		float fade = smoothstep(24.0, 200.0, here);
		int octaves = int(mix(float(wave_octaves), 3.0, fade));
		// The same waves from below as from above: they are one surface.
		// Seen from under it they were softened to a third, against
		// aliasing where the underside is a mirror, and the underside's
		// pattern stopped matching the top's. The mirror is now the murk's
		// own colour (total internal reflection, below), not a sharp image.
		float detail = wave_strength;
		detail *= mix(1.0, 0.45, fade);
		// And in the deep far field even the longest train is below a pixel,
		// so the last octaves hand over to the flat face smoothly; the far
		// tiers run this same ramp, which is what removes the wave seam at
		// whatever range the near mesh happens to end.
		detail *= 1.0 - smoothstep(500.0, 1200.0, here);
		// The sea state is measured round the eye; far out, where the water
		// may be another body altogether, it hands back to a lake's.
		detail *= mix(goanna_water_sea.x, 1.0, smoothstep(64.0, 160.0, here));
		if (detail > 0.004) {
			vec3 n = wave_normal(world_pos.xz, TIME * wave_speed, octaves,
					TAU / max(wave_length, 0.5), wave_relief);
			NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(n, 0.0)).xyz, detail));
		}
	}
	// Rain rings, where rain is really landing on this water: not under a
	// bridge or a roof, by the same cover map the falling rain is drawn
	// against. Normal only, like the waves, and only near the eye, where a
	// ring is more than a pixel; they ride on top of the waves rather than
	// replacing them. They are gone by 22 nodes, inside the cover map's
	// 32 node reach, so its edge never shows as a line of rings; further
	// out a ring is a pixel or two and only glitters in the sun.
	if (goanna_render_wet_surfaces > 0.5 && goanna_rain > 0.001 && FRONT_FACING && here < 22.0) {
		float open = goanna_rain_open(world_pos, 1.0);
		float k = open * min(goanna_rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, here));
		if (k > 0.001) {
			// A ring now stays inside its cell (weather_common), so the
			// cell is sized for rings of up to about a quarter node.
			float cell = 1.0;
			vec2 rings = goanna_rain_rings(world_pos.xz, TIME, cell, 0.9,
					clamp(0.45 * goanna_rain, 0.0, 0.9));
			vec3 nw = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
			nw = normalize(nw - vec3(rings.x, 0.0, rings.y) * 0.35 * k);
			NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
		}
	}
	// Wakes, round the player and animals moving through the water. Normal
	// only, like the rain rings, and summed on top of the waves and the rain
	// so a swimmer in a storm still leaves a trail. From below too: the
	// surface seen from under it is the same water. The crest also whitens
	// the water a little where a body is moving hard, which is what reads
	// when the sky in the water is too dark for the normal alone to show.
	float wake_foam = 0.0;
	{
		vec3 wake = goanna_wake(world_pos.xz, here);
		if (dot(wake, wake) > 1e-8) {
			vec3 nw = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
			nw = normalize(nw - vec3(wake.x, 0.0, wake.y) * WAKE_RELIEF);
			NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
			wake_foam = wake.z * WAKE_FOAM;
		}
	}
	// Ripples, on the one surface the patch lies on and only on the top of
	// the water, from above or below. Where the patch has water the rings
	// are not drawn (wake.gd hands those bodies to the patch), so the two
	// add rather than double.
	vec2 ripple_grad = vec2(0.0);
	if (goanna_ripple_state.x > 0.5 && face_up > 0.7
			&& abs(world_pos.y - goanna_ripple_area.w) < 0.4) {
		vec2 ruv = (world_pos.xz - goanna_ripple_area.xy) / goanna_ripple_area.z;
		if (ruv == clamp(ruv, vec2(0.0), vec2(1.0))) {
			vec2 texel = 1.0 / vec2(textureSize(goanna_ripple_height, 0));
			float hl = texture(goanna_ripple_height, ruv - vec2(texel.x, 0.0)).r;
			float hr = texture(goanna_ripple_height, ruv + vec2(texel.x, 0.0)).r;
			float hd = texture(goanna_ripple_height, ruv - vec2(0.0, texel.y)).r;
			float hu = texture(goanna_ripple_height, ruv + vec2(0.0, texel.y)).r;
			vec2 grad = vec2(hr - hl, hu - hd) / (2.0 * goanna_ripple_area.z * texel);
			ripple_grad = grad;
			vec3 nw = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
			nw = normalize(nw - vec3(grad.x, 0.0, grad.y) * RIPPLE_RELIEF);
			NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
		}
	}
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
		flat_normal = -flat_normal;
	}

	// Thickness of water along the view ray, from the opaque depth buffer.
	float behind = scene_distance(SCREEN_UV, INV_PROJECTION_MATRIX);
	float thick = clamp(behind - here, 0.0, 64.0);
	// From under the surface what lies behind it is air, not water: the
	// water this light crosses is the stretch from the surface to the eye.
	// Taking the depth behind the surface instead (as much as 64 nodes to
	// the trees or the sky) absorbed everything seen up through the surface
	// to near black.
	// And that stretch has been taken already: the opaque pass absorbed
	// whatever it drew under the water's reach by the water between it and
	// the eye (underwater.gdshaderinc), and the sky is put in below.
	if (!FRONT_FACING)
		thick = 0.0;
	// Past a few hundred nodes every water body reads as deep: at eye height
	// the view ray through a surface out there is always near grazing, so the
	// near mesh is fully absorbed anyway. The far tiers need the same answer
	// forced, because a tier's water plane sits directly on the tier terrain
	// and its measured thickness is near zero, which let the ground show
	// through a sea (docs/history/far-rendering-log.md, "the far tier water plane").
	float deep_far = smoothstep(160.0, 420.0, here);
	thick = max(thick, 64.0 * deep_far);
	// How far the floor is straight down, which is what "shallow" means to
	// anyone standing on the shore. The view ray length is long at a grazing
	// angle however shallow the water is, so it cannot answer this.
	vec3 floor_world = (INV_VIEW_MATRIX
			* vec4(scene_position(SCREEN_UV, INV_PROJECTION_MATRIX), 1.0)).xyz;
	float below = clamp(world_pos.y - floor_world.y, 0.0, 64.0);
	below = max(below, 32.0 * deep_far);
	float shallow = exp(-below * 0.9);

	// Refraction, validated: if the offset sample is not actually behind the
	// water surface it would be a halo pulled off unrelated geometry, so fall
	// back to the straight sample. Only the waves' tilt moves the bed, not
	// the face's own slant to the view, and by the depth of water over it
	// (seen from below, by the water between the eye and the surface).
	float refract_depth = clamp(FRONT_FACING ? below : thick, 0.0, REFRACT_DEPTH);
	vec2 ofs = (NORMAL - flat_normal).xy * refraction * refract_depth / max(here, 0.5);
	ofs = clamp(ofs, vec2(-0.03), vec2(0.03));
	vec2 ruv = clamp(SCREEN_UV + ofs, vec2(0.001), vec2(0.999));
	if (scene_distance(ruv, INV_PROJECTION_MATRIX) < here)
		ruv = SCREEN_UV;
	vec3 seen = texture(screen_tex, ruv).rgb;
	// The bed goes out as emission now, unshaded and unclamped, so a bad
	// pixel in the opaque pass (a NaN, or a sun disc at many times white)
	// would come through as a coloured speck. Bounded here rather than
	// trusted.
	if (any(isnan(seen)) || any(isinf(seen)))
		seen = vec3(0.0);
	seen = min(seen, vec3(8.0));

	// Caustics. Looked down on, clear shallow water reflects a fiftieth of
	// the sky and hides its waves; what shows them is the sunlight they
	// focus into moving bright lines on the bed. The light reaching the bed
	// here came in through the surface up the refracted sun ray, so the
	// patch is read there; only in sunlight (goanna_sun_glow is dark at
	// night, under a weather sky and in a ridge's shadow), and only for the
	// ripple patch, whose heights are at hand.
	if (goanna_ripple_state.x > 0.5 && FRONT_FACING && face_up > 0.7
			&& abs(world_pos.y - goanna_ripple_area.w) < 0.4 && below < 8.0) {
		float sun_k = clamp(dot(goanna_sun_glow, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
		vec3 into = refract(-normalize(goanna_sun_dir), vec3(0.0, 1.0, 0.0), 1.0 / 1.33);
		if (sun_k > 0.01 && into.y < -0.2) {
			vec2 entry = floor_world.xz - into.xz * (below / -into.y);
			vec2 cuv = (entry - goanna_ripple_area.xy) / goanna_ripple_area.z;
			if (cuv == clamp(cuv, vec2(0.0), vec2(1.0))) {
				float texel = CAUSTIC_SPAN / float(textureSize(goanna_ripple_height, 0).x);
				float c = texture(goanna_ripple_height, cuv).r;
				float around = texture(goanna_ripple_height, cuv + vec2(texel, 0.0)).r
						+ texture(goanna_ripple_height, cuv - vec2(texel, 0.0)).r
						+ texture(goanna_ripple_height, cuv + vec2(0.0, texel)).r
						+ texture(goanna_ripple_height, cuv - vec2(0.0, texel)).r;
				float span = texel * goanna_ripple_area.z;
				float curvature = (around - 4.0 * c) / (span * span);
				float focus = 1.0 / max(1.0 + CAUSTIC_FOCUS * below * curvature, 0.05);
				seen *= mix(1.0, clamp(focus, CAUSTIC_RANGE.x, CAUSTIC_RANGE.y),
						sun_k * CAUSTIC_STRENGTH);
			}
		}
	}

	vec3 trans = exp(-goanna_water_absorption * thick);
	// Two things come up out of the water and they are lit differently. The
	// bed, seen through the column, was lit when the opaque pass drew it and
	// arrives here as radiance: it goes out as emission, attenuated, and is
	// not shaded again. The column's own scatter is the tile's colour, dim,
	// and that is the one part the lamp lights; it is what is left where the
	// column has absorbed the bed away, so it takes the share the bed lost.
	vec3 transmitted = seen * trans;
	vec3 scatter = tex.rgb * goanna_water_tint * 0.5 * body_gain * (1.0 - trans);

	// Face on you see into the water, grazing you see the world reflected.
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	// Schlick, with water's real normal-incidence reflectance.
	float refl_amount = clamp(0.02 + 0.98 * fres, 0.0, 1.0);

	vec3 reflected = vec3(0.0);
	// Looking straight down there is almost nothing reflected to find, and
	// from under the surface nothing marches at all.
	bool do_reflect = reflections && FRONT_FACING
			&& goanna_eye_underwater < 0.5 && refl_amount > 0.03;
	// The march is the expensive half, and past reflect_range it finds only
	// what the sky answer already says, so it fades out with distance; the
	// sky fallback runs everywhere, far tiers included, which is what keeps
	// the horizon water lit instead of a dark band past the near mesh.
	float march_keep = 1.0 - smoothstep(reflect_range * 0.7, reflect_range, here);
	if (do_reflect) {
		vec3 dir = reflect(normalize(VERTEX), NORMAL);
		// The sky the ray would have reached, on the same curve the sky
		// shader uses, as both the fallback and what a screen hit fades to.
		vec3 world_dir = normalize((INV_VIEW_MATRIX * vec4(dir, 0.0)).xyz);
		// Seen at a grazing angle, a wave's slope is steeper than the view
		// ray and tips the reflection below the horizon, into the water. The
		// ray would really meet the back of the next wave and reflect up off
		// it, so it is folded back above the horizon here. Left pointing
		// down, it found nothing to march to and took the pale horizon
		// colour, which lay a white veil over the whole lake whenever the
		// eye was near the water. Only on the top of the water: the side of
		// a fall really does reflect the ground in front of it.
		if (face_up > 0.7 && world_dir.y < 0.02) {
			world_dir.y = max(-world_dir.y, 0.02);
			world_dir = normalize(world_dir);
			dir = normalize((VIEW_MATRIX * vec4(world_dir, 0.0)).xyz);
		}
		float up = clamp(world_dir.y, 0.0, 1.0);
		reflected = mix(goanna_sky_horizon, goanna_sky_top, pow(up, 0.45));
		// The sun in that sky, disc and halo, the same shape and weights
		// sky.gdshader draws (its disc is tint times 3, its halo the same
		// power of 350). This is what lays the sunrise and sunset out
		// across the water; on the waves the jittered normal breaks it
		// into the glitter path.
		float sun_d = max(dot(world_dir, goanna_sun_dir), 0.0);
		reflected += goanna_sun_glow
				* (pow(sun_d, 1500.0) * 3.0 + pow(sun_d, 350.0) * 0.8);

		// Better than any gradient: the sky as it was actually drawn this
		// frame. The opaque pass has already rendered the sky shader, clouds,
		// discs and haze included, into the screen texture this shader is
		// sampling anyway, and the camera sits at the view space origin, so a
		// reflected direction projects to the screen point showing that very
		// direction with one matrix multiply. Water near the horizon reflects
		// sky just above the horizon, which is exactly the sky most likely to
		// be on screen; a ray whose sky is off screen keeps the gradient and
		// the drawn glint, and fresnel is small at those steep angles anyway.
		// Only where the depth buffer says sky (reversed Z, far plane is 0):
		// by-direction sampling treats everything as infinitely far, which is
		// true of the sky and a double image on near geometry, whose parallax
		// the march below handles properly. The wave normal is already in the
		// direction, so the reflection ripples for free.
		// Past a side of the screen the column at the edge stands in (see
		// edge_keep), so only the top and bottom fade.
		if (goanna_render_water_reflections > 0.5 && dir.z < 0.0) {
			vec4 sclip = PROJECTION_MATRIX * vec4(dir, 1.0);
			vec2 suv = (sclip.xy / sclip.w) * 0.5 + 0.5;
			float skeep = edge_keep(suv.x);
			suv.x = clamp(suv.x, 0.002, 0.998);
			if (suv.y >= 0.0 && suv.y <= 1.0 && skeep > 0.0
					&& texture(depth_tex, suv).r < 1e-6) {
				float sfade = smoothstep(0.0, 0.08, suv.y)
						* (1.0 - smoothstep(0.92, 1.0, suv.y));
				reflected = mix(reflected, texture(screen_tex, suv).rgb,
						sfade * skeep);
			}
		}

		// March the reflected ray against the depth buffer. Steps grow, so a
		// near bank is found precisely and a far one is still reached.
		if (goanna_render_water_reflections > 0.5 && waving && march_keep > 0.001) {
			float step_len = 0.3;
			vec3 p = VERTEX;
			for (int i = 0; i < 24; i++) {
				p += dir * step_len;
				step_len *= 1.32;
				vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
				if (clip.w <= 0.0)
					break;
				vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
				if (uv.y < 0.0 || uv.y > 1.0)
					break;
				float keep = edge_keep(uv.x);
				if (keep <= 0.0)
					break;
				uv.x = clamp(uv.x, 0.002, 0.998);
				float scene = scene_distance(uv, INV_PROJECTION_MATRIX);
				float ray = -p.z;
				// Behind the depth buffer, but not so far behind that the ray
				// passed through open space in front of something distant.
				if (ray > scene && ray - scene < step_len * 4.0) {
					// A hit near the top or bottom of the screen fades to
					// the sky rather than cutting off; past a side, the
					// edge column stands in (edge_keep).
					float fade_y = smoothstep(0.0, 0.1, uv.y)
							* (1.0 - smoothstep(0.9, 1.0, uv.y));
					reflected = mix(reflected, texture(screen_tex, uv).rgb,
							fade_y * keep * march_keep);
					break;
				}
			}
		}
	}

	// The reflected share only comes out of the body where it is going back
	// in as light. Nothing is reflected from below, and taking it out anyway
	// drove the surface to black at exactly the grazing angles that fill the
	// view when you are under it.
	float refl_mix = do_reflect ? refl_amount : 0.0;
	ALBEDO = scatter * (1.0 - refl_mix);
	// Broken water at a wake's crest: a little white the lamp lights, taken
	// out of what comes up through the surface.
	ALBEDO = mix(ALBEDO, vec3(0.8), wake_foam);
	// Reflected light is light that never entered the water, and the bed's
	// light has already been through the lamp once, so neither is shaded
	// again here.
	EMISSION = (transmitted * (1.0 - refl_mix) + reflected * refl_mix) * (1.0 - wake_foam);
	// The ripple patch looked down on. Clear water reflects a fiftieth of
	// the sky straight down and the bent normal only shifts the bed a
	// little, so from any height the rings round a body did not show. The
	// faces of a ripple turned towards the sun are lit and those turned
	// away shaded, as a slope of ground is; and where the patch is steep,
	// at the bow of a body pushing through and hard round one going in, the
	// water churns into froth: bubbles, more of them the steeper it is, in
	// uneven clumps, popping and coming back. An even white wash, what the
	// whitening of the earlier rings did, read as smoke rings.
	float ripple_steep = length(ripple_grad);
	if (FRONT_FACING && ripple_steep > 1e-4) {
		// Lit from the sun's side however high it stands, or, with it
		// straight overhead, from across the view.
		vec2 key = goanna_sun_dir.xz;
		if (dot(key, key) < 0.0025)
			key = (INV_VIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xz;
		float towards = dot(-ripple_grad, normalize(key));
		EMISSION *= 1.0 + RIPPLE_SHADE * clamp(towards, -1.0, 1.0);
		float churn = smoothstep(FOAM_SLOPE.x, FOAM_SLOPE.y, ripple_steep)
				* mix(0.4, 1.4, foam_value(world_pos.xz * 2.3 + TIME * 0.2));
		churn = clamp(churn, 0.0, 1.0) * (1.0 - smoothstep(16.0, 28.0, here));
		if (churn > 0.01) {
			float froth = max(foam_bubbles(world_pos.xz, 0.07, churn, TIME),
					0.8 * foam_bubbles(world_pos.xz + 3.7, 0.16, churn * 0.7, TIME * 0.8));
			float cover = froth * min(churn * 1.6, 1.0) * FOAM_COVER;
			ALBEDO = mix(ALBEDO, vec3(0.9), cover);
			EMISSION *= 1.0 - cover;
		}
	}
	// From under the water, the sky is seen only through a window straight
	// up: light from above bends down into a cone of about 48.6 degrees
	// either side of the vertical. Past it the underside is a mirror of the
	// water below (total internal reflection): the bed and whatever is in
	// the water, marched for in screen space down the reflected ray, faded
	// into the murk by the length of that ray, and the murk itself where the
	// ray finds nothing. The waves tilt the surface, so they bend the
	// mirrored bed and break the window's edge up into their pattern, which
	// is how the underside of real water shows its waves. Before, the whole
	// underside showed the sky, and then a flat murk colour that read as a
	// black void.
	// Only the top of the water: a side of water seen from inside it (the
	// edge of a flowing step, water beside an air pocket) shows what is
	// behind it, and taking the mirror there drew flat teal sheets.
	if (!FRONT_FACING && face_up > 0.7) {
		float cos_i = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		float sin_i = sqrt(1.0 - cos_i * cos_i);
		// sin of the critical angle is 1 / 1.33, 0.752.
		float tir = smoothstep(0.71, 0.79, sin_i);
		vec3 mirror = goanna_water_fog.rgb;
		if (tir > 0.01 && goanna_render_water_reflections > 0.5) {
			vec3 rdir = reflect(normalize(VERTEX), NORMAL);
			float step_len = 0.25;
			vec3 p = VERTEX;
			// The last thing on screen along the ray, for a ray that finds
			// no surface: what lies that way, faded by how far the ray went.
			// Falling back to the bare murk instead, rays that hit and rays
			// that missed alternated under the waves into bands of mirrored
			// bed and flat teal.
			vec3 last = goanna_water_fog.rgb;
			float last_len = 0.0;
			bool hit = false;
			for (int i = 0; i < 20; i++) {
				p += rdir * step_len;
				step_len *= 1.35;
				vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
				if (clip.w <= 0.0)
					break;
				vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
				if (uv.y < 0.0 || uv.y > 1.0)
					break;
				float keep = edge_keep(uv.x);
				if (keep <= 0.0)
					break;
				uv.x = clamp(uv.x, 0.002, 0.998);
				vec3 seen_here = texture(screen_tex, uv).rgb;
				if (!(any(isnan(seen_here)) || any(isinf(seen_here)))) {
					last = mix(goanna_water_fog.rgb, min(seen_here, vec3(8.0)), keep);
					last_len = length(p - VERTEX);
				}
				float scene = scene_distance(uv, INV_PROJECTION_MATRIX);
				float ray = -p.z;
				if (ray > scene && ray - scene < step_len * 4.0) {
					// The opaque pass absorbed the bed by its distance from
					// the eye; the mirror's light also came up the ray.
					float murk = 1.0 - exp(-goanna_water_fog.w * length(p - VERTEX));
					mirror = mix(last, goanna_water_fog.rgb, murk);
					hit = true;
					break;
				}
			}
			if (!hit)
				mirror = mix(last, goanna_water_fog.rgb, 1.0 - exp(-goanna_water_fog.w * (last_len + 8.0)));
		}
		// Inside the window, the sky. The opaque pass drew the sky behind the
		// surface already fogged into the murk (the underwater fog covers the
		// sky, so nothing past the water's reach shows as open sky), and the
		// window came out the murk's own colour, flat, with nothing for the
		// waves to break up. Where the screen behind the surface is sky, it
		// is drawn here instead, for the ray the surface refracts up into
		// the air, from the same gradient and sun the reflections use.
		vec3 window = EMISSION;
		vec3 up = refract(normalize(VERTEX), NORMAL, 1.33);
		if (dot(up, up) > 1e-6 && texture(depth_tex, ruv).r < 1e-6) {
			vec3 world_up = normalize((INV_VIEW_MATRIX * vec4(up, 0.0)).xyz);
			vec3 sky = mix(goanna_sky_horizon, goanna_sky_top, pow(clamp(world_up.y, 0.0, 1.0), 0.45));
			float sun_d = max(dot(world_up, goanna_sun_dir), 0.0);
			sky += goanna_sun_glow * (pow(sun_d, 1500.0) * 3.0 + pow(sun_d, 350.0) * 0.8);
			// Through the water between the surface and the eye, per
			// colour, as the opaque pass absorbs what it draws.
			window = sky * exp(-goanna_water_absorption * min(here, 64.0));
		}
		EMISSION = mix(window, mirror, tir);
		ALBEDO *= 1.0 - tir;
	}
	// What arrives at the underside has already come through the water to
	// the eye, absorbed and with the murk's glow over it (the opaque pass
	// fogged it over its whole distance). Godot then fogs this fragment
	// again over the distance to the surface, which made the water twice
	// as murky looked through from inside as from above. That fog is taken
	// back out here: the emission is set to what, fogged, comes out as
	// itself.
	if (!FRONT_FACING) {
		float fogged = 1.0 - exp(-goanna_water_fog.w * here);
		EMISSION = max((EMISSION - goanna_water_fog.rgb * fogged)
				/ max(1.0 - fogged, 0.05), vec3(0.0));
	}
	ALPHA = clamp(0.9 + 0.1 * fres, 0.0, 1.0);
	METALLIC = 0.0;
	// Godot's own specular reflects its sky, which is above the surface.
	// From under it that lit the underside with the sky at every grazing
	// angle, brighter than any murk it was meant to be mirroring.
	SPECULAR = FRONT_FACING ? 0.4 + 0.6 * fres : 0.0;
	// a touch rougher from below, again to stop the mirror aliasing
	ROUGHNESS = FRONT_FACING ? 0.04 : 0.13;
}
