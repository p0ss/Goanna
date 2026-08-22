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

uniform sampler2DArray albedo_array : source_color, filter_nearest_mipmap, repeat_enable;
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
}

void fragment() {
	if (fade < 0.999) {
		// interleaved gradient noise, stable per pixel
		float dither = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (dither > fade)
			discard;
	}
	ALBEDO = (texture(albedo_array, vec3(UV, UV2.x)) * COLOR).rgb;
	if (v_stale > 0.001)
		ALBEDO = mix(ALBEDO, vec3(dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722))), v_stale * stale_strength);
	// Either how far away this fragment is or how wide the quad it sits
	// on actually is can call for flattening (see lod_repeat above), so a
	// wide merged panel flattens on its own size even at point blank
	// range and a small one still only flattens at range. Read below by
	// the normal map too: a flattened colour with its relief left alone
	// still shades like the tile pattern, bumps and all, so the repeat
	// reads through the lighting even where the albedo no longer shows it.
	float flatten = 0.0;
	if (lod_flatten) {
		flatten = max(
				smoothstep(lod_flatten_near, lod_flatten_far, length(VERTEX)),
				smoothstep(lod_repeat_near, lod_repeat_far, lod_repeat));
		if (flatten > 0.001)
			ALBEDO = mix(ALBEDO, lod_avg_colour[int(UV2.x)] * COLOR.rgb, flatten);
	}
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	float pack_ao = 1.0;

	if (has_normal) {
		vec4 n = texture(normal_array, vec3(UV, UV2.x));
		// No green flip. LabPBR stores Y down, and Luanti's tile UVs run V
		// down as well, so the two already agree. Flipping to match the
		// usual OpenGL description of a normal map turns block sides black,
		// which a fixed camera A/B shows plainly. The inferred normals in
		// goanna_textures.cpp do flip, because they are built in image space
		// where the row order is the other way about.
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
		vec4 sp = texture(spec_array, vec3(UV, UV2.x));
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
		// it is subsurface scattering. Porosity only reads as anything once
		// a surface is wet, so it waits for weather; scattering is what
		// makes a leaf glow with the sun behind it.
		if (sp.b > 0.2549) {
			float sss = (sp.b - 0.2549) / 0.7451;
			// BACKLIGHT, not SSS_STRENGTH. Godot's subsurface scattering is a
			// screen-space pass meant for skin: pointed at a solid block it
			// eats the diffuse and leaves it near black. Backlight adds the
			// light coming through from behind, which is the whole of what a
			// leaf or a pane of ice wants.
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
