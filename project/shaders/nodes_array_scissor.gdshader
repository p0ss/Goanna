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

#include "res://shaders/nodes_array_common.gdshaderinc"

void vertex() {
	// CUSTOM0 arrives as four bytes scaled to 0 to 1: block light, sky light,
	// occlusion. See docs/mesh-attributes.md.
	v_nodelight = CUSTOM0.rgb;
	v_stale = 1.0 - CUSTOM0.a;
	// Where this fragment is in the world, and which way the face points
	// there. Every per class treatment runs in these and nothing else, so a
	// near block and a far tier's merged quad cannot disagree.
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (fade < 0.999) {
		// interleaved gradient noise, stable per pixel
		float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (dither > fade)
			discard;
	}
	// Derivatives before any branching: a fragment quad can straddle two
	// array layers, and dFdx inside that is not defined.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	// The array layer, rounded rather than truncated; see the note on the
	// same line in nodes_array.gdshader.
	int layer = int(round(UV2.x));
	// Either how far away this fragment is or how wide the quad it sits
	// on actually is can call for flattening (see lod_repeat above), so a
	// wide merged panel flattens on its own size even at point blank
	// range and a small one still only flattens at range. Read below by
	// the normal map too: a flattened colour with its relief left alone
	// still shades like the tile pattern, bumps and all, so the repeat
	// reads through the lighting even where the albedo no longer shows it.
	// It is computed here, before the tile is read, because the surface
	// detail below rides on it: one factor decides both, so there can be no
	// band of range where the detail has gone and the flattening has not
	// started.
	float flatten = 0.0;
	if (lod_flatten) {
		flatten = max(
				smoothstep(lod_flatten_near, lod_flatten_far, length(VERTEX)),
				smoothstep(lod_repeat_near, lod_repeat_far, lod_repeat));
	}
	// Per class surface treatment, in world space so a near block and a far
	// tier's merged quad draw one continuous pattern. Spent only where a node
	// is still worth more than a pixel.
	int cls = layer_class[layer];
	float detail = detail_strength * (1.0 - flatten);
	vec4 tile;
	// The cells are chosen once and then used for the relief and the specular
	// as well, further down: one fragment has to read all three arrays from
	// the same shifted copy of the tile, or it lights a pattern its colour no
	// longer has.
	bool tiled = detail > 0.01 && goanna_class_is_granular(cls);
	vec3 cell_w = vec3(1.0, 0.0, 0.0);
	vec2 cell_o1 = vec2(0.0), cell_o2 = vec2(0.0), cell_o3 = vec2(0.0);
	if (tiled) {
		vec2 hex = goanna_surface_uv(v_world, v_wnormal) / max(detail_cell, 0.5);
		goanna_cell_pick(UV, hex, float(textureSize(albedo_array, 0).x), detail_sharpen,
				cell_w, cell_o1, cell_o2, cell_o3);
		tile = goanna_cells_albedo(float(layer), uv_dx, uv_dy,
				cell_w, cell_o1, cell_o2, cell_o3);
	} else {
		tile = texture(albedo_array, vec3(UV, UV2.x));
	}
	vec4 tex = tile * COLOR;
	ALBEDO = tex.rgb;
	if (v_stale > 0.001)
		ALBEDO = mix(ALBEDO, vec3(dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722))), v_stale * stale_strength);
	if (flatten > 0.001)
		ALBEDO = mix(ALBEDO, lod_avg_colour[layer] * COLOR.rgb, flatten);
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	float pack_ao = 1.0;

	if (has_normal) {
		vec4 n = tiled
				? goanna_cells_normal(float(layer), uv_dx, uv_dy,
						cell_w, cell_o1, cell_o2, cell_o3)
				: texture(normal_array, vec3(UV, UV2.x));
		vec2 xy = (n.rg * 2.0 - 1.0) * normal_strength * (1.0 - flatten);
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, z * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
		// Toward fully lit as the strength falls, so 0 removes the pack's
		// occlusion rather than removing Godot's own shading with it. The
		// pack's occlusion is texture scale detail; the vertex one below is
		// the shape of the room, and they multiply. Flattened the same way
		// as the relief above, for the same reason.
		pack_ao = mix(1.0, n.b, ao_strength * (1.0 - flatten));
	}
	if (has_spec) {
		vec4 sp = tiled
				? goanna_cells_spec(float(layer), uv_dx, uv_dy,
						cell_w, cell_o1, cell_o2, cell_o3)
				: texture(spec_array, vec3(UV, UV2.x));
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

	// Cloth catches the light along a grazing edge, which no LabPBR channel
	// can say and which is most of what separates wool from painted stone.
	// Godot's own rim term, so it stays inside the lighting the rest of the
	// world is lit by. The class is the one already looked up above.
	if (cls == 11) {
		RIM = 0.6;
		RIM_TINT = 0.35;
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
