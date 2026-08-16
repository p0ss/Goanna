// Goanna: liquids (Luanti TILE_MATERIAL_LIQUID_TRANSPARENT / WAVING_LIQUID_*).
// Vertex waves like Luanti's waving liquids, low roughness, screen refraction.
shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float wave_height = 0.045;
uniform float wave_speed = 1.6;
uniform float wave_length = 4.0;
uniform float alpha_mul = 0.92;
uniform float refraction = 0.018;
uniform bool waving = true;

varying vec3 world_pos;

void vertex() {
	world_pos = VERTEX;
	if (waving && NORMAL.y > 0.5) {
		float ph = (VERTEX.x + VERTEX.z * 0.7) * (6.2831853 / wave_length) + TIME * wave_speed;
		float h = sin(ph) * wave_height + sin(ph * 1.7 + 1.3) * wave_height * 0.5;
		VERTEX.y += h;
	}
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	ALBEDO = tex.rgb;
	ROUGHNESS = 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	// small animated normal perturbation for glints
	float ph = (world_pos.x + world_pos.z * 0.7) * (6.2831853 / wave_length) + TIME * wave_speed;
	vec3 n = normalize(vec3(cos(ph) * 0.15, 1.0, cos(ph * 1.7 + 1.3) * 0.08));
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(n, 0.0)).xyz, waving ? 0.6 : 0.0));
	vec2 ofs = NORMAL.xy * refraction;
	vec3 behind = texture(screen_tex, SCREEN_UV + ofs).rgb;
	float a = clamp(tex.a * alpha_mul, 0.0, 1.0);
	// Water should read as water: bias the surface toward its own colour and
	// keep a high opacity so the bottom is tinted, not clear glass.
	ALBEDO = mix(behind, tex.rgb, 0.72);
	ALPHA = clamp(a * 0.78 + 0.22, 0.0, 1.0);
}
