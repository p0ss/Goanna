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
// little below the top of its own node, count as open. An explicit level of
// detail, since the falling drops ask it in the vertex stage, where there
// are no derivatives to pick one; the map has no mipmaps, so it is the same
// read in the fragment stage.
float goanna_rain_open(vec3 p, float fallback) {
	if (goanna_rain_cover_area.w < 0.5)
		return fallback;
	vec2 uv = (p.xz - goanna_rain_cover_area.xy) / goanna_rain_cover_area.z;
	if (uv != clamp(uv, vec2(0.0), vec2(1.0)))
		return fallback;
	float cover = textureLod(goanna_rain_cover, uv, 0.0).r;
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

// Smooth noise on the world's own grid, 0 to 1: a hash at each whole
// coordinate, eased between. A function of the position alone, so what it
// shapes stays put in the world.
float goanna_weather_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = goanna_weather_hash(i);
	float b = goanna_weather_hash(i + vec2(1.0, 0.0));
	float c = goanna_weather_hash(i + vec2(0.0, 1.0));
	float d = goanna_weather_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Shallow puddles: 0 to 1, how much of a point on flat ground stands under
// water. Patches a node or three across, where a broad noise and a finer one
// together pass a threshold that falls as the ground gets wetter, so they
// appear in the hollows first and spread as the rain goes on, and shrink
// again as goanna_wetness dries after it. The caller keeps them to flat,
// open, up facing ground. After a minute of rain from dry (wetness 0.86) a
// fifth of such ground is under water, at full wetness 29 per cent, and
// below a wetness of about 0.4 none of it.
const float GOANNA_PUDDLE_DRY = 0.98;
const float GOANNA_PUDDLE_SOAKED = 0.55;
float goanna_puddle(vec2 p, float wet) {
	float n = 0.7 * goanna_weather_noise(p / 3.1)
			+ 0.3 * goanna_weather_noise(p / 1.13 + vec2(17.0, 5.0));
	float t = mix(GOANNA_PUDDLE_DRY, GOANNA_PUDDLE_SOAKED, clamp(wet, 0.0, 1.0));
	return smoothstep(t, t + 0.08, n);
}

// Where rain lands on the ground, for the two node array shaders: x how much
// of a point stands under a puddle, y how strongly it splashes, both 0 to
// about 1. `n` is the world normal, `sky` the vertex sky light (the roof test
// off the cover map), `flatten` the far tiers' distance flatten (0 on the
// near mesh), `wet` goanna_wetness, `eye_d` the distance from the eye.
//
// Puddles follow the wetness, how rained on the world is, so they spread
// through a long shower and linger after it; flat tops only, since water
// does not stand on a slope. Splashes follow goanna_rain, what is falling
// this moment, near the eye. Both only where the cover map says the sky
// reaches.
//
// Shared, not written out in each shader, because it was written out in one:
// the splashes and puddles were in nodes_array.gdshader alone, and in play
// the ground is drawn by nodes_array_scissor.gdshader (an array holding any
// alpha layer goes there, and upstream bunches tiles by size alone), so the
// owner saw the ground go wet and never a splash or a puddle. The writes to
// ALBEDO and the rest stay in each shader, which Godot requires.
vec2 goanna_ground_rain(vec3 p, vec3 n, float sky, float flatten, float wet, float eye_d) {
	vec2 t = vec2(0.0);
	if ((goanna_rain > 0.001 || wet > 0.35) && n.y > 0.7) {
		float open_sky = goanna_rain_open(p, smoothstep(0.85, 0.95, sky));
		if (wet > 0.35 && n.y > 0.95)
			t.x = goanna_puddle(p.xz, wet) * open_sky * (1.0 - flatten);
		t.y = min(goanna_rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, eye_d))
				* (1.0 - flatten) * open_sky;
	}
	return t;
}

// Rain rings on a flat surface: the slope of the ripple height field at p
// (xz, world), and in z how much of a fresh splash crown is at p, 0 to 1.
// Each cell of `cell` nodes holds at most one drop per `period` seconds,
// landing at a random place and time, and its ring grows and dies away.
// Two grids offset by half a cell double the drops without a 3 by 3
// neighbour search; `density` is the share of cells that get a drop each
// period.
//
// Each cell is evaluated alone, so a ring must never reach its cell's edge:
// one that did was cut off by a straight line, and seen at a low angle with
// the sun in the water the cut rings read as bright arcs. So a ring's
// largest radius is the distance from its drop to the nearest edge, less
// the ring's own width, and anything left of the envelope is faded to zero
// before the edge as well.
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
		vec2 centre = id + 0.35 + h.xy * 0.3;
		vec2 d = q - centre;
		float r = length(d);
		// Distance from the drop to the nearest edge of its cell.
		vec2 f = centre - id;
		float edge = min(min(f.x, f.y), min(1.0 - f.x, 1.0 - f.y));
		// The envelope below is under 5 per cent past 0.11 of a cell.
		float radius = age * max(edge - 0.11, 0.05);
		float x = (r - radius) * 28.0;
		// One crest and a trough behind it, fading as the ring grows.
		float env = exp(-x * x * 0.35) * (1.0 - age) * (1.0 - age)
				* (1.0 - smoothstep(edge - 0.08, edge - 0.01, r));
		float slope = (cos(x) - 0.7 * x * sin(x)) * env;
		acc.xy += (r > 1e-4 ? d / r : vec2(0.0)) * slope;
		// The crown: the moment of impact, a point of broken water. It was
		// a tenth of a cell for the first eighth of the period, which on a
		// live client showed nothing at all; a fifth of a cell for a fifth
		// of the period is a fleck about a fifth of a node across for a tenth
		// of a second on the ground.
		acc.z += (1.0 - smoothstep(0.05, 0.2, age)) * (1.0 - smoothstep(0.08, 0.2, r));
	}
	return vec3(acc.xy, min(acc.z, 1.0));
}
