// Goanna: wake ripples on water, round the player and the animals moving
// through it. docs/weather.md, "Wakes", has the whole picture.
//
// project/ui/wake.gd drops a point on the water behind each swimmer at
// intervals set by its speed, and one every second or so under a body
// standing still in water, and publishes the live ones here. Each point grows
// one ring that spreads at a fixed speed and dies away over two seconds. A
// swimmer faster than the rings spread leaves them overlapping along two
// lines behind it, which is the V of a wake; nothing here draws a V as such.
//
// Presentation only: the points come from positions the client already has.
// With no point live, goanna_wake_state.x is 0 and the whole term is one
// uniform branch.

// One point per texel along the first row: world x, world z, the wake clock
// at its birth, and its strength, 0 to 1.
global uniform sampler2D goanna_wake_points : filter_nearest, repeat_disable;
// x how many texels hold live points, y the wake clock now. The clock is
// wake.gd's own, not TIME, so a point's age is the same number on both sides.
global uniform vec4 goanna_wake_state;
// The xz box the live rings can reach (min x, min z, max x, max z), so water
// away from every swimmer skips the loop.
global uniform vec4 goanna_wake_area;

// wake.gd repeats these, and project/tests/wake.gd checks the two agree.
const int GOANNA_WAKE_MAX_POINTS = 64;
// Seconds a ring lives.
const float GOANNA_WAKE_MAX_AGE = 2.0;
// How fast a ring spreads, nodes a second. Slower than a swimmer, so the
// rings of a moving body trail in a V: its half angle is asin(this / speed),
// about 17 degrees at 2 nodes a second, near the 19.5 of a real wake.
const float GOANNA_WAKE_SPREAD = 0.6;
// Radius at birth: a body displaces water round itself, not at a point.
const float GOANNA_WAKE_START = 0.15;
// Half width of the ring's wave packet, and its wavelength, in nodes.
const float GOANNA_WAKE_WIDTH = 0.12;
const float GOANNA_WAKE_WAVE = 0.24;
// Past this many nodes from the eye a ring is a pixel or two and only
// glitters; wake.gd takes no source beyond it either.
const float GOANNA_WAKE_RANGE = 32.0;

// One point's ring at p: in xy the slope of its height field along xz, in z
// how much of a crest is at p, 0 to 1. The height is a short packet round
// the ring's radius, cos(k u) under a Gaussian of GOANNA_WAKE_WIDTH, with u
// the distance from the radius; the slope is its derivative along the
// radius, divided by k so it is about 1 at full strength whatever the
// wavelength. The strength falls linearly to nothing at GOANNA_WAKE_MAX_AGE,
// so a trail is still there a second behind a swimmer, and as it spreads (its
// energy is shared round a longer circle), and eases in over its first
// tenth of a second so a new point does not pop.
vec3 goanna_wake_ring(vec2 p, vec4 pt, float now) {
	float age = now - pt.z;
	if (age < 0.0 || age > GOANNA_WAKE_MAX_AGE)
		return vec3(0.0);
	vec2 d = p - pt.xy;
	float r = length(d);
	float radius = GOANNA_WAKE_START + GOANNA_WAKE_SPREAD * age;
	float u = r - radius;
	float x = u / GOANNA_WAKE_WIDTH;
	if (abs(x) > 3.0)
		return vec3(0.0);
	float life = 1.0 - age / GOANNA_WAKE_MAX_AGE;
	float amp = pt.w * life * smoothstep(0.0, 0.1, age)
			* inversesqrt(1.0 + 2.0 * radius);
	float k = 6.2831853 / GOANNA_WAKE_WAVE;
	float env = exp(-x * x);
	float slope = amp * env * (-2.0 * x / (GOANNA_WAKE_WIDTH * k) * cos(k * u) - sin(k * u));
	float crest = amp * env * max(cos(k * u), 0.0);
	return vec3((r > 1e-4 ? d / r : vec2(0.0)) * slope, crest);
}

// Every live ring at p, summed, for a pixel `eye_d` nodes from the eye.
vec3 goanna_wake(vec2 p, float eye_d) {
	int n = min(int(goanna_wake_state.x), GOANNA_WAKE_MAX_POINTS);
	if (n <= 0 || eye_d > GOANNA_WAKE_RANGE)
		return vec3(0.0);
	if (p.x < goanna_wake_area.x || p.y < goanna_wake_area.y
			|| p.x > goanna_wake_area.z || p.y > goanna_wake_area.w)
		return vec3(0.0);
	vec3 acc = vec3(0.0);
	for (int i = 0; i < n; i++)
		acc += goanna_wake_ring(p, texelFetch(goanna_wake_points, ivec2(i, 0), 0),
				goanna_wake_state.y);
	float fade = 1.0 - smoothstep(GOANNA_WAKE_RANGE * 0.6, GOANNA_WAKE_RANGE, eye_d);
	return vec3(acc.xy * fade, min(acc.z, 1.0) * fade);
}
