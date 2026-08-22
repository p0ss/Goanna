// Goanna: opaque entity (mob/model) meshes, one flat texture per surface.
//
// The single-texture counterpart to nodes_array.gdshader: an entity has one
// texture per mesh surface, not many tiles sharing an array, so this reads
// sampler2D at UV directly rather than sampler2DArray at (UV, layer). Entity
// meshes also carry no per-vertex colour (see EntityRenderer::buildMeshVisual
// and goanna_models.cpp, which never write ARRAY_COLOR), unlike node meshes'
// per-vertex light, so there is no COLOR multiply here either.
//
// Opaque only, deliberately: EntityRenderer::materialForTexture only builds
// this material when the entity needs neither alpha blend nor alpha scissor,
// so this shader never touches ALPHA or ALPHA_SCISSOR_THRESHOLD at all. See
// nodes_array.gdshader's header for why that pairing is the one to avoid
// (godotengine/godot#60388) rather than a runtime toggle: an entity needing
// alpha scissor still gets today's plain StandardMaterial3D, not this.
// The LabPBR decode below is duplicated from nodes_array.gdshader rather
// than shared; see nodes_array_common.gdshaderinc for why.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo : source_color, filter_nearest_mipmap, repeat_enable;
// LabPBR companions, when a resource pack ships them (see docs): _n carries
// the tangent normal in RG with ambient occlusion in B, _s carries perceptual
// smoothness in R, F0/metalness in G and emission in A.
uniform sampler2D normal_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D spec_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
// Per channel strengths, matching nodes_array_common.gdshaderinc; see its
// comment for why a pack's channels routinely need scaling down.
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_strength : hint_range(0.0, 1.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 1.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 4.0;
uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;
// Luanti's light at the entity's position, as the vanilla client lights its
// entities: x is block light (torches), y is sky light, both 0 to 1, set per
// instance by EntityRenderer::sync. The sky fill is the same one the node
// shaders add from their vertex sky light (nodes_array_common.gdshaderinc),
// the block light is a warm fill, and the sky light also scales ambient, so
// a mob in a dungeon is dark and one in a torch lit cave is lit, instead of
// every mob out of the sun being black. Without this a mesh entity had no
// share of the node light at all, where the nodes around it do.
global uniform vec3 goanna_sky_fill;
instance uniform vec2 node_light = vec2(0.0, 1.0);
uniform float block_fill : hint_range(0.0, 2.0) = 0.6;
uniform float sky_light_strength : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	ALBEDO = texture(albedo, UV).rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	AO = mix(1.0, node_light.y, sky_light_strength);
	EMISSION = ALBEDO * (goanna_sky_fill * node_light.y + vec3(1.0, 0.85, 0.6) * node_light.x * block_fill);

	if (has_normal) {
		vec4 n = texture(normal_tex, UV);
		// No green flip; see nodes_array.gdshader for why.
		vec2 xy = (n.rg * 2.0 - 1.0) * normal_strength;
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, z * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
		AO *= mix(1.0, n.b, ao_strength);
		AO_LIGHT_AFFECT = 0.4 * ao_strength;
	}
	if (has_spec) {
		vec4 sp = texture(spec_tex, UV);
		float sm = sp.r;
		ROUGHNESS = mix(1.0, clamp((1.0 - sm) * (1.0 - sm), 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
		if (sp.a < 0.999)
			EMISSION += ALBEDO * sp.a * emission_strength;
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			BACKLIGHT = ALBEDO * sss * sss_strength;
		}
	}
}
