// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// The cloud shadow on a surface, shared by the node array shaders
// (nodes_array_common.gdshaderinc) and the entity ones when they draw a
// wall plate (entity_common.gdshaderinc), so a plate on a wall is dimmed by
// the same cloud as the wall beside it.

// Cloud shadows, from the same field the sky draws: offset.xy is the deck's
// scroll, z the coverage, w the strength, which main.gd scales with the sun
// so the night has none. goanna_cloud_geom carries the noise scale, the
// deck's absolute height and the sun's xz parallax per unit of height, so a
// shadow lies where the cloud between this point and the sun actually is,
// and drifts with the deck. The threshold is wider than the sky's own
// (0.34 against 0.16), so the shadow of a soft cloud is a soft dimming
// rather than a plate with the cloud's outline.
global uniform vec4 goanna_cloud_shadow;
global uniform vec4 goanna_cloud_geom;

float goanna_cloud_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float goanna_cloud_vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = goanna_cloud_hash(i), b = goanna_cloud_hash(i + vec2(1, 0));
	float c = goanna_cloud_hash(i + vec2(0, 1)), d = goanna_cloud_hash(i + vec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// The sky's fbm, same octaves and same lacunarity, or the shadow and the
// cloud part company.
float goanna_cloud_fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * goanna_cloud_vnoise(p);
		p = p * 2.03 + vec2(7.3, 1.7);
		a *= 0.5;
	}
	return v / 0.9375;
}

float goanna_cloud_dim(vec3 world) {
	float strength = goanna_cloud_shadow.w;
	if (strength <= 0.002 || world.y >= goanna_cloud_geom.y)
		return 1.0;
	vec2 par = goanna_cloud_geom.zw * max(goanna_cloud_geom.y - world.y, 0.0);
	vec2 uv = (world.xz + par) * goanna_cloud_geom.x + goanna_cloud_shadow.xy;
	float n = goanna_cloud_fbm(uv);
	float cov = smoothstep(1.0 - goanna_cloud_shadow.z - 0.06, 1.0 - goanna_cloud_shadow.z + 0.28, n);
	return 1.0 - cov * strength;
}
