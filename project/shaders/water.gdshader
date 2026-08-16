// Goanna: liquids (Luanti TILE_MATERIAL_LIQUID_TRANSPARENT / WAVING_LIQUID_*).
//
// Waves are normal-only. Displacing the surface vertically tore it away from
// the land it meets and from the water below a waterfall, because neighbouring
// blocks are separate meshes whose shared edges cannot be kept in step; the
// ripple is carried entirely in the shading normal instead.
//
// Depth-dependent absorption from the opaque depth buffer (shallow water is
// clear, deep water converges to the water colour), and refraction that is
// validated against depth so it can only ever sample geometry that is really
// behind the surface: an unvalidated offset both doubles the image and drags
// haloes onto blocks that are not behind the water at all.
shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform float wave_speed = 1.1;
uniform float wave_length = 3.0;
uniform float wave_strength = 0.5;
uniform float refraction = 0.006;
// Beer-Lambert absorption per node; red dies first, like real water.
uniform vec3 absorption = vec3(0.55, 0.24, 0.16);
uniform bool waving = true;

varying vec3 world_pos;

// View-space distance of whatever opaque geometry is at this screen uv.
// inv_proj is passed in: shader built-ins are only in scope in fragment().
float scene_distance(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -(v.z / v.w);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	float here = -VERTEX.z;

	// Ripple as a normal perturbation only: two crossing wave trains in world
	// space, so neighbouring blocks agree along their shared edges.
	if (waving) {
		float k = 6.2831853 / wave_length;
		float a = world_pos.x * k + TIME * wave_speed;
		float b = (world_pos.z * 0.86 + world_pos.x * 0.5) * k * 1.3 - TIME * wave_speed * 0.8;
		vec3 n = normalize(vec3(cos(a) * 0.12 + cos(b) * 0.07, 1.0,
				cos(b) * 0.12 + cos(a * 1.3) * 0.05));
		NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(n, 0.0)).xyz, wave_strength));
	}
	if (!FRONT_FACING)
		NORMAL = -NORMAL;

	// Thickness of water along the view ray, from the opaque depth buffer.
	float behind = scene_distance(SCREEN_UV, INV_PROJECTION_MATRIX);
	float thick = clamp(behind - here, 0.0, 64.0);

	// Refraction, validated: if the offset sample is not actually behind the
	// water surface it would be a halo pulled off unrelated geometry, so fall
	// back to the straight sample.
	vec2 ofs = NORMAL.xy * refraction * clamp(thick, 0.0, 3.0);
	vec2 ruv = clamp(SCREEN_UV + ofs, vec2(0.001), vec2(0.999));
	if (scene_distance(ruv, INV_PROJECTION_MATRIX) < here)
		ruv = SCREEN_UV;
	vec3 seen = texture(screen_tex, ruv).rgb;

	vec3 trans = exp(-absorption * thick);
	vec3 deep_col = tex.rgb * 0.5;
	vec3 body = mix(deep_col, seen, trans);
	body = mix(body, tex.rgb * 0.85, 0.22);

	// Face on you see into the water, grazing you see the sky reflected.
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = body;
	ALPHA = clamp(0.9 + 0.1 * fres, 0.0, 1.0);
	METALLIC = 0.15;
	SPECULAR = 0.4 + 0.6 * fres;
	ROUGHNESS = 0.03;
}
