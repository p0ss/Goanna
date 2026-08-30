// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// A small blur over sky pixels only, so the cloud march can afford fewer
// steps. sky.gdshader raymarches the cumulus deck with a jittered start
// offset, and the jitter is what turns step banding into noise; at a low
// step count that noise is coarse speckle across every cloud edge. The
// speckle is sampling error with roughly zero mean between neighbours, and
// a cloud carries no detail at pixel scale, so a one or two pixel filter
// recovers the converged image almost exactly. Measured at the benchmark
// vista at 2560x1440, against a 24 step reference:
//
//   24 steps, as shipped          speckle 0.575
//   8 steps                       speckle 4.630, 5.75/255 from the reference
//   8 steps and this pass         speckle 0.274, 3.11/255
//
// so eight steps filtered is quieter than twenty-four unfiltered. Blue
// noise was tried in the jitter instead and is not in this shader because
// it measured no better (5.68 against 5.75) while costing about four per
// cent, and it would have traded away the per-direction jitter's one real
// virtue, that it does not crawl when the camera pans.
//
// Only pixels the depth buffer says are sky are touched, and only sky
// neighbours are averaged into them, so a cloud against a ridge does not
// smear terrain into the sky along the silhouette.
shader_type spatial;
render_mode unshaded, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
// Set from main.gd: zero passes the frame through untouched, so the pass
// costs a copy and nothing else when the clouds are marched at full rate.
uniform float denoise_radius = 0.0;

void vertex() {
	// Full screen quad at the near plane (reversed Z), as light_shafts does.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Reversed Z: nothing drawn means the far plane, which is 0, which is sky.
bool is_sky(vec2 uv) {
	return texture(depth_tex, uv).r < 1e-6;
}

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	if (denoise_radius > 0.01 && is_sky(SCREEN_UV)) {
		vec2 px = denoise_radius / VIEWPORT_SIZE;
		// A 3x3 binomial kernel, which is the cheapest thing that is still a
		// Gaussian. Nine taps at radius 1.5 was measured to take the speckle
		// below the full rate march; more taps buy nothing a cloud can show.
		vec3 sum = vec3(0.0);
		float wsum = 0.0;
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec2 uv = SCREEN_UV + vec2(float(x), float(y)) * px;
				if (!is_sky(uv))
					continue;
				float w = (x == 0 && y == 0) ? 4.0 : ((x == 0 || y == 0) ? 2.0 : 1.0);
				sum += texture(screen_tex, uv).rgb * w;
				wsum += w;
			}
		}
		if (wsum > 0.0)
			col = sum / wsum;
	}
	// ALBEDO, not EMISSION: under `unshaded` Godot takes the fragment colour
	// from ALBEDO alone and never runs the lighting that applies emission.
	ALBEDO = col;
}
