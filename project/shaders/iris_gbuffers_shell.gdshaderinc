// Goanna: the shell a translated shader pack geometry program runs in.
//
// docs/design/iris-compat.md, "Two translations, not one": the pack's
// gbuffers program is translated into Godot's shading language by
// src/iris/iris_gbuffers.cpp, and lands in a shader that includes this
// file first. It declares what the node materials already bind (the
// texture arrays, the animation table) and the helpers the generated
// vertex() and fragment() call to answer the pack's built in inputs from
// the node mesh contract (docs/systems/mesh-attributes.md). Everything the
// pack names that varies per frame (its matrices, the lightmap, fog) is a
// global the generated code declares itself, so only what it uses is
// registered.
//
// GOANNA_IRIS_ARRAY is defined for the node array tiles, near and far
// (the materials GoannaClient::materialFor builds for nodes_array.gdshader
// and nodes_array_scissor.gdshader), and not for the water, which draws
// one texture. GOANNA_IRIS_OLD_LIGHTING is the pack's oldLighting.

#ifdef GOANNA_IRIS_ARRAY
// The same arrays nodes_array_common.gdshaderinc declares, without
// source_color: a pack samples its atlas as stored, in gamma space, and
// converts at the end (goanna_to_linear) the way Minecraft's output does.
// Minecraft's default atlas sampler uses nearest texels with blended mip
// levels and no anisotropy. Native terrain keeps its sharper sampler.
uniform sampler2DArray albedo_array : filter_nearest_mipmap, repeat_enable;
uniform sampler2DArray normal_array : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray spec_array : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
// An animated tile's frame count and frame length per first layer, as in
// nodes_array_common.gdshaderinc, and the clock that picks the frame.
uniform ivec2 layer_anim[256];
global uniform float goanna_node_anim_time;

int goanna_anim_layer(int base) {
	ivec2 anim = layer_anim[base];
	if (anim.x < 2)
		return base;
	uint frame = uint(goanna_node_anim_time * 1000.0 / float(max(anim.y, 1))) % uint(anim.x);
	return base + int(frame);
}
#else
uniform sampler2D albedo_tex : filter_nearest_mipmap, repeat_enable;
#endif

// The pack's number for each entry of the client's block table
// (MaterialTable::block_names, which UV2.y indexes), from its
// block.properties; -1 for a block it does not list, as Iris gives. Set by
// GoannaClient::materialFor from GoannaIrisGbuffers::block_ids. A material
// that is all one block (the water) sets the override instead.
uniform int goanna_iris_block_ids[512];
uniform int goanna_iris_entity_override = -2;

float goanna_block_entity(float uv2y) {
	if (goanna_iris_entity_override != -2)
		return float(goanna_iris_entity_override);
	int i = int(round(uv2y));
	if (i <= 0 || i >= 512)
		return -1.0;
	return float(goanna_iris_block_ids[i]);
}

// gl_Color carries local corner AO, without Goanna's broad cone trace.
// separateAo moves AO into alpha; oldLighting adds
// Minecraft's directional face shading (top 1.0, bottom 0.5, the faces
// along z 0.8 and along x 0.6), which a vanilla-like pack expects to find
// in the colour.
vec4 goanna_vertex_colour(vec4 tint, vec4 custom2, vec3 normal) {
	float ao = mix(1.0, custom2.r, goanna_iris_ao_level);
	vec3 c = tint.rgb;
#ifndef GOANNA_IRIS_SEPARATE_AO
	c *= ao;
#endif
#ifdef GOANNA_IRIS_OLD_LIGHTING
	vec3 n = normalize(normal);
	vec3 n2 = n * n;
	float shade = n2.x * 0.6 + n2.z * 0.8 + n2.y * (n.y > 0.0 ? 1.0 : 0.5);
	c *= shade;
#endif
#ifdef GOANNA_IRIS_SEPARATE_AO
	return vec4(c, tint.a * ao);
#else
	return vec4(c, tint.a);
#endif
}

// gl_FragCoord in OpenGL's convention: x and y in pixels from the bottom
// left, z the window depth the pack's own gbufferProjection would give the
// fragment, so a pack that rebuilds a position from it through
// gbufferProjectionInverse gets this fragment's.
vec4 goanna_frag_coord(vec4 fragcoord, vec2 viewport, vec3 view, mat4 projection) {
	vec4 clip = projection * vec4(view, 1.0);
	float z = clip.z / clip.w * 0.5 + 0.5;
	return vec4(fragcoord.x, viewport.y - fragcoord.y, z, 1.0 / clip.w);
}

// Textures of the screen (the opaque depth under translucent geometry, the
// chain's targets) are stored top row first, as Godot's screen coordinates
// run, while a pack's coordinates for them run bottom up from
// gl_FragCoord above. These turn a pack's coordinate into the texture's.
vec2 goanna_screen_uv(vec2 gl_uv) {
	return vec2(gl_uv.x, 1.0 - gl_uv.y);
}

ivec2 goanna_screen_texel(ivec2 gl_texel, ivec2 size) {
	return ivec2(gl_texel.x, size.y - 1 - gl_texel.y);
}

// Godot 4.5 stores depth reversed, 1 at the near plane and 0 at the far,
// with the same projection the pack's gbufferProjection is, so OpenGL's
// window depth is one less it: 1.0 where nothing opaque was drawn.
vec4 goanna_gl_depth(vec4 d) {
	return vec4(vec3(1.0 - d.r), 1.0);
}

// at_midBlock: from the vertex to the centre of its node, in sixty
// fourths of a node. A node's centre is at integer coordinates and its
// faces half a node out, so half a node back along the normal is inside it.
vec3 goanna_mid_block(mat4 model, vec3 vertex, vec3 normal) {
	vec3 w = (model * vec4(vertex, 1.0)).xyz;
	vec3 n = normalize(mat3(model) * normal);
	vec3 centre = floor(w - 0.5 * n + 0.5);
	return (centre - w) * 64.0;
}

// A clip position the pack made with the player camera's matrices, back
// to the model space Godot transforms. The view position is rebuilt from
// x, y and w, which a perspective projection keeps exactly; z is where its
// precision went, and at a thousand nodes rebuilding from it moved a
// vertex by half a node.
vec3 goanna_unproject(vec4 clip, mat4 projection, mat4 view_inverse, vec3 camera, mat4 model) {
	float z = -clip.w;
	float x = (clip.x - projection[2][0] * z) / projection[0][0];
	float y = (clip.y - projection[2][1] * z) / projection[1][1];
	vec3 player = (view_inverse * vec4(x, y, z, 1.0)).xyz;
	return (inverse(model) * vec4(player + camera, 1.0)).xyz;
}

// The pack's colour is display referred, gamma encoded; Godot's colour
// buffer is linear.
vec3 goanna_to_linear(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

#ifdef GOANNA_IRIS_SHADOW
// The pack's shadow program (docs/design/iris-compat.md, rung 7). Goanna
// draws the shadow map with a camera of its own whose cull mask is render
// layer 13 alone (GoannaIrisGbuffers::SHADOW_LAYER), the only layer the
// shadow copies of the near terrain are on. The clip position the pack
// made with the light's matrices goes out unchanged in x, y and w, so the
// map's texels are where the pack's own lookups expect them, and its depth
// is moved from OpenGL's -w..w to the reversed 0..w Godot's depth test
// wants, near the light at w. Any other camera, which should never see
// these surfaces, gets nothing: every vertex on one point outside the clip
// volume.
const uint GOANNA_IRIS_SHADOW_LAYERS = 4096u;

vec4 goanna_shadow_position(vec4 clip, uint layers) {
	if (layers != GOANNA_IRIS_SHADOW_LAYERS)
		return vec4(2.0, 2.0, 2.0, 1.0);
	return vec4(clip.x, clip.y, 0.5 * (clip.w - clip.z), clip.w);
}
#endif

// Six groups of at most eleven bits carry four UNORM16 channels through
// two RGB half-float viewports. Multiples of 1/2048 are represented exactly;
// this also carries the fourth data channel despite opaque alpha being 1.
vec3 goanna_pack_unorm16(vec4 value, bool low) {
	uvec4 bits = uvec4(round(clamp(value, 0.0, 1.0) * 65535.0));
	if (!low)
		return vec3(uvec3(bits.r & 2047u, (bits.r >> 11u) | ((bits.g & 63u) << 5u),
				(bits.g >> 6u) | ((bits.b & 1u) << 10u))) / 2048.0;
	return vec3(uvec3((bits.b >> 1u) & 2047u, (bits.b >> 12u) | ((bits.a & 127u) << 4u),
			bits.a >> 7u)) / 2048.0;
}
