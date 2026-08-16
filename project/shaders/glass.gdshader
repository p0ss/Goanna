// Goanna: alpha-blended non-liquid nodes (glass, ice, stained glass): TILE_MATERIAL_ALPHA.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float refraction = 0.015;
uniform float roughness = 0.08;

void fragment() {
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	vec2 ofs = NORMAL.xy * refraction;
	vec3 behind = texture(screen_tex, SCREEN_UV + ofs).rgb;
	ALBEDO = mix(behind, tex.rgb, tex.a);
	ALPHA = clamp(tex.a + 0.2, 0.0, 1.0);
	ROUGHNESS = roughness;
	SPECULAR = 0.6;
}
