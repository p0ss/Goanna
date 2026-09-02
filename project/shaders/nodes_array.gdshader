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
// need alpha testing use nodes_array_scissor.gdshader instead, chosen in
// GoannaClient::materialFor rather than by a uniform. The LabPBR decode below
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
	// layer back. See docs/far-rendering.md, "The far field's albedo".
	int layer = int(round(UV2.x));
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
	}
	// A middling default for tiles without an _s: soil-like, takes rain
	// without turning to glass.
	float porosity = 0.35;
	if (has_spec) {
		vec4 sp = textureGrad(spec_array, vec3(tile_uv, float(layer)), uv_dx, uv_dy);
		// LabPBR: R is perceptual smoothness, roughness = (1 - smoothness)^2
		float sm = sp.r;
		// Toward 1.0, the unlit-looking fully rough default, so 0 gives back
		// exactly what a node with no companion gets.
		ROUGHNESS = mix(1.0, clamp((1.0 - sm) * (1.0 - sm), 0.04, 1.0), roughness_strength);
		// G below 229/255 is dielectric F0, at or above it is a metal index
		METALLIC = sp.g >= 0.898 ? 1.0 : 0.0;
		// Godot's SPECULAR is not F0: it defines F0 = 0.08 * SPECULAR, so the
		// ordinary dielectric F0 of 0.04 is SPECULAR 0.5. LabPBR stores F0
		// directly, and we were passing it straight through doubled, which
		// turned the standard dielectric byte of 10 into an F0 of 0.006,
		// roughly six times too dark. Dielectrics had almost no specular at
		// all, which is a large part of why none of this read as PBR.
		SPECULAR = clamp((sp.g >= 0.898 ? 0.5 : sp.g / 0.08) * specular_strength, 0.0, 1.0);
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
	// world is lit by. The class is the one already looked up above.
	if (cls == 11) {
		RIM = 0.6;
		RIM_TINT = 0.35;
	}

	// Rain wets what the sky can reach: up facing surfaces with strong sky
	// light darken and go glossy, so a shower leaves the ground gleaming,
	// while anything under a roof keeps its dry look; the sky light channel
	// is the roof test the mesh already carries. Porosity (the _s blue
	// channel) decides the split the way LabPBR intends: soil soaks and
	// darkens, stone sheens.
	if (goanna_wetness > 0.001) {
		float wet = goanna_wetness * clamp(v_wnormal.y, 0.0, 1.0)
				* smoothstep(0.55, 0.9, v_nodelight.g);
		ALBEDO *= 1.0 - wet * (0.10 + 0.18 * porosity);
		ROUGHNESS = mix(ROUGHNESS, 0.13, wet * (0.85 - 0.45 * porosity));
		SPECULAR = mix(SPECULAR, 0.5, wet * 0.6);
	}

	// Node light and occlusion. Occlusion multiplies ambient and, by default,
	// leaves direct light alone: a corner is dark because less sky reaches it,
	// not because the sun stopped shining on it. Sky visibility attenuates the
	// same ambient, which is what darkens interiors and caves.
	float sky_vis = mix(1.0, v_nodelight.g, sky_light_strength);
	float occ = mix(1.0, v_nodelight.b, vertex_ao_strength);
	AO = clamp(pack_ao * occ * sky_vis, 0.0, 1.0);
	AO_LIGHT_AFFECT = vertex_ao_light_strength;
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
}
