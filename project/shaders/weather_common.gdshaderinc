// Goanna: what the ground, water and falling rain shaders share about the
// weather. docs/weather.md has the whole picture.
//
// Set by project/ui/weather.gd, only while a weather spawner is running and
// shader weather is on; with it off, or in fair weather, goanna_rain is 0 and
// every branch below is skipped.

// How hard it is raining now, 0 to 2 (1 is Mineclonia's ordinary rain, 1.8
// its thunderstorm), eased over a few seconds. Unlike goanna_wetness, which
// lingers for minutes after, this is what is falling this moment: splashes
// and ripples stop with the rain, puddled gloss does not.
global uniform float goanna_rain;
// Top of the highest rain stopping node per column, one texel per node,
// around the player (project/ui/rain_cover.gd).
global uniform sampler2D goanna_rain_cover : filter_nearest, repeat_disable;
// World xz of the map's outer corner, its size in nodes, and 1 once a map
// has been published.
global uniform vec4 goanna_rain_cover_area;

// 1 where rain reaches a point, 0 where something above shelters it, and
// `fallback` off the map. The margin lets a liquid surface, which sits a
// little below the top of its own node, count as open.
float goanna_rain_open(vec3 p, float fallback) {
	if (goanna_rain_cover_area.w < 0.5)
		return fallback;
	vec2 uv = (p.xz - goanna_rain_cover_area.xy) / goanna_rain_cover_area.z;
	if (uv != clamp(uv, vec2(0.0), vec2(1.0)))
		return fallback;
	float cover = texture(goanna_rain_cover, uv).r;
	return step(cover - 0.55, p.y);
}

float goanna_weather_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 goanna_weather_hash3(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// Rain rings on a flat surface: the slope of the ripple height field at p
// (xz, world), and in z how much of a fresh splash crown is at p, 0 to 1.
// Each cell of `cell` nodes holds at most one drop per `period` seconds,
// landing at a random place and time, and its ring grows to `reach` of the
// cell and dies away. Two grids offset by half a cell, so a ring is never
// clipped at a cell edge without another nearby to hide it; `density` is the
// share of cells that get a drop each period.
vec3 goanna_rain_rings(vec2 p, float t, float cell, float period, float density) {
	vec3 acc = vec3(0.0);
	for (int g = 0; g < 2; g++) {
		vec2 q = p / cell + (g == 1 ? vec2(0.5) : vec2(0.0));
		vec2 id = floor(q);
		vec2 seed = id + vec2(float(g) * 17.0, float(g) * 31.0);
		float t0 = goanna_weather_hash(seed) * period;
		float cycle = floor((t + t0) / period);
		float age = fract((t + t0) / period);
		vec3 h = goanna_weather_hash3(seed + cycle * 7.13);
		if (h.z > density)
			continue;
		// The drop lands in the middle of its cell, so its ring stays inside.
		vec2 centre = id + 0.3 + h.xy * 0.4;
		vec2 d = q - centre;
		float r = length(d);
		float radius = age * 0.45;
		float x = (r - radius) * 18.0;
		// One crest and a trough behind it, fading as the ring grows.
		float env = exp(-x * x * 0.35) * (1.0 - age) * (1.0 - age);
		float slope = (cos(x) - 0.7 * x * sin(x)) * env;
		acc.xy += (r > 1e-4 ? d / r : vec2(0.0)) * slope;
		// The crown: the moment of impact, a point of broken water.
		acc.z += (1.0 - smoothstep(0.0, 0.12, age)) * (1.0 - smoothstep(0.02, 0.1, r));
	}
	return vec3(acc.xy, min(acc.z, 1.0));
}
