// Goanna: Luanti TILE_MATERIAL_WAVING_LEAVES. Alpha-clipped, double sided, swaying.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float sway = 0.06;
uniform float speed = 1.4;
uniform bool waving = true;
// The same sky fill the terrain adds (nodes_array_common.gdshaderinc);
// without it a canopy went near black at dawn and dusk while the ground
// under it stayed lit. See waving_plants.gdshader.
global uniform vec3 goanna_sky_fill;
global uniform vec3 goanna_ground_fill;
uniform float sky_fill_strength : hint_range(0.0, 2.0) = 1.0;

varying float v_skylight;
varying float v_wnormal_y;

void vertex() {
	// CUSTOM0.g is Luanti's sky light at the vertex (docs/mesh-attributes.md).
	v_skylight = CUSTOM0.g;
	v_wnormal_y = (MODEL_MATRIX * vec4(NORMAL, 0.0)).y;
	if (waving) {
		float ph = TIME * speed + VERTEX.x * 0.35 + VERTEX.z * 0.25 + VERTEX.y * 0.15;
		VERTEX.x += sin(ph) * sway;
		VERTEX.z += cos(ph * 0.8 + 0.7) * sway * 0.7;
	}
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	// leaves are thin: let light through a little
	BACKLIGHT = vec3(0.25);
	EMISSION += ALBEDO * mix(goanna_ground_fill, goanna_sky_fill,
			clamp(0.5 + 0.5 * v_wnormal_y, 0.0, 1.0)) * v_skylight * sky_fill_strength;
}
