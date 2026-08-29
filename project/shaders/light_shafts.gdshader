// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Screen space crepuscular rays: the "godrays" that stream past a ridge
// when the sun pokes above it. The volumetric fog cannot draw these from
// distant terrain, because its froxel grid is metres wide per cell at any
// range past a couple of hundred nodes and the ridge that shapes the rays
// is a far region mesh the 200 node shadow map never sees. This pass works
// where both of those cannot: it marches the depth buffer from each pixel
// toward the sun's screen position, so anything drawn at any distance,
// far tiers included, occludes the light, and the cost is a few dozen
// depth taps per pixel rather than any shadow map at all.
//
// Drawn on a full screen quad parented to the camera, additive, after the
// opaque pass. main.gd owns the strength: it follows the light shafts
// slider, dies underwater and at night, and fades as the sun climbs,
// because a crepuscular ray is a low sun effect.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
// Set from main.gd: zero disables the pass entirely.
uniform float shaft_strength = 0.0;
// The sun's direction and its glow colour, the same globals the water's
// fallback reflection uses; the glow is already zero at night and under
// weather skies that hide the disc, so those cases cost nothing here.
global uniform vec3 goanna_sun_dir;
global uniform vec3 goanna_sun_glow;

void vertex() {
	// Full screen triangle-strip quad at the near plane (reversed Z).
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec3 col = vec3(0.0);
	// The sun in view space, projected to its screen point the same way
	// water.gdshader projects a reflected direction. Behind the camera
	// there is nothing to march toward.
	vec3 dir = mat3(VIEW_MATRIX) * normalize(goanna_sun_dir);
	float glow = dot(goanna_sun_glow, vec3(0.2126, 0.7152, 0.0722));
	if (shaft_strength > 0.0001 && glow > 0.0001 && dir.z < -0.05) {
		vec4 sclip = PROJECTION_MATRIX * vec4(dir, 1.0);
		vec2 sun_uv = (sclip.xy / sclip.w) * 0.5 + 0.5;
		// Rays keep working while the sun slides a little off frame, then
		// fade rather than pop.
		vec2 edge = smoothstep(vec2(-0.25), vec2(0.0), sun_uv)
				* (1.0 - smoothstep(vec2(1.0), vec2(1.25), sun_uv));
		float on = edge.x * edge.y;
		if (on > 0.001) {
			const int STEPS = 40;
			vec2 duv = (sun_uv - SCREEN_UV) / float(STEPS);
			// Interleaved gradient noise start offset, the same jitter the
			// terrain dither uses: banding from 40 steps becomes noise the
			// eye ignores.
			float jit = fract(52.9829189
					* fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
			vec2 p = SCREEN_UV + duv * jit;
			float acc = 0.0;
			float w = 1.0;
			float total = 0.0;
			for (int i = 0; i < STEPS; i++) {
				// Reversed Z: the far plane is 0, so a pixel nothing was
				// drawn to is sky and the light comes through it.
				if (p == clamp(p, vec2(0.0), vec2(1.0)) && texture(depth_tex, p).r < 1e-6)
					acc += w;
				total += w;
				w *= 0.96;
				p += duv;
			}
			float shaft = acc / total;
			// Rays belong near the sun; the falloff keeps the far corner of
			// the frame from milking over.
			float fall = exp(-2.2 * length(sun_uv - SCREEN_UV));
			// Squaring keeps the fully open sky around the disc from
			// doubling the bloom while a half occluded lane still reads.
			col = goanna_sun_glow * (shaft * shaft * fall * on * shaft_strength);
		}
	}
	ALBEDO = vec3(0.0);
	EMISSION = col;
}
