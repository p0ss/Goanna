// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Shared PBR decoding and lighting for entity surface variants.
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
// Item meshes (a held tool, a dropped item) carry the item's colour in
// their vertices, Luanti's wield mesh baking it there: a dyed piece of
// leather, a tinted grass block. Mob meshes carry none.
uniform bool vertex_tint = false;
uniform float block_fill : hint_range(0.0, 2.0) = 0.6;
uniform float sky_light_strength : hint_range(0.0, 1.0) = 1.0;
// Goanna: what this surface is made of, from the classifier
// (src/goanna_materials.h, MaterialClass), and that class's material
// constants. A node tile gets these through a generated _s; an item, a tool,
// a piece of armour or a mob skin is not a node and gets nothing, so they
// arrive here directly. Used only where the pack ships no authored _s, which
// for Mineclonia's items is always.
uniform int mat_class = 0;
// A gem code, mode | kind << 2; see diamond.gdshaderinc.
uniform int diamond_mode = 0;
uniform vec2 diamond_texels = vec2(16.0);
uniform float class_smoothness : hint_range(0.0, 1.0) = 0.0;
uniform float class_f0 : hint_range(0.0, 1.0) = 0.04;
uniform float class_metal : hint_range(0.0, 1.0) = 0.0;
uniform float class_sss : hint_range(0.0, 1.0) = 0.0;

#define GOANNA_DIAMOND
#include "res://shaders/direct_light.gdshaderinc"
#ifdef GOANNA_DIAMOND_TRANSMISSION
#include "res://shaders/diamond_refraction.gdshaderinc"
#endif

void fragment() {
#ifdef GOANNA_DOUBLE_SIDED
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
		BINORMAL = -BINORMAL;
	}
#endif
	// Item and skinned entity meshes arrive without tangents. Reconstruct
	// the UV frame from the deformed surface so their normal maps and gem
	// planes work just as they do on terrain, including mirrored armour UVs.
	vec2 gem_dx = dFdx(UV), gem_dy = dFdy(UV);
	vec3 gem_position_dx = dFdx(VERTEX), gem_position_dy = dFdy(VERTEX);
	float gem_det = gem_dx.x * gem_dy.y - gem_dx.y * gem_dy.x;
	if (diamond_mode != 0 && abs(gem_det) > 1e-12) {
		vec3 along_u = (gem_position_dx * gem_dy.y - gem_position_dy * gem_dx.y) / gem_det;
		vec3 along_v = (gem_position_dy * gem_dx.x - gem_position_dx * gem_dy.x) / gem_det;
		vec3 tangent = along_u - NORMAL * dot(NORMAL, along_u);
		if (length(tangent) > 1e-6) {
			TANGENT = normalize(tangent);
			vec3 across = normalize(cross(NORMAL, TANGENT));
			// Match Godot's SurfaceTool and the node mesh: binormal is -V.
			BINORMAL = across * (dot(across, along_v) < 0.0 ? 1.0 : -1.0);
		}
	}
	v_lamp_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 tex = texture(albedo, UV);
	ALBEDO = tex.rgb;
	if (vertex_tint)
		ALBEDO *= COLOR.rgb;
#ifdef GOANNA_DIAMOND_TRANSMISSION
	// Holes in the art remain holes, while the surviving crystal can blend.
	// Alpha scissor would threshold the crystal's transmission away too.
	if (tex.a < 0.5)
		discard;
#else
#ifdef GOANNA_ALPHA_SCISSOR
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
#endif
#endif
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
	if (!has_spec && (class_smoothness > 0.0 || class_metal > 0.0)) {
		// The same decode as the authored path below, from the class's own
		// constants rather than from a texture. An iron pickaxe is not rough
		// plastic, and until this it was shaded as exactly that.
		ROUGHNESS = mix(1.0, clamp(1.0 - class_smoothness, 0.04, 1.0),
				roughness_strength);
		METALLIC = class_metal;
		SPECULAR = clamp((class_metal > 0.5 ? 0.5 : class_f0 / 0.08) * specular_strength, 0.0, 1.0);
		if (class_sss > 0.0)
			BACKLIGHT = ALBEDO * class_sss * sss_strength;
	}
	// Cloth catches the light along a grazing edge, which no channel LabPBR
	// carries can say and which is most of what separates wool from painted
	// stone. Godot's own rim term, so it stays inside the lighting the rest
	// of the world is lit by, carried to light() as RIM and RIM_TINT would be
	// (see direct_light.gdshaderinc).
	v_rim = mat_class == 11 ? vec2(0.6, 0.35) : vec2(0.0);
	if (has_spec) {
		vec4 sp = texture(spec_tex, UV);
		float sm = sp.r;
		ROUGHNESS = mix(1.0, clamp(1.0 - sm, 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
		if (sp.a < 0.999)
			EMISSION += ALBEDO * sp.a * emission_strength;
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			BACKLIGHT = ALBEDO * sss * sss_strength;
		}
	}
	float gem = goanna_diamond_mask(tex.rgb, diamond_mode);
	// Without an authored map, the class applies to the whole item. Keep
	// wood handles and dark armour joins rough rather than glazing them.
	if (diamond_mode != 0 && !has_spec) {
		ROUGHNESS = mix(ROUGHNESS, 0.78, (1.0 - gem) * diamond_strength);
		SPECULAR = mix(SPECULAR, 0.5 * specular_strength, (1.0 - gem) * diamond_strength);
	}
	vec3 gem_normal = has_normal ? NORMAL_MAP : vec3(0.5, 0.5, 1.0);
	vec2 gem_size = min(vec2(textureSize(albedo, 0)), diamond_texels);
	float gem_px = max(length(gem_dx * gem_size), length(gem_dy * gem_size));
	if (gem > 0.001 && gem_px < 1.25) {
		// Cut a narrow planar bevel where the source art changes colour.
		// Native armour and loose gems lack the ore pack's carved relief;
		// these square edges give their polished planes the same light catch.
		vec2 cell = fract(UV * gem_size) - 0.5;
		vec2 centre = (floor(UV * gem_size) + 0.5) / gem_size;
		vec4 face = textureGrad(albedo, centre, gem_dx, gem_dy);
		vec2 slope = vec2(0.0);
		for (int axis = 0; axis < 2; axis++) {
			vec2 direction = axis == 0 ? vec2(sign(cell.x), 0.0) : vec2(0.0, sign(cell.y));
			vec4 neighbour = textureGrad(albedo, centre + direction / gem_size, gem_dx, gem_dy);
			float seam = smoothstep(0.025, 0.12, length(face.rgb - neighbour.rgb) + abs(face.a - neighbour.a));
			float coordinate = axis == 0 ? abs(cell.x) : abs(cell.y);
			float width = max(0.025, min(gem_px, 0.18));
			float bevel = smoothstep(0.38 - width, 0.46 + width, coordinate);
			slope += direction * seam * bevel;
		}
		// Tangent Y points along -V, matching the normal-map convention.
		slope.y = -slope.y;
		float cut = gem * diamond_strength * normal_strength
				* (1.0 - smoothstep(0.35, 1.25, gem_px));
		gem_normal = normalize(gem_normal * 2.0 - 1.0 + vec3(slope * 0.45 * cut, 0.0)) * 0.5 + 0.5;
	}
	v_gem_optics = goanna_gem_optics(diamond_mode);
	v_diamond = goanna_diamond_surface(diamond_mode, tex.rgb, gem, gem_px, gem_normal, ROUGHNESS, METALLIC, SPECULAR);
	NORMAL_MAP = gem_normal;
	NORMAL_MAP_DEPTH = 1.0;
	v_diamond_axis = TANGENT;
	v_diamond_interior = 0.0;
	v_diamond_inner_normal = NORMAL;
	v_diamond_scatter = vec3(0.0);
	if (gem > 0.001 && diamond_interior_strength > 0.001) {
		vec2 texel = 1.0 / gem_size;
		float surround = 0.0;
		for (int edge = 0; edge < 4; edge++) {
			vec2 offset = edge < 2 ? vec2(edge == 0 ? -1.0 : 1.0, 0.0)
					: vec2(0.0, edge == 2 ? -1.0 : 1.0);
			vec4 neighbour = textureGrad(albedo, UV + offset * texel, gem_dx, gem_dy);
			surround += goanna_diamond_mask(neighbour.rgb, diamond_mode) * neighbour.a * 0.25;
		}
		float thickness = goanna_gem_mode(diamond_mode) == 2 ? 3.0 : mix(0.4, 2.5, surround);
		vec3 eye = vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), max(dot(VIEW, NORMAL), 0.05));
		vec2 travel = goanna_diamond_travel(eye, thickness, diamond_mode);
		vec4 middle = textureGrad(albedo, UV + travel * texel * 0.45, gem_dx, gem_dy);
		vec4 rear = textureGrad(albedo, UV + travel * texel, gem_dx, gem_dy);
		middle.rgb = mix(tex.rgb, middle.rgb, goanna_diamond_mask(middle.rgb, diamond_mode) * middle.a);
		rear.rgb = mix(tex.rgb, rear.rgb, goanna_diamond_mask(rear.rgb, diamond_mode) * rear.a);
		vec3 tint = vertex_tint ? COLOR.rgb : vec3(1.0);
		vec3 original = ALBEDO;
		vec3 scatter;
		vec3 inner = goanna_diamond_interior(diamond_mode, tex.rgb * tint, middle.rgb * tint,
				rear.rgb * tint, thickness, gem, gem_px, travel, ALBEDO, scatter);
		// The existing node-light fill and any authored emission must follow
		// the new body colour, not leave an opaque painted layer on top.
		EMISSION *= ALBEDO / max(original, vec3(0.001));
		v_diamond_scatter = scatter;
		v_diamond_inner_normal = normalize(TANGENT * inner.x + BINORMAL * inner.y + NORMAL * inner.z);
		v_diamond_interior = v_diamond * diamond_interior_strength * 0.45;
	}

	// No sun or moon where Luanti has no sunlight at the entity, and F0 for
	// light(); see direct_light.gdshaderinc. An entity without node_light
	// keeps the default (0, 1), full sky, as before.
	v_sun_gate = goanna_sun_gate(node_light.y, node_light.x);
	v_specular = SPECULAR;
#ifdef GOANNA_DIAMOND_TRANSMISSION
	// Only dedicated item/armour shaders enter the transparent pipeline.
	// Keep handles and joins solid, with clearer faces and reflective rims.
	vec3 crystal_normal = normalize(TANGENT * (gem_normal.x * 2.0 - 1.0)
			+ BINORMAL * (gem_normal.y * 2.0 - 1.0)
			+ NORMAL * (gem_normal.z * 2.0 - 1.0));
	float rim = pow(1.0 - clamp(dot(crystal_normal, VIEW), 0.0, 1.0), 5.0);
	float opacity = mix(goanna_gem_mode(diamond_mode) == 2 ? 0.32 : 0.24, 0.9, rim);
	ALPHA = mix(1.0, opacity, gem * diamond_strength * diamond_transparency
			* GEM_CLARITY[goanna_gem_kind(diamond_mode)]);
	if (gem > 0.001 && diamond_refraction > 0.001 && ALPHA < 0.999) {
		// Derivatives recover the source texel's world size on both item
		// tiles and armour atlases, including the wield model's scaling.
		float texel_size = max(length(gem_position_dx), length(gem_position_dy))
				/ max(gem_px, 0.0001);
		float depth = clamp(texel_size * (goanna_gem_mode(diamond_mode) == 2 ? 6.0 : 3.5), 0.005, 0.5);
		vec2 refracted_uv = goanna_diamond_screen_ray(VERTEX, VIEW, crystal_normal,
				depth, SCREEN_UV, 1.0 / VIEWPORT_SIZE, PROJECTION_MATRIX, INV_PROJECTION_MATRIX,
				GEM_ETA[goanna_gem_kind(diamond_mode)]);
		vec3 behind = textureLod(diamond_scene, refracted_uv, 0.0).rgb;
		// Compose prelit transmission once, retaining the surface highlights.
		// At zero strength this is exactly the previous alpha-blended path.
		float composed_alpha = mix(ALPHA, 1.0, diamond_refraction);
		float surface = ALPHA / composed_alpha;
		ALBEDO *= surface;
		EMISSION = EMISSION * surface + behind * (1.0 - surface);
		BACKLIGHT *= surface;
		v_diamond_scatter *= surface;
		ALPHA = composed_alpha;
	}
#endif
}
