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
uniform float cloud_plane_h = 90.0;
uniform float cloud_thickness = 16.0;
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
float cloud_weather(vec2 wxz) {
	return fbm(wxz * 0.0009 + cloud_offset * 0.4);
}

// Density at a world point. base_w and deck are the slab; weather is
// cloud_weather at the sample's column, passed in because the light march
// reuses its own.
float cloud_density(vec3 wp, float base_w, float deck, float weather) {
	float hf = (wp.y - base_w) / deck;
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
	uvw.xz += cloud_offset * 0.05;
	float body = texture(cloud_body_tex, uvw).r;
	float cover = cloud_coverage * smoothstep(0.30, 0.62, weather);
	return smoothstep(1.0 - cover, 1.0 - cover + 0.16, body * grad * 1.25);
}

// Optical depth toward the sun: four short steps of the same density. This
// is what buries a core in its own shadow and leaves the sunward flank lit.
float cloud_light_od(vec3 wp, vec3 toward_sun, float base_w, float deck, float weather) {
	float od = 0.0;
	for (int j = 1; j <= 4; j++)
		od += cloud_density(wp + toward_sun * (22.0 * float(j)), base_w, deck, weather);
	return od * 22.0;
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

	// Volumetric cumulus, raymarched. The ray is intersected with the slab
	// the clouds live in, then walked with Beer-Lambert transmittance; each
	// occupied step is lit by a short march toward the sun through the same
	// density, plus an ambient share of the sky. POSITION anchors everything
	// to the world, so masses parallax properly as the player moves and the
	// froxel volume's nearby bodies sit under the same weather. The result
	// occludes the sun disc and the stars behind it through T, which a
	// blended sheet never did.
	if (cloud_coverage > 0.01) {
		float base_w = POSITION.y + cloud_plane_h;
		float deck = max(cloud_thickness * 3.0, 170.0);
		float top_w = base_w + deck;
		float t0 = 0.0;
		float t1 = -1.0;
		if (abs(dir.y) > 0.002) {
			float ta = (base_w - POSITION.y) / dir.y;
			float tb = (top_w - POSITION.y) / dir.y;
			t0 = max(min(ta, tb), 0.0);
			t1 = max(ta, tb);
		} else if (POSITION.y > base_w && POSITION.y < top_w) {
			t0 = 0.0;
			t1 = 8000.0;
		}
		// The horizon cap: past this the deck has melted into the haze band
		// anyway, and a grazing ray otherwise marches tens of kilometres.
		t1 = min(t1, 9000.0);
		if (t1 > t0 + 1.0) {
			int steps = AT_CUBEMAP_PASS ? 8 : 24;
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
			float sigma = 0.055;
			for (int i = 0; i < 24; i++) {
				if (i >= steps)
					break;
				float t = t0 + (float(i) + jit) * dt;
				vec3 wp = POSITION + dir * t;
				float weather = cloud_weather(wp.xz);
				float dens = cloud_density(wp, base_w, deck, weather);
				// Thin out with distance so the far deck dissolves into the
				// horizon haze instead of stacking into a wall.
				dens *= 1.0 - smoothstep(5200.0, 8800.0, t);
				if (dens > 0.004) {
					float od = cloud_light_od(wp, sun_dir, base_w, deck, weather);
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
			col = acc + col * T;
		}
	}
	COLOR = col;
}
