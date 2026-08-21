// Goanna: alpha tested node tiles drawn from an array texture.
//
// Same as nodes_array.gdshader, for the tiles Luanti flags as needing alpha
// testing rather than opaque draws (cutout foliage and the like). Kept as a
// separate shader, not a runtime toggle on the opaque one, because Godot
// decides whether a material needs the alpha scissor pipeline by scanning the
// shader source for a write to ALPHA_SCISSOR_THRESHOLD, not by whether a
// uniform enables it at draw time: godotengine/godot#60388. The LabPBR decode
// below is duplicated from nodes_array.gdshader rather than shared; see
// nodes_array_common.gdshaderinc for why.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray albedo_array : source_color, filter_nearest_mipmap, repeat_enable;
#include "res://shaders/nodes_array_common.gdshaderinc"

void vertex() {
	// CUSTOM0 arrives as four bytes scaled to 0 to 1: block light, sky light,
	// occlusion. See docs/mesh-attributes.md.
	v_nodelight = CUSTOM0.rgb;
	v_stale = 1.0 - CUSTOM0.a;
}

void fragment() {
	vec4 tex = texture(albedo_array, vec3(UV, UV2.x)) * COLOR;
	ALBEDO = tex.rgb;
	if (v_stale > 0.001)
		ALBEDO = mix(ALBEDO, vec3(dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722))), v_stale * stale_strength);
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	float pack_ao = 1.0;

	if (has_normal) {
		vec4 n = texture(normal_array, vec3(UV, UV2.x));
		vec2 xy = (n.rg * 2.0 - 1.0) * normal_strength;
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, z * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
		// Toward fully lit as the strength falls, so 0 removes the pack's
		// occlusion rather than removing Godot's own shading with it. The
		// pack's occlusion is texture scale detail; the vertex one below is
		// the shape of the room, and they multiply.
		pack_ao = mix(1.0, n.b, ao_strength);
	}
	if (has_spec) {
		vec4 sp = texture(spec_array, vec3(UV, UV2.x));
		float sm = sp.r;
		// Toward 1.0, the unlit-looking fully rough default, so 0 gives back
		// exactly what a node with no companion gets.
		ROUGHNESS = mix(1.0, clamp((1.0 - sm) * (1.0 - sm), 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
		if (sp.a < 0.999)
			EMISSION = ALBEDO * sp.a * emission_strength;
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			BACKLIGHT = ALBEDO * sss * sss_strength;
		}
	}

	// Node light and occlusion. Occlusion multiplies ambient and, by default,
	// leaves direct light alone: a corner is dark because less sky reaches it,
	// not because the sun stopped shining on it. Sky visibility attenuates the
	// same ambient, which is what darkens interiors and caves.
	float sky_vis = mix(1.0, v_nodelight.g, sky_light_strength);
	float occ = mix(1.0, v_nodelight.b, vertex_ao_strength);
	AO = clamp(pack_ao * occ * sky_vis, 0.0, 1.0);
	AO_LIGHT_AFFECT = vertex_ao_light_strength;
	// The fill is emission so that it is neither shadowed nor occluded: it is
	// the light the sky light channel says reaches here, see the include.
	EMISSION += ALBEDO * goanna_sky_fill * v_nodelight.g * sky_fill_strength;
	if (block_light_emission > 0.0)
		EMISSION += ALBEDO * v_nodelight.r * block_light_emission;
	if (debug_nodelight_strength > 0.0) {
		ALBEDO = vec3(0.0);
		EMISSION = v_nodelight * debug_nodelight_strength;
	}
}
