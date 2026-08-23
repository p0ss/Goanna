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
// How much occlusion is allowed to touch direct light. Occlusion is not
// shadow, so this is 0 by default and exists to be swept, not to be turned up.
uniform float vertex_ao_light_strength : hint_range(0.0, 1.0) = 0.0;
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
uniform float sky_fill_strength : hint_range(0.0, 2.0) = 1.0;
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
uniform float lod_flatten_near : hint_range(0.0, 2048.0) = 64.0;
uniform float lod_flatten_far : hint_range(0.0, 4096.0) = 256.0;
// How many times the tile repeats across the widest quad this region's
// mesher actually built (GoannaClient::lodBuildRegion, from
// LodRegionMesh::max_span), in nodes. Distance alone missed a panel drawn
// close to the camera where the server has not streamed a block but the
// store or a summary has: it is a single wide merged quad, so the tile still
// visibly repeats at point blank range. A quad this wide reads as a pattern
// on its own, independent of how far away it is, so it gets its own
// threshold below rather than sharing lod_flatten_near/far: those are tuned
// for when ordinary aliasing starts at range, and a merge only a few tens of
// nodes across already shows as a repeat once it fills much of the view up
// close, well inside where the distance test would ever fire.
instance uniform float lod_repeat : hint_range(0.0, 4096.0) = 0.0;
uniform float lod_repeat_near : hint_range(0.0, 512.0) = 16.0;
uniform float lod_repeat_far : hint_range(0.0, 1024.0) = 64.0;

// Fade in, per instance: a region mesh or a block that has just appeared
// is drawn through a screen space dither that opens over a fraction of a
// second (GoannaClient advances it), so terrain arriving at the horizon no
// longer pops in as a wall. Opaque geometry cannot blend, so it dithers;
// at 1.0 the test compiles away to nothing visible.
instance uniform float fade : hint_range(0.0, 1.0) = 1.0;

// Goanna: the material class the classifier voted for each array layer
// (src/goanna_materials.h, MaterialClass: 1 stone, 2 wood, 3 leaves, 4 glass,
// 5 sand, 6 gravel, 7 snow, 8 ice, 9 soil, 10 metal, 11 cloth, 0 none), so a
// treatment can be chosen by what a surface is rather than by which pack
// dressed it. Same 256 layer cap as lod_avg_colour.
uniform int layer_class[256];
// Surface detail: how much of the per class treatment runs. 0 is the plain
// single sample this shader has always done, which is what the far tiers and
// modest hardware want; the Material tab drives it as mat_detail.
uniform float detail_strength : hint_range(0.0, 2.0) = 1.0;
// World units across one cell of the stochastic grid. Below about a node the
// pattern breaks up into noise; well above it the repeat comes back.
uniform float detail_cell : hint_range(0.5, 32.0) = 3.0;
// How hard the three cell weights are pushed toward the nearest one. High
// values keep pixel art crisp and take one texture read instead of three
// over most of the screen; low values cross fade and blur.
uniform float detail_sharpen : hint_range(1.0, 32.0) = 8.0;

varying vec3 v_nodelight;
varying float v_stale;
varying vec3 v_world;
varying vec3 v_wnormal;

// Goanna: stochastic tiling, so a field of sand or a cliff face stops being
// the same sixteen pixels repeated to the horizon. A virtual triangle grid
// laid over world space picks three cells; each cell shifts the tile by its
// own random amount, and the three are blended by their barycentric weights,
// which leaves the mean of the surface exactly what it was. Mean preserving
// matters here beyond tidiness: the far tiers blend toward each layer's
// average colour, so a treatment that moved the mean would show as a band of
// changed brightness at whatever range it faded out.
//
// After Mikkelsen's practical hex tiling, by way of the Godot adaptation at
// https://godotshaders.com/shader/stochastic-hex-tiling-mikkelsens-adaptation
// (MIT). Two departures, both because this is pixel art rather than a
// photographed material. The offsets are whole texels and there is no random
// rotation, so the tile's own pixel grid still lands on the pixel grid.
// And the weights are sharpened, so all but a narrow band along each cell
// border takes a single sample: pixel art is made of hard edges and a three
// way cross fade turns them to mush. The sharpening pays for itself twice,
// because the single sample case is also one texture read rather than three.
vec2 goanna_cell_hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

// Which triangle of the skewed grid this point falls in, and how near it is
// to each of that triangle's three corners.
void goanna_cell_weights(vec2 p, out vec3 w, out vec2 c1, out vec2 c2, out vec2 c3) {
	p *= 3.464; // 2 sqrt 3, the grid to triangle scale
	vec2 skew = vec2(p.x, p.y * 1.15470054 - p.x * 0.57735027);
	vec2 base = floor(skew);
	vec3 f = vec3(fract(skew), 0.0);
	f.z = 1.0 - f.x - f.y;
	if (f.z > 0.0) {
		w = vec3(f.z, f.y, f.x);
		c1 = base;
		c2 = base + vec2(0.0, 1.0);
		c3 = base + vec2(1.0, 0.0);
	} else {
		w = vec3(-f.z, 1.0 - f.y, 1.0 - f.x);
		c1 = base + vec2(1.0, 1.0);
		c2 = base + vec2(1.0, 0.0);
		c3 = base + vec2(0.0, 1.0);
	}
}

// The tile shifted by whole texels, so the pixel grid is never broken.
vec2 goanna_cell_offset(vec2 cell, float texels) {
	return floor(goanna_cell_hash(cell) * texels) / texels;
}

// A quarter turn per cell, chosen from the same hash. Shifting alone leaves
// every copy of the tile in the same orientation, so whatever direction the
// art runs in runs the same way in every cell, and the eye joins them up
// into the faint diagonal weave that the grid's own axes are laid out on.
// Turning by a right angle breaks that and is the one rotation pixel art can
// take: the texel grid lands back on the texel grid, where an arbitrary
// angle would resample it into mush.
vec2 goanna_cell_turn(vec2 uv, vec2 cell) {
	// A second, unrelated hash of the same cell, so the turn and the shift do
	// not agree with each other.
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

// Which cells this fragment sits between, and how far each shifts the tile.
// Chosen once and then used for every array, because the albedo, the relief
// and the specular of one fragment have to come from the same copy of the
// tile. Shifting only the colour leaves the relief still repeating on the
// node grid and, worse, lighting a pattern that is no longer there: this
// file's own comment on lod_flatten already names that failure, where a
// flattened colour with its relief left alone still shades like the tile.
void goanna_cell_pick(vec2 uv, vec2 hex, float texels, float sharpen,
		out vec3 w, out vec2 u1, out vec2 u2, out vec2 u3) {
	vec2 c1, c2, c3;
	goanna_cell_weights(hex, w, c1, c2, c3);
	w = pow(w, vec3(sharpen));
	w /= (w.x + w.y + w.z);
	// Each cell gets the tile turned and then shifted, and returns a whole
	// coordinate rather than an offset, because a turn is not an offset.
	u1 = goanna_cell_turn(uv, c1) + goanna_cell_offset(c1, texels);
	u2 = goanna_cell_turn(uv, c2) + goanna_cell_offset(c2, texels);
	u3 = goanna_cell_turn(uv, c3) + goanna_cell_offset(c3, texels);
}

// One of these per array, because Godot will not let a single function take
// samplers that differ in filter, repeat or hint, and its preprocessor will
// not take a #define from an included file either. The bodies are the same
// three lines; the sampler is the only difference between them.
//
// The first three cases are the common one: with the weights sharpened, all
// but a narrow band along each cell border wants a single texture read. The
// derivatives are the caller's, taken before any branching, because a
// fragment quad can straddle two array layers and dFdx inside that is not
// defined.
vec4 goanna_cells_albedo(float lyr, vec2 dx, vec2 dy, vec3 w, vec2 u1, vec2 u2, vec2 u3) {
	if (w.x > 0.995) return textureGrad(albedo_array, vec3(u1, lyr), dx, dy);
	if (w.y > 0.995) return textureGrad(albedo_array, vec3(u2, lyr), dx, dy);
	if (w.z > 0.995) return textureGrad(albedo_array, vec3(u3, lyr), dx, dy);
	return w.x * textureGrad(albedo_array, vec3(u1, lyr), dx, dy)
			+ w.y * textureGrad(albedo_array, vec3(u2, lyr), dx, dy)
			+ w.z * textureGrad(albedo_array, vec3(u3, lyr), dx, dy);
}

vec4 goanna_cells_normal(float lyr, vec2 dx, vec2 dy, vec3 w, vec2 u1, vec2 u2, vec2 u3) {
	if (w.x > 0.995) return textureGrad(normal_array, vec3(u1, lyr), dx, dy);
	if (w.y > 0.995) return textureGrad(normal_array, vec3(u2, lyr), dx, dy);
	if (w.z > 0.995) return textureGrad(normal_array, vec3(u3, lyr), dx, dy);
	return w.x * textureGrad(normal_array, vec3(u1, lyr), dx, dy)
			+ w.y * textureGrad(normal_array, vec3(u2, lyr), dx, dy)
			+ w.z * textureGrad(normal_array, vec3(u3, lyr), dx, dy);
}

vec4 goanna_cells_spec(float lyr, vec2 dx, vec2 dy, vec3 w, vec2 u1, vec2 u2, vec2 u3) {
	if (w.x > 0.995) return textureGrad(spec_array, vec3(u1, lyr), dx, dy);
	if (w.y > 0.995) return textureGrad(spec_array, vec3(u2, lyr), dx, dy);
	if (w.z > 0.995) return textureGrad(spec_array, vec3(u3, lyr), dx, dy);
	return w.x * textureGrad(spec_array, vec3(u1, lyr), dx, dy)
			+ w.y * textureGrad(spec_array, vec3(u2, lyr), dx, dy)
			+ w.z * textureGrad(spec_array, vec3(u3, lyr), dx, dy);
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
