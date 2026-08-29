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

// The pack's LabPBR companions, looked up by stem in goanna_client.cpp the
// way glass and the entity path already do. Leaves had none of this: it
// hardcoded a roughness and a specular and never read the pack at all, so
// every mat_ slider in the settings panel did nothing to it while the solid
// nodes beside it took the pack's gloss in full. In a forested world that
// is a large part of the frame taking one material response and the rest
// taking another.
uniform sampler2D normal_tex : hint_normal, filter_nearest_mipmap, repeat_enable;
uniform sampler2D spec_tex : filter_nearest_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_strength : hint_range(0.0, 1.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 1.0;
uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 4.0;
// How rained-on the world is, the same global the terrain reads.
global uniform float goanna_wetness;

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
	METALLIC = 0.0;
	// The pack's occlusion, but deliberately not its relief. Leaves are an
	// allfaces drawtype, so two stacked blocks draw a pair of coincident
	// interior faces at the same plane. That z-fight was always there and
	// was invisible while both faces shaded identically at a fixed
	// roughness; giving them per-face normals made the two sides shade
	// differently and the fight started to flicker. Measured nose-first in
	// a canopy, the relief took the share of temporally unstable pixels
	// from 0.8% to 1.7%.
	//
	// It was buying nothing anyway. The node mesher writes no ARRAY_TANGENT
	// (src/goanna_client.cpp), so a tangent space normal map here has no
	// basis to be expressed in and degenerates to the geometric normal.
	// Occlusion is a scalar and needs no tangents, so that part stays.
	float pack_ao = 1.0;
	if (has_normal)
		pack_ao = mix(1.0, texture(normal_tex, UV).b, ao_strength);
	AO = pack_ao;
	AO_LIGHT_AFFECT = 0.0;
	// Soil-like, for a tile with no _s: takes rain without turning to glass.
	float porosity = 0.35;
	if (has_spec) {
		vec4 sp = texture(spec_tex, UV);
		// LabPBR: R perceptual smoothness, G dielectric F0 or a metal index
		// at or above 229/255, A emission with 1.0 meaning none, B porosity
		// up to 64/255 and subsurface scattering above it. Godot's SPECULAR
		// defines F0 = 0.08 * SPECULAR, hence the divide.
		float sm = sp.r;
		ROUGHNESS = mix(0.9, clamp((1.0 - sm) * (1.0 - sm), 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
		if (sp.a < 0.999)
			EMISSION += ALBEDO * sp.a * emission_strength;
		if (sp.b <= 0.2549)
			porosity = sp.b / 0.2549;
	}
	// leaves are thin: let light through a little
	// Thin foliage lets light through. The pack's own scattering, where it
	// authors one, replaces the constant rather than adding to it.
	BACKLIGHT = vec3(0.25) * sss_strength;
	if (has_spec) {
		float sb = texture(spec_tex, UV).b;
		if (sb > 0.2549)
			BACKLIGHT = ALBEDO * ((sb - 0.2549) / 0.7451) * sss_strength;
	}
	// Rain. The terrain gates this on an up facing surface, which is right
	// for ground and roofs and wrong here: a leaf or a stalk is a thin
	// cross whose faces are mostly vertical, and it still comes out of a
	// shower wet. So sky light does the roof test on its own and the facing
	// only leans it, which is why anything under a canopy or an eave stays
	// dry. Matches nodes_array.gdshader otherwise, porosity and all.
	if (goanna_wetness > 0.001) {
		float wet = goanna_wetness * smoothstep(0.55, 0.9, v_skylight)
				* mix(0.6, 1.0, clamp(v_wnormal_y, 0.0, 1.0));
		ALBEDO *= 1.0 - wet * (0.10 + 0.18 * porosity);
		ROUGHNESS = mix(ROUGHNESS, 0.13, wet * (0.85 - 0.45 * porosity));
		SPECULAR = mix(SPECULAR, 0.5, wet * 0.6);
	}
	EMISSION += ALBEDO * mix(goanna_ground_fill, goanna_sky_fill,
			clamp(0.5 + 0.5 * v_wnormal_y, 0.0, 1.0)) * v_skylight * sky_fill_strength;
}
