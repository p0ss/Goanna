// Goanna: uniforms shared between the node array shaders.
//
// Only the uniforms live here, not the decode logic: Godot only allows a
// write to a fragment built-in (ALBEDO, ROUGHNESS, ...) from inside
// fragment() itself, not from a function it calls, so the LabPBR decode is
// duplicated in nodes_array.gdshader and nodes_array_scissor.gdshader rather
// than shared. Change one, change the other.

// The tile colours. Declared here rather than in each shader because the
// stochastic sampling below has to reach all three arrays, and Godot will not
// let one function take samplers that differ in filter, repeat or hint, which
// these deliberately do: the albedo is nearest because it is pixel art, the
// other two linear because a direction field snapped to texels swings the
// highlight from frame to frame.
uniform sampler2DArray albedo_array : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_array : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray spec_array : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_normal = false;
uniform bool has_spec = false;
// Per channel strengths. A LabPBR pack is authored for someone else's
// renderer and someone else's art, so its channels routinely arrive too hot
// for the game they are dressing: the Mineclonia bake's normals carry a
// per channel standard deviation over 40 of 255, and its ambient occlusion
// reaches 147, which on 16 pixel art reads as smeared blotches rather than
// relief. Each of these scales one decoded channel, 1.0 being the pack as
// authored and 0.0 being that channel off. They are set from the settings
// panel through GoannaClient::set_material_strength.
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_strength : hint_range(0.0, 1.0) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0) = 1.0;
uniform float emission_strength : hint_range(0.0, 8.0) = 4.0;
uniform float sss_strength : hint_range(0.0, 1.0) = 1.0;

// Per vertex node light and occlusion, packed into CUSTOM0 by
// GoannaClient::update_blocks: r is Luanti's block light (torches, lava), g is
// its sky light, b is Goanna's own ambient occlusion, a is spare. See
// docs/mesh-attributes.md for the contract and why light does not ride in
// COLOR.
//
// How much each channel is allowed to do is a uniform rather than a constant,
// because the balance is judged on lighting_chart.tscn and is expected to move
// (docs/pbr-plan.md step 3).
//
// sky_light_strength attenuates ambient by how much sky reaches the vertex,
// which is what makes an interior read as an interior instead of being lit by
// the sky through its own roof.
uniform float sky_light_strength : hint_range(0.0, 1.0) = 1.0;
// vertex_ao_strength scales the traced occlusion. It multiplies ambient only.
uniform float vertex_ao_strength : hint_range(0.0, 1.0) = 1.0;
// How much occlusion is allowed to touch direct light. It began at 0 on the
// principle that occlusion is not shadow, and the principle lost to the
// picture: with it at 0 the corner term vanishes wherever the sun is, which
// is most of every frame, and the world reads flat at noon (the vanilla
// look multiplies its corner darkening into everything, which is why its
// blocks read at any distance). 0.3 keeps direct light dominant while the
// corners stay present.
uniform float vertex_ao_light_strength : hint_range(0.0, 1.0) = 0.3;
// Sky fill: Luanti's sky light, added as a flat fill in the colour of the
// sky, scaled by the environment. This is what the vanilla client's own
// light is, and it is here because Godot's GI cannot do it: measured on
// lighting_chart.tscn, SDFGI gives a vertical face about 0.27 of a
// horizontal face's ambient, so with the sun overhead a wall can never reach
// a third of the top's brightness whatever the energy or exposure, and
// raising either only washes the tops and lights the roofed bay. The fill
// follows the sky light channel, so a cave gets none and a wall under open
// sky gets it all. goanna_sky_fill is a global shader parameter, set by
// main.gd's _apply_sky from the horizon colour and the time of day; the
// strength here is the per material slider the rest of this file has.
global uniform vec3 goanna_sky_fill;
// The lower half of the fill: what bounces up off the ground, warmer and
// dimmer than the sky above. The fill blends between the two by the world
// normal, so a ceiling is not lit by the sky through the roof of the world
// and a wall gets the horizon's mix, which is the hemisphere ambient of
// docs/pbr-plan.md's "The macro scale". Set beside goanna_sky_fill.
global uniform vec3 goanna_ground_fill;
uniform float sky_fill_strength : hint_range(0.0, 2.0) = 1.0;

// Cloud shadows, from the same field the sky draws: offset.xy is the deck's
// scroll, z the coverage, w the strength, which main.gd scales with the sun
// so the night has none. goanna_cloud_geom carries the noise scale, the
// deck's absolute height and the sun's xz parallax per unit of height, so a
// shadow lies where the cloud between this point and the sun actually is,
// and drifts with the deck. The threshold is wider than the sky's own
// (0.34 against 0.16), so the shadow of a soft cloud is a soft dimming
// rather than a plate with the cloud's outline.
global uniform vec4 goanna_cloud_shadow;
global uniform vec4 goanna_cloud_geom;

float goanna_cloud_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float goanna_cloud_vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = goanna_cloud_hash(i), b = goanna_cloud_hash(i + vec2(1, 0));
	float c = goanna_cloud_hash(i + vec2(0, 1)), d = goanna_cloud_hash(i + vec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// The sky's fbm, same octaves and same lacunarity, or the shadow and the
// cloud part company.
float goanna_cloud_fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * goanna_cloud_vnoise(p);
		p = p * 2.03 + vec2(7.3, 1.7);
		a *= 0.5;
	}
	return v / 0.9375;
}

float goanna_cloud_dim(vec3 world) {
	float strength = goanna_cloud_shadow.w;
	if (strength <= 0.002)
		return 1.0;
	vec2 par = goanna_cloud_geom.zw * max(goanna_cloud_geom.y - world.y, 0.0);
	vec2 uv = (world.xz + par) * goanna_cloud_geom.x + goanna_cloud_shadow.xy;
	float n = goanna_cloud_fbm(uv);
	float cov = smoothstep(1.0 - goanna_cloud_shadow.z - 0.06, 1.0 - goanna_cloud_shadow.z + 0.28, n);
	return 1.0 - cov * strength;
}
// Block light as emission. Off by default: Goanna already places real Godot
// lights for light emitting nodes, so adding it here would count torches
// twice. The far tiers, which are past the range those lights reach, turn it
// on; see docs/far-rendering.md.
uniform float block_light_emission : hint_range(0.0, 4.0) = 0.0;

// Paints the three channels straight onto the screen as emission: red block
// light, green sky light, blue occlusion. It answers "is this data arriving at
// all", which no amount of looking at a lit frame can, and it is a channel
// rather than a define so it can be toggled inside one run.
uniform float debug_nodelight_strength : hint_range(0.0, 1.0) = 0.0;

// Staleness: CUSTOM0.a is 255 on a live block and lower on one the far
// tiers drew from the local store (docs/far-rendering.md, "Staleness"),
// and the shader can pull such surfaces toward grey by this much. Off by
// default: a grey far field is a per tier signal painted into the frame,
// and the far field is judged by there being none (docs/launch-target.md,
// "one light, one air"). The channel stays so the signal can be turned on
// to see what is remembered rather than seen.
uniform float stale_strength : hint_range(0.0, 1.0) = 0.0;

// Far tiers only (docs/far-rendering.md, "Shade the far field as a far
// field"): a region quad's UV still repeats once per node, which is right up
// close where a tile is a tile's width away, but a merged quad can span a
// couple of hundred nodes, and at that scale the repeat aliases into a
// shimmer no amount of ordinary mipmapping fixes without anisotropic
// filtering, which this sampler does not have. Past lod_flatten_near the
// sampled colour blends toward the tile's own average, reaching it fully by
// lod_flatten_far, so a quad reads as one surface rather than a repeating
// pattern at the range it is actually seen from. False, and the array below
// empty, on every material the near mesh builds: it never draws far enough
// for the blend to be visible, but leaving the flag off rather than trusting
// distance alone keeps that an explicit fact about the material instead of a
// hope about where the camera can reach.
uniform bool lod_flatten = false;
// One entry per array layer, that layer's average colour
// (GoannaTextureSource::getTextureAverageColor, the same value the no-array
// fallback material already paints with), set once when a LOD material is
// built. 256 is the array layer cap (getArrayTextureMax in node_visuals.cpp).
uniform vec3 lod_avg_colour[256];
// What fraction of each layer's tile the near mesh's alpha test keeps, from
// GoannaTextureSource::textureCoverage. 1.0 for an ordinary opaque tile.
//
// A far tier draws an alpha tested node (leaves above all) as a solid box of
// its tile, where the near mesh draws faces you see through to shadow behind.
// The same canopy therefore integrates brighter and more saturated at range,
// which is the trees changing colour as they cross the tier boundary. Scaling
// the far albedo by coverage is the cheap half of the right answer: what is
// behind the gaps is treated as dark, which is true of a canopy over ground
// and wrong for a lone tree against the sky, so it is a strength rather than
// a flat multiply. Same 256 layer cap as lod_avg_colour.
uniform float lod_coverage[256];
uniform float lod_coverage_strength : hint_range(0.0, 1.0) = 1.0;
// Keep the hand-off range visually identical to the near renderer. Detail is
// only flattened once fog and screen footprint make an individual tile too
// small to read. These are camera distances, not distances from world zero.
uniform float lod_flatten_near : hint_range(0.0, 2048.0) = 384.0;
uniform float lod_flatten_far : hint_range(0.0, 4096.0) = 1024.0;

// Goanna: the material class the classifier voted for each array layer
// (src/goanna_materials.h, MaterialClass: 1 stone, 2 wood, 3 leaves, 4 glass,
// 5 sand, 6 gravel, 7 snow, 8 ice, 9 soil, 10 metal, 11 cloth, 0 none), so a
// treatment can be chosen by what a surface is rather than by which pack
// dressed it. Same 256 layer cap as lod_avg_colour.
uniform int layer_class[256];
// How much of each layer's variance sits in big shapes rather than grain
// (GoannaTextureSource::textureCoarseness). A tile whose point is a few
// large shapes in known places is a picture rather than a field: shifting it
// wraps those shapes around the tile edge and cuts them in half.
//
// This only catches the loudest cases and does not pretend otherwise. The
// measured share for Mineclonia's grain tiles tops out at 0.200 for sand,
// while the worst ores run 0.36 to 0.65, so a threshold above sand can only
// help and can never take the treatment away from a field. Plenty of ores
// sit below it: three statistics were tried against these tiles and none
// separates ore from grain, because what makes a lone ore look wrong is that
// it is alone, which is a fact about the world and not about its texture.
// The real rule wants the mesher to say how far the same node runs.
uniform float layer_coarse[256];
uniform float detail_max_coarse : hint_range(0.0, 1.0) = 0.35;
// Surface detail: how much of the per class treatment runs. 0 is the plain
// single sample this shader has always done, which is what the far tiers and
// modest hardware want; the Material tab drives it as mat_detail.
uniform float detail_strength : hint_range(0.0, 2.0) = 1.0;
// How hard the three cell weights are pushed toward the nearest one. High
// values keep pixel art crisp and take one texture read instead of three
// over most of the screen; low values cross fade and blur.
// Whether a node may also turn its tile by a right angle, as well as shift
// it. Off by default, and it is a look decision rather than a tuning one:
// on an isotropic texture like stone or gravel a turn adds variety for
// nothing, but sand's ripple runs in one direction on purpose, and turning
// it per node reads as a woven quilt rather than as a dune.
uniform float detail_turn : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_nodelight;
varying float v_stale;
varying vec3 v_world;
varying vec3 v_wnormal;

// Goanna: per node tiling, so a field of sand or a cliff face stops being
// the same sixteen pixels repeated to the horizon.
//
// This started as Mikkelsen's stochastic hex tiling, a virtual triangle grid
// over world space with three shifted copies of the tile blended by
// barycentric weight. That method is built for photographed materials laid
// continuously over a surface, and this is not that. Two attempts showed
// why. Shifted copies alone left every cell the same way up, so the cell
// borders all lay on the grid's own axes and the eye joined them into a
// diagonal weave. Turning each cell to break the alignment made neighbouring
// cells differ far more, so every border became a hard edge and the grid
// itself appeared, as triangles.
//
// The grid was the mistake. Voxel art already has a grid, and its seams are
// already visible: every node face draws one whole tile, with a hard edge at
// every node boundary, which is the look the art is drawn for. So randomise
// per node face instead. A shift and a quarter turn chosen from the node's
// own coordinate puts a different part of the tile on every node, and puts
// every discontinuity exactly where the art already has one. No new seam is
// created anywhere, which is why this needs no blending, no weights and no
// contrast restoration, and costs one texture read rather than three.
//
// Whole texels and right angles only: the tile's own pixel grid then lands
// back on the pixel grid, where a fractional shift or an arbitrary angle
// would resample pixel art into mush.
vec2 goanna_cell_hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

// A quarter turn, chosen from a second hash of the same node so the turn and
// the shift do not agree with each other.
vec2 goanna_cell_turn(vec2 uv, vec2 cell) {
	float h = fract(sin(dot(cell, vec2(74.7, 219.3))) * 21793.13);
	int q = int(floor(h * 4.0));
	if (q == 1)
		return vec2(uv.y, -uv.x);
	if (q == 2)
		return -uv;
	if (q == 3)
		return vec2(-uv.y, uv.x);
	return uv;
}

// Which node this fragment is on. A face lies half a node out from its own
// centre along its normal, so step back along the normal to get there. All
// six faces of one node then agree, which is the difference between a block
// that reads as a block and a collage: keyed on the face's own plane
// instead, the top of a block and its side drew different parts of the tile
// and every stair step in a cave came apart.
vec3 goanna_node_of(vec3 world, vec3 wnormal) {
	return floor(world - 0.5 * wnormal + 0.5);
}

// Two numbers from a node coordinate, and one more for the turn.
vec2 goanna_node_hash(vec3 n) {
	vec3 p = vec3(dot(n, vec3(127.1, 311.7, 74.7)),
			dot(n, vec3(269.5, 183.3, 246.1)),
			dot(n, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p.xy) * 43758.5453);
}

// The coordinate to read the tile at: this node's own turn and shift. The
// derivatives stay the caller's, taken from the untouched UV, because the
// offset is a step at every node boundary and an implicit derivative across
// one would pick a mip level for a jump that is not really there.
vec2 goanna_node_uv(vec2 uv, vec3 node, float texels, float turn) {
	vec2 t = turn > 0.5 ? goanna_cell_turn(uv, node.xz + node.y) : uv;
	return t + floor(goanna_node_hash(node) * texels) / texels;
}

// The surface coordinate a treatment runs in: world space, on the plane the
// face actually faces, so two nodes side by side continue one pattern and a
// far tier's merged quad lands on the same pattern the near mesh drew. Every
// treatment has to be a function of this and the class alone, or the near
// mesh and the far field will disagree at the seam by construction.
vec2 goanna_surface_uv(vec3 world, vec3 wnormal) {
	vec3 a = abs(wnormal);
	if (a.y >= a.x && a.y >= a.z)
		return world.xz;
	if (a.x >= a.z)
		return world.zy;
	return world.xy;
}

// Which classes want stochastic tiling. Wood and brickwork are ruled out by
// the method itself, whose author warns that parallel lines distort; glass,
// metal and cloth are man made and are meant to repeat.
bool goanna_class_is_granular(int cls) {
	return cls == 1 || cls == 5 || cls == 6 || cls == 7 || cls == 9;
}
