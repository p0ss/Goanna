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
// Diffuse light retained by the droplets after many scattering events. The
// server supplies this separately from the directly lit cloud colour. It is
// additive radiance, not another tint to multiply by a dark sky: doing the
// latter made an optically thick deck converge to black when viewed from
// underneath at night or under overcast.
uniform vec3 cloud_ambient_color : source_color = vec3(0.16);
// The transmitted sun, per layer, premultiplied hue times strength, from
// SkyDirector via main.gd: cloud_beam is the beam at the deck's own
// horizon-relative altitude, air_beam the one the dome's high air
// scatters, which outlives the ground's through predawn and afterglow.
// One hue script behind every warm term is what keeps the cloud
// undersides and the glow around the disc from being unrelated
// luminances.
uniform vec3 cloud_beam = vec3(1.0, 0.9, 0.7);
uniform vec3 air_beam = vec3(0.0);
// The baked horizon (src/goanna_horizon.cpp, docs/sky-orchestration.md):
// a cylindrical panorama of the terrain the client knows about beyond the
// drawn far field. Albedo and distance only; it is relit here every frame
// from the same beam and air the live terrain answers to, so it rides
// through dawn, dusk and biome fades without being re-rendered. U wraps
// the azimuth with theta 0 facing -Z, V spans horizon_y_min..max in the
// same sin-elevation units as sun_dir.y.
uniform float horizon_on = 0.0;
uniform sampler2D horizon_tex : source_color, filter_linear, repeat_enable;
uniform sampler2D horizon_dist : hint_default_black, filter_linear, repeat_enable;
uniform float horizon_y_min = -0.08;
uniform float horizon_y_max = 0.35;
uniform float horizon_fade0 = 512.0;
uniform float horizon_r1 = 4096.0;
// What the baked land is lit by, worked out per frame in main.gd from the
// same authorities as the fill.
uniform vec3 horizon_light = vec3(0.5);
// The ground's beam, gated by the ridge probe, shared with the water's
// fallback reflection and the screen space shafts. Here it is the light
// the land throws back up at the deck: see the underside term in the
// march.
global uniform vec3 goanna_sun_glow;
uniform float cloud_coverage = 0.4;
uniform bool clouds_enabled = true;
uniform int cloud_style : hint_range(0, 2) = 2;
uniform int cloud_quality : hint_range(0, 2) = 2;
#include "res://shaders/cloud_layers.gdshaderinc"
uniform vec2 cloud_offset = vec2(0.0);
uniform vec4 haze_color : source_color = vec4(0.72, 0.8, 0.9, 1.0);
uniform float haze_twilight : hint_range(0.0, 1.0) = 0.0;
// How much of the air colour the sky takes along the geometric horizon by
// day. This is the band a hole in the far field is seen against, and at the
// old 0.26 it stayed three quarters sky while the terrain beside it faded
// fully into the air, so a gap read as a pale slot between brown hills.
uniform float horizon_air_day : hint_range(0.0, 1.0) = 0.26;
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
// How broad the haze band below the horizon is. The lower hemisphere runs
// from the horizon colour to ground_color, and this is the exponent on that
// blend, so a high value keeps a wide band of horizon colour under the
// horizon line and only darkens when you look steeply down, where terrain is
// always loaded anyway. That band is the background the far field is drawn
// over (docs/far-rendering.md, "Background, overlay, foreground"): terrain
// that has not arrived, or a hole between two panels, reads as haze at the
// same colour the fog fades the far edge to, rather than as a void.
uniform float ground_curve : hint_range(0.2, 8.0) = 0.6;
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

#include "res://shaders/night_sky.gdshaderinc"

// The cumulus body: real 3D noise from a texture (built once in main.gd,
// far cheaper than ALU noise at march rates), shaped by a height gradient
// into a flat base and a domed top. Every earlier attempt at clouds here
// sampled a 2D field at stacked heights, and every one of them read as
// stacked translucent sheets whatever the shading said, because a sheet has
// no side to see. Only a density the ray actually marches through has one.
uniform sampler3D cloud_body_tex : repeat_enable, filter_linear;

// Where masses are at all: a slow 2D system hundreds of nodes across. It
// modulates coverage, breaks the 3D texture's tiling, and is the same
// envelope the node shaders approximate for their cloud shadows.
float cloud_weather(vec2 wxz, int layer) {
	return cloud_layer_weather((wxz * 0.0009 + cloud_layer_offset(cloud_offset, layer) * 0.4)
		/ cloud_horizontal_scale(layer));
}

// Normalise each axis before rounding so a broad cloud has soft horizontal
// edges as well as a soft crown. World-space noise carves uneven bays and
// lobes into that envelope; the density reaches zero inside its bounds.
float block_cloud_density(vec3 p, vec3 midpoint, vec3 half_size, float scale) {
	float sdf = cloud_block_distance(p, midpoint, half_size);
	if (sdf >= 0.0) return 0.0;
	vec3 shape_p = vec3(p.x / scale, p.y, p.z / scale);
	float body = texture(cloud_body_tex, shape_p / 180.0).r;
	float detail = texture(cloud_body_tex, shape_p / 55.0 + vec3(0.37)).r;
	float erosion = (1.0 - body) * 0.48 + (0.5 - detail) * 0.16;
	float shell = 1.0 - smoothstep(-0.22, 0.0, sdf + erosion);
	return shell * mix(0.45, 1.0, body);
}

// Integrate a soft body inside one occupied cell. Return premultiplied
// radiance and opacity so a thin edge reveals clouds farther along the ray.
vec4 fluffy_block_cell(vec3 ro, vec3 dir, vec3 lo, vec3 hi,
		float entry, float leave, bool cubemap, float strength, float reach, float scale) {
	vec3 midpoint = (lo + hi) * 0.5;
	vec3 half_size = (hi - lo) * 0.5;
	int samples = cubemap ? 8 : (cloud_quality == 0 ? 12 : (cloud_quality == 1 ? 16 : 24));
	int sun_samples = cloud_quality == 0 ? 2 : (cloud_quality == 1 ? 3 : 4);
	float stride = (leave - entry) / float(samples);
	float light_stride = half_size.y * 1.95 / float(sun_samples);
	float sigma = 4.0 * strength / max(hi.y - lo.y, 1.0);
	float mu = dot(dir, sun_dir);
	float phase = mix(1.0, 0.75 / pow(1.25 - mu, 1.5), 0.35);
	float transmittance = 1.0;
	vec3 accumulated = vec3(0.0);
	for (int j = 0; j < 24; j++) {
		if (j >= samples || transmittance < 0.015) break;
		float t = entry + (float(j) + 0.5) * stride;
		vec3 p = ro + dir * t;
		float density = block_cloud_density(p, midpoint, half_size, scale);
		if (density < 0.001) continue;
		float od = 0.0;
		for (int k = 0; k < 4; k++) {
			if (k >= sun_samples) break;
			vec3 toward_light = p + sun_dir * (float(k) + 0.5) * light_stride;
			od += block_cloud_density(toward_light, midpoint, half_size, scale) * light_stride;
		}
		float light = exp(-od * sigma);
		float hf = clamp((p.y - lo.y) / (hi.y - lo.y), 0.0, 1.0);
		vec3 ambient = mix(sky_horizon.rgb, sky_top.rgb, 0.6)
			* mix(0.28, 0.55, hf);
		ambient = mix(ambient, haze_color.rgb * 0.65, haze_twilight * 0.6);
		vec3 lit = cloud_color.rgb * (cloud_beam * light * phase * 1.5
			+ goanna_sun_glow * (1.0 - hf) * 0.22)
			+ ambient + cloud_ambient_color;
		float fade = 1.0 - smoothstep(reach * 0.65, reach, t);
		float alpha = 1.0 - exp(-density * sigma * stride * fade);
		accumulated += transmittance * alpha * lit;
		transmittance *= 1.0 - alpha;
	}
	return vec4(accumulated, 1.0 - transmittance);
}

// One height-varying layer of cloud cells traversed in grid order. Plain blocks use
// an analytic solid surface; fluffy blocks integrate density inside rounded
// bounds. Both follow the drifting weather envelope and server colours.
vec4 block_clouds(vec3 eye, vec3 dir, bool cubemap, int layer) {
	vec4 deck = cloud_layers[layer];
	float base = deck.x;
	float height = deck.y;
	float reach = 2800.0 + float(layer) * 2400.0;
	vec3 ray = mix(vec3(0.000001), dir, greaterThan(abs(dir), vec3(0.000001)));
	float enter = (base - height * 0.75 - eye.y) / ray.y;
	float leave = (base + height * 1.75 - eye.y) / ray.y;
	float start = max(0.0, min(enter, leave));
	float end = min(reach, max(enter, leave));
	if (end <= start) return vec4(0.0);
	float cell_size = cloud_cell_size(layer);
	// Advancing noise coordinates makes the visible cloud mass move opposite
	// the offset, just like the volume. Grid boundaries drift continuously.
	vec2 drift = cloud_layer_offset(cloud_offset, layer) * (0.4 / 0.0009);
	vec3 ro = eye + vec3(drift.x, 0.0, drift.y);
	float t = start;
	vec2 cell = cloud_cell_at(ro.xz + dir.xz * start, cell_size);
	vec2 direction = sign(dir.xz);
	vec2 boundary = cloud_cell_origin(cell, cell_size) + step(vec2(0.0), dir.xz) * cell_size;
	vec2 crossing = (boundary - ro.xz) / ray.xz;
	crossing = mix(vec2(1e20), crossing, greaterThan(abs(dir.xz), vec2(0.000001)));
	vec2 crossing_step = cell_size / max(abs(dir.xz), vec2(0.000001));
	vec4 accumulated = vec4(0.0);
	for (int i = 0; i < 64; i++) {
		if (t > end) break;
		vec2 centre = cloud_cell_origin(cell, cell_size) + cell_size * 0.5;
		float weather = cloud_layer_weather(centre * 0.0009 / cloud_horizontal_scale(layer));
		float occupancy = deck.z * mix(0.25, 1.0, smoothstep(0.25, 0.65, weather));
		if (hash12(cell + vec2(37.1, 91.7)) < occupancy) {
			float crown = height * mix(0.55, 1.0, hash12(cell));
			vec4 footprint = cloud_cell_footprint(cell, cell_size);
			vec3 lo = vec3(footprint.x - footprint.z, cloud_cell_base(cell, deck),
				footprint.y - footprint.w);
			vec3 hi = lo + vec3(footprint.z * 2.0, crown, footprint.w * 2.0);
			vec3 a = (lo - ro) / ray;
			vec3 b = (hi - ro) / ray;
			vec3 near_t = min(a, b), far_t = max(a, b);
			float hit = max(max(near_t.x, near_t.y), near_t.z);
			float exit_t = min(min(far_t.x, far_t.y), far_t.z);
			if (exit_t >= max(hit, start) && hit <= end) {
				hit = max(hit, start);
				vec3 normal = near_t.x >= near_t.y && near_t.x >= near_t.z
					? vec3(-sign(ray.x), 0.0, 0.0)
					: near_t.y >= near_t.z ? vec3(0.0, -sign(ray.y), 0.0)
					: vec3(0.0, 0.0, -sign(ray.z));
				if (cloud_style == 1) {
					vec4 body = fluffy_block_cell(ro, dir, lo, hi, hit,
						min(exit_t, end), cubemap, deck.w, reach, cloud_horizontal_scale(layer));
					accumulated.rgb += (1.0 - accumulated.a) * body.rgb;
					accumulated.a += (1.0 - accumulated.a) * body.a;
					if (accumulated.a > 0.985) break;
				} else {
					float diffuse = 0.25 + 0.75 * max(dot(normal, sun_dir), 0.0);
					float under = max(-normal.y, 0.0);
					vec3 ambient = mix(sky_horizon.rgb, haze_color.rgb, haze_twilight * 0.6);
					vec3 lit = cloud_color.rgb * (cloud_beam * diffuse * 1.4
						+ goanna_sun_glow * under * 0.6)
						+ cloud_ambient_color + ambient * 0.08;
					float alpha = 1.0 - smoothstep(reach * 0.65, reach, hit);
					return vec4(lit, alpha);
				}
			}
		}
		// Advance the integer cell, not a rounded world point plus epsilon.
		// At large drift offsets that epsilon vanished in float precision,
		// repeatedly integrating one cell and exhausting the traversal budget.
		bool cross_x = crossing.x <= crossing.y;
		bool cross_z = crossing.y <= crossing.x;
		t = min(crossing.x, crossing.y);
		if (cross_x) { cell.x += direction.x; crossing.x += crossing_step.x; }
		if (cross_z) {
			cell.y += direction.y;
			crossing.y += crossing_step.y;
			// A new row has its own horizontal origin. Re-enter its x cell
			// at this same ray distance, without a world-space epsilon.
			cell.x = floor((ro.x + dir.x * t) / cell_size - cloud_row_shift(cell.y));
			float next_x = (cell.x + cloud_row_shift(cell.y)
				+ step(0.0, dir.x)) * cell_size;
			crossing.x = abs(dir.x) > 0.000001 ? (next_x - ro.x) / ray.x : 1e20;
		}
	}
	return vec4(accumulated.rgb / max(accumulated.a, 0.00001), accumulated.a);
}

// Density at a world point. base_w and deck are the slab; weather is
// cloud_weather at the sample's column, passed in because the light march
// reuses its own.
float cloud_density(vec3 wp, float base_w, float deck, float weather, int layer) {
	float hf = (wp.y - base_w) / deck - (weather - 0.5) * 0.65;
	if (hf <= 0.0 || hf >= 1.0)
		return 0.0;
	// The base ramp spans several march steps on purpose. At 0.08 of the
	// deck it was a fourteen-node cliff that one step could straddle, and
	// with the per-direction jitter that showed as heavy speckle across
	// every underside: neighbouring pixels landed on opposite sides of the
	// ramp and disagreed about both opacity and light. A soft underside is
	// true of cumulus anyway. The top tapers early where the weather is
	// weak and late where it is strong, so strong systems tower and weak
	// ones stay shallow.
	float grad = smoothstep(0.0, 0.22, hf) * (1.0 - smoothstep(mix(0.20, 0.85, weather), 1.0, hf));
	vec3 uvw = vec3(wp.x, wp.y * 2.4, wp.z) / 680.0;
	uvw.xz = (uvw.xz + cloud_layer_offset(cloud_offset, layer) * 0.05)
		/ cloud_horizontal_scale(layer);
	float body = texture(cloud_body_tex, uvw).r;
	float cover = cloud_layers[layer].z * smoothstep(0.30, 0.62, weather);
	return smoothstep(1.0 - cover, 1.0 - cover + 0.16, body * grad * 1.25);
}

// Optical depth toward the sun over the same distance at every quality. This
// is what buries a core in its own shadow and leaves the sunward flank lit.
float cloud_light_od(vec3 wp, vec3 toward_sun, float base_w, float deck, float weather, int layer) {
	float od = 0.0;
	int samples = cloud_quality == 0 ? 2 : (cloud_quality == 1 ? 3 : 4);
	float stride = 88.0 / float(samples);
	for (int j = 1; j <= 4; j++) {
		if (j > samples) break;
		od += cloud_density(wp + toward_sun * (stride * float(j)), base_w, deck, weather, layer);
	}
	return od * stride;
}

// Billboard uv of `dir` on a disc of angular half-size `size` around `center`.
vec2 disc_uv(vec3 dir, vec3 center, float size, out float inside) {
	vec3 u_ax = normalize(cross(abs(center.y) > 0.99 ? vec3(1, 0, 0) : vec3(0, 1, 0), center));
	vec3 v_ax = cross(center, u_ax);
	float du = dot(dir, u_ax), dv = dot(dir, v_ax), dc = dot(dir, center);
	inside = (dc > 0.0 && max(abs(du), abs(dv)) < size) ? 1.0 : 0.0;
	return vec2(du, dv) / (2.0 * size) + 0.5;
}

vec4 volume_clouds(vec3 eye, vec3 dir, bool cubemap, int layer) {
	float base_w = cloud_layers[layer].x;
	float deck = cloud_layers[layer].y;
	float top_w = base_w + deck * 1.325;
	float t0 = 0.0;
	float t1 = -1.0;
	if (abs(dir.y) > 0.002) {
		float ta = (base_w - deck * 0.325 - eye.y) / dir.y;
		float tb = (top_w - eye.y) / dir.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = max(ta, tb);
	} else if (eye.y > base_w - deck * 0.325 && eye.y < top_w) {
		t0 = 0.0;
		t1 = 8000.0;
	}
	// The horizon cap: past this the deck has melted into the haze band
	// anyway, and a grazing ray otherwise marches tens of kilometres.
	t1 = min(t1, 9000.0);
	if (t1 > t0 + 1.0) {
		// Coarser view sampling visibly grains the cloud edges at 800p.
		// Keep silhouettes intact; quality budgets the sun march instead.
		int steps = cubemap ? 8 : 24;
		// Capped step: a grazing ray's slab crossing is kilometres, and
		// (t1 - t0) / steps then puts hundreds of nodes in one step, so
		// a single sample straddled the whole base transition and the
		// jitter turned that into speckle. The near stretch gets the
		// steps; whatever lies past steps * dt is already inside the
		// distance fade and the horizon haze.
		float dt = min((t1 - t0) / float(steps), 45.0);
		// Per-direction start offset: stable (no shimmer), breaks the
		// slab's stepping into noise the eye ignores. At 0.6 of a step,
		// not a full one: the soft base ramp already spans several
		// steps, so full-amplitude white noise was pure grain on the
		// torn edges with no banding left for it to hide.
		float jit = hash12(dir.xz * 311.7 + vec2(dir.y * 97.3)) * 0.6 + 0.2;
		float T = 1.0;
		vec3 acc = vec3(0.0);
		float mu = dot(dir, sun_dir);
		// A forward lobe over an isotropic floor: silver linings toward
		// the sun without the away side going black.
		float hg = 0.55;
		float phase = mix(1.0, (1.0 - hg * hg) / pow(1.0 + hg * hg - 2.0 * hg * mu, 1.5), 0.55);
		// The sun as the clouds see it: the shared beam at the deck's
		// own altitude. Its strength already encodes that the deck sees
		// over the ground's ridge and holds the light past the ground's
		// sunset, so there is no elevation gate here any more.
		vec3 csun = cloud_beam * 2.2;
		float sigma = 0.055 * cloud_layers[layer].w;
		for (int i = 0; i < 24; i++) {
			if (i >= steps)
				break;
			float t = t0 + (float(i) + jit) * dt;
			vec3 wp = eye + dir * t;
			float weather = cloud_weather(wp.xz, layer);
			float dens = cloud_density(wp, base_w, deck, weather, layer);
			// Thin out with distance so the far deck dissolves into the
			// horizon haze instead of stacking into a wall.
			dens *= 1.0 - smoothstep(5200.0, 8800.0, t);
			if (dens > 0.004) {
				float od = cloud_light_od(wp, sun_dir, base_w, deck, weather, layer);
				float light = exp(-od * sigma);
				// Powder term: a dense core keeps a bright rim where the
				// eye and the light are on the same side.
				light *= 1.0 - 0.5 * exp(-dens * 3.0);
				float hf = clamp((wp.y - base_w) / deck, 0.0, 1.0);
				vec3 amb = mix(sky_horizon.rgb, sky_top.rgb, 0.6) * mix(0.35, 0.75, hf);
				// A shadowed cloud is lit by the air around it, so in
				// the twilight window it takes the same air colour the
				// haze band and the depth fog wear.
				amb = mix(amb, haze_color.rgb * 0.8, haze_twilight * 0.6);
				// The ground bounce: when the beam reaches the land (the
				// same gated glow the water and shafts use), the flood
				// it lays on the ground lights the deck from beneath,
				// strongest at the base and gone by the crown. Without
				// it the underside of a sunset deck stood black over a
				// golden valley, which is the one face of the deck the
				// player is usually looking at.
				vec3 under = goanna_sun_glow * (1.2 * exp(-hf * 3.0));
				// Direct beam and ground bounce take the cloud albedo. The
				// diffuse term is light already recycled through the cloud and
				// therefore adds in its own colour. Retain a small share of the
				// surrounding sky for altitude variation, but never use that
				// dark sky as a second multiplier on the server's ambient cloud.
				vec3 diffuse = cloud_ambient_color + amb * 0.18;
				vec3 s = cloud_color.rgb * (csun * (light * phase) + under) + diffuse;
				float a = 1.0 - exp(-dens * sigma * dt);
				acc += T * s * a;
				T *= 1.0 - a;
				if (T < 0.015)
					break;
			}
		}
		return vec4(acc / max(1.0 - T, 0.00001), 1.0 - T);
	}
	return vec4(0.0);
}

void sky() {
	vec3 dir = EYEDIR;
	float up = clamp(dir.y, -1.0, 1.0);
	vec3 col;
	if (up >= 0.0) {
		col = mix(sky_horizon.rgb, sky_top.rgb, pow(up, 0.45));
	} else {
		// The whole lower hemisphere is the fog wall: terrain wearing full
		// fog, not unlit ground. Where the far field stands proud of the
		// horizon line it dissolves into this same air (the depth fog
		// converges on haze_color), and where it dips below, the wall
		// stands in as the horizon, so the disc's edge and the dome blend
		// through one gradient instead of meeting at a join. ground_color
		// is now the wall's depth (main.gd feeds the fog colour darkened),
		// so looking steeply down reads as thicker air, not as a different
		// material. Ramped over a couple of degrees so the horizon line is
		// not a step. The cubemap pass keeps the old colour, because that
		// half of this shader is the light the world is lit by rather than
		// what is drawn, and this is a fix to the picture only.
		vec3 base = sky_horizon.rgb;
		if (!AT_CUBEMAP_PASS)
			base = mix(sky_horizon.rgb, haze_color.rgb, smoothstep(0.0, -0.03, up));
		col = mix(base, ground_color.rgb, pow(-up, ground_curve));
	}
	if (AT_CUBEMAP_PASS) {
		if (up < 0.0)
			col = mix(col, sky_horizon.rgb, radiance_ground_lift);
		col = mix(col, vec3(dot(col, vec3(0.2126, 0.7152, 0.0722))), radiance_desaturate);
		col += radiance_floor;
	}
	// The same air colour used by depth fog lives in the sky itself. This is
	// strongest along the geometric horizon and toward a low sun, so sunset
	// cannot leave orange land against an unrelated blue/grey backdrop. The
	// warm term is the high air's beam, the same one the clouds are lit by.
	// No lower bound on up: the warm gradient runs down the fog wall with
	// the same exponential falloff, so the wall and the band are one air.
	// `air` survives the block: it is also what the baked horizon's own
	// aerial perspective dissolves toward, so the panorama and the band are
	// one air too.
	vec3 air = haze_color.rgb;
	if (!AT_CUBEMAP_PASS) {
		float horizon = exp(-abs(up) * mix(9.0, 5.0, haze_twilight));
		float sun_haze = pow(max(dot(normalize(vec3(dir.x, 0.08, dir.z)),
				normalize(vec3(sun_dir.x, 0.08, sun_dir.z))), 0.0), 5.0);
		air = mix(haze_color.rgb, air_beam * 0.82,
				haze_twilight * mix(0.20, 0.82, sun_haze));
		col = mix(col, air, horizon * (horizon_air_day + 0.48 * haze_twilight));
	}

	// Higher air keeps its blue/violet scattering after the warm horizon
	// beam fades. The anti-solar arch is the last pink light above the shadow.
	if (!AT_CUBEMAP_PASS && night_sky_strength > 0.0 && up > 0.0) {
		float twilight = smoothstep(-0.32, -0.12, sun_dir.y)
				* (1.0 - smoothstep(0.02, 0.18, sun_dir.y));
		vec2 solar = sun_dir.xz / max(length(sun_dir.xz), 0.001);
		float facing = dot(dir.xz, solar);
		float arch = exp(-pow((up - 0.16) * 8.0, 2.0));
		vec3 scatter = vec3(0.028, 0.040, 0.10) * exp(-up * 2.8)
				+ vec3(0.11, 0.036, 0.055) * arch * max(-facing, 0.0);
		col += scatter * twilight * night_sky_strength * smoothstep(0.0, 0.035, up);
	}

	// Keep point lights and transient events out of ambient radiance, just
	// like the sun/moon discs below. Clouds and the horizon occlude them all.
	float pixel_angle = max(length(dFdx(dir)), length(dFdy(dir)));
	if (!AT_CUBEMAP_PASS && star_opacity > 0.001 && star_density > 0.0
			&& star_scale > 0.0 && up > 0.0) {
		vec3 celestial = celestial_direction(dir);
		float extinction = smoothstep(0.015, 0.25, up);
		float dark = 1.0 - smoothstep(-0.30, -0.055, sun_dir.y);
		float moon_glare = moon_visible ? pow(max(dot(dir, moon_dir), 0.0), 12.0)
				* smoothstep(-0.02, 0.18, moon_dir.y) : 0.0;
		vec3 stars = night_stars(celestial, pixel_angle, celestial_time, up);
		vec3 deep_sky = vec3(0.0);
		if (night_sky_strength > 0.0) {
			vec4 groups = night_constellations(celestial, pixel_angle, celestial_time, up);
			stars *= mix(1.0, groups.a, night_sky_strength);
			deep_sky += groups.rgb;
			if (dark > 0.001) {
				deep_sky += galactic_clouds(celestial, pixel_angle) * dark * (1.0 - moon_glare * 0.85);
				deep_sky += night_meteor(dir, celestial_time, pixel_angle) * dark;
			}
			deep_sky += night_planets(celestial, pixel_angle);
		}
		col += (stars + deep_sky * night_sky_strength) * star_color.rgb
				* star_opacity * extinction;
	}

	// The discs and their halos are the picture, not the light: the radiance
	// cubemap feeds ambient and, through fog_aerial_perspective, the colour
	// depth fog blends toward, per direction. With the sun disc in it, a
	// hazed hill in front of a low sun glowed with the disc behind it, dawn
	// shining through the terrain. Their solid angle is far too small to
	// matter to ambient energy, so the cubemap pass skips them entirely.
	float inside;
	if (moon_visible && !AT_CUBEMAP_PASS) {
		// Scattering around the moon belongs to the atmosphere behind geometry,
		// not to a depth-fog gradient painted over the nearest hillside. Kept
		// tight: the old exponent of 24 spread a glow across a third of the
		// sky, and with bloom on top the moon read as a big blur with no
		// body in it.
		float moon_mu = max(dot(dir, moon_dir), 0.0);
		float moon_halo = pow(moon_mu, 90.0) * 0.05 + pow(moon_mu, 600.0) * 0.18;
		col += moon_tint.rgb * moon_halo * smoothstep(-0.08, 0.12, moon_dir.y);
		vec2 uv = disc_uv(dir, moon_dir, moon_size, inside);
		if (inside > 0.5) {
			if (moon_use_tex) {
				vec4 t = texture(moon_tex, uv);
				// The faint additive term is the dark side of the disc. A
				// phase texture is mostly black near new moon, and drawing
				// black on a black sky erased the moon entirely: all that
				// survived was the halo, a blur with no body in it. The real
				// sky shows the unlit disc as a silhouette a shade off the
				// sky behind it.
				col = mix(col, t.rgb * moon_tint.rgb * 2.4 + moon_tint.rgb * 0.06, t.a);
			} else {
				float d = length(uv - 0.5) * 2.0;
				col = mix(col, moon_tint.rgb * 1.5, smoothstep(1.0, 0.85, d));
			}
		}
	}
	if (sun_visible && !AT_CUBEMAP_PASS) {
		vec2 uv = disc_uv(dir, sun_dir, sun_size, inside);
		if (inside > 0.5) {
			if (sun_use_tex) {
				vec4 t = texture(sun_tex, uv);
				col = mix(col, t.rgb * sun_tint.rgb * 3.0, t.a);
			} else {
				float d = length(uv - 0.5) * 2.0;
				col = mix(col, sun_tint.rgb * 3.0, smoothstep(1.0, 0.8, d));
			}
		}
		// 0.8, down from 1.2: with bloom and the dawn scatter on top, the
		// old value blew a third of the sky to white around a low sun.
		col += sun_tint.rgb * pow(max(dot(dir, sun_dir), 0.0), 350.0) * 0.8;
	}

	// The baked horizon: drawn after the discs, so a far mountain hides a
	// rising sun and the stars behind it, and before the clouds, which
	// stand nearer along a grazing ray than the land they overhang. Skipped
	// in the cubemap pass like the discs: it is the picture, not the light.
	if (horizon_on > 0.5 && !AT_CUBEMAP_PASS && up < horizon_y_max && up > horizon_y_min) {
		float hu = fract(atan(dir.x, -dir.z) / 6.28318530718);
		float hv = clamp((up - horizon_y_min) / (horizon_y_max - horizon_y_min), 0.0, 1.0);
		vec4 hp = texture(horizon_tex, vec2(hu, hv));
		if (hp.a > 0.4) {
			float hd = texture(horizon_dist, vec2(hu, hv)).r;
			vec3 lit = hp.rgb * horizon_light;
			// Its own aerial perspective continues the depth fog's: mostly
			// air by its near edge, almost but never fully air at the far
			// one, so the furthest ridges stay silhouettes the way the
			// drawn far field's do.
			float fogf = clamp((hd - horizon_fade0)
					/ max(horizon_r1 - horizon_fade0, 1.0), 0.0, 1.0);
			col = mix(col, mix(lit, air, 0.45 + 0.50 * fogf), hp.a);
		}
	}

	// Disjoint slabs composite from near to far, including views from above
	// or between decks. Opaque near clouds skip the more distant marches.
	if (clouds_enabled && cloud_coverage > 0.01) {
		vec4 accumulated = vec4(0.0);
		for (int pass = 0; pass < 3; pass++) {
			int layer = dir.y >= 0.0 ? pass : 2 - pass;
			if (cloud_layers[layer].z <= 0.01) continue;
			vec4 clouds = cloud_style < 2
				? block_clouds(POSITION, dir, AT_CUBEMAP_PASS, layer)
				: volume_clouds(POSITION, dir, AT_CUBEMAP_PASS, layer);
			accumulated.rgb += (1.0 - accumulated.a) * clouds.rgb * clouds.a;
			accumulated.a += (1.0 - accumulated.a) * clouds.a;
			if (accumulated.a > 0.985) break;
		}
		col = accumulated.rgb + col * (1.0 - accumulated.a);
	}
	COLOR = col;
}
