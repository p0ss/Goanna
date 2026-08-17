// Goanna: opaque node tiles drawn from an array texture.
//
// Luanti's mesher groups same-sized tile images into array textures and writes
// each vertex's layer index into S3DVertex::Aux; Goanna carries that across as
// UV2.x. A whole bunch of different node tiles can then share one material,
// which is what takes a block from ~19 draw calls down to a handful.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray albedo_array : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool scissor = true;
// LabPBR companions, when a resource pack ships them (see docs): _n carries
// the tangent normal in RG with ambient occlusion in B, _s carries perceptual
// smoothness in R, F0/metalness in G and emission in A.
uniform sampler2DArray normal_array : hint_default_black, filter_nearest_mipmap, repeat_enable;
uniform sampler2DArray spec_array : hint_default_black, filter_nearest_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
uniform float normal_strength = 1.0;
uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 tex = texture(albedo_array, vec3(UV, UV2.x)) * COLOR;
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	if (scissor)
		ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;

	if (has_normal) {
		vec4 n = texture(normal_array, vec3(UV, UV2.x));
		vec2 xy = (n.rg * 2.0 - 1.0) * normal_strength;
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, z * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
		AO = n.b;
		AO_LIGHT_AFFECT = 0.4;
	}
	if (has_spec) {
		vec4 sp = texture(spec_array, vec3(UV, UV2.x));
		// LabPBR: R is perceptual smoothness, roughness = (1 - smoothness)^2
		float sm = sp.r;
		ROUGHNESS = clamp((1.0 - sm) * (1.0 - sm), 0.04, 1.0);
		// G below 229/255 is dielectric F0, at or above it is a metal index
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = sp.g >= 0.898 ? 0.5 : clamp(sp.g * 2.0, 0.0, 1.0);
		// A is emission strength, with 1.0 meaning none
		if (sp.a < 0.999)
			EMISSION = ALBEDO * sp.a * 4.0;
		// B is two channels in one: up to 64/255 it is porosity, above that
		// it is subsurface scattering. Porosity only reads as anything once
		// a surface is wet, so it waits for weather; scattering is what
		// makes a leaf glow with the sun behind it.
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			SSS_STRENGTH = sss * sss_strength;
			SSS_TRANSMITTANCE_COLOR = vec4(ALBEDO, 1.0);
			SSS_TRANSMITTANCE_DEPTH = mix(0.1, 0.8, sss);
			SSS_TRANSMITTANCE_BOOST = 0.4;
		}
	}
}
