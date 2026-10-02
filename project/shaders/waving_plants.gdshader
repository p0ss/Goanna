// Goanna: Luanti TILE_MATERIAL_WAVING_PLANTS. Sway grows with height above the node base.
shader_type spatial;
#include "feature_flags.gdshaderinc"
#include "res://shaders/underwater.gdshaderinc"
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

// The pack's LabPBR companions, looked up by stem in goanna_client.cpp the
// way glass and the entity path already do. Plants had none of this: it
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
// Off for a game whose non-waving allfaces leaves land here: two stacked
// blocks draw coincident interior faces, and per face normals make that
// z-fight flicker (measured 0.8% to 1.7% unstable pixels in a canopy).
uniform bool relief = true;
uniform float relief_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_strength : hint_range(0.0, 1.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 1.0;
uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 4.0;
// How rained-on the world is, the same global the terrain reads.
global uniform float goanna_wetness;

varying float v_skylight;
varying float v_blocklight;
varying float v_wnormal_y;

#include "res://shaders/direct_light.gdshaderinc"

void vertex() {
	// CUSTOM0.g is Luanti's sky light at the vertex (docs/mesh-attributes.md).
	v_skylight = CUSTOM0.g;
	v_blocklight = CUSTOM0.r;
	v_wnormal_y = (MODEL_MATRIX * vec4(NORMAL, 0.0)).y;
	if (waving && goanna_render_foliage_wind > 0.5) {
		// UV.y = 0 at the top of the tile, 1 at the base
		float k = 1.0 - clamp(UV.y, 0.0, 1.0);
		float ph = TIME * speed + VERTEX.x * 0.5 + VERTEX.z * 0.4;
		VERTEX.x += sin(ph) * sway * k;
		VERTEX.z += cos(ph * 0.9 + 0.5) * sway * 0.6 * k;
	}
}

void fragment() {
	v_lamp_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 tex = texture(albedo_tex, UV) * COLOR;
	// The pack's authored relief. The mesher writes no tangents, so the UV
	// frame is rebuilt from screen derivatives, as entity_common.gdshaderinc
	// does for item and mob meshes, and it follows a back face's mirrored
	// image by itself. Plants went without this until 2026-10-02 on account
	// of a z-fight between coincident allfaces leaves, but leaves that wave
	// take waving_leaves.gdshader, and a crossed quad has no coincident
	// twin, so the plants paid for a fault that was not theirs: a mushroom
	// on a log drew as flat paper among extruded bark.
	vec4 nrm = has_normal ? texture(normal_tex, UV) : vec4(0.5, 0.5, 1.0, 1.0);
	if (has_normal && relief) {
		vec2 duv_x = dFdx(UV), duv_y = dFdy(UV);
		vec3 dp_x = dFdx(VERTEX), dp_y = dFdy(VERTEX);
		float det = duv_x.x * duv_y.y - duv_x.y * duv_y.x;
		if (abs(det) > 1e-12) {
			vec3 along_u = (dp_x * duv_y.y - dp_y * duv_x.y) / det;
			vec3 along_v = (dp_y * duv_x.x - dp_x * duv_y.x) / det;
			vec3 t = along_u - NORMAL * dot(NORMAL, along_u);
			if (length(t) > 1e-6) {
				t = normalize(t);
				vec3 across = normalize(cross(NORMAL, t));
				// Binormal is -V, the node mesh's convention; no green flip.
				vec3 b = across * (dot(across, along_v) < 0.0 ? 1.0 : -1.0);
				vec2 xy = (nrm.rg * 2.0 - 1.0) * normal_strength * relief_strength;
				float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
				NORMAL = normalize(t * xy.x + b * xy.y + NORMAL * z);
			}
		}
	}
	// Lean the shading normal toward up. A plant is two crossed vertical
	// quads, so at noon the sun barely lit them and, drawn double sided,
	// half the faces pointed away from it; what light they got was mostly
	// the blue sky fill, and palette tinted sugar cane read as blue grey
	// beside green grass (test_world, 2026-09-29). Luanti lights plantlike
	// nodes without regard to facing. At 0.45 the cane reads its palette
	// green and grass tufts lighten only a little; 0.7 washed them out.
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz, 0.45));
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
	METALLIC = 0.0;
	// The pack's occlusion. Godot's AO only reaches ambient light, so it
	// darkens the hollows without fighting the relief above.
	float pack_ao = 1.0;
	if (has_normal)
		pack_ao = mix(1.0, nrm.b, ao_strength);
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
		ROUGHNESS = mix(0.85, clamp(1.0 - sm, 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
		if (sp.a < 0.999)
			EMISSION += ALBEDO * sp.a * emission_strength;
		if (sp.b <= 0.2549)
			porosity = sp.b / 0.2549;
	}
	// Thin foliage lets light through. The pack's own scattering, where it
	// authors one, replaces the constant rather than adding to it.
	BACKLIGHT = vec3(0.3) * sss_strength;
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
	if (goanna_render_wet_surfaces > 0.5 && goanna_wetness > 0.001) {
		float wet = goanna_wetness * smoothstep(0.55, 0.9, v_skylight)
				* mix(0.6, 1.0, clamp(v_wnormal_y, 0.0, 1.0));
		ALBEDO *= 1.0 - wet * (0.10 + 0.18 * porosity);
		ROUGHNESS = mix(ROUGHNESS, 0.13, wet * (0.85 - 0.45 * porosity));
		SPECULAR = mix(SPECULAR, 0.5, wet * 0.6);
	}
	EMISSION += ALBEDO * mix(goanna_ground_fill, goanna_sky_fill,
			clamp(0.5 + 0.5 * v_wnormal_y, 0.0, 1.0)) * v_skylight * sky_fill_strength;
	// No sun or moon where Luanti has no sunlight, and F0 for light(); see
	// direct_light.gdshaderinc.
	v_sun_gate = goanna_sun_gate(v_skylight, v_blocklight);
	v_specular = SPECULAR;
	v_rim = vec2(0.0);
	// The water between the eye and this surface, per colour (underwater.gdshaderinc).
	vec3 goanna_uw = goanna_underwater_keep(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD);
	ALBEDO *= goanna_uw;
	EMISSION *= goanna_uw;
}
