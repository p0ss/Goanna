// SPDX-License-Identifier: LGPL-2.1-or-later
// A fictional dark-sky panorama, shared by every view. No catalogue assets.
// Included after the sky's hash12 and fbm helpers.
uniform float star_scale = 1.0;
uniform float celestial_phase = 0.0;
uniform float celestial_time = 0.0;
uniform float night_sky_strength : hint_range(0.0, 1.0) = 1.0;
uniform float galaxy_relief : hint_range(0.0, 1.0) = 1.0;
uniform float constellation_strength : hint_range(0.0, 1.0) = 1.0;

vec3 celestial_direction(vec3 d) {
	float c = cos(celestial_phase), s = sin(celestial_phase);
	return vec3(c * d.x - s * d.y, s * d.x + c * d.y, d.z);
}

// Integrate a flat square core over the pixel footprint. Small stars retain
// their light as they cross pixel boundaries; resolved stars have straight
// edges and corners. Match the previous Gaussian's total angular area.
float square_star(vec2 delta, float radius, float pixel) {
	float half_size = radius * 0.886226925;
	float footprint = max(pixel, 0.000001);
	vec2 lo = max(delta - footprint * 0.5, vec2(-half_size));
	vec2 hi = min(delta + footprint * 0.5, vec2(half_size));
	vec2 coverage = max(hi - lo, vec2(0.0)) / footprint;
	return coverage.x * coverage.y;
}

// A cube projection avoids the pinched stars of a latitude/longitude grid.
// Points stay inside their cells; their filtered wings vanish at the edges.
vec3 night_stars(vec3 d, float pixel, float clock, float altitude) {
	vec3 a = abs(d);
	vec2 uv;
	float face;
	if (a.x >= a.y && a.x >= a.z) {
		uv = d.yz / a.x;
		face = d.x > 0.0 ? 1.0 : 2.0;
	} else if (a.y >= a.z) {
		uv = d.xz / a.y;
		face = d.y > 0.0 ? 3.0 : 4.0;
	} else {
		uv = d.xy / a.z;
		face = d.z > 0.0 ? 5.0 : 6.0;
	}
	vec3 light = vec3(0.0);
	for (int layer = 0; layer < 2; layer++) {
		float grid = layer == 0 ? 48.0 : 138.0;
		vec2 p = uv * grid;
		vec2 cell = floor(p);
		vec2 seed = cell + vec2(face * 137.0, float(layer) * 311.0);
		float pick = hash12(seed);
		// Compensate the cube's solid angle so corners are not star clusters.
		float density = star_density / pow(1.0 + dot(uv, uv), 1.5);
		if (pick < density) {
			vec2 offset = vec2(hash12(seed + 17.3), hash12(seed + 43.1));
			vec2 delta = (fract(p) - (0.25 + offset * 0.5)) / grid;
			delta /= sqrt(1.0 + dot(uv, uv));
			float magnitude = hash12(seed + 91.7);
			float radius = (layer == 0 ? mix(0.0006, 0.0015, pow(magnitude, 5.0))
					: 0.00045) * star_scale;
			float point = square_star(delta, radius, pixel);
			float temperature = hash12(seed + 65.2);
			vec3 tint = mix(vec3(1.0, 0.63, 0.38), vec3(0.65, 0.79, 1.0), temperature);
			tint = mix(tint, vec3(1.0), 0.4);
			float phase = hash12(seed + 8.4) * 6.283185;
			float twinkle = sin(clock * (1.1 + magnitude * 1.7) + phase)
					* sin(clock * 0.73 + phase * 2.1);
			float scintillation = 1.0 + twinkle * mix(0.24, 0.08, altitude);
			light += tint * point * scintillation
					* (layer == 0 ? mix(1.1, 4.5, pow(magnitude, 6.0)) : 0.65);
		}
	}
	return light;
}

// The material art's extrusion language: neighbouring texels merge into
// flat plateaus, separated by height steps with narrow chamfers. Heights
// wrap around the band; there is no seam at the longitude wrap.
float galactic_height(vec2 cell) {
	float longitude = (mod(cell.x, 512.0) + 0.5) * (6.28318530718 / 512.0);
	float latitude = (cell.y + 0.5) / 80.0;
	float radial = sqrt(max(1.0 - latitude * latitude, 0.0));
	vec2 p = vec2((cos(longitude) * 13.0 + sin(longitude) * 6.0) * radial,
			latitude * 34.0);
	float billow = fbm(p);
	float detail = fbm(p * 3.1 + vec2(12.7, 3.9));
	float spine = latitude + (billow - 0.5) * 0.085;
	float dust = exp(-spine * spine * 1800.0) * smoothstep(0.25, 0.65, detail);
	// Height follows this very cloud's light and dust, as terrain relief
	// follows its albedo art. An unrelated noise field reads as an embossed
	// panel with a galaxy painted on it.
	float field = (billow * 0.65 + detail * 0.35) * exp(-latitude * latitude * 19.0)
			* (1.0 - dust * 0.9);
	float level = floor(clamp(field * 1.4, 0.0, 0.999) * 6.0) / 5.0;
	return 0.12 + level * 0.72;
}

vec3 galactic_relief(vec2 uv, float footprint) {
	// Intersect a shallow oblique heightfield, like the terrain's parallax
	// march. The fixed projection is artwork at infinity: it must not move
	// when the player walks or turn into a screen-space emboss filter.
	vec3 ray = vec3(0.85, 0.55, -1.0);
	vec3 origin = vec3(uv - ray.xy * 0.4, 1.0);
	vec2 cell = floor(origin.xy);
	vec2 crossing = (cell + 1.0 - origin.xy) / ray.xy;
	float entry = 0.0;
	vec3 normal = vec3(0.0, 0.0, 1.0);
	vec3 hit = origin;
	float height = 0.0;
	// Less than one texel of lateral travel in either axis. Four cells
	// include every possible top or vertical face along this bounded ray.
	for (int i = 0; i < 4; i++) {
		height = galactic_height(cell);
		float top = 1.0 - height;
		float leave = min(crossing.x, crossing.y);
		if (top <= leave) {
			hit = origin + ray * max(entry, top);
			if (top >= entry) normal = vec3(0.0, 0.0, 1.0);
			break;
		}
		if (crossing.x < crossing.y) {
			entry = crossing.x;
			crossing.x += 1.0 / ray.x;
			cell.x += 1.0;
			normal = vec3(-1.0, 0.0, 0.0);
		} else {
			entry = crossing.y;
			crossing.y += 1.0 / ray.y;
			cell.y += 1.0;
			normal = vec3(0.0, -1.0, 0.0);
		}
	}
	if (normal.z > 0.5) {
		vec2 local = hit.xy - cell;
		float bevel = clamp(max(0.075, footprint * 0.65), 0.075, 0.22);
		vec2 slope = vec2(0.0);
		// Only exposed steps bevel; equal-height neighbours are one face.
		if (local.x < bevel)
			slope.x -= max(height - galactic_height(cell - vec2(1, 0)), 0.0)
					* (1.0 - local.x / bevel);
		if (local.x > 1.0 - bevel)
			slope.x += max(height - galactic_height(cell + vec2(1, 0)), 0.0)
					* (1.0 - (1.0 - local.x) / bevel);
		if (local.y < bevel)
			slope.y -= max(height - galactic_height(cell - vec2(0, 1)), 0.0)
					* (1.0 - local.y / bevel);
		if (local.y > 1.0 - bevel)
			slope.y += max(height - galactic_height(cell + vec2(0, 1)), 0.0)
					* (1.0 - (1.0 - local.y) / bevel);
		normal = normalize(vec3(slope * 9.0, 1.0));
	}
	vec3 light = normalize(vec3(-0.6, 0.8, 1.0));
	float shade = 0.60 + max(dot(normal, light), 0.0) * 0.60;
	return vec3(height, shade, (cell.y + 0.5) / 80.0);
}

vec3 galactic_clouds(vec3 direction, float pixel) {
	// An inclined great circle, with a bright core and a broken dust lane.
	vec3 normal = normalize(vec3(0.38, 0.61, 0.69));
	vec3 along = normalize(cross(normal, vec3(0.0, 0.0, 1.0)));
	vec3 across = cross(normal, along);
	vec3 d = direction;
	vec3 q = vec3(dot(d, along), dot(d, normal), dot(d, across));
	float latitude = q.y;
	// The broad halo stays soft while the structure inside has stepped edges.
	float smooth_latitude = dot(direction, normal);
	float envelope = exp(-smooth_latitude * smooth_latitude * 38.0);
	if (envelope < 0.002) return vec3(0.0);
	vec2 p = vec2(q.x * 13.0 + q.z * 6.0, latitude * 34.0);
	float billow = fbm(p);
	float detail = fbm(p * 3.1 + vec2(12.7, 3.9));
	float core = pow(max(dot(d, normalize(vec3(-0.48, 0.77, -0.42))), 0.0), 5.0);
	float spine = latitude + (billow - 0.5) * 0.085;
	float dust = exp(-spine * spine * 1800.0) * smoothstep(0.25, 0.65, detail);
	float structure = mix(0.3, 1.25, billow) * mix(0.7, 1.3, detail);
	if (galaxy_relief > 0.001) {
		vec2 uv = vec2(atan(q.z, q.x) * (512.0 / 6.28318530718), latitude * 80.0);
		vec3 relief = galactic_relief(uv, pixel * 80.0);
		float raised = mix(0.72, 1.35, relief.x) * relief.y;
		structure *= mix(1.0, raised, galaxy_relief);
		float stepped_spine = relief.z + (billow - 0.5) * 0.085;
		float recess = exp(-stepped_spine * stepped_spine * 1800.0)
				* smoothstep(0.25, 0.65, detail) * mix(1.15, 0.65, relief.x);
		dust = mix(dust, recess, galaxy_relief);
	}
	vec3 tint = mix(vec3(0.46, 0.57, 0.82), vec3(0.95, 0.77, 0.57), core);
	vec3 glow = tint * envelope * structure * (0.18 + core * 0.34);
	glow *= 1.0 - dust * 0.92;
	// Small, subdued emission regions within the stellar cloud.
	float nebula = smoothstep(0.60, 0.78, detail) * envelope * billow;
	glow += vec3(0.10, 0.025, 0.055) * nebula;
	return glow;
}

// Four small fictional asterisms: a hooked chain, an uneven kite, a fork
// and a compact cluster. Coordinates are local tangent-plane offsets;
// z is relative brightness and w is the warm-to-cool colour mixture.
const vec4 GROUP_STARS[24] = {
	vec4(-0.15, 0.06, 0.80, 0.75), vec4(-0.07, 0.025, 1.00, 0.55),
	vec4(0.005, -0.005, 0.70, 0.80), vec4(0.08, -0.06, 1.15, 0.25),
	vec4(0.12, -0.14, 0.80, 0.70), vec4(0.045, -0.17, 0.60, 0.85),
	vec4(-0.02, 0.15, 1.10, 0.80), vec4(-0.12, 0.035, 0.70, 0.60),
	vec4(0.10, 0.02, 0.85, 0.75), vec4(0.025, -0.09, 1.00, 0.30),
	vec4(0.055, -0.17, 0.65, 0.65), vec4(-0.065, -0.015, 0.40, 0.85),
	vec4(-0.10, 0.14, 0.85, 0.65), vec4(-0.055, 0.06, 0.65, 0.80),
	vec4(0.005, -0.015, 1.15, 0.40), vec4(0.07, 0.065, 0.75, 0.75),
	vec4(0.13, 0.12, 0.95, 0.60), vec4(0.02, -0.14, 0.80, 0.85),
	vec4(-0.055, 0.025, 0.85, 0.85), vec4(0.00, 0.055, 1.00, 0.70),
	vec4(0.065, 0.015, 0.75, 0.80), vec4(-0.025, -0.035, 0.65, 0.90),
	vec4(0.04, -0.075, 1.10, 0.65), vec4(0.105, -0.03, 0.55, 0.85)
};

vec4 night_constellations(vec3 d, float pixel, float clock, float altitude) {
	vec3 light = vec3(0.0);
	float field = 1.0;
	for (int group = 0; group < 4; group++) {
		vec3 centre = group == 0 ? normalize(vec3(-0.20, 0.40, -0.89))
				: (group == 1 ? normalize(vec3(-0.88, 0.64, -0.10))
				: (group == 2 ? normalize(vec3(0.62, 0.48, 0.70))
				: normalize(vec3(0.55, -0.55, -0.63))));
		float facing = dot(d, centre);
		if (facing < 0.94) continue;
		// Give the named shapes breathing room in the random background field.
		field *= 1.0 - smoothstep(0.95, 0.989, facing) * 0.35;
		vec3 right = normalize(cross(centre, vec3(0.0, 1.0, 0.0)));
		vec3 upper = cross(right, centre);
		for (int member = 0; member < 6; member++) {
			int index = group * 6 + member;
			vec4 star = GROUP_STARS[index];
			vec3 position = normalize(centre + right * star.x + upper * star.y);
			float radius = (0.0012 + 0.0006 * star.z) * star_scale;
			vec3 delta = d - position;
			float point = square_star(vec2(dot(delta, right), dot(delta, upper)), radius, pixel);
			float phase = float(index) * 2.39996;
			float twinkle = sin(clock * (1.2 + star.z) + phase) * sin(clock * 0.73 + phase);
			vec3 tint = mix(vec3(1.0, 0.66, 0.42), vec3(0.68, 0.81, 1.0), star.w);
			light += tint * point * star.z * 5.0
					* (1.0 + twinkle * mix(0.20, 0.07, altitude));
		}
	}
	float strength = constellation_strength * smoothstep(0.0, 0.20, star_density);
	return vec4(light * strength, mix(1.0, field, strength));
}

vec3 night_planets(vec3 d, float pixel) {
	vec3 light = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		vec3 position = i == 0 ? normalize(vec3(-0.73, 0.38, -0.56))
				: (i == 1 ? normalize(vec3(0.48, 0.30, 0.82))
				: normalize(vec3(0.83, 0.51, -0.22)));
		float radius = (i == 0 ? 0.0020 : 0.0013) * star_scale;
		float width2 = radius * radius + pixel * pixel * 0.35;
		vec3 delta = d - position;
		float disc = exp(-dot(delta, delta) / width2) * radius * radius / width2;
		vec3 tint = i == 2 ? vec3(1.0, 0.52, 0.28) : vec3(1.0, 0.90, 0.69);
		light += tint * disc * (i == 0 ? 5.0 : 3.0);
	}
	return light;
}

vec3 night_meteor(vec3 d, float clock, float pixel) {
	// One opportunity per 83 seconds, with skipped slots and a variable delay.
	// Use the supplied clock, not TIME (which wraps every hour in Godot).
	float slot = floor(clock / 83.0);
	float seed = hash12(vec2(slot, 19.7));
	float age = mod(clock, 83.0) - (8.0 + seed * 60.0);
	if (seed < 0.28 || age < 0.0 || age > 1.15) return vec3(0.0);
	float azimuth = hash12(vec2(slot, 53.2)) * 6.283185;
	vec3 origin = normalize(vec3(cos(azimuth), 0.65 + seed, sin(azimuth)));
	vec3 tangent = normalize(cross(origin, vec3(0.2, 1.0, 0.3)));
	tangent = normalize(tangent - vec3(0.0, 0.38, 0.0));
	vec3 head = normalize(origin + tangent * (age - 0.4) * 0.34);
	vec3 tail = normalize(head - tangent * 0.15);
	vec3 segment = head - tail;
	float t = clamp(dot(d - tail, segment) / dot(segment, segment), 0.0, 1.0);
	float distance = length(d - normalize(tail + segment * t));
	float width = max(0.00065, pixel * 0.65);
	float streak = exp(-pow(distance / width, 2.0)) * pow(t, 2.5);
	float fade = smoothstep(0.0, 0.10, age) * (1.0 - smoothstep(0.65, 1.15, age));
	return mix(vec3(0.40, 0.64, 1.0), vec3(1.0, 0.91, 0.75), t) * streak * fade * 2.0;
}
