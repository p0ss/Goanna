// Goanna: Luanti TILE_MATERIAL_WAVING_PLANTS. Sway grows with height above the node base.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float sway = 0.12;
uniform float speed = 1.8;
uniform bool waving = true;
// The same sky fill the terrain adds (nodes_array_common.gdshaderinc). This
// shader had none of it, so at dawn and dusk, when the fill carries most of
// the scene's light, every plant was a black silhouette on lit ground: the
// sugarcane on the showcase beach, the grass at sunset.
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
		// UV.y = 0 at the top of the tile, 1 at the base
		float k = 1.0 - clamp(UV.y, 0.0, 1.0);
		float ph = TIME * speed + VERTEX.x * 0.5 + VERTEX.z * 0.4;
		VERTEX.x += sin(ph) * sway * k;
		VERTEX.z += cos(ph * 0.9 + 0.5) * sway * 0.6 * k;
	}
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
	BACKLIGHT = vec3(0.3);
	EMISSION += ALBEDO * mix(goanna_ground_fill, goanna_sky_fill,
			clamp(0.5 + 0.5 * v_wnormal_y, 0.0, 1.0)) * v_skylight * sky_fill_strength;
}
