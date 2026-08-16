// Goanna: Luanti TILE_MATERIAL_WAVING_LEAVES. Alpha-clipped, double sided, swaying.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float sway = 0.06;
uniform float speed = 1.4;
uniform bool waving = true;

void vertex() {
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
}
