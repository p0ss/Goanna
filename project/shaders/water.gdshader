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
// fall back to the sky gradient where the ray leaves the screen. That is what
// puts the far bank and its trees into the water; the sky is most of what a
// water surface reflects anyway, so the fallback is not a poor relation.
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
uniform float refraction = 0.006;
// Beer-Lambert absorption per node; red dies first, like real water.
uniform vec3 absorption = vec3(0.55, 0.24, 0.16);
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

// Far tiers only, set alongside waving=false: a tier's water quad is one
// flat plane per cell, whose UV repeats the tile the same way a solid one
// does, and aliases the same way at range (docs/far-rendering.md, "Shade the
// far field as a far field"). fragment() answers that by sampling the tile's
// last mip rather than by blending toward an average with distance, so the
// three uniforms that blend is set from are no longer read here.
// GoannaClient still sets them on this material, which is harmless, and the
// solid node shaders still use their own copies.
uniform bool lod_flatten = false;

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
	// A tier's quad is one merged face that can span hundreds of nodes while
	// its UV still repeats the tile once per node, so sampling it normally
	// aliases into a shimmer at any range a tier is actually seen from. Take
	// the 1 by 1 mip instead, which is the tile's own average: one colour,
	// from one place, for the whole far surface. That is what the near mesh
	// converges to as well, so the two agree where they meet by construction
	// rather than by a distance blend that has to be tuned. That replaces the
	// blend toward lod_avg_colour between lod_flatten_near and
	// lod_flatten_far, which reached the same colour but only past 64 nodes,
	// so a tier drawn closer than that, which the store produces wherever the
	// server has not streamed a block yet, still showed the tile repeating.
	vec4 tex = lod_flatten ? textureLod(albedo_tex, vec2(0.5), 24.0) * COLOR
			: texture(albedo_tex, UV) * COLOR;
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
		vec3 n = wave_normal(world_pos.xz, TIME * wave_speed, octaves,
				TAU / max(wave_length, 0.5), wave_relief);
		NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(n, 0.0)).xyz, detail));
	}
	if (!FRONT_FACING)
		NORMAL = -NORMAL;

	// Thickness of water along the view ray, from the opaque depth buffer.
	float behind = scene_distance(SCREEN_UV, INV_PROJECTION_MATRIX);
	float thick = clamp(behind - here, 0.0, 64.0);
	// How far the floor is straight down, which is what "shallow" means to
	// anyone standing on the shore. The view ray length is long at a grazing
	// angle however shallow the water is, so it cannot answer this.
	vec3 floor_world = (INV_VIEW_MATRIX
			* vec4(scene_position(SCREEN_UV, INV_PROJECTION_MATRIX), 1.0)).xyz;
	float below = clamp(world_pos.y - floor_world.y, 0.0, 64.0);
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
	// Two places the march is not worth running: waving is false on the far
	// tiers, which are one flat quad per cell and are meant to stay cheap and
	// plain, so it would cost the most where it shows least; and looking
	// straight down there is almost nothing reflected to find.
	bool do_reflect = reflections && waving && FRONT_FACING
			&& goanna_eye_underwater < 0.5 && refl_amount > 0.03;
	if (do_reflect) {
		vec3 dir = reflect(normalize(VERTEX), NORMAL);
		// The sky the ray would have reached, on the same curve the sky
		// shader uses, as both the fallback and what a screen hit fades to.
		vec3 world_dir = normalize((INV_VIEW_MATRIX * vec4(dir, 0.0)).xyz);
		float up = clamp(world_dir.y, 0.0, 1.0);
		reflected = mix(goanna_sky_horizon, goanna_sky_top, pow(up, 0.45));

		// March the reflected ray against the depth buffer. Steps grow, so a
		// near bank is found precisely and a far one is still reached.
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
						fade2.x * fade2.y);
				break;
			}
		}
	}

	ALBEDO = body * (1.0 - refl_amount);
	// Reflected light is light that never entered the water, so it must not
	// be shaded a second time by the lamp that already lit what it came from.
	EMISSION = reflected * refl_amount;
	ALPHA = clamp(0.9 + 0.1 * fres, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.4 + 0.6 * fres;
	// a touch rougher from below, again to stop the mirror aliasing
	ROUGHNESS = FRONT_FACING ? 0.04 : 0.13;
}
