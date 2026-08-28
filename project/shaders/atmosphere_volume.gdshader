// Participating media near the ground and camera: one world-sized volume that
// pools mist in valleys and gives nearby clouds real depth, without geometry
// or per-bank draw calls. The sky shader continues the cloud field beyond the
// froxel range, where true volume resolution would be too coarse to help.
//
// Clouds are deliberately not here. Godot's froxel grid is camera relative
// and ends at volumetric_fog_length, which main.gd caps at 768 nodes, so a
// cloud deck drawn in it stops partway to the horizon instead of receding to
// it; and the grid spreads a fixed cell count over that whole distance, so
// cells are metres across and a cumulus edge cannot exist. Clouds drawn here
// came out as a dark band low in the sky, which is the grid running out, not
// a lighting fault. They live in sky.gdshader instead, on a projected deck
// that has real perspective and no range limit, and the node shaders already
// read that same deck to cast its shadows on the ground.
//
// What the grid is good at is exactly this: bounded, close to the camera, and
// soft-edged by nature.
shader_type fog;

uniform vec3 atmosphere_color : source_color = vec3(0.72, 0.80, 0.90);
uniform float mist_level = 64.0;
uniform float mist_density : hint_range(0.0, 0.1) = 0.012;
uniform vec2 weather_offset = vec2(0.0);
uniform float quality : hint_range(0.0, 1.0) = 1.0;
uniform float cloud_level = 120.0;
uniform float cloud_thickness = 24.0;
uniform float cloud_density : hint_range(0.0, 0.1) = 0.025;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.4;
uniform vec3 cloud_albedo : source_color = vec3(0.95, 0.96, 1.0);

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

void fog() {
	vec3 p = WORLD_POSITION;
	float mist = 0.0;

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
	}

	// A real local cloud body. Its far continuation is projected by the sky
	// shader, but within the froxel range this density has thickness, can be
	// entered from either side, and is lit/shadowed as participating media.
	float cloud = 0.0;
	float half_cloud = max(cloud_thickness * 0.5, 4.0);
	float ch = 1.0 - abs(p.y - cloud_level) / half_cloud;
	if (ch > 0.0 && cloud_coverage > 0.01) {
		float profile = smoothstep(0.0, 0.22, ch) * smoothstep(0.0, 0.18, ch);
		vec3 cp = vec3(p.x * 0.006 + weather_offset.x * 0.12,
				p.y * 0.018, p.z * 0.006 + weather_offset.y * 0.12);
		float shape = weather_noise(cp);
		float threshold = mix(0.76, 0.32, cloud_coverage);
		cloud = cloud_density * profile * smoothstep(threshold, threshold + 0.18, shape);
	}

	float total = mist + cloud;
	DENSITY = total;
	ALBEDO = total > 0.00001 ?
			(atmosphere_color * mist + cloud_albedo * cloud) / total : atmosphere_color;
}
