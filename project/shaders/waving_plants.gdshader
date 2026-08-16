// Goanna: Luanti TILE_MATERIAL_WAVING_PLANTS. Sway grows with height above the node base.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float sway = 0.12;
uniform float speed = 1.8;
uniform bool waving = true;

void vertex() {
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
}
