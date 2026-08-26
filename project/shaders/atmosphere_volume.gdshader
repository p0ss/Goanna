// Sparse participating media near the ground: one world-sized volume that
// pools mist in the valleys, without geometry or draw calls.
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

	// Moist air pools below the local inhabited elevation. Large-scale noise
	// breaks the layer into banks rather than tinting every valley uniformly.
	// The lower fade also keeps this out of the vast underground volume.
	float mist_height = smoothstep(mist_level - 58.0, mist_level - 28.0, p.y) *
			(1.0 - smoothstep(mist_level - 8.0, mist_level + 28.0, p.y));
	if (mist_height > 0.001) {
		float mist_noise = smoothstep(0.28, 0.78,
				weather_noise(vec3(p.xz * 0.008 + weather_offset * 0.15, p.y * 0.018)));
		mist = mist_density * mist_height * mix(0.28, 1.0, mist_noise);
	}

	DENSITY = mist;
	ALBEDO = atmosphere_color;
}
