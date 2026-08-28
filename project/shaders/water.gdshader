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
uniform float refraction = 0.006;
// Beer-Lambert absorption per node; red dies first, like real water. The
// old (0.55, 0.24, 0.16) went opaque within a few nodes, so every lake read
// as a bottomless blue void; these keep a bed visible ten or so nodes down
// through a teal shift, which is roughly what clear real water does.
uniform vec3 absorption = vec3(0.45, 0.11, 0.05);
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

// Far tiers use the same near sample at the hand-off, then converge on the
// tile average only in the deep far field. Switching immediately to the last
// mip made otherwise flat water change colour at the near/far boundary.
uniform bool lod_flatten = false;
uniform float lod_flatten_near : hint_range(0.0, 2048.0) = 384.0;
uniform float lod_flatten_far : hint_range(0.0, 4096.0) = 1024.0;

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
	float flatten = lod_flatten ? smoothstep(lod_flatten_near, lod_flatten_far,
			length(world_pos - CAMERA_POSITION_WORLD)) : 0.0;
	vec4 tex = mix(texture(albedo_tex, UV),
			textureLod(albedo_tex, vec2(0.5), 24.0), flatten) * COLOR;
	float here = -VERTEX.z;

	if (waving) {
		// Drop octaves with distance. The fine ones are below a pixel long
		// out there and only alias; dropping them is also most of the cost
		// back on a screen that is all ocean.
		float fade = smoothstep(24.0, 200.0, here);
		int octaves = int(mix(float(wave_octaves), 3.0, fade));
		// Seen from below the surface is a mirror at grazing angles, where
		// fine normal detail aliases badly, so soften it there.
		float detail = FRONT_FACING ? wave_strength : wave_strength * 0.35;
		detail *= mix(1.0, 0.45, fade);
		// And in the deep far field even the longest train is below a pixel,
		// so the last octaves hand over to the flat face smoothly; the far
		// tiers run this same ramp, which is what removes the wave seam at
		// whatever range the near mesh happens to end.
		detail *= 1.0 - smoothstep(500.0, 1200.0, here);
		if (detail > 0.004) {
			vec3 n = wave_normal(world_pos.xz, TIME * wave_speed, octaves,
					TAU / max(wave_length, 0.5), wave_relief);
			NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(n, 0.0)).xyz, detail));
		}
	}
	if (!FRONT_FACING)
		NORMAL = -NORMAL;

	// Thickness of water along the view ray, from the opaque depth buffer.
	float behind = scene_distance(SCREEN_UV, INV_PROJECTION_MATRIX);
	float thick = clamp(behind - here, 0.0, 64.0);
	// Past a few hundred nodes every water body reads as deep: at eye height
	// the view ray through a surface out there is always near grazing, so the
	// near mesh is fully absorbed anyway. The far tiers need the same answer
	// forced, because a tier's water plane sits directly on the tier terrain
	// and its measured thickness is near zero, which let the ground show
	// through a sea (docs/far-rendering.md, "the far tier water plane").
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
	// back to the straight sample.
	vec2 ofs = NORMAL.xy * refraction * clamp(thick, 0.0, 3.0);
	vec2 ruv = clamp(SCREEN_UV + ofs, vec2(0.001), vec2(0.999));
	if (scene_distance(ruv, INV_PROJECTION_MATRIX) < here)
		ruv = SCREEN_UV;
	vec3 seen = texture(screen_tex, ruv).rgb;

	vec3 trans = exp(-absorption * thick);
	vec3 deep_col = tex.rgb * 0.5;
	vec3 body = mix(deep_col, seen, trans);
	// The tile's own colour is what makes water read as water rather than as
	// tinted glass, but over a sandy shallow it is just a veil over the sand,
	// so let the shore keep more of what is under it.
	body = mix(body, tex.rgb * 0.85, 0.22 * (1.0 - 0.75 * shallow));

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
		if (dir.z < 0.0) {
			vec4 sclip = PROJECTION_MATRIX * vec4(dir, 1.0);
			vec2 suv = (sclip.xy / sclip.w) * 0.5 + 0.5;
			if (suv == clamp(suv, vec2(0.0), vec2(1.0))
					&& texture(depth_tex, suv).r < 1e-6) {
				vec2 sfade = smoothstep(vec2(0.0), vec2(0.08), suv)
						* (1.0 - smoothstep(vec2(0.92), vec2(1.0), suv));
				reflected = mix(reflected, texture(screen_tex, suv).rgb,
						sfade.x * sfade.y);
			}
		}

		// March the reflected ray against the depth buffer. Steps grow, so a
		// near bank is found precisely and a far one is still reached.
		if (waving && march_keep > 0.001) {
			float step_len = 0.3;
			vec3 p = VERTEX;
			for (int i = 0; i < 24; i++) {
				p += dir * step_len;
				step_len *= 1.32;
				vec4 clip = PROJECTION_MATRIX * vec4(p, 1.0);
				if (clip.w <= 0.0)
					break;
				vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
				if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
					break;
				float scene = scene_distance(uv, INV_PROJECTION_MATRIX);
				float ray = -p.z;
				// Behind the depth buffer, but not so far behind that the ray
				// passed through open space in front of something distant.
				if (ray > scene && ray - scene < step_len * 4.0) {
					// A screen hit is only as good as the edge it sits near:
					// fade it out rather than cutting it off, and let the sky
					// take over.
					vec2 fade2 = smoothstep(vec2(0.0), vec2(0.1), uv)
							* (1.0 - smoothstep(vec2(0.9), vec2(1.0), uv));
					reflected = mix(reflected, texture(screen_tex, uv).rgb,
							fade2.x * fade2.y * march_keep);
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
	ALBEDO = body * (1.0 - refl_mix);
	// Reflected light is light that never entered the water, so it must not
	// be shaded a second time by the lamp that already lit what it came from.
	EMISSION = reflected * refl_mix;
	ALPHA = clamp(0.9 + 0.1 * fres, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.4 + 0.6 * fres;
	// a touch rougher from below, again to stop the mirror aliasing
	ROUGHNESS = FRONT_FACING ? 0.04 : 0.13;
}
