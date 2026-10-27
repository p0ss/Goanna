// Participating media near the ground and camera: one world-sized volume that
// pools mist in valleys and gives nearby clouds real depth, without geometry
// or per-bank draw calls. The sky shader continues the cloud field beyond the
// froxel range, where true volume resolution would be too coarse to help.
//
// The complete cloud deck is deliberately not here. Godot's froxel grid is
// camera relative and ends at volumetric_fog_length, so it cannot carry a
// deck continuously to the horizon. sky.gdshader draws that full projected
// field; this volume contributes only the nearby body that the camera may
// approach or enter. The node shaders read the related deck field for ground
// shadows.
//
// What the grid is good at is exactly this: bounded, close to the camera, and
// soft-edged by nature.
//
// main.gd gives it to one world-shaped FogVolume (through
// GoannaClient.load_view_shader), shown only while the Volumetric atmosphere
// switch (render_atmosphere) is on, the tier's atmosphere_quality is above
// zero and the eye is above water: Low and up, not Lowest
// (docs/systems/graphics-tiers.md). Every uniform is set from main.gd.
shader_type fog;

// Valley mist. atmosphere_color is the fog colour (_apply_sky). mist_level is
// the world height in nodes the mist pools below, the regional ground plus
// 18; mist_density its peak extinction per node, scaled by cloud cover, the
// mist's day cycle and atmosphere_quality (_update_environment_extras).
uniform vec3 atmosphere_color : source_color = vec3(0.72, 0.80, 0.90);
uniform float mist_level = 64.0;
uniform float mist_density : hint_range(0.0, 0.1) = 0.012;
// Clear-air scattering belongs near the surface. A uniform Environment
// density also fills the zenith, forcing an incorrect partial sky composite
// to keep the clouds visible. Fade smoothly with height instead.
// air_density is the clear air's extinction per node, the scattering the
// light shafts are seen in, and air_albedo the sun's colour it scatters;
// both from main.gd's _apply_sky, which zeroes the Environment's own density
// while this volume carries the air.
uniform float air_density = 0.0;
uniform vec3 air_albedo : source_color = vec3(1.0, 0.98, 0.95);
// The sky's cloud_offset, so the local bodies drift with the projected deck
// (_update_environment_extras).
uniform vec2 weather_offset = vec2(0.0);
// The tier's atmosphere_quality, 0 to 1: Low 0.35, Medium 0.65, High and
// Ultra 1. Below 0.34 the noise is one octave, below 0.67 two, else three.
uniform float quality : hint_range(0.0, 1.0) = 1.0;
#include "res://shaders/cloud_layers.gdshaderinc"
// The sky's cloud style (sky.gdshader), so a local body matches the shape
// drawn beyond it: below 2 it follows the block cells, at 2 the volume.
// Set with cloud_layers in main.gd's _update_cloud_layers.
uniform int cloud_style = 2;
// Extinction per node of a local cloud body at full deck coverage, 0.026
// times atmosphere_quality (_update_environment_extras). cloud_albedo is a
// default only.
uniform float cloud_density : hint_range(0.0, 0.1) = 0.025;
uniform vec3 cloud_albedo : source_color = vec3(0.95, 0.96, 1.0);
// The mist's own faint light, set from the night radiance floor in
// main.gd's _apply_sky. Fog on the fens exists at night; without this it was invisible
// until dawn arrived to light it, so the dawn appeared to summon the fog
// rather than pierce it. Zero by day, when the sun owns the banks.
uniform vec3 mist_glow : source_color = vec3(0.0);
// The ground's beam thrown back up at the local cloud bodies, set from
// the same gated sun glow as the sky march's underside term. The froxel
// sun is gated down under heavy cover (sun_open in main.gd) to stop the
// air glowing through the deck, and that gate also robbed the bodies of
// the low sun that really does slide under a deck's edge; this puts the
// underside light back without ungating the air.
uniform vec3 cloud_under_glow : source_color = vec3(0.0);
// Approximate the multiple scattering a water cloud retains. Godot's fog
// lighting is largely single scattering; without a diffuse floor, dense
// near-camera cloud extinguishes the sky to black rather than becoming grey.
// Set in _apply_sky beside the sky's cloud_ambient_color.
uniform vec3 cloud_ambient : source_color = vec3(0.12, 0.14, 0.16);

// The climate field a paired server sends (docs/systems/climate.md), and
// the air it fills: mist where the air is cool and near saturated, dust
// where the ground is dry and the wind lifts it, and in a dry cave the fine
// haze a lamp's beam shows. Dry and damp are bands apart, so a place has
// one or the other, never both. Off the field's grid, and against any
// other server, none of it, and the valley mist above is as it was.
#define GOANNA_CLIMATE_FIELD_ONLY
#include "res://shaders/climate.gdshaderinc"
// The top of the highest rain stopping node per column round the player
// (weather_common.gdshaderinc), which is the ground or the water the mist
// lies on, and the roof a cave is under.
global uniform sampler2D goanna_rain_cover : filter_nearest, repeat_disable;
global uniform vec4 goanna_rain_cover_area;
// The wind, from the clouds' motion as the grass takes it: direction times
// strength, 0.25 to 1 (main.gd).
uniform vec2 climate_wind = vec2(0.25, 0.0);
// Extinction per node of the field's mist and dust at full strength, scaled
// by atmosphere_quality and, for the mist, its day cycle (main.gd).
uniform float climate_mist_density = 0.2;
uniform float climate_dust_density = 0.14;
// The still haze in a dry cave at full dryness, extinction per node: thin
// enough to see across a cave, thick enough that a beam of sun down a
// shaft or a lamp's light stands in it.
uniform float climate_cave_haze = 0.1;
uniform vec3 climate_dust_albedo : source_color = vec3(0.78, 0.68, 0.52);

// The same sine free hash as the sky's hash12, in three dimensions, and
// value noise and fbm over it. main.gd keeps an exact CPU copy of the
// local cloud field (_cloud_hash31 and what follows it), which gives the
// light shafts pass the cloud's optical depth at the camera, so a change to
// the field here wants the same change there.
float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1, 0, 0));
	float n010 = hash31(i + vec3(0, 1, 0));
	float n110 = hash31(i + vec3(1, 1, 0));
	float n001 = hash31(i + vec3(0, 0, 1));
	float n101 = hash31(i + vec3(1, 0, 1));
	float n011 = hash31(i + vec3(0, 1, 1));
	float n111 = hash31(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float weather_noise(vec3 p) {
	float value = noise3(p) * 0.55;
	float weight = 0.55;
	if (quality > 0.34) {
		p = p * 2.03 + vec3(7.1, 3.7, 1.9);
		value += noise3(p) * 0.264;
		weight += 0.264;
	}
	if (quality > 0.67) {
		p = p * 2.03 + vec3(7.1, 3.7, 1.9);
		value += noise3(p) * 0.127;
		weight += 0.127;
	}
	return value / weight;
}

// Height of `p` over the ground under it: x from the cover map, y how much
// of it to trust (1 inside, fading to 0 over the map's last 8 nodes and
// beyond). Past the map the regional ground (mist_level less 18) is all
// there is, and it is no floor: over the sea it lies above the water, so a
// point under it is taken as on it rather than cut off, or the mist ends in
// a hard disc round the player. Terrain hides what lies under the ground.
vec2 climate_above(vec3 p) {
	float regional = max(p.y - (mist_level - 18.0), 0.0);
	if (goanna_rain_cover_area.w > 0.5) {
		vec2 uv = (p.xz - goanna_rain_cover_area.xy) / goanna_rain_cover_area.z;
		if (uv == clamp(uv, vec2(0.0), vec2(1.0))) {
			vec2 edge = min(uv, 1.0 - uv) * goanna_rain_cover_area.z;
			float trust = smoothstep(0.0, 8.0, min(edge.x, edge.y));
			float mapped = p.y - textureLod(goanna_rain_cover, uv, 0.0).r;
			return vec2(mix(regional, mapped, trust), trust);
		}
	}
	return vec2(regional, 0.0);
}

// How enclosed `p` is, 0 to 1: the share of four columns four nodes round
// it whose roof (the cover map's top) is over it. A shaft down into a cave
// is open to the sky in its own column, so climate_above takes a point in
// it for open air, and the haze was cut from the one column the sun came
// down; the columns round it are roofed, and say it is inside.
float climate_roofed(vec3 p) {
	if (goanna_rain_cover_area.w < 0.5)
		return 0.0;
	float n = 0.0;
	const vec2 OFFS[4] = vec2[4](vec2(4.0, 0.0), vec2(-4.0, 0.0), vec2(0.0, 4.0), vec2(0.0, -4.0));
	for (int i = 0; i < 4; i++) {
		vec2 uv = (p.xz + OFFS[i] - goanna_rain_cover_area.xy) / goanna_rain_cover_area.z;
		if (uv == clamp(uv, vec2(0.0), vec2(1.0)))
			n += step(p.y + 1.0, textureLod(goanna_rain_cover, uv, 0.0).r);
	}
	return n * 0.25;
}

void fog() {
	vec3 p = WORLD_POSITION;
	float mist = 0.0;
	float field_mist = 0.0;
	float dust = 0.0;
	float haze = 0.0;
	float cave_mist = 0.0;
	vec4 c = goanna_climate_at(p);
	// Height over the ground, and how far the cover map vouches for it.
	vec2 ground = climate_above(p);
	// Under a roof: in a column the cover map roofs over it, or in an open
	// one (a shaft, a doorway) with roofs all round.
	float roofed = max(ground.y * smoothstep(1.5, 5.0, -ground.x),
			smoothstep(0.5, 1.0, climate_roofed(p)));

	// Moist air pools below the local inhabited elevation. Use an exponential
	// tail above it, rather than a finite band with a visible horizontal top.
	// The lower fade keeps the volume out of the vast underground space.
	//
	// The tail is short and the noise floor is zero on purpose. A 42 node
	// tail with a 0.28 floor was not valley mist, it was a world-wide medium:
	// at eye level it still held a third of full density, and over a few
	// hundred nodes of path that extinguished the scene into grey murk
	// (measured as the frame mean falling from 216 to 119 with the volume
	// on). Banks with real gaps between them read as weather; a floor reads
	// as a dirty lens.
	float mist_height = smoothstep(mist_level - 72.0, mist_level - 32.0, p.y) *
			exp(-max(p.y - mist_level, 0.0) / 18.0);
	if (mist_height > 0.001) {
		float mist_noise = smoothstep(0.40, 0.68,
				weather_noise(vec3(p.xz * 0.005 + weather_offset * 0.15, p.y * 0.018)));
		mist = mist_density * mist_height * mist_noise;
		// Where the field is known the valley mist follows its humidity:
		// none in dry country, more over wet.
		mist *= mix(1.0, 1.6 * smoothstep(0.5, 0.9, c.z), c.w);
		// Not under a roof. The band is set by the inhabited elevation, so
		// a cave a few tens of nodes down sat inside it, and its banks
		// filled the cave as big pale blobs, the cells of the noise; the
		// air in a cave is the field's (dust, or nothing).
		mist *= 1.0 - ground.y * smoothstep(1.5, 5.0, -ground.x);
	}

	if (c.w > 0.01) {
		float above = ground.x;
		float drift_t = TIME * 0.6;
		// Mist: banks lying on the ground and the water, a few nodes deep,
		// where the air is near saturated and cool, thickest at dawn and in
		// the night (mist_cycle in main.gd, through climate_mist_density).
		float sat = smoothstep(0.8, 0.97, c.z) * smoothstep(24.0, 8.0, c.x);
		if (sat > 0.001 && above > -1.0) {
			float lie = smoothstep(-1.0, 0.5, above) * exp(-max(above, 0.0) / 4.0);
			vec2 drift = climate_wind * drift_t * 0.15;
			float banks = smoothstep(0.38, 0.72, weather_noise(vec3((p.xz - drift) * 0.07, p.y * 0.15)));
			field_mist = climate_mist_density * c.w * sat * lie * banks;
			// Under a roof, thinner and dark, for the reason the dry haze
			// is (below): at the fog colour, lit by the sky's ambient
			// underground, it filled a wet cave as opaque pale steam.
			cave_mist = field_mist * roofed * 0.35;
			field_mist *= 1.0 - roofed;
		}
		// Dust: dry ground in the wind, lifted a few nodes, streaming with
		// it; under a roof, a still, faint haze, more in a deep dry cave.
		float dry = smoothstep(0.5, 0.25, c.y);
		// Cave air settles damper than the open ground over it (a mesa's
		// dry cave reads about 0.42), so the still haze starts higher.
		float still_dry = smoothstep(0.58, 0.32, c.y);
		if (still_dry > 0.001) {
			float wind = length(climate_wind);
			if (roofed < 0.5 && (above > -0.5 || ground.y < 0.5)) {
				float lift = smoothstep(-0.5, 0.5, above) * exp(-max(above, 0.0) / (2.0 + 6.0 * wind));
				vec2 drift = climate_wind * drift_t * 4.0;
				float gusts = smoothstep(0.25, 0.7, weather_noise(vec3((p.xz - drift) * 0.05, p.y * 0.1 + drift_t * 0.2)));
				dust = climate_dust_density * c.w * dry * wind * wind * lift * gusts;
			} else {
				float deep = max(smoothstep(2.0, 8.0, -above), roofed);
				haze = climate_cave_haze * c.w * still_dry * deep
						* mix(0.6, 1.0, noise3(p * 0.25 + vec3(0.0, drift_t * 0.05, 0.0)));
			}
		}
	}

	// A real local cloud body. Its far continuation is projected by the sky
	// shader, but within the froxel range this density has thickness, can be
	// entered from either side, and is lit/shadowed as participating media.
	float cloud = 0.0;
	float cloud_bounce = 0.0;
	for (int layer = 0; layer < 3; layer++) {
		vec4 deck = cloud_layers[layer];
		if (deck.z <= 0.01 || deck.y <= 0.0 || p.y < deck.x - deck.y * 0.75
				|| p.y > deck.x + deck.y * 1.75) continue;
		vec2 offset = cloud_layer_offset(weather_offset, layer);
		float scale = cloud_horizontal_scale(layer);
		float base = deck.x;
		float depth = deck.y;
		float envelope = 1.0;
		if (cloud_style < 2) {
			vec2 position = p.xz + offset * (0.4 / 0.0009);
			vec2 cell = cloud_cell_at(position, cloud_cell_size(layer));
			vec4 footprint = cloud_cell_footprint(cell, cloud_cell_size(layer));
			if (any(greaterThanEqual(abs(position - footprint.xy), footprint.zw))) continue;
			float weather = cloud_layer_weather((cloud_cell_origin(cell, cloud_cell_size(layer))
				+ cloud_cell_size(layer) * 0.5) * 0.0009 / scale);
			float occupancy = deck.z * mix(0.25, 1.0, smoothstep(0.25, 0.65, weather));
			if (cloud_cell_hash(cell + vec2(37.1, 91.7)) >= occupancy) continue;
			base = cloud_cell_base(cell, deck);
			depth *= mix(0.55, 1.0, cloud_cell_hash(cell));
			if (cloud_style == 1) {
				float sdf = cloud_block_distance(vec3(position.x, p.y, position.y),
					vec3(footprint.x, base + depth * 0.5, footprint.y),
					vec3(footprint.z, depth * 0.5, footprint.w));
				envelope = 1.0 - smoothstep(-0.22, 0.0, sdf + 0.15);
			}
		} else {
			float weather = cloud_layer_weather((p.xz * 0.0009 + offset * 0.4) / scale);
			base += (weather - 0.5) * depth * 0.65;
		}
		float ch = 1.0 - abs(p.y - (base + depth * 0.5)) / (depth * 0.5);
		if (ch > 0.0 && deck.z > 0.01) {
			float profile = smoothstep(0.0, 0.22, ch) * smoothstep(0.0, 0.18, ch);
			vec3 cp = vec3(p.x * 0.006 + offset.x * 0.12,
				p.y * 0.018, p.z * 0.006 + offset.y * 0.12);
			cp.xz /= scale;
			float shape = weather_noise(cp);
			float threshold = mix(0.76, 0.32, deck.z);
			float density = cloud_density * deck.w * profile * envelope
				* smoothstep(threshold, threshold + 0.18, shape);
			cloud += density;
			cloud_bounce += density * clamp(1.0 - (p.y - base) / depth, 0.0, 1.0);
		}
	}

	float air_height = smoothstep(mist_level - 72.0, mist_level - 32.0, p.y)
			* exp(-max(p.y - (mist_level - 18.0), 0.0) / 32.0);
	float air = air_density * air_height;
	mist += field_mist;
	float total = mist + cloud + air + dust + haze + cave_mist;
	DENSITY = total;
	ALBEDO = total > 0.00001 ?
			(atmosphere_color * mist + cloud_albedo * cloud + air_albedo * air
					+ climate_dust_albedo * dust
					// A cave's haze is dark: the volume takes the sky's
					// ambient light everywhere, underground too, and at the
					// dust's albedo the haze lit the whole cave like a room
					// with the lights on. Dark, it is lit by what really
					// reaches it, the sun down a shaft and lamps.
					+ climate_dust_albedo * 0.12 * haze
					+ atmosphere_color * 0.15 * cave_mist) / total : atmosphere_color;
	// The mist share glows with the night floor; the cloud share takes the
	// ground bounce on its underside, fading out by the crown.
	EMISSION = total > 0.00001 ?
			(mist_glow * mist + cloud_ambient * cloud
					+ cloud_under_glow * cloud_bounce) / total
			: vec3(0.0);
}
