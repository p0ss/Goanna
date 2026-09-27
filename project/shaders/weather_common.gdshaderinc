#include "feature_flags.gdshaderinc"
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

// Settled snow, 0 to 1 at a point on an up facing surface. main.gd builds
// goanna_snow_cover while snow falls and melts it after; where the sky
// reaches (the cover map, or strong sky light beyond it) it settles texel
// by texel on the art's own grid, sixteen to a node, so the dusting keeps
// the blocky look: first scattered texels, then most, then all. On an
// authored relief the hollows fill before the crests, as with the pools.
global uniform float goanna_snow_cover;

float goanna_snow(vec3 p, vec3 n, float sky, float h, bool relief_known) {
	if (goanna_snow_cover < 0.001 || n.y < 0.3)
		return 0.0;
	float up = smoothstep(0.3, 0.8, n.y);
	float open = goanna_rain_open(p, smoothstep(0.85, 0.95, sky));
	float grain = goanna_weather_hash(floor((p.xz + 0.5) * 16.0 + 1e-3));
	float rank = relief_known ? mix(h, grain, 0.35) : grain;
	float level = goanna_snow_cover * 1.25 - 0.1;
	return up * open * smoothstep(rank - 0.03, rank + 0.03, level);
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


// Basins: 0 to 1, how far a point on flat ground lies in one of the low
// patches, a node or three across, where water gathers over whole tiles. A
// broad noise and a finer one together pass a threshold that falls as the
// ground gets wetter, so basins appear first where the noise is highest and
// spread as the rain goes on, and shrink again as goanna_wetness dries after
// it. The ramp is wide on purpose: it lifts the water level
// (goanna_water_level) gradually toward a basin's middle, so at its rim only
// the relief's hollows are under water and the edge follows the texture,
// not a line drawn by the noise.
const float GOANNA_PUDDLE_DRY = 0.98;
const float GOANNA_PUDDLE_SOAKED = 0.55;
float goanna_puddle(vec2 p, float wet) {
	float n = 0.7 * goanna_weather_noise(p / 3.1)
			+ 0.3 * goanna_weather_noise(p / 1.13 + vec2(17.0, 5.0));
	float t = mix(GOANNA_PUDDLE_DRY, GOANNA_PUDDLE_SOAKED, clamp(wet, 0.0, 1.0));
	return smoothstep(t - 0.06, t + 0.1, n);
}

// How high water stands on flat open ground at p, measured on the tile's
// own relief: the height a LabPBR _n map carries in its alpha, 0 in the
// deepest hollow and 1 on the highest crest, which the parallax march reads
// too. Everywhere it rises with the wetness to GOANNA_POOL_FILL, which fills
// the joints and dips between an authored relief's ridges; in a basin it
// rises past 1, over every crest, and the tile is a puddle. The owner's
// idea: the soft wet look is the dips between ridges filled with water.
// Measured on the Mineclonia packs here, a level of 0.45 drowns the lowest
// tenth to quarter of the dirt, sand, gravel and stone tops of the authored
// pack, and more of the Material Maker one, whose heights sit lower.
const float GOANNA_POOL_FILL = 0.45;
const float GOANNA_BASIN_RISE = 1.2;
float goanna_water_level(vec2 p, float wet) {
	return GOANNA_POOL_FILL * smoothstep(0.35, 1.0, wet)
			+ GOANNA_BASIN_RISE * goanna_puddle(p, wet);
}

// Standing water at one pixel, from the level above, how much of it this
// ground can hold (`weight`, the gating below), and the relief height `h`
// at the tile coordinate actually drawn. After the parallax march that is
// the texel the eye ray met, and the test is then exact: a ray that met the
// relief under the level crossed the water's surface first, and one that
// met it above did not. x how much of the pixel is water, y the wet margin
// just above the waterline, where water is drawn up between the grains, z
// how deep the water is, 0 to 1, for its darkening. A pixel whose tile has
// no authored height passes h = 1, a crest everywhere, and holds water only
// in a basin.
vec3 goanna_pool(float level, float weight, float h) {
	float water = (1.0 - smoothstep(level - 0.04, level, h)) * weight;
	float shore = (1.0 - smoothstep(level, level + 0.25, h)) * weight * (1.0 - water);
	float depth = clamp((level - h) * 4.0, 0.0, 1.0) * water;
	return vec3(water, shore, depth);
}

// The meniscus (owner, 2026-09-27): where standing water meets a ridge its
// surface curls up against the solid and catches the light as a thin bright
// line. How much of that band a pixel is in: a narrow strip either side of
// the waterline, only where there is water to have an edge at all.
float goanna_meniscus(float level, float weight, float h) {
	return (1.0 - smoothstep(0.0, 0.035, abs(h - level))) * weight
			* step(0.02, level);
}

// Splashes are faded out where a pixel is wider than this many nodes: a
// ring a few centimetres across drawn over fewer pixels than it has parts
// only shimmers. 0.012 is about 9 nodes away square on at 1080 lines and 70
// degrees, nearer at a low angle.
const float GOANNA_SPLASH_PX_FULL = 0.012;
const float GOANNA_SPLASH_PX_GONE = 0.03;

// Where rain lands on the ground, for the two node array shaders: x the
// water level (goanna_water_level), y how much of it this ground holds, 0
// to 1, z how strongly it splashes, 0 to about 1. `n` is the world normal,
// `sky` the vertex sky light (the roof test off the cover map), `flatten`
// the far tiers' distance flatten (0 on the near mesh), `wet`
// goanna_wetness, `eye_d` the distance from the eye, `px` the world size of
// a pixel there.
//
// Standing water follows the wetness, how rained on the world is, so it
// rises through a long shower and lingers after it; flat tops only, since
// water does not stand on a slope. Splashes follow goanna_rain, what is
// falling this moment, near the eye. Both only where the cover map says the
// sky reaches.
//
// Shared, not written out in each shader, because it was written out in one:
// the splashes and puddles were in nodes_array.gdshader alone, and in play
// the ground was drawn by nodes_array_scissor.gdshader, so the owner saw the
// ground go wet and never a splash or a puddle. The writes to ALBEDO and the
// rest stay in each shader, which Godot requires.
vec3 goanna_ground_rain(vec3 p, vec3 n, float sky, float flatten, float wet, float eye_d, float px) {
	vec3 t = vec3(0.0);
	if (goanna_render_wet_surfaces < 0.5) return t;
	if ((goanna_rain > 0.001 || wet > 0.35) && n.y > 0.7) {
		float open_sky = goanna_rain_open(p, smoothstep(0.85, 0.95, sky));
		if (wet > 0.35 && n.y > 0.95) {
			t.x = goanna_water_level(p.xz, wet);
			t.y = smoothstep(0.35, 0.45, wet) * open_sky * (1.0 - flatten);
		}
		t.z = min(goanna_rain, 1.5) * (1.0 - smoothstep(10.0, 22.0, eye_d))
				* (1.0 - smoothstep(GOANNA_SPLASH_PX_FULL, GOANNA_SPLASH_PX_GONE, px))
				* (1.0 - flatten) * open_sky;
	}
	return t;
}

// What rain on open ground does to its colour: a factor on the albedo, and
// never over 1, so whatever a splash or a puddle shows is the ground's own
// colour in the scene's own light. Standing water darkens most, more where
// it is deeper; the wet margin and a splash's mark less, by the porosity:
// soil drinks the water and darkens, stone barely does. The splashes this
// replaced mixed the albedo toward white and added light of their own, and
// in play were "bright white giant spots", their colour not the surface's.
float goanna_wet_darken(vec3 pool, float mark, float porosity) {
	float soak = max(pool.y, mark) * (1.0 - pool.x);
	return (1.0 - pool.x * (0.28 + 0.12 * porosity + 0.2 * pool.z))
			* (1.0 - soak * (0.08 + 0.17 * porosity));
}

// The splashes on the ground. A drop lands in each cell of
// GOANNA_SPLASH_CELL nodes at most once a period, at a random place and
// time, and for the first GOANNA_SPLASH_LIFE of the period a ring spreads
// from it. Two grids offset by half a cell double the drops. At intensity 1
// that is about 31 drops a square node a second, each ring living about a
// third of a second and growing to between 7 and 15 centimetres across.
const float GOANNA_SPLASH_CELL = 0.22;
const float GOANNA_SPLASH_PERIOD = 0.6;
const float GOANNA_SPLASH_LIFE = 0.6;
// The ring's half width, as a share of a cell (about 1.3 centimetres).
const float GOANNA_SPLASH_WIDTH = 0.06;

// One ring, at distance r from its drop, k of the way through its life (0
// to 1), growing to rmax, half width w (all in cells): x its slope outward,
// y the wet mark. The ring is a crest whose radius grows fast and slows, and
// whose height dies away as it spreads; w above GOANNA_SPLASH_WIDTH is a
// ring widened to the pixel, and it is lowered in proportion so a far ring
// fades rather than turns to noise. The mark is the water the drop threw
// out, a disc as wide as the ring, gone by the end of the ring's life.
vec2 goanna_splash_ring(float r, float k, float rmax, float w) {
	float radius = rmax * (1.0 - (1.0 - k) * (1.0 - k));
	float x = (r - radius) / w;
	float fade = (1.0 - k) * (1.0 - k) * (GOANNA_SPLASH_WIDTH / w);
	float slope = -1.2 * x * exp(-x * x) * fade;
	float mark = (1.0 - smoothstep(radius, radius + 2.0 * w, r)) * (1.0 - k);
	return vec2(slope, mark);
}

// The splashes at p (xz, world) at time t: in xy the slope of the ring
// height field, in z the wet mark, 0 to 1. `px` is the world size of a
// pixel, which widens the rings, `rain` goanna_rain, which sets how many
// cells get a drop. Each cell is evaluated alone, so a ring stops short of
// its cell's edge, for the reason goanna_rain_rings gives.
vec3 goanna_rain_splash(vec2 p, float t, float px, float rain) {
	float w = max(GOANNA_SPLASH_WIDTH, 0.7 * px / GOANNA_SPLASH_CELL);
	float density = clamp(0.45 * rain, 0.0, 0.9);
	vec3 acc = vec3(0.0);
	for (int g = 0; g < 2; g++) {
		vec2 q = p / GOANNA_SPLASH_CELL + (g == 1 ? vec2(0.5) : vec2(0.0));
		vec2 id = floor(q);
		vec2 seed = id + vec2(float(g) * 23.0, float(g) * 41.0);
		float t0 = goanna_weather_hash(seed) * GOANNA_SPLASH_PERIOD;
		float cycle = floor((t + t0) / GOANNA_SPLASH_PERIOD);
		float age = fract((t + t0) / GOANNA_SPLASH_PERIOD);
		if (age >= GOANNA_SPLASH_LIFE)
			continue;
		vec3 h = goanna_weather_hash3(seed + cycle * 5.71);
		if (h.z > density)
			continue;
		vec2 centre = id + 0.3 + h.xy * 0.4;
		vec2 d = q - centre;
		float r = length(d);
		vec2 f = centre - id;
		float edge = min(min(f.x, f.y), min(1.0 - f.x, 1.0 - f.y));
		vec2 ring = goanna_splash_ring(r, age / GOANNA_SPLASH_LIFE, max(edge - 2.5 * w, 0.0), w);
		ring.x *= 1.0 - smoothstep(edge - 1.5 * w, edge, r);
		acc.xy += (r > 1e-4 ? d / r : vec2(0.0)) * ring.x;
		acc.z += ring.y;
	}
	return vec3(acc.xy, min(acc.z, 1.0));
}

// Rain rings on open water: the slope of the ripple height field at p
// (xz, world). The ground once drew these too, with a bright crown at the
// moment of impact; it has its own smaller splashes now
// (goanna_rain_splash), and the crown went with them.
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
vec2 goanna_rain_rings(vec2 p, float t, float cell, float period, float density) {
	vec2 acc = vec2(0.0);
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
		acc += (r > 1e-4 ? d / r : vec2(0.0)) * slope;
	}
	return acc;
}
