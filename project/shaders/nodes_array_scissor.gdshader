// Goanna: alpha tested node tiles drawn from an array texture.
//
// Same as nodes_array.gdshader, less its parallax march and self shadow,
// for tiles whose own layer has alpha (cut-out foliage, grass side
// overlays and the like). The near mesh picks per tile (arrayTileKey in
// goanna_client.cpp), so an opaque tile in an array that also holds a
// cut-out is drawn by nodes_array.gdshader. The far tiers merge a whole
// array into one surface and so still pick by the array; the march ends
// at parallax_range (40 nodes), and the far tiers normally start beyond
// it, so there only the alpha test's cost differs. Cut-outs stay flat: a
// march here would have to alpha test at the offset coordinate, moving a
// leaf's holes with the view, and whether that reads better is untried.
// Kept as a separate shader, not a runtime toggle on the opaque one,
// because Godot decides whether a material needs the alpha scissor
// pipeline by scanning the shader source for a write to
// ALPHA_SCISSOR_THRESHOLD, not by whether a uniform enables it at draw
// time: godotengine/godot#60388. The LabPBR decode below is duplicated
// from nodes_array.gdshader rather than shared; see
// nodes_array_common.gdshaderinc for why.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/nodes_array_common.gdshaderinc"
#define GOANNA_DIAMOND
#include "res://shaders/direct_light.gdshaderinc"
#include "res://shaders/diamond_ore.gdshaderinc"
// goanna_rain and the rain cover map, for splashes and puddles. Cut-outs
// on open ground take rain too, and the far tiers draw ground with this
// shader (above; docs/weather.md, "Splashes and puddles in play").
#include "res://shaders/weather_common.gdshaderinc"

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
	v_wtangent = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz);
	v_wbinormal = normalize((MODEL_MATRIX * vec4(BINORMAL, 0.0)).xyz);
}

void fragment() {
	v_lamp_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Derivatives before any branching: a fragment quad can straddle two
	// array layers, and dFdx inside that is not defined.
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	// The world size of a pixel, which sizes and fades the rain splashes
	// (weather_common.gdshaderinc); taken here, outside any branch, like
	// the other derivatives.
	float px = max(length(dFdx(v_world)), length(dFdy(v_world)));
	// The array layer, rounded rather than truncated; see the note on the
	// same line in nodes_array.gdshader, which also explains the animation.
	int layer = goanna_anim_layer(int(round(UV2.x)));
	// Flatten by camera distance. VERTEX is an absolute world position in
	// Goanna's meshes, so length(VERTEX) measured distance from world zero and
	// made the same hill change colour as the player crossed tier boundaries.
	// A former region-wide widest-quad term also flattened every face because
	// one unrelated face happened to merge well. Read below by
	// the normal map too: a flattened colour with its relief left alone
	// still shades like the tile pattern, bumps and all, so the repeat
	// reads through the lighting even where the albedo no longer shows it.
	// It is computed here, before the tile is read, because the surface
	// detail below rides on it: one factor decides both, so there can be no
	// band of range where the detail has gone and the flattening has not
	// started.
	float flatten = 0.0;
	if (lod_flatten)
		flatten = smoothstep(lod_flatten_near, lod_flatten_far,
				length(v_world - CAMERA_POSITION_WORLD));
	// Per class surface treatment, in world space so a near block and a far
	// tier's merged quad draw one continuous pattern. Spent only where a node
	// is still worth more than a pixel.
	int cls = layer_class[layer];
	float detail = detail_strength * (1.0 - flatten);
	vec4 tile;
	// Per node: this face reads its own turned and shifted copy of the tile.
	// One read, and every discontinuity lands on a node boundary, where the
	// art already has one.
	bool tiled = detail > 0.01 && goanna_class_is_granular(cls)
			&& layer_coarse[layer] < detail_max_coarse;
	vec2 tile_uv = UV;
	if (tiled)
		tile_uv = goanna_node_uv(UV, goanna_node_of(v_world, v_wnormal),
				float(textureSize(albedo_array, 0).x), detail_turn);
	tile = textureGrad(albedo_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
	vec4 tex = tile * COLOR;
	ALBEDO = tex.rgb;
	if (v_stale > 0.001)
		ALBEDO = mix(ALBEDO, vec3(dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722))), v_stale * stale_strength);
	if (flatten > 0.001)
		ALBEDO = mix(ALBEDO, lod_avg_colour[layer] * COLOR.rgb, flatten);
	// Coverage applies wherever a far tier draws, not only past
	// lod_flatten_near: a canopy changes colour at the tier boundary, which
	// is well inside where any flattening starts. An opaque tile has
	// coverage 1.0 and is untouched.
	if (lod_flatten)
		ALBEDO *= mix(1.0, lod_coverage[layer], lod_coverage_strength);
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	float pack_ao = 1.0;
	vec3 relief_normal = vec3(0.0, 0.0, 1.0);
	// The relief height for the rain's standing water; see
	// nodes_array.gdshader for why only a layer with a depth has one.
	float relief_h = 1.0;
	bool relief_known = false;

	if (has_normal) {
		vec4 n = textureGrad(normal_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
		vec2 xy = (n.rg * 2.0 - 1.0) * normal_strength * pack_normal_gain * (1.0 - flatten);
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		relief_normal = vec3(xy, z);
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, z * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
		// Toward fully lit as the strength falls, so 0 removes the pack's
		// occlusion rather than removing Godot's own shading with it. The
		// pack's occlusion is texture scale detail; the vertex one below is
		// the shape of the room, and they multiply. Flattened the same way
		// as the relief above, for the same reason.
		pack_ao = mix(1.0, n.b, ao_strength * (1.0 - flatten));
		if (layer_depth[layer] > 0.0) {
			relief_h = n.a;
			relief_known = true;
		}
	}
	// See nodes_array.gdshader: the wetness block reads porosity.
	float porosity = 0.35;
	if (has_spec) {
		vec4 sp = textureGrad(spec_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
		float sm = sp.r;
		// Toward 1.0, the unlit-looking fully rough default, so 0 gives back
		// exactly what a node with no companion gets.
		ROUGHNESS = mix(1.0, clamp(1.0 - sm, 0.04, 1.0), roughness_strength);
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
		if (sp.a < 0.999)
			EMISSION = ALBEDO * sp.a * emission_strength;
		if (sp.b <= 0.2549)
			porosity = sp.b / 0.2549;
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			BACKLIGHT = ALBEDO * sss * sss_strength * (1.0 - flatten);
		}
	}
	// Keep the complete micro-PBR response on the same distance ramp as the
	// albedo and normal detail. Otherwise a flat averaged canopy retains the
	// close tile's sharp highlight and becomes reflective at the LOD handoff.
	float gem = goanna_diamond_mask(tile.rgb, layer_diamond[layer]) * (1.0 - flatten);
	vec3 gem_normal = relief_normal * 0.5 + 0.5;
	// Authored maps are upscaled; the gem's art remains a 16-texel tile.
	float gem_px = max(length(uv_dx), length(uv_dy)) * 16.0;
	int gem_code = layer_diamond[layer];
	v_gem_optics = goanna_gem_optics(gem_code);
	v_diamond = goanna_diamond_surface(gem_code, tile.rgb, gem, gem_px, gem_normal, ROUGHNESS, METALLIC, SPECULAR);
	relief_normal = gem_normal * 2.0 - 1.0;
	NORMAL_MAP = gem_normal;
	NORMAL_MAP_DEPTH = 1.0;
	v_diamond_axis = TANGENT;
	v_diamond_interior = 0.0;
	v_diamond_inner_normal = NORMAL;
	v_diamond_scatter = vec3(0.0);
	if (gem > 0.001 && diamond_interior_strength > 0.001) {
		vec2 texel = vec2(1.0 / 16.0);
		float surround = 0.0;
		for (int edge = 0; edge < 4; edge++) {
			vec2 offset = edge < 2 ? vec2(edge == 0 ? -1.0 : 1.0, 0.0)
					: vec2(0.0, edge == 2 ? -1.0 : 1.0);
			vec3 neighbour = textureGrad(albedo_array,
					vec3(tile_uv + offset * texel, float(layer)), uv_dx, uv_dy).rgb;
			surround += goanna_diamond_mask(neighbour, layer_diamond[layer]) * 0.25;
		}
		vec2 edge_dist = min(fract(tile_uv), 1.0 - fract(tile_uv));
		float block_depth = mix(0.65, 4.0, smoothstep(0.0, 0.22, min(edge_dist.x, edge_dist.y)));
		float thickness = goanna_gem_mode(gem_code) == 2 ? block_depth : mix(0.4, 1.8, surround);
		vec3 eye = vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), max(dot(VIEW, NORMAL), 0.05));
		vec2 travel = goanna_diamond_travel(eye, thickness, gem_code);
		vec3 middle = textureGrad(albedo_array,
				vec3(tile_uv + travel * texel * 0.45, float(layer)), uv_dx, uv_dy).rgb;
		vec3 rear = textureGrad(albedo_array,
				vec3(tile_uv + travel * texel, float(layer)), uv_dx, uv_dy).rgb;
		middle = mix(tile.rgb, middle, goanna_diamond_mask(middle, layer_diamond[layer]));
		rear = mix(tile.rgb, rear, goanna_diamond_mask(rear, layer_diamond[layer]));
		vec3 scatter;
		vec3 inner = goanna_diamond_interior(gem_code, tile.rgb * COLOR.rgb, middle * COLOR.rgb,
				rear * COLOR.rgb, thickness, gem, gem_px, travel, ALBEDO, scatter);
		v_diamond_scatter = scatter;
		v_diamond_inner_normal = normalize(TANGENT * inner.x + BINORMAL * inner.y + NORMAL * inner.z);
		v_diamond_interior = v_diamond * diamond_interior_strength * 0.45;
		if (goanna_gem_mode(gem_code) == 1 && diamond_ore_transmission > 0.001 && gem_px < 1.5) {
			vec3 backed = goanna_ore_interior(gem_code, tile_uv, layer, uv_dx, uv_dy,
					eye, gem_normal * 2.0 - 1.0, tile.rgb, gem_px);
			ALBEDO = mix(ALBEDO, backed * COLOR.rgb,
					gem * diamond_strength * diamond_interior_strength);
		}
	}

	ROUGHNESS = mix(ROUGHNESS, mix(1.0, lod_avg_rough[layer], roughness_strength), flatten);
	// The relief that flattening just removed, returned as roughness. Added in
	// squared roughness, which is where a slope distribution's variance
	// belongs, and scaled by normal_strength because that is how much of the
	// relief was being shown in the first place.
	if (flatten > 0.001 && lod_variance_roughness > 0.0) {
		float g = normal_strength * pack_normal_gain;
		float lost = lod_normal_variance[layer] * g * g
				* flatten * lod_variance_roughness;
		ROUGHNESS = clamp(sqrt(ROUGHNESS * ROUGHNESS + lost), 0.0, 1.0);
	}
	METALLIC = mix(METALLIC, lod_avg_metal[layer], flatten);
	SPECULAR = mix(SPECULAR, clamp(lod_avg_spec[layer] * specular_strength, 0.0, 1.0), flatten);

	// Cloth catches the light along a grazing edge, which no LabPBR channel
	// can say and which is most of what separates wool from painted stone.
	// Godot's own rim term, so it stays inside the lighting the rest of the
	// world is lit by, carried to light() as RIM and RIM_TINT would be (see
	// direct_light.gdshaderinc). The class is the one already looked up above.
	v_rim = cls == 11 ? vec2(0.6, 0.35) : vec2(0.0);

	// Dry bark retains diffuse relief without polished highlights.
	ROUGHNESS = max(ROUGHNESS, layer_roughness_floor[layer]);

	// Rain wets what the sky can reach, damp rather than glazed; the full
	// account is in nodes_array.gdshader beside the same block.
	float wet_film = 0.0;
	if (goanna_render_wet_surfaces > 0.5 && goanna_wetness > 0.001) {
		// Wet only where rain reaches: the cover map where there is one,
		// sky light beyond it. Sky light alone wet the floor several nodes
		// in from a doorway, where the light still reaches.
		wet_film = goanna_wetness * clamp(v_wnormal.y, 0.0, 1.0)
				* goanna_rain_open(v_world, smoothstep(0.55, 0.9, v_nodelight.g));
		if (relief_known)
			wet_film *= 1.0 - 0.5 * smoothstep(0.75, 1.0, relief_h) * (1.0 - flatten);
		ALBEDO *= 1.0 - wet_film * (0.10 + 0.18 * porosity);
		ROUGHNESS = mix(ROUGHNESS, 0.32, wet_film * (0.8 - 0.4 * porosity));
		SPECULAR = mix(SPECULAR, 0.4, wet_film * 0.5);
	}

	// Standing water in the relief, and splashes, only where rain lands on
	// open, up facing ground. No march here, so the height is the tile's
	// own at its coordinate. The whole account is in nodes_array.gdshader
	// beside the same block: change one, change the other.
	vec3 ground_rain = goanna_ground_rain(v_world, v_wnormal, v_nodelight.g, flatten,
			goanna_wetness, length(v_world - CAMERA_POSITION_WORLD), px);
	vec3 pool = goanna_pool(ground_rain.x, ground_rain.y, relief_h);
	float water = pool.x;
	float meniscus = goanna_meniscus(ground_rain.x, ground_rain.y, relief_h);
	vec3 splash = vec3(0.0);
	if (ground_rain.z > 0.001)
		splash = goanna_rain_splash(v_world.xz, TIME, px, goanna_rain) * min(ground_rain.z, 1.0);
	if (max(max(wet_film, water), max(pool.y, ground_rain.z)) > 0.001) {
		ALBEDO *= goanna_wet_darken(pool, splash.z, porosity);
		// The margin and a splash's mark: smoother, still not glass.
		ROUGHNESS = mix(ROUGHNESS, 0.22, max(pool.y * 0.6, splash.z * 0.8));
		ROUGHNESS = mix(ROUGHNESS, 0.06, water);
		ROUGHNESS = mix(ROUGHNESS, 0.03, meniscus);
		// Water's own F0 of 0.02, which is SPECULAR 0.25: what reflects is
		// the water over the tile, whatever the tile would.
		SPECULAR = mix(SPECULAR, 0.25, water);
		METALLIC = mix(METALLIC, 0.0, water);
		// Standing water is level, so under it the relief is drowned and the
		// normal is the face's own; the film and the margin soften the
		// relief rather than drown it. The rings ride on what is left, at
		// full strength in water and a third of it on damp ground.
		vec3 slope = -vec3(splash.x, 0.0, splash.y) * mix(0.35, 1.0, water);
		vec2 xy = relief_normal.xy * (1.0 - water) * (1.0 - 0.3 * wet_film)
				* (1.0 - 0.4 * max(pool.y, splash.z))
				+ vec2(dot(slope, v_wtangent), dot(slope, v_wbinormal));
		// The meniscus tilts the water up against the ridge beside it, the
		// way the relief itself rises there, so the rim catches the light.
		float rise = length(relief_normal.xy);
		if (meniscus > 0.001 && rise > 0.001)
			xy += relief_normal.xy / rise * 0.45 * meniscus;
		float z = sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0));
		relief_normal = vec3(xy, z);
		NORMAL_MAP = vec3(xy * 0.5 + 0.5, z * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
	}

	// Node light and occlusion. Occlusion multiplies ambient and, by default,
	// leaves direct light alone: a corner is dark because less sky reaches it,
	// not because the sun stopped shining on it. Sky visibility attenuates the
	// same ambient, which is what darkens interiors and caves.
	float sky_vis = mix(1.0, v_nodelight.g, sky_light_strength);
	float occ = mix(1.0, v_nodelight.b, vertex_ao_strength);
	AO = clamp(pack_ao * occ * sky_vis, 0.0, 1.0);
	AO_LIGHT_AFFECT = vertex_ao_light_strength;
	// The fill is emission so that the sun's shadow does not darken it, but
	// emission is also outside Godot's AO path and the fill is most of the
	// light in a frame, so it multiplies the same occlusion the ambient path
	// carries. See nodes_array.gdshader for the measurement.
	// Clouds between here and the sun dim the surface, fill and all.
	ALBEDO *= goanna_cloud_dim(v_world);
	vec3 fill_normal = normalize(v_wtangent * relief_normal.x +
			v_wbinormal * relief_normal.y + v_wnormal * relief_normal.z);
	float fill_up = clamp(0.5 + 0.5 * fill_normal.y, 0.0, 1.0);
	vec3 fill_col = mix(goanna_ground_fill, goanna_sky_fill, fill_up);
	float fill_shape = mix(0.65, 1.0, fill_up);
	EMISSION += ALBEDO * fill_col * fill_shape * v_nodelight.g * sky_fill_strength
			* clamp(pack_ao * occ, 0.0, 1.0);
	// Same rule as nodes_array.gdshader: the far tiers bake lamp light, the
	// near mesh fades the same bake in past the light pool's reach.
	float lamp_bake = max(block_light_emission,
			smoothstep(goanna_lamp_reach, goanna_lamp_reach * 1.5 + 48.0, length(VERTEX)));
	if (lamp_bake > 0.0)
		EMISSION += ALBEDO * v_nodelight.r * lamp_bake;
	if (debug_nodelight_strength > 0.0) {
		ALBEDO = vec3(0.0);
		EMISSION = v_nodelight * debug_nodelight_strength;
	}
	// Sun gate and F0 for light(), as in nodes_array.gdshader.
	v_sun_gate = goanna_sun_gate(v_nodelight.g, v_nodelight.r);
	v_specular = SPECULAR;
}
