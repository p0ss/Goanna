// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Goanna: the shimmer of air over hot ground, from the climate field
// (docs/systems/climate.md, "Heat"). A full screen quad on the camera,
// made and shown by game/effects/heat_shimmer.gd only while there is heat
// round the player.
//
// Each pixel finds the point it sees from the depth buffer and the field's
// temperature there. Hot air lies in a thin layer over the ground, so a
// glancing look across it, over a long path, bends the most; a look down
// at the ground at one's feet hardly at all. Far hotter places (lava, a
// forge's hearth) shimmer at any angle close by. Like flame_shimmer, it
// adds the difference between the opaque scene at a displaced point and at
// this pixel, so water and glass in front keep their colour.
//
// Mirage: far off, at a glancing angle, over air hotter than about
// 30 C, the ground gives way to the sky mirrored below the horizon, as a
// pale wet looking sheet that shimmers with the rest.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;

#define GOANNA_CLIMATE_FIELD_ONLY
#include "res://shaders/climate.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// The render feature switch render_fire_shimmer, which this shares: off on
// Lowest and Low.
global uniform float goanna_render_fire_shimmer;

// The most a pixel moves, in pixels at 1080 lines, for a glancing look
// over long hot ground; and how much of the mirrored sky a mirage takes.
uniform float shimmer_pixels = 4.0;
uniform float mirage_strength = 0.7;

void vertex() {
	POSITION = goanna_render_fire_shimmer < 0.5 ? vec4(0.0) : vec4(VERTEX.xy, 1.0, 1.0);
}

// Heat in the air over a point at `t` C: from 24 C a little, 36 C fully
// (the field is the air's; sunlit ground runs far hotter),
// and well beyond that (40 to 80 C: the field's cells by lava or a hearth,
// which average the source with the air round it) a second, stronger
// share that does not need a glancing look.
vec2 heat(float t) {
	return vec2(smoothstep(24.0, 36.0, t), smoothstep(40.0, 80.0, t));
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	// Reversed Z: nothing drawn here, only sky.
	if (depth <= 0.0) {
		discard;
	}
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec3 eye = INV_VIEW_MATRIX[3].xyz;
	vec3 ray = world - eye;
	float dist = length(ray);
	vec3 dir = ray / max(dist, 0.001);
	// The air just over the surface seen, which the field holds a texel up.
	vec4 c = goanna_climate_at(world + vec3(0.0, 1.0, 0.0));
	if (c.w < 0.01) {
		discard;
	}
	vec2 h = heat(c.x) * c.w;
	// Glancing: the ray nearly level. Long: the hot layer is crossed over
	// tens of nodes, not one.
	float glance = 1.0 - smoothstep(0.04, 0.3, abs(dir.y));
	float along = smoothstep(6.0, 60.0, dist);
	float near = 1.0 - smoothstep(16.0, 48.0, dist);
	float k = h.x * glance * along + h.y * near;
	if (k < 0.002) {
		discard;
	}
	// Waves rising off the ground, keyed to the world so they hold still
	// as the view turns: mostly a vertical wobble in thin bands.
	float t = TIME;
	vec2 wave = vec2(
			sin(dot(world.xz, vec2(0.9, 0.4)) * 1.3 + world.y * 2.1 - t * 4.3)
				* 0.35,
			sin(world.y * 5.7 - t * 6.1 + sin(world.x * 0.7 + t * 1.7) * 1.4)
				+ 0.5 * sin(world.z * 1.9 + world.y * 3.1 - t * 8.3));
	vec2 px = wave * shimmer_pixels * min(k, 1.5) * (VIEWPORT_SIZE.y / 1080.0);
	vec2 uv = clamp(SCREEN_UV + px / VIEWPORT_SIZE, vec2(0.0), vec2(1.0));
	vec3 here = texture(screen_tex, SCREEN_UV).rgb;
	vec3 bent = texture(screen_tex, uv).rgb;
	vec3 col = bent - here;
	// The mirage: the sky the same angle above the horizon, where it is sky.
	float m = mirage_strength * smoothstep(30.0, 40.0, c.x) * c.w
			* (1.0 - smoothstep(0.0, 0.05, -dir.y)) * step(dir.y, 0.0)
			* smoothstep(50.0, 140.0, dist);
	if (m > 0.002) {
		vec3 up = vec3(dir.x, -dir.y, dir.z);
		vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(eye + up * 1000.0, 1.0);
		vec2 muv = clip.xy / clip.w * 0.5 + 0.5;
		if (all(greaterThan(muv, vec2(0.0))) && all(lessThan(muv, vec2(1.0)))
				&& texture(depth_tex, muv).r <= 0.0) {
			vec3 sky = texture(screen_tex, clamp(muv + px / VIEWPORT_SIZE, vec2(0.0), vec2(1.0))).rgb;
			col += (sky - bent) * m;
		}
	}
	ALBEDO = col;
}
