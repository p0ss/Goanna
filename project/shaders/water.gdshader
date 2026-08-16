// Goanna: liquids (Luanti TILE_MATERIAL_LIQUID_TRANSPARENT / WAVING_LIQUID_*).
// Vertex waves like Luanti's waving liquids; depth-dependent absorption from
// the opaque depth buffer (shallow water is clear, deep water darkens toward
// the water colour); fresnel so grazing views reflect the sky/sun/moon
// instead of reading as tinted ground.
shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float wave_height = 0.045;
uniform float wave_speed = 1.6;
uniform float wave_length = 4.0;
uniform float refraction = 0.015;
// Beer-Lambert absorption per metre; red dies first, like real water.
uniform vec3 absorption = vec3(0.55, 0.24, 0.16);
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

	// animated normal perturbation for glints
	float ph = (world_pos.x + world_pos.z * 0.7) * (6.2831853 / wave_length) + TIME * wave_speed;
	vec3 n = normalize(vec3(cos(ph) * 0.07, 1.0, cos(ph * 1.7 + 1.3) * 0.05));
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(n, 0.0)).xyz, waving ? 0.35 : 0.0));

	if (!FRONT_FACING)
		NORMAL = -NORMAL;

	// water thickness along the view ray, from the opaque depth buffer
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	scene.xyz /= scene.w;
	float thick = clamp(length(scene.xyz) - length(VERTEX), 0.0, 64.0);
	vec3 trans = exp(-absorption * thick);

	// what is behind, refracted, absorbed by the water column
	vec2 ofs = NORMAL.xy * refraction * clamp(thick, 0.0, 4.0) * 0.5;
	vec3 behind = texture(screen_tex, SCREEN_UV + ofs).rgb;
	vec3 deep_col = tex.rgb * 0.5; // the colour deep water converges to
	vec3 body = mix(deep_col, behind, trans);
	// a floor of the water's own colour so even shallow water reads as water
	body = mix(body, tex.rgb * 0.85, 0.22);

	// fresnel: face-on you see the water body, grazing you see reflection
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = body;
	ALPHA = clamp(0.9 + 0.1 * fres, 0.0, 1.0);
	METALLIC = 0.15;
	SPECULAR = 0.4 + 0.6 * fres;
	ROUGHNESS = 0.025;
}
