// Goanna: the dig crack, drawn as a second pass over a cracked tile's own
// triangles.
//
// The crack used to be composited into a one off copy of the tile image,
// which took the tile off its array material for the whole dig and onto the
// single image one, so a block lost its pack's relief and smoothness the
// moment it was struck. The tile now keeps its array material, like its
// neighbours, and this pass lays the crack over it. Because it reuses the
// node's own triangles it fits stairs, slabs and every other shape the
// mesher makes. GoannaClient::keyForIrr decides which tiles get it.
//
// The crack frame is upstream's: nodes_shader/opengl_fragment.glsl picks the
// stage's square frame out of crack_anylength.png, repeats it crackTextureScale
// times across the tile (a world aligned texture spans several nodes), and
// mixes it into the base colour by its alpha before the tile is lit. Here
// that mix is Godot's alpha blend over the lit surface, with the crack lit
// by the same node light terms as nodes_array.gdshader, so for the diffuse
// part the two orders agree. The blend is done in linear light where the
// composite blended sRGB bytes, and the surface's specular is covered by the
// crack's rather than kept under it, which is the whole of the difference.
//
// Depth: the pass draws the very same vertices as the surface, and a
// different shader is not guaranteed to produce bit identical depth, so the
// vertices are lifted off the face along its normal by crack_lift. That
// separates the two in depth at any view angle without moving the crack
// sideways across the tile. It does not write depth, and casts no shadow
// (the MeshInstance3D turns that off too).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

// The node light uniforms and helpers the surface under the crack uses.
// albedo_array and layer_anim are only bound for an alpha tested array.
#include "res://shaders/nodes_array_common.gdshaderinc"
#include "res://shaders/direct_light.gdshaderinc"

uniform sampler2D crack_tex : source_color, filter_nearest, repeat_disable;
// Frames in the strip and the one drawn, already clamped to the strip.
uniform int crack_frames = 5;
uniform int crack_frame = 0;
// Upstream's crackTextureScale: how many times the crack repeats across the
// tile image, the tile's own scale for a world aligned texture.
uniform float crack_scale = 1.0;
// Cut the crack to the tile's own alpha test, so an alpha tested tile's
// holes stay holes.
uniform bool base_alpha_test = false;
// In nodes. Two millimetres: too small to see at digging range, and many
// times the depth buffer's resolution there.
uniform float crack_lift = 0.002;

void vertex() {
	VERTEX += NORMAL * crack_lift;
	// As nodes_array.gdshader. See docs/mesh-attributes.md.
	v_nodelight = CUSTOM0.rgb;
	v_stale = 1.0 - CUSTOM0.a;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	v_lamp_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (base_alpha_test) {
		int layer = goanna_anim_layer(int(round(UV2.x)));
		if (texture(albedo_array, vec3(UV, float(layer))).a < 0.5)
			discard;
	}
	// uv_repeat in upstream's shader: wrap only past 1, so the far edge of a
	// tile that is not scaled stays on its own frame.
	vec2 cuv = UV * crack_scale;
	if (cuv.x > 1.0)
		cuv.x = fract(cuv.x);
	if (cuv.y > 1.0)
		cuv.y = fract(cuv.y);
	// Kept off the frame's last edge, where nearest filtering would read the
	// first row of the next stage down the strip.
	cuv = clamp(cuv, 0.0, 0.999);
	vec4 crack = texture(crack_tex,
			vec2(cuv.x, (float(crack_frame) + cuv.y) / float(crack_frames)));
	if (crack.a < 0.004)
		discard;
	// Tinted like the tile, as upstream multiplies the mixed colour by the
	// vertex colour after the crack goes in.
	ALBEDO = crack.rgb * COLOR.rgb;
	ALPHA = crack.a;
	// A tile with no _s companion: fully rough, the default dielectric.
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.2;
	v_rim = vec2(0.0);

	// The node light and occlusion of nodes_array.gdshader, without the
	// pack's own occlusion, which belongs to the surface under the crack.
	// Keep the two in step.
	float sky_vis = mix(1.0, v_nodelight.g, sky_light_strength);
	float occ = mix(1.0, v_nodelight.b, vertex_ao_strength);
	AO = clamp(occ * sky_vis, 0.0, 1.0);
	AO_LIGHT_AFFECT = vertex_ao_light_strength;
	ALBEDO *= goanna_cloud_dim(v_world);
	float fill_up = clamp(0.5 + 0.5 * v_wnormal.y, 0.0, 1.0);
	vec3 fill_col = mix(goanna_ground_fill, goanna_sky_fill, fill_up);
	float fill_shape = mix(0.65, 1.0, fill_up);
	EMISSION = ALBEDO * fill_col * fill_shape * v_nodelight.g * sky_fill_strength
			* clamp(occ, 0.0, 1.0);
	float lamp_bake = max(block_light_emission,
			smoothstep(goanna_lamp_reach, goanna_lamp_reach * 1.5 + 48.0, length(VERTEX)));
	if (lamp_bake > 0.0)
		EMISSION += ALBEDO * v_nodelight.r * lamp_bake;
	v_sun_gate = goanna_sun_gate(v_nodelight.g, v_nodelight.r);
	v_specular = SPECULAR;
}
