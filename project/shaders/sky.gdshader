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
uniform float cloud_scale = 0.012;

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

	// flat cloud layer overhead, scrolled by the server's cloud speed
	if (cloud_coverage > 0.01 && dir.y > 0.02) {
		vec2 cpos = dir.xz / dir.y * cloud_plane_h * cloud_scale + cloud_offset;
		float nse = vnoise(cpos) * 0.65 + vnoise(cpos * 2.7 + 13.1) * 0.35;
		float cov = smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + 0.25, nse);
		float fade = smoothstep(0.02, 0.18, dir.y);
		col = mix(col, cloud_color.rgb, cov * fade * cloud_color.a);
	}
	COLOR = col;
}
