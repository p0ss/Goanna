// Goanna: the sky. Vanilla Luanti draws sun and moon discs (textures from the
// server), stars and a flat cloud layer; Godot's procedural gradient had none
// of them, so nights were blank and water had nothing to reflect. Drawing
// them in the sky shader puts them in the radiance cubemap too, so
// reflections pick them up for free.
shader_type sky;

uniform vec4 sky_top : source_color = vec4(0.36, 0.55, 0.85, 1.0);
uniform vec4 sky_horizon : source_color = vec4(0.72, 0.8, 0.9, 1.0);
uniform vec4 ground_color : source_color = vec4(0.2, 0.2, 0.22, 1.0);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_dir = vec3(0.0, -1.0, 0.0);
uniform float sun_size : hint_range(0.0, 0.5) = 0.05;
uniform float moon_size : hint_range(0.0, 0.5) = 0.04;
uniform bool sun_visible = true;
uniform bool moon_visible = true;
uniform bool sun_use_tex = false;
uniform bool moon_use_tex = false;
uniform sampler2D sun_tex : source_color, filter_nearest;
uniform sampler2D moon_tex : source_color, filter_nearest;
uniform vec4 sun_tint : source_color = vec4(1.0, 0.95, 0.85, 1.0);
uniform vec4 moon_tint : source_color = vec4(0.9, 0.92, 1.0, 1.0);
uniform float star_opacity = 0.0;
uniform vec4 star_color : source_color = vec4(0.92, 0.92, 1.0, 1.0);
uniform float star_density = 0.35;
uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 0.9);
uniform float cloud_coverage = 0.4;
uniform float cloud_plane_h = 90.0;
uniform vec2 cloud_offset = vec2(0.0);
uniform float cloud_scale = 0.035;
// Goanna: what the sky feeds to lighting is not what it shows. Godot samples
// this shader into the radiance cubemap that SDFGI and the ambient term read,
// with AT_CUBEMAP_PASS set, so the lighting half can differ from the visible
// half where the look and the light disagree. Three ways, all judged on
// project/lighting_chart.tscn (docs/pbr-plan.md step 3):
//   radiance_ground_lift  the visible ground half of the dome is the horizon
//                         colour darkened, which reads as a horizon; as
//                         light it tells a vertical face that the ground
//                         below is dark, when the ground is sunlit. 1 uses
//                         the horizon colour for the lower hemisphere.
//   radiance_desaturate   Mineclonia's zenith is a saturated blue and the
//                         look here deepens it further; as light it turns
//                         every shadowed face blue. Pulls the radiance
//                         toward its own luminance.
//   radiance_floor        added to the radiance only. A black night sky with
//                         stars lights nothing, and Luanti's night is a dim
//                         blue world, not a black one. main.gd sets this from
//                         the night weight; it is zero by day.
uniform float radiance_ground_lift : hint_range(0.0, 1.0) = 0.0;
uniform float radiance_desaturate : hint_range(0.0, 1.0) = 0.0;
uniform vec3 radiance_floor = vec3(0.0);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i), b = hash12(i + vec2(1, 0));
	float c = hash12(i + vec2(0, 1)), d = hash12(i + vec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Four octaves, so the deck has both big masses and torn edges rather than
// one smooth blob.
float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(7.3, 1.7);
		a *= 0.5;
	}
	return v / 0.9375;
}

// Billboard uv of `dir` on a disc of angular half-size `size` around `center`.
vec2 disc_uv(vec3 dir, vec3 center, float size, out float inside) {
	vec3 u_ax = normalize(cross(abs(center.y) > 0.99 ? vec3(1, 0, 0) : vec3(0, 1, 0), center));
	vec3 v_ax = cross(center, u_ax);
	float du = dot(dir, u_ax), dv = dot(dir, v_ax), dc = dot(dir, center);
	inside = (dc > 0.0 && max(abs(du), abs(dv)) < size) ? 1.0 : 0.0;
	return vec2(du, dv) / (2.0 * size) + 0.5;
}

void sky() {
	vec3 dir = EYEDIR;
	float up = clamp(dir.y, -1.0, 1.0);
	vec3 col;
	if (up >= 0.0)
		col = mix(sky_horizon.rgb, sky_top.rgb, pow(up, 0.45));
	else
		col = mix(sky_horizon.rgb, ground_color.rgb, pow(-up, 0.6));
	if (AT_CUBEMAP_PASS) {
		if (up < 0.0)
			col = mix(col, sky_horizon.rgb, radiance_ground_lift);
		col = mix(col, vec3(dot(col, vec3(0.2126, 0.7152, 0.0722))), radiance_desaturate);
		col += radiance_floor;
	}

	// stars: one jittered point per hashed cell on the dome, faded by daylight.
	// sin of the angle to the star (via the cross product) keeps the star far
	// smaller than its cell; a dot-product threshold at this scale would light
	// whole cells.
	if (star_opacity > 0.001 && up > 0.0) {
		float n = 56.0;
		vec3 cell = floor(dir * n);
		float h = hash12(cell.xy * 7.13 + vec2(cell.z * 3.7));
		vec3 jitter = vec3(hash12(cell.xy + cell.z), hash12(cell.yz * 1.7 + cell.x),
				hash12(cell.zx * 2.3 + cell.y)) - 0.5;
		vec3 center = normalize((cell + 0.5 + jitter * 0.7) / n);
		float s = length(cross(dir, center));
		float star = step(h, star_density) * smoothstep(0.0030, 0.0010, s);
		col += star_color.rgb * star * star_opacity * (0.6 + 0.4 * hash12(cell.zy + 4.7));
	}

	float inside;
	if (moon_visible) {
		vec2 uv = disc_uv(dir, moon_dir, moon_size, inside);
		if (inside > 0.5) {
			if (moon_use_tex) {
				vec4 t = texture(moon_tex, uv);
				col = mix(col, t.rgb * moon_tint.rgb * 1.6, t.a);
			} else {
				float d = length(uv - 0.5) * 2.0;
				col = mix(col, moon_tint.rgb * 1.5, smoothstep(1.0, 0.85, d));
			}
		}
	}
	if (sun_visible) {
		vec2 uv = disc_uv(dir, sun_dir, sun_size, inside);
		if (inside > 0.5) {
			if (sun_use_tex) {
				vec4 t = texture(sun_tex, uv);
				col = mix(col, t.rgb * sun_tint.rgb * 3.0, t.a);
			} else {
				float d = length(uv - 0.5) * 2.0;
				col = mix(col, sun_tint.rgb * 4.0, smoothstep(1.0, 0.8, d));
			}
		}
		col += sun_tint.rgb * pow(max(dot(dir, sun_dir), 0.0), 350.0) * 1.2;
	}

	// Cloud deck on a plane overhead, scrolled by the server's cloud speed.
	// The ray is projected onto the deck, so the clouds have real perspective:
	// big overhead, compressed toward the horizon.
	if (cloud_coverage > 0.01 && dir.y > 0.02) {
		vec2 world = dir.xz / dir.y * cloud_plane_h;
		vec2 uv = world * cloud_scale + cloud_offset;
		float n = fbm(uv);
		float cov = smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + 0.16, n);
		float fade = smoothstep(0.02, 0.22, dir.y);
		// Shade by the gradient toward the sun: the sunward side of a mass is
		// bright, the far side darker, which is what reads as volume.
		vec2 sund = normalize(sun_dir.xz + vec2(1e-4));
		float lit = fbm(uv + sund * 0.6);
		float shade = clamp(0.55 + (n - lit) * 3.0, 0.0, 1.0);
		vec3 cc = mix(cloud_color.rgb * 0.45, cloud_color.rgb, shade);
		// warm the clouds near the sun, as at dawn and dusk
		float toward_sun = pow(max(dot(normalize(vec3(dir.x, 0.0, dir.z)), vec3(sund.x, 0.0, sund.y)), 0.0), 3.0);
		cc = mix(cc, cc * sun_tint.rgb * 1.25, 0.35 * toward_sun);
		col = mix(col, cc, cov * fade * cloud_color.a);
	}
	COLOR = col;
}
