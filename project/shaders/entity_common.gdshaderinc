// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Shared PBR decoding and lighting for entity surface variants.
uniform sampler2D albedo : source_color, filter_nearest_mipmap, repeat_enable;
// LabPBR companions, when a resource pack ships them (see docs): _n carries
// the tangent normal in RG with ambient occlusion in B, _s carries perceptual
// smoothness in R, F0/metalness in G and emission in A.
// _n is sampled nearest too, like the albedo. A skin with no _n gets the
// relief inferred from its own 64 pixel art, and a linear filter spread each
// texel's tilt across its neighbours: the shading ran in soft bands across
// the texel grid, the lantern's highlight smeared over a villager's brow,
// and the mob looked out of focus beside the same mob with maps. An
// authored map at eight texels per art texel loses nothing by it.
uniform sampler2D normal_tex : hint_default_black, filter_nearest_mipmap, repeat_enable;
// _s is sampled nearest: its channels are categorical (LabPBR metals are G
// 230 and up), and on a skin a metal plate beside cloth interpolated through
// values that decode as a dielectric with SPECULAR at its maximum, a shiny
// rim half a companion texel wide round every plate.
uniform sampler2D spec_tex : hint_default_black, filter_nearest_mipmap, repeat_enable;
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
// Parallax occlusion with self shadow through the authored _n's height, the
// node path's march (nodes_array.gdshader) on a skin. A is the height, 255
// the crest. has_height only for an authored _n: the inferred relief has no
// height. relief_depth is the map's own depth in nodes, measured as a node
// layer's is (reliefDepth in goanna_textures.cpp, capped alike) with a node
// counted as sixteen art texels; 0 takes the class table's. art_texels is
// the art's size in texels, which turns that into a distance on the mesh.
// parallax_strength is the "parallax" material strength (0 on the Low
// profile) times GOANNA_ENTITY_PARALLAX; see EntityRenderer::setParallax.
uniform bool has_height = false;
uniform float relief_depth = 0.0;
// 1 minus the highest height stored over the skin's drawn texels, added to
// every height read, so the highest texel sits on the face. Skins authored
// before parallax keep their main surfaces at 0.4 to 0.7; marched as
// stored they drew sunk into the box, and the march ran off every face
// edge onto the clamped edge texel, smeared. A node tile's crest is its
// byte's top, so the node path has no such lift.
uniform float height_lift : hint_range(0.0, 1.0) = 0.0;
// The same per face, at the art's resolution, where the model gave its
// faces: one part standing far above the rest (the player's hair, a few
// golem rivets) otherwise left every other face sunk.
uniform sampler2D lift_tex : hint_default_black, filter_nearest, repeat_enable;
uniform bool has_lift_tex = false;
uniform vec2 art_texels = vec2(64.0, 32.0);
uniform float parallax_strength : hint_range(0.0, 1.0) = 1.0;
uniform float parallax_depth : hint_range(0.0, 4.0) = 1.0;
uniform float parallax_range : hint_range(0.0, 256.0) = 40.0;
uniform float parallax_shadow_strength : hint_range(0.0, 1.0) = 0.85;
// Halvings of the last march step before the chord (see the march); 0 is
// the node path's chord alone. GOANNA_ENTITY_PARALLAX_REFINE sets it.
uniform int parallax_refine : hint_range(0, 8) = 5;
global uniform vec3 goanna_sun_dir;
// The UV rectangle of the face this fragment is on, (min, max), from CUSTOM0
// (faceRects in goanna_models.cpp). A skin is an atlas: the march clamps to
// this so it never slides into the island beside the face. A mesh without
// it reads zeros, an empty rectangle, and gets no parallax.
varying vec4 v_face_rect;

#include "res://shaders/relief_depth.gdshaderinc"

// Hair's along the strand highlight (direct_light.gdshaderinc), on texels
// whose _s green byte is 12 (atlas.HAIR_F0_BYTE in tools/pbr_author): F0
// 0.047, which no other map writes, so the byte marks hair. 0 draws them
// with the isotropic lobe, the default until it is judged on the GPU. Set
// by EntityRenderer::setHair from the "hair" material strength times
// GOANNA_HAIR_ANISO.
uniform float hair_strength : hint_range(0.0, 1.0) = 0.0;
// Hair drawn by the shader on the same texels (hair_strands.gdshaderinc):
// strands, tips, lock shadows, a wrapped diffuse and the highlight above,
// at full weight whatever hair_strength is. 0 leaves hair as the maps and
// hair_strength draw it. Set by EntityRenderer::setHairShader from the
// "hair_shader" material strength times GOANNA_HAIR_SHADER.
uniform float hair_shader_strength : hint_range(0.0, 1.0) = 0.0;

#define GOANNA_DIAMOND
#define GOANNA_HAIR
#include "res://shaders/direct_light.gdshaderinc"
#include "res://shaders/hair_strands.gdshaderinc"
#include "res://shaders/underwater.gdshaderinc"
#ifdef GOANNA_DIAMOND_TRANSMISSION
#include "res://shaders/diamond_refraction.gdshaderinc"
#endif

void vertex() {
	v_face_rect = CUSTOM0;
}

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
	// Every surface with a normal map needs it, not only gems: Godot's
	// fallback frame comes from the vertex normal alone, so on a mob skin
	// it turned or mirrored the relief on every face and flattened it on
	// the faces along Z (project/entity_normal_probe.tscn shows both).
	vec2 gem_dx = dFdx(UV), gem_dy = dFdy(UV);
	vec3 gem_position_dx = dFdx(VERTEX), gem_position_dy = dFdy(VERTEX);
	float gem_det = gem_dx.x * gem_dy.y - gem_dx.y * gem_dy.x;
	// The image's down on this face, for hair's strand direction below.
	vec3 image_down = vec3(0.0);
	if ((diamond_mode != 0 || has_normal) && abs(gem_det) > 1e-12) {
		vec3 along_u = (gem_position_dx * gem_dy.y - gem_position_dy * gem_dx.y) / gem_det;
		vec3 along_v = (gem_position_dy * gem_dx.x - gem_position_dx * gem_dy.x) / gem_det;
		image_down = along_v;
		vec3 tangent = along_u - NORMAL * dot(NORMAL, along_u);
		if (length(tangent) > 1e-6) {
			TANGENT = normalize(tangent);
			vec3 across = normalize(cross(NORMAL, TANGENT));
			// Match Godot's SurfaceTool and the node mesh: binormal is -V.
			BINORMAL = across * (dot(across, along_v) < 0.0 ? 1.0 : -1.0);
		}
	}
	v_lamp_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Parallax occlusion, as nodes_array.gdshader marches it: the same
	// steps, the same chord refinement, the same self shadow, the same fade.
	// The basis is the view space extent of one unit of UV, solved from the
	// same derivatives as the frame above, so a mirrored face (a limb that
	// shares its twin's UVs reversed) marches the mirrored way by itself.
	// What blocks never needed: a skin is an atlas, and the island beside a
	// face in the image is not its neighbour on the model. Every sample is
	// clamped to the face's own UV rectangle (v_face_rect), so a march that
	// runs off the face stops at its edge texel, as a ray would meet the
	// box's side; and a hit that lands on a transparent texel inside the
	// rectangle is pulled back toward the drawn point until it is opaque.
	vec2 puv = UV;
	float self_shadow = 1.0;
	float pom = 0.0;
	vec4 rect = v_face_rect;
	if (has_normal && has_height && diamond_mode == 0 && parallax_strength > 0.001
			&& rect.z > rect.x && rect.w > rect.y && abs(gem_det) > 1e-12) {
		pom = (1.0 - smoothstep(parallax_range * 0.5, parallax_range, length(VERTEX)))
				* parallax_strength;
	}
	if (pom > 0.001) {
		vec3 d_tu = (gem_position_dx * gem_dy.y - gem_position_dy * gem_dx.y) / gem_det;
		vec3 d_tv = (gem_position_dy * gem_dx.x - gem_position_dx * gem_dy.x) / gem_det;
		float lu = max(dot(d_tu, d_tu), 1e-12);
		float lv = max(dot(d_tv, d_tv), 1e-12);
		float vn = max(dot(VIEW, NORMAL), 0.08);
		vec3 vt = VIEW - NORMAL * dot(VIEW, NORMAL);
		// The depth in nodes, then in view space units through the size an
		// art texel is drawn at here, a node being sixteen of them.
		float depth_nodes = (relief_depth > 0.0 ? relief_depth : goanna_class_depth(mat_class))
				* parallax_depth * pom;
		float texel = 0.5 * (sqrt(lu) / art_texels.x + sqrt(lv) / art_texels.y);
		float depth = depth_nodes * 16.0 * texel;
		vec2 slope = vec2(dot(vt, d_tu) / lu, dot(vt, d_tv) / lv) * (depth / vn);
		// Half a hundredth of an art texel inside the face, so a clamped
		// sample never rounds onto the neighbouring island's texel.
		vec2 inset = 0.005 / art_texels;
		vec2 lo = rect.xy + inset;
		vec2 hi = max(rect.zw - inset, lo);
		// This face's lift, so its own highest texel sits on it.
		float lift = has_lift_tex ? textureLod(lift_tex, clamp(UV, lo, hi), 0.0).r : height_lift;
		// The node march's step count, capped lower: a mob is a few
		// hundred pixels at most and its authored heights are plateaus
		// one art texel wide, which the chord refinement below finds.
		int steps = int(mix(16.0, 6.0, vn) * clamp(depth_nodes / 0.05, 1.0, 2.0));
		float dd = 1.0 / float(steps);
		float d = 0.0;
		float d_prev = 0.0;
		vec2 uv = clamp(UV, lo, hi);
		float h = max(1.0 - lift - textureGrad(normal_tex, uv, gem_dx, gem_dy).a, 0.0);
		float h_prev = h;
		for (int i = 0; i < 32; i++) {
			if (i >= steps || d >= h)
				break;
			d_prev = d;
			h_prev = h;
			d += dd;
			uv = clamp(UV - slope * d, lo, hi);
			h = max(1.0 - lift - textureGrad(normal_tex, uv, gem_dx, gem_dy).a, 0.0);
		}
		// The hit lies between the last two samples. The node march takes
		// the chord between them, which is right on a smooth field; a skin's
		// heights are plateaus with walls between them, the chord then lands
		// anywhere inside the step, and a deep wall (the creeper's eye pits
		// drop 0.76 of the range inside one face) drew as one slice per step,
		// a vertical staircase. A few halvings find where the ray meets the
		// wall itself, to a thirty second of a step.
		for (int i = 0; i < parallax_refine; i++) {
			float dm = 0.5 * (d_prev + d);
			float hm = max(1.0 - lift - textureGrad(normal_tex,
					clamp(UV - slope * dm, lo, hi), gem_dx, gem_dy).a, 0.0);
			if (dm >= hm) {
				d = dm;
				h = hm;
			} else {
				d_prev = dm;
				h_prev = hm;
			}
		}
		float below = d - h;
		float above = h_prev - d_prev;
		float w = below / max(below + above, 1e-5);
		// After the halvings the hit is taken at the end under the surface,
		// never the chord: on a wall the two ends straddle the step, and the
		// chord's point fell to one side or the other from pixel to pixel,
		// so the wall drew in stripes of the rim's texel and the floor's.
		// The end under the surface is the rim, which is what a wall shows.
		float d_hit = parallax_refine > 0 ? d : mix(d, d_prev, w);
		puv = clamp(UV - slope * d_hit, lo, hi);
		bool shadow_ok = true;
		if (textureGrad(albedo, puv, gem_dx, gem_dy).a < 0.5) {
			// Back toward the drawn point, to the furthest opaque texel.
			float t_in = 0.0;
			float t_out = 1.0;
			for (int i = 0; i < 4; i++) {
				float t = 0.5 * (t_in + t_out);
				if (textureGrad(albedo, mix(UV, puv, t), gem_dx, gem_dy).a >= 0.5)
					t_in = t;
				else
					t_out = t;
			}
			puv = mix(UV, puv, t_in);
			shadow_ok = false;
		}

		// Self shadow: from the hit, climb toward the sun through the same
		// field, clamped to the same face. Only the sun, as on the nodes.
		vec3 sun = normalize((VIEW_MATRIX * vec4(goanna_sun_dir, 0.0)).xyz);
		float sn = dot(sun, NORMAL);
		if (shadow_ok && parallax_shadow_strength > 0.001 && goanna_sun_dir.y > 0.02 && sn > 0.05) {
			vec3 st = sun - NORMAL * sn;
			vec2 sslope = vec2(dot(st, d_tu) / lu, dot(st, d_tv) / lv) * (depth / sn);
			float blocked = 0.0;
			float k = 0.0;
			float dk = d_hit / 8.0;
			for (int i = 0; i < 8; i++) {
				k += dk;
				vec2 suv = clamp(puv + sslope * k, lo, hi);
				float hs = max(1.0 - lift - textureGrad(normal_tex, suv, gem_dx, gem_dy).a, 0.0);
				blocked = max(blocked, (d_hit - k) - hs);
			}
			self_shadow = 1.0 - clamp(blocked * 6.0, 0.0, 1.0)
					* parallax_shadow_strength * pom;
		}
	}

	// Explicit gradients: puv jumps where the march does, and an implicit
	// one would pick the smallest mip level along every such edge.
	vec4 tex = textureGrad(albedo, puv, gem_dx, gem_dy);
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
	// The cut is the art's own at the drawn point, never the marched one:
	// the march moves what is seen inside the silhouette, not the
	// silhouette, which stays where the vanilla client draws it.
	ALPHA = pom > 0.001 ? textureGrad(albedo, UV, gem_dx, gem_dy).a : tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
#endif
#endif
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	AO = mix(1.0, node_light.y, sky_light_strength);
	EMISSION = ALBEDO * (goanna_sky_fill * node_light.y + vec3(1.0, 0.85, 0.6) * node_light.x * block_fill);

	if (has_normal) {
		vec4 n = textureGrad(normal_tex, puv, gem_dx, gem_dy);
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
		SPECULAR = clamp((class_metal > 0.5 ? 0.5 : sqrt(class_f0 / 0.16)) * specular_strength, 0.0, 1.0);
		if (class_sss > 0.0)
			BACKLIGHT = ALBEDO * class_sss * sss_strength;
	}
	// Cloth catches the light along a grazing edge, which no channel LabPBR
	// carries can say and which is most of what separates wool from painted
	// stone. Godot's own rim term, so it stays inside the lighting the rest
	// of the world is lit by, carried to light() as RIM and RIM_TINT would be
	// (see direct_light.gdshaderinc).
	v_rim = mat_class == 11 ? vec2(0.6, 0.35) : vec2(0.0);
	v_hair = 0.0;
	v_hair_strand = vec4(0.0);
	v_hair_fx = vec2(0.0);
	if (has_spec) {
		vec4 sp = textureGrad(spec_tex, puv, gem_dx, gem_dy);
		float sm = sp.r;
		// Hair, by its exact F0 byte: _s is nearest and the overlay
		// composite takes F0 whole from the covering layer, so the byte
		// arrives as written, and a mip that averages hair with anything
		// else is not 12 and drops out, which is harmless.
		vec3 down_t = image_down - NORMAL * dot(NORMAL, image_down);
		if ((hair_strength > 0.001 || hair_shader_strength > 0.001)
				&& abs(sp.g * 255.0 - 12.0) < 0.5 && dot(down_t, down_t) > 1e-12) {
			// The strand runs along the image's vertical on every face of
			// these atlases: image down is model down on a side face, and
			// on a top or bottom face image up is the model's front to back
			// (atlas.face_frames). So down on a side, front to back on a
			// top, which is the way the authored tresses run. A mirrored
			// face reverses U, never V, and the frame is solved from the
			// derivatives, so it needs nothing.
			vec3 up_v = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
			bool cap = abs(dot(NORMAL, up_v)) > 0.7;
			vec3 strand = normalize(down_t) * (cap ? -1.0 : 1.0);
			// Where along the strand this is on its face, 0 at the root's
			// edge and 1 at the tip's, as the rounding: -45 degrees
			// (toward the root) to +45 across the face, so two faces
			// meet at the same normal on the edge between them.
			float arc = 0.0;
			if (rect.w > rect.y) {
				float s = clamp((UV.y - rect.y) / (rect.w - rect.y), 0.0, 1.0);
				arc = ((cap ? 1.0 - s : s) - 0.5) * (0.5 * PI);
			}
			v_hair = hair_strength;
			if (hair_shader_strength > 0.001) {
				float k = hair_shader_strength;
				float shade, tilt, shift, shine;
				goanna_hair_strands(puv, gem_dx, gem_dy, rect, cap, shade, tilt, shift, shine);
				ALBEDO *= mix(1.0, shade, k);
				EMISSION *= mix(1.0, shade, k);
				// The strands' own normals replace the map's fine ones as
				// far as a tilt across can: the lock's slopes stay the map's.
				vec3 nm = NORMAL_MAP * 2.0 - 1.0;
				nm.x += tilt * k;
				NORMAL_MAP = normalize(nm) * 0.5 + 0.5;
				arc += shift * k;
				v_hair = max(v_hair, k);
				v_hair_fx = vec2(k, mix(1.0, shine, k));
			}
			v_hair_strand = vec4(strand, arc);
		}
		ROUGHNESS = mix(1.0, clamp(1.0 - sm, 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sqrt(sp.g / 0.16)) * specular_strength, 0.0, 1.0);
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
	// The parallax self shadow reaches direct light through AO, folded in
	// exactly as nodes_array.gdshader folds it: direct light is scaled by
	// mix(1, AO, AO_LIGHT_AFFECT), which this makes the shadow itself.
	if (self_shadow < 0.999) {
		AO = clamp(AO * self_shadow, 0.0, 1.0);
		AO_LIGHT_AFFECT = clamp(max(AO_LIGHT_AFFECT,
				(1.0 - self_shadow) / max(1.0 - AO, 1e-3)), 0.0, 1.0);
		SPECULAR *= self_shadow;
	}
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
	// The water between the eye and this surface, per colour (underwater.gdshaderinc).
	vec3 goanna_uw = goanna_underwater_keep(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD);
	ALBEDO *= goanna_uw;
	EMISSION *= goanna_uw;
}
