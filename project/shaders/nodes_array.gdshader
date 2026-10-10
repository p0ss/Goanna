// Goanna: opaque node tiles drawn from an array texture.
//
// Luanti's mesher groups same-sized tile images into array textures and writes
// each vertex's layer index into S3DVertex::Aux; Goanna carries that across as
// UV2.x. A whole bunch of different node tiles can then share one material,
// which is what takes a block from ~19 draw calls down to a handful.
//
// This variant never touches ALPHA_SCISSOR_THRESHOLD, not even behind a
// runtime toggle that is usually off. Godot decides whether a material needs
// the alpha scissor pipeline by scanning the shader source for that write, not
// by the value the toggle holds at draw time, and that pipeline mishandles
// mipmaps on the array texture: godotengine/godot#60388. Tiles that actually
// need alpha testing use nodes_array_scissor.gdshader instead, chosen per
// tile by its own layer (arrayTileKey in goanna_client.cpp) rather than by a
// uniform or by the array: upstream's arrays mix opaque and cut-out tiles,
// and both shaders sample the same arrays. The LabPBR decode below
// is duplicated there rather than shared; see nodes_array_common.gdshaderinc
// for why.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// LabPBR companions, when a resource pack ships them (see docs): _n carries
// the tangent normal in RG with ambient occlusion in B, _s carries perceptual
// smoothness in R, F0/metalness in G and emission in A.
// Linear, unlike the albedo. Nearest is right for the colour, which is
// pixel art and wants its hard edges, but a normal map is a direction field:
// this pack tilts a texel by 19 degrees on average and up to 51 at the ninth
// decile, so snapping between neighbouring texels swings the specular
// highlight from frame to frame and reads as shimmer.
#include "res://shaders/nodes_array_common.gdshaderinc"
#include "res://shaders/underwater.gdshaderinc"
#define GOANNA_DIAMOND
#define GOANNA_MICRO_SHADOW
#include "res://shaders/direct_light.gdshaderinc"
#include "res://shaders/diamond_ore.gdshaderinc"
// goanna_rain and the rain cover map, for splashes and puddles.
#include "res://shaders/weather_common.gdshaderinc"

void vertex() {
	// CUSTOM0 arrives as four bytes scaled to 0 to 1: block light, sky light,
	// occlusion. See docs/systems/mesh-attributes.md.
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
	// The array layer, rounded rather than truncated. UV2.x holds the same
	// integer at every vertex of a face, but it still reaches the fragment
	// through interpolation, so it arrives a hair either side of that integer
	// and int() takes layer 16 to 15 on about half the fragments. The texture
	// samplers never showed it because GLSL rounds an array layer coordinate
	// itself; only the arrays indexed by hand below were affected, and they
	// took the colour and the class of whichever tile happens to sit one
	// layer back. See docs/systems/far-rendering.md, "The far field's albedo".
	// An animated tile's face names its first frame; the clock picks the
	// frame drawn (nodes_array_common.gdshaderinc, goanna_anim_layer).
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
	// Parallax occlusion. The tile coordinate is moved to where the eye ray
	// really meets the height field, so every read below (albedo, normal,
	// material) is of the texel actually seen, and a joint's far wall hides
	// behind its near lip the way a real one does. The basis for it is the
	// world space extent of one unit of tile coordinate, solved from the
	// screen derivatives of position against those of the tile coordinate:
	// that is exact inside a node whatever turn and shift goanna_node_uv
	// applied, and asks nothing of the mesh's tangent convention. Faded out
	// with distance, and off wherever the far flatten has started, so the
	// far tiers never pay for it.
	vec2 tuv_dx = dFdx(tile_uv);
	vec2 tuv_dy = dFdy(tile_uv);
	// Position derivatives here too, outside any branch: a derivative
	// inside flow that not every pixel of the quad takes is undefined.
	vec3 dpx = dFdx(v_world);
	vec3 dpy = dFdy(v_world);
	// The world size of a pixel, which sizes and fades the rain splashes
	// (weather_common.gdshaderinc).
	float px = max(length(dpx), length(dpy));
	float self_shadow = 1.0;
	float pom = 0.0;
	// How much of the sun's light the march's self shadow decided, which the
	// micro shadow in light() then leaves alone (direct_light.gdshaderinc).
	float march_shadow = 0.0;
	bool short_march = parallax_short_strength > 0.5;
	if (has_normal && parallax_strength > 0.001 && flatten < 0.999) {
		float eye_dist = length(v_world - CAMERA_POSITION_WORLD);
		float range = short_march ? min(parallax_range, parallax_short_range) : parallax_range;
		pom = (1.0 - smoothstep(range * 0.5, range, eye_dist))
				* (1.0 - flatten) * parallax_strength;
	}
	if (pom > 0.001) {
		float det = tuv_dx.x * tuv_dy.y - tuv_dy.x * tuv_dx.y;
		// A quad straddling a node boundary sees the per node shift as a
		// derivative and gets a basis of nothing; those pixels stay flat.
		if (abs(det) > 1e-12) {
			vec3 d_tu = (dpx * tuv_dy.y - dpy * tuv_dx.y) / det;
			vec3 d_tv = (dpy * tuv_dx.x - dpx * tuv_dy.x) / det;
			float lu = max(dot(d_tu, d_tu), 1e-8);
			float lv = max(dot(d_tv, d_tv), 1e-8);
			vec3 view_w = normalize(CAMERA_POSITION_WORLD - v_world);
			float vn = max(dot(view_w, v_wnormal), 0.08);
			vec3 vt = view_w - v_wnormal * dot(view_w, v_wnormal);
			// Tile units the visible point shifts per unit of normalised
			// depth: down the eye ray, so against the view's tangent part.
			float depth = (layer_depth[layer] > 0.0 ? layer_depth[layer] : goanna_class_depth(cls))
					* parallax_depth * pom;
			vec2 slope = vec2(dot(vt, d_tu) / lu, dot(vt, d_tv) / lv) * (depth / vn);
			// More steps the flatter the view, where the ray runs furthest
			// across the tile before it lands.
			// A deeper march runs further across the tile and needs more
			// samples to keep a joint's wall from tearing.
			int steps = short_march ? 4
					: int(mix(22.0, 8.0, vn) * clamp(depth / 0.05, 1.0, 2.0));
			float dd = 1.0 / float(steps);
			float d = 0.0;
			float d_prev = 0.0;
			vec2 uv = tile_uv;
			float h = 1.0 - textureGrad(normal_array, vec3(uv, float(layer)), uv_dx, uv_dy).a;
			float h_prev = h;
			for (int i = 0; i < 48; i++) {
				if (i >= steps || d >= h)
					break;
				d_prev = d;
				h_prev = h;
				d += dd;
				uv = tile_uv - slope * d;
				h = 1.0 - textureGrad(normal_array, vec3(uv, float(layer)), uv_dx, uv_dy).a;
			}
			// The short march's four steps are a quarter of the depth each,
			// coarser than a joint's wall: two halvings of the step that
			// crossed the surface put the hit within a sixteenth of the
			// depth before the chord below. Skipped when the ray never got
			// under the surface, where there is nothing to bracket.
			if (short_march && d >= h) {
				for (int i = 0; i < 2; i++) {
					float dm = 0.5 * (d_prev + d);
					float hm = 1.0 - textureGrad(normal_array,
							vec3(tile_uv - slope * dm, float(layer)), uv_dx, uv_dy).a;
					if (dm >= hm) {
						d = dm;
						h = hm;
					} else {
						d_prev = dm;
						h_prev = hm;
					}
				}
			}
			// The hit lies between the last two samples: intersect the ray
			// with the chord between them.
			float below = d - h;
			float above = h_prev - d_prev;
			float w = below / max(below + above, 1e-5);
			float d_hit = mix(d, d_prev, w);
			if (parallax_silhouette > 0.5
					&& any(notEqual(floor(UV - slope * d_hit), floor(UV))))
				discard;
			tile_uv = tile_uv - slope * d_hit;

			// Self shadow: from the hit, climb toward the sun through the
			// same field. Where the surface stands above the climbing ray
			// the texel is in its own shade. Only the sun; the moon and
			// lamps are left to the normal map.
			float sn = dot(goanna_sun_dir, v_wnormal);
			if (parallax_shadow_strength > 0.001 && goanna_sun_dir.y > 0.02 && sn > 0.05) {
				vec3 st = goanna_sun_dir - v_wnormal * sn;
				vec2 sslope = vec2(dot(st, d_tu) / lu, dot(st, d_tv) / lv) * (depth / sn);
				float blocked = 0.0;
				float k = 0.0;
				int shadow_steps = short_march ? 4 : 8;
				float dk = d_hit / float(shadow_steps);
				for (int i = 0; i < shadow_steps; i++) {
					k += dk;
					vec2 suv = tile_uv + sslope * k;
					float hs = 1.0 - textureGrad(normal_array, vec3(suv, float(layer)), uv_dx, uv_dy).a;
					// how far the surface here stands above the ray
					blocked = max(blocked, (d_hit - k) - hs);
				}
				self_shadow = 1.0 - clamp(blocked * 6.0, 0.0, 1.0)
						* parallax_shadow_strength * pom;
				march_shadow = pom;
			}
		}
	}
	tile = textureGrad(albedo_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
	ALBEDO = (tile * COLOR).rgb;
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
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	float pack_ao = 1.0;
	vec3 relief_normal = vec3(0.0, 0.0, 1.0);
	// The relief height at the texel drawn, for the rain's standing water.
	// 1, a crest everywhere, unless the layer's own map carries a height:
	// a layer with no _n gets a filler whose alpha is 0, and one inferred
	// from the colour has 255, neither of them a height. layer_depth is
	// measured only from an authored height, so it says which is which.
	float relief_h = 1.0;
	bool relief_known = false;

	if (has_normal) {
		vec4 n = textureGrad(normal_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
		// No green flip. LabPBR stores Y down, and Luanti's tile UVs run V
		// down as well, so the two already agree. Flipping to match the
		// usual OpenGL description of a normal map turns block sides black,
		// which a fixed camera A/B shows plainly. The inferred normals in
		// goanna_textures.cpp do flip, because they are built in image space
		// where the row order is the other way about.
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
		// The height at the coordinate the march moved to, from this same
		// fetch, so the water costs no read of its own.
		if (layer_depth[layer] > 0.0) {
			relief_h = n.a;
			relief_known = true;
		}
	}
	// A middling default for tiles without an _s: soil-like, takes rain
	// without turning to glass.
	float porosity = 0.35;
	if (has_spec) {
		vec4 sp = textureGrad(spec_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
		// Godot expects perceptual roughness; its BRDF squares this itself.
		// LabPBR R is perceptual smoothness, so invert without squaring here.
		float sm = sp.r;
		// Toward 1.0, the unlit-looking fully rough default, so 0 gives back
		// exactly what a node with no companion gets.
		ROUGHNESS = mix(1.0, clamp(1.0 - sm, 0.04, 1.0), roughness_strength);
		// G below 229/255 is dielectric F0, at or above it is a metal index
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		// Godot's SPECULAR is not F0: its BRDF takes F0 = 0.16 * SPECULAR
		// squared (direct_light.gdshaderinc does the same), so the ordinary
		// dielectric F0 of 0.04 is SPECULAR 0.5 and F0 is decoded through a
		// square root. LabPBR stores F0 directly. Passed straight through it
		// turned the standard byte of 10 into an F0 of 0.006; the linear
		// F0 / 0.08 that replaced it was right only at 0.04, and rendered
		// 0.06 as 0.086 and amethyst's 0.078 as 0.15. specular_strength
		// scales SPECULAR, so F0 by its square, as it does on every path.
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sqrt(sp.g / 0.16)) * specular_strength, 0.0, 1.0);
		// A is emission strength, with 1.0 meaning none
		if (sp.a < 0.999)
			EMISSION = ALBEDO * sp.a * emission_strength;
		// B is two channels in one: up to 64/255 it is porosity, above that
		// it is subsurface scattering. Porosity is read by the wetness block
		// below: a porous surface soaks and darkens, a dense one sheens.
		// Scattering is what makes a leaf glow with the sun behind it.
		if (sp.b <= 0.2549)
			porosity = sp.b / 0.2549;
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			// BACKLIGHT, not SSS_STRENGTH. Godot's subsurface scattering is a
			// screen-space pass meant for skin: pointed at a solid block it
			// eats the diffuse and leaves it near black. Backlight adds the
			// light coming through from behind, which is the whole of what a
			// leaf or a pane of ice wants.
			BACKLIGHT = ALBEDO * sss * sss_strength * (1.0 - flatten);
		}
	}
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

	// The albedo, normal relief and material response are one level of
	// texture-scale detail. Flattening only the first two left the averaged
	// far tile carrying the close tile's sharp specular lobe, so distant
	// foliage became smoother and more reflective than the same tree nearby.
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

	// Rain wets what the sky can reach: up facing surfaces with strong sky
	// light darken and grow smoother, while anything under a roof keeps its
	// dry look; the sky light channel is the roof test the mesh already
	// carries. Porosity (the _s blue channel) decides the split the way
	// LabPBR intends: soil soaks and darkens, stone sheens. Damp, not
	// glazed: this took everything open to a roughness of 0.13 with the
	// relief left whole under it, and the ground read as wet plastic. A film
	// of water softens the fine relief (below) and smooths the surface only
	// so far; the mirror is kept for water that stands. The crests of an
	// authored relief drain first and stay drier.
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

	// Settled snow (goanna_snow in weather_common.gdshaderinc): pale, matt,
	// lying level over the relief. Rain after it pools on it as slush.
	float snow = goanna_snow(v_world, v_wnormal, v_nodelight.g, relief_h,
			relief_known && flatten < 0.999);
	if (snow > 0.001) {
		ALBEDO = mix(ALBEDO, vec3(0.80, 0.82, 0.86), snow);
		ROUGHNESS = mix(ROUGHNESS, 0.72, snow);
		SPECULAR = mix(SPECULAR, 0.35, snow);
		METALLIC = mix(METALLIC, 0.0, snow);
		vec2 sxy = relief_normal.xy * (1.0 - 0.7 * snow);
		float sz = sqrt(clamp(1.0 - dot(sxy, sxy), 0.0, 1.0));
		relief_normal = vec3(sxy, sz);
		NORMAL_MAP = vec3(sxy * 0.5 + 0.5, sz * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 1.0;
	}

	// Rain on open, up facing ground (goanna_ground_rain and the functions
	// round it in weather_common.gdshaderinc have the gating and the
	// numbers). Standing water fills the relief: where the height at the
	// texel drawn, after the parallax march, lies under the water level,
	// the surface is water, flat, darker and near mirror smooth, with a wet
	// margin just above it; the level rises with the wetness, and over every
	// crest in a basin. A splash is a small ring spreading from where a drop
	// lands, carried in the normal, over a wet mark that darkens and smooths
	// the ground's own colour for a moment. Nothing here adds light: a
	// splash shows the surface's own shading and whatever sky or lamp its
	// tilted, smoother patch reflects. The same block is in
	// nodes_array_scissor.gdshader, which draws cut-outs near and every
	// array with one in it on the far tiers: change one, change the other.
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
		// Water's own F0 of 0.02, which is SPECULAR sqrt(0.02 / 0.16): what
		// reflects is the water over the tile, whatever the tile would.
		SPECULAR = mix(SPECULAR, 0.354, water);
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
	// The parallax self shadow is a shadow, so it has to reach direct light,
	// which only AO_LIGHT_AFFECT can do. Godot scales direct light by
	// mix(1, AO, AO_LIGHT_AFFECT); folding the shadow into AO and raising
	// the affect to (1 - shadow) / (1 - AO) makes that product exactly the
	// shadow wherever AO is at or above it, and the ambient path pays only
	// the shadow on top of the occlusion it already had.
	if (self_shadow < 0.999) {
		AO = clamp(AO * self_shadow, 0.0, 1.0);
		AO_LIGHT_AFFECT = clamp(max(vertex_ao_light_strength,
				(1.0 - self_shadow) / max(1.0 - AO, 1e-3)), 0.0, 1.0);
		SPECULAR *= self_shadow;
	}
	// The fill is emission so that the sun's shadow does not darken it: it is
	// the light the sky light channel says reaches here, see the include.
	// Emission is also outside Godot's AO path, and the fill is most of the
	// light in a frame (87 per cent of the dark quartile, measured on a noon
	// forest floor), so it multiplies the same occlusion the ambient path
	// carries or corners can never read dark. SSAO still cannot reach it;
	// the traced term is the stable one anyway.
	// Clouds between here and the sun dim the surface, fill and all.
	ALBEDO *= goanna_cloud_dim(v_world);
	// The sky channel is ambient, but it comes from a hemisphere. Basing its
	// dominant fill only on the geometric cube face hid normal relief anywhere
	// a point light was not nearby. Let the decoded normal softly shape it too.
	vec3 fill_normal = normalize(v_wtangent * relief_normal.x +
			v_wbinormal * relief_normal.y + v_wnormal * relief_normal.z);
	float fill_up = clamp(0.5 + 0.5 * fill_normal.y, 0.0, 1.0);
	vec3 fill_col = mix(goanna_ground_fill, goanna_sky_fill, fill_up);
	float fill_shape = mix(0.65, 1.0, fill_up);
	EMISSION += ALBEDO * fill_col * fill_shape * v_nodelight.g * sky_fill_strength
			* clamp(pack_ao * occ, 0.0, 1.0);
	// block_light_emission is 1 on the far tiers (baked lamp light instead
	// of real lights) and 0 on the near mesh, where the fade takes over
	// past the pool's reach so a mid-distance village stays lit.
	float lamp_bake = max(block_light_emission,
			smoothstep(goanna_lamp_reach, goanna_lamp_reach * 1.5 + 48.0, length(VERTEX)));
	if (lamp_bake > 0.0)
		EMISSION += ALBEDO * v_nodelight.r * lamp_bake;
	if (debug_nodelight_strength > 0.0) {
		ALBEDO = vec3(0.0);
		EMISSION = v_nodelight * debug_nodelight_strength;
	}
	// The sun and moon reach only as far as Luanti's sunlight does, and
	// light() needs the final SPECULAR to build F0: direct_light.gdshaderinc.
	v_sun_gate = goanna_sun_gate(v_nodelight.g, v_nodelight.r);
	v_specular = SPECULAR;
	// The pack's occlusion for the micro shadow, and how much of it the
	// sun takes: none where the march's self shadow already traced it.
	v_micro = vec2(pack_ao, 1.0 - clamp(march_shadow, 0.0, 1.0));
	v_sun_view = (VIEW_MATRIX * vec4(goanna_sun_dir, 0.0)).xyz;
	// The water between the eye and this surface, per colour (underwater.gdshaderinc).
	vec3 goanna_uw = goanna_underwater_keep(VERTEX, INV_VIEW_MATRIX, CAMERA_POSITION_WORLD);
	ALBEDO *= goanna_uw;
	EMISSION *= goanna_uw;
}
