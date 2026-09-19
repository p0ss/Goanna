// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Dark glass for Goanna's interface: the panel behind a form, a menu, a
// tooltip, chat or the hotbar. project/ui/glass_surface.gd draws one
// rectangle with this material, grown by `margin` on every side so the drop
// shadow has somewhere to fall; project/ui/glass_style.gd owns the numbers
// and docs/interface-style.md explains them. Two shaders include this file:
//
// ui_glass.gdshader defines GLASS_FROST. What is behind the panel is read
// from the screen texture, which Godot copies once per canvas the first time
// something asks for it, with a blurred mipmap chain. A few taps at one level
// of that chain make the frost. The blurred world is pulled towards a dark
// tint and put through a soft luminance ceiling, so that however bright the
// world is (snow at noon, open sky) the glass never gets brighter than
// `ceiling`. That bound is what lets glass_style.gd promise a contrast ratio
// for text drawn on it, rather than hoping the world behind is dark. The
// copy is the whole cost of the style, about 0.4 ms a frame at 1600 by 900
// (docs/interface-style.md), so it is paid only while a window is open.
//
// ui_glass_clear.gdshader does not read the screen. It is the hotbar's, which
// is on screen for the whole game: the same shape, rim and shadow over a
// translucent tint, with no frost and no copy.
//
// Per surface settings arrive in the vertex colour, so every surface can
// share one material: r is the corner radius over 64 pixels, g how opaque
// the tint is (0 is the ordinary panel, 1 hides the world entirely), b the
// strength of the drop shadow, and a the surface's overall opacity.

#ifdef GLASS_FROST
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
#endif

// Pixels the drawn rectangle is grown by on every side, for the shadow.
uniform float margin = 24.0;
// The mipmap level the frost is read from, and how far apart its taps are.
uniform float blur_lod = 4.0;
// The dark tint, as sRGB, and how much of the linear light result it is.
uniform vec3 tint : source_color = vec3(0.055, 0.063, 0.086);
uniform float tint_mix = 0.62;
// The relative luminance the glass tends towards and never reaches.
uniform float ceiling = 0.05;
// Colour kept in the blurred world, 1 being as it was.
uniform float saturation = 1.2;
// A faint lift at the top of the surface, in linear light, and how far down
// it reaches in pixels. Text contrast is worked out with it included.
uniform float sheen = 0.02;
uniform float sheen_reach = 28.0;
// The hairline just inside the edge, an outline all round that is brighter
// where the edge faces up.
uniform float rim_top = 0.32;
uniform float rim_bottom = 0.16;
// How many pixels the edge bends the view behind it, fading inwards over
// refraction_reach pixels.
uniform float refraction = 8.0;
uniform float refraction_reach = 16.0;
uniform float shadow_alpha = 0.36;
uniform float shadow_drop = 6.0;
// Without frost: how much of the world shows through the tint, unblurred.
uniform float clear_opacity = 0.74;

float sd_round_rect(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// The outward normal of the rounded rectangle nearest to p.
vec2 round_rect_normal(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + r;
	vec2 n;
	if (q.x > 0.0 && q.y > 0.0) {
		n = normalize(q);
	} else if (q.x > q.y) {
		n = vec2(1.0, 0.0);
	} else {
		n = vec2(0.0, 1.0);
	}
	return n * vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

#ifdef GLASS_FROST
// Five taps at one level of the blurred chain: one level alone shows the
// bilinear grid of a sixteenth resolution image as soft squares.
vec3 frost(vec2 uv, vec2 px) {
	vec2 o = px * exp2(blur_lod) * 0.7;
	vec3 c = textureLod(screen_tex, uv, blur_lod).rgb * 0.36;
	c += textureLod(screen_tex, uv + vec2(o.x, o.y), blur_lod).rgb * 0.16;
	c += textureLod(screen_tex, uv + vec2(-o.x, o.y), blur_lod).rgb * 0.16;
	c += textureLod(screen_tex, uv + vec2(o.x, -o.y), blur_lod).rgb * 0.16;
	c += textureLod(screen_tex, uv + vec2(-o.x, -o.y), blur_lod).rgb * 0.16;
	return c;
}
#endif

void fragment() {
	// The rectangle's size in pixels, from how fast UV changes across it,
	// so that no surface needs a material of its own to say how big it is.
	vec2 full = 1.0 / max(abs(vec2(dFdx(UV.x), dFdy(UV.y))), vec2(1e-6));
	vec2 size = max(full - 2.0 * margin, vec2(1.0));
	vec2 half_size = size * 0.5;
	vec2 p = UV * full - margin - half_size;
	float radius = min(COLOR.r * 64.0, min(half_size.x, half_size.y));
	float opaque = COLOR.g;
	float shadow_strength = COLOR.b;
	float opacity = COLOR.a;

	float d = sd_round_rect(p, half_size, radius);
	float body = clamp(0.5 - d, 0.0, 1.0);

	// A soft shadow a little below the surface, for depth.
	float ds = sd_round_rect(p - vec2(0.0, shadow_drop), half_size, radius);
	float shade = shadow_alpha * shadow_strength
		* (1.0 - smoothstep(-6.0, margin - shadow_drop, ds));
	// A darker hairline just outside the edge keeps the outline over snow.
	shade = max(shade, 0.28 * shadow_strength * (1.0 - smoothstep(0.0, 1.5, d)));

	vec3 glass = vec3(0.0);
	float glass_alpha = 1.0;
	if (body > 0.0) {
		float inside = -d;
		vec2 n = round_rect_normal(p, half_size, radius);
#ifdef GLASS_FROST
		float bend = refraction * pow(1.0 - clamp(inside / refraction_reach, 0.0, 1.0), 2.0);
		vec2 uv = SCREEN_UV - n * bend * SCREEN_PIXEL_SIZE;
		vec3 world = to_linear(frost(uv, SCREEN_PIXEL_SIZE));
		world = max(mix(vec3(luminance(world)), world, saturation), vec3(0.0));
		vec3 g = mix(world, to_linear(tint), mix(tint_mix, 1.0, opaque));
		g /= 1.0 + luminance(g) / ceiling;
#else
		vec3 g = to_linear(tint);
		glass_alpha = mix(clear_opacity, 1.0, opaque);
#endif
		float from_top = p.y + half_size.y;
		g += vec3(sheen) * (1.0 - clamp(from_top / sheen_reach, 0.0, 1.0));
		float rim = (1.0 - smoothstep(0.0, 1.6, inside))
			* mix(rim_bottom, rim_top, clamp(-n.y, 0.0, 1.0));
		g = mix(g, vec3(1.0), rim);
		glass_alpha = max(glass_alpha, rim);
		glass = to_srgb(g);
	}
	float front = body * glass_alpha;
	float alpha = front + shade * (1.0 - front);
	vec3 rgb = alpha > 0.0 ? glass * front / alpha : vec3(0.0);
	COLOR = vec4(rgb, alpha * opacity);
}
