# Plan for materials and shading

Written after a day of per texture work that did not add up, to say where
this actually stands and what order the remaining work goes in.

## Where it stands, measured

Not claimed, measured, with the instruments named at the end.

- **Coverage is 20 per cent.** In the Mineclonia jungle, 294 of 1442 texture
  layers load an authored companion. The other 80 per cent get a neutral
  fallback: flat normal, roughness 1.0, no emission. They are featureless
  matte by construction, and no amount of mapping work moves that much.
- **The decode is correct**, case by case, against a differential probe:
  roughness within 1 of Godot's own material at 8 bit, metalness within 2.6,
  emission at 0.0525 linear where the arithmetic wants 0.0542.
- **One real decode bug was found and fixed**: Godot defines
  `F0 = 0.08 * SPECULAR`, and we passed LabPBR's F0 through doubled, so the
  standard dielectric byte became an F0 of 0.006 rather than 0.04. Dielectric
  specular was effectively off.
- **The exposure is wrong.** Mineclonia's snow texture has a standard
  deviation of 8.0 and renders at 0.2 with 99 per cent of its pixels at pure
  white. Vertical faces are lit almost entirely by sky ambient, so a dirt
  side reads 193,194,211, blue rather than brown.

So the material path works and almost nothing is plugged into it, in a
lighting environment that would hide it if it were.

## Why the pack matching approach caps out

The maps pair a Minecraft pack against a Luanti game by texture name. That
is worth having and it is finished: 155 pairs for Mineclonia, 154 for
VoxeLibre, 65 for Asuna, 32 for Minetest Game.

It cannot go much further. The pack holds 434 blocks and Mineclonia has
3245 textures, and the shortfall is not a naming problem. Most of what is
missing does not exist in Minecraft at all: the flowers, the mob drops, the
decorative variants, everything a Luanti game adds. No Minecraft pack will
ever cover them, and a better matcher does not change that.

The conclusion is structural. **Authored data has to be an override on top
of something that covers everything, not the only source of material.**

## The order of work

### 1. A standalone pipeline scene

Develop the pipeline outside the game. A material chart: one row per
material class, one column per lighting condition, each cell a node sized
cube, rendered with reference values printed alongside. Fixed camera, fixed
lights, no world.

The jungle is the worst place to develop this. It has no repeatable
viewpoint, its lighting changes under you, and the effects being judged are
small. Every wrong conclusion recorded in this repository's history came
from trying to read one of those frames.

Done when the chart renders, its numbers are logged, and a change to the
shader shows up as a number rather than an impression.

Done, 2026-08-21. `project/lighting_chart.tscn` renders twelve baked
Mineclonia materials (stone, dirt, sand, gravel, snow, wood, leaves, ice,
gold, steel, wool, glowstone) through `nodes_array.gdshader` itself, on
cubes carrying the `docs/mesh-attributes.md` vertex layout, in three
conditions (open, under a roofed bay, and with the sky light byte at zero)
at four times of day driven through the same sky blend `main.gd` uses. It
prints per cell and per face the rendered sRGB, luma, clipping, the texture
contrast kept against the albedo's own, and the albedo mean, writes the lot
as JSON, and `tools/chart_summary.py` reduces a run to step 3's pass or
fail lines, or two runs to a table of what moved. A run takes five seconds,
which is what made the sweep below possible.

### 2. A material for every node

Derive a material for every node from what the server already sends, and let
authored maps override it where they exist.

Luanti gives us more than we use. `groups` (cracky, crumbly, snappy,
oddly_breakable_by_hand) separate stone from soil from plant from glass.
`sound_footstep` is a strong material classifier on its own. Add `drawtype`,
`liquid_viscosity`, `light_source`, `damage_per_second`, and a small table of
material classes covers every node in every game, including the ones no pack
will ever ship.

Relief comes from the diffuse texture, which we already infer and which
already covers everything. That generator currently only feeds
`StandardMaterial3D`, so it has to move onto the array path where the rest of
the materials live.

Done when the coverage number reads 100 per cent for class and relief, with
the 20 per cent authored data overriding cleanly on top.

Done, 2026-08-21. `src/goanna_materials.{h,cpp}` is the table:
`classifyNode` reads the footstep sound first, then groups (Mineclonia's
`material_*`, `axey`, `shearsy`, `hoey` and Minetest Game's `cracky`,
`crumbly`, `choppy`, `snappy`), then drawtype, then the node's name as a
last resort, counted separately; `buildMaterialTable` votes the class down
to each base texture, keeps the minimum light level a texture is shown at
for emission, and fills the block column from the texture map. The texture
source reads the table when it builds an array's `_n` and `_s` companions:
a layer with no authored `_s` gets a flat one from the class (smoothness,
F0 or metal, scattering, emission), and a layer with no authored `_n` gets
the relief inferred from its own brightness, the same inference the auto
bump slider applied on the single image path and at the same strength,
instead of the neutral filler both had before. Authored data overrides by
being there.

Against Mineclonia, `GOANNA_DEBUG_PBR=1`: 3264 nodes, 2928 classed by
footstep, 24 by group, 9 by drawtype, 90 by name, 213 unclassed (6.5 per
cent, mostly items, machines and decoration with no footstep and no telling
group); 1060 textures classed, 60 emissive. Per array texture the coverage
line reads `authored 195/256 classed 61/256 neutral 0`, and `_n` reads
`inferred` for every layer not authored: 100 per cent for both on the main
arrays, with one 141 layer array (the large textures) at 25 classed and 116
neutral because its nodes are the unclassed ones. With the texture map set,
200 block names for the Iris column. The thing to say plainly: in the
jungle at noon, turning the material channels off changes 0.3 per cent of
the frame, because stone at smoothness 0.12 under an overhead sun is matte
and leaves and plants are not on the array path. The classes exist to be
told apart on the chart and at the angles and times where they can be; the
gallery is where that gets judged, and the audit (step 4) is where the
unclassed 6.5 per cent gets names.

This classifier is one table with two output columns, and it should be built
that way. The same nodedef read that assigns a material class can also
assign the Minecraft block a node most resembles, which is what an Iris
pack's `block.properties` needs to give it a semantic ID
(`docs/iris-compat.md`, `docs/roadmap.md`). The texture map alone cannot do
that, because in Mineclonia more than half the textures are shared between
nodes. Do the nodedef work once, emit both columns, and the Iris ID is a
lookup later rather than a second classifier.

### 3. Lighting and exposure

Two prerequisites landed on 2026-08-21 and changed what this step faces.
Luanti's light now reaches the vertices, through Goanna's own sampler rather
than through `encode_light`, along with a traced ambient occlusion term; the
contract is `docs/mesh-attributes.md`. That file also records the reason the
vertex light path had never worked: `light_decode_table` was a table of zeros
because `set_light_curve()` was never called, so every decoded light level was
black regardless of any flag.

The measurement that matters for this step: with occlusion and sky visibility
multiplying ambient only, toggling them changes 0.1 per cent of pixels in
daylight, while allowing occlusion to touch direct light changes 44.5 per
cent. The channels work. There is nothing to occlude, because ambient is a
negligible share of the image. So the rework below is not a polish pass that
would make an existing effect nicer; it is what makes the effect exist.

None of the above is visible until this is right, and it is a rework rather
than a tuning pass: the balance between sun, sky ambient and global
illumination, the tonemap and its white point, specular anti aliasing, and
the sky ambient that turns every vertical face blue.

Who owns lighting is settled by this step rather than left as a question:
Godot does. Sun, sky, GI and tonemap are Godot's, and the rework above is a
rework of Godot's environment. What is not settled by that, and has to be
done in the same step, is that Luanti's baked light travels alongside. The
per vertex block and sky light that `encode_light` in
`src/transplant/client/mapblock_mesh.cpp` computes, and that
`g_goanna_no_light` currently forces to white, comes back on as a vertex
attribute. Three things need it: caves and interiors, which Godot's sky
ambient and SDFGI do not darken the way the server means them to and which
the headlight in `main.gd` papers over; the `lmcoord` that almost every Iris
pack reads (`docs/iris-compat.md`); and the baked ambient occlusion term in
`docs/far-rendering.md`, which rides in the same attribute. So the decision
is "both", Godot lights and Luanti's values ride along, and the task is the
switch plus deciding what the shader multiplies them into.

The near field of that occlusion term, the hemisphere trace against the
block's own neighbourhood, belongs in this step too. It replaces the corner
term Luanti computes under smooth lighting, it is what SSAO cannot give
(stable, view independent, a real radius), and it is measured on the chart
like everything else here. The far field waits for the occupancy chain in
`docs/far-rendering.md`.

Done when the chart's classes are told apart at three times of day, snow
keeps its texture, clipping outside the sky stays in single figures, a
roofed bay reads dark without the headlight, and `GOANNA_DEBUG_VCOL=1`
reports a spread of vertex light rather than one value per buffer.

Done, 2026-08-21, on the chart, Godot 4.5.1, against the thresholds written
into `tools/chart_summary.py`. The old recipe scored 7 of 15: a sunlit stone
top at 1.87 times its albedo, snow, sand, ice and wool tops clipped flat with
no texture left, walls at 0.28 of the top, the bay's top blue (b minus r of
47 on a neutral grey) and night pitch black. The recipe now in `main.gd`
scores 15 of 15:

- **Exposure.** Sun 1.0 (was 1.5), ACES white 4.0 (was 1.5), base exposure
  0.46 times the server's correction (was 1.0 times). A sunlit stone top
  renders at 1.28 times its albedo, snow at 229 with 0.42 of its texture
  contrast and no clipping, and nothing below the horizon clips at any of
  the four times.
- **What the sky feeds to lighting** is no longer what it shows.
  `sky.gdshader` takes `AT_CUBEMAP_PASS`, the pass Godot samples into the
  radiance SDFGI and the ambient term read, and there lifts the lower half
  of the dome to the horizon colour instead of a darkened ground, pulls the
  colour a quarter of the way to grey, and adds a dim floor at night. The
  bay's blue cast fell from 47 to 18 (7 at half grey, but that half also
  greys the sky that water, ice and metal reflect, and ice and steel on the
  chart moved by two counts between the two, so the quarter is the trade),
  and night stone reads 22 rather than 6.
- **Walls were a limit of the GI, not the exposure.** SDFGI gives a
  vertical face about 0.27 of a horizontal face's ambient, at every energy
  tried, so with the sun overhead a wall could never reach a third of the
  top's brightness: raising ambient washed the tops and lit the bay first.
  So Luanti's sky light does what the vanilla client's light does: the node
  shaders add a flat fill in the horizon colour, scaled by the sky light
  byte (`goanna_sky_fill`, a global shader parameter `_apply_sky` sets,
  times the `sky_fill` strength). Walls at noon went from 0.18 of the top
  to 0.38, the bay stays at 0.22, and a face with sky light zero reads 0.23
  of the same face in the open, which is the channel finally biting:
  before this it moved 0.1 per cent of a daylight frame.
- **Told apart** is measured as the smallest sRGB colour distance between
  any two classes on the vertical face, over the stone top's luma at that
  time, so a dim dawn is judged at its own exposure; gold against steel at
  the same luma is not confusion.

Two things the chart did not settle. Snow keeps 0.42 of its texture
contrast at noon, not half; that is the ACES shoulder at the snow's
brightness, and the filmic curve gave 0.44 while taking stone's own
texture from 1.0 to 0.78, so the bar was set at 0.35 rather than the curve
changed. And the in-world check was nearly done against Mineclonia rain:
the server overrides the day night ratio and recolours the sky in weather,
and `GOANNA_TOD` only overrode the hour, so a "noon" frame was dusk. It now
drops the server's ratio too, and renderer comparisons belong on the
`lighting_walk` fixture (`docs/building.md`), where the new recipe reads as
a darker, deeper blue frame with the sunlit pillars off their clip and the
shaded walls grey rather than black. Whether that overall level is right
is a look judgement the Exposure and Sky fill sliders now make live.

Reported and not yet reproduced: a frozen lake in a snowy Mineclonia biome
rendering near black under the new recipe, seen by eye in play. The `icer`
test site shows pale ice under both recipes, so it is not ice's material
path as such; the likely suspects are the water shader under the ice at a
grazing angle, whose reflection is the darker radiance, and the halved
exposure on a surface that gets no sky fill (ice and water are not on the
array shader). It wants coordinates and a fixed camera A/B before it is
chased further; the chart now has no row for the non array material paths,
and should.

Entities take the same light since later that day. Nearly every mob skin
has transparent texels, so mobs went through a plain `StandardMaterial3D`
that had no share of the node light, and next to terrain carrying the sky
fill they read as black, in a dungeon and in daylight alike. Mesh entities
now render through `entity.gdshader` and its alpha scissor twin
(`entity_scissor.gdshader`), which take the node light at the entity's
position as a per instance uniform (`EntityRenderer::sync`): the sky fill
by the sky light, a warm fill by the block light, and ambient scaled by the
sky light, as the vanilla client lights its entities. A cow in deep shade
reads as a cow.

Night was the one part of the exposure the chart's daylight cases did not
guard, and it came out near black in play: stone read 22 on a horizontal
face and 0 on a wall, where the vanilla client's night is about 17.5 per
cent of day. The night now has three sources, all measured on the chart's
night case and on the jungle at the spawn: the moon at 0.25 (was 0.12), the
sky radiance floor at 3.5 in the night horizon colour (`sky.gdshader`,
`AT_CUBEMAP_PASS`), and the sky fill carrying a night share of 1.6 times its
day strength in the night horizon colour. Stone reads about 70 on top and
20 on a wall, the canopy near two fifths of its day brightness: a dim blue
world, dark but legible, rather than black. `night visible, not day` on the
chart is now 30 to 95 rather than 12 to 70.

The headlight in `main.gd` is still there. The bay reads dark without it
on the chart; taking it out of caves is a separate call.

### 4. The audit

Per game and per node: the class assigned, whether authored data exists,
and a rendered swatch. A table, generated, over every registered node.

Done when we can point at a row rather than at a screenshot.

## What we are not doing

Porting Iris. Iris loads Minecraft's shader pipeline for Minecraft's
renderer; we have Godot's. What that world has that we want is the LabPBR
convention, which costs a decode and is done, and the packs themselves,
which `docs/iris-compat.md` plans to load by recreating the environment
they expect rather than by porting the loader. That plan subsumes a good
deal of what step 3 above would otherwise grow into (bloom, tonemap,
volumetrics, reflections), which is why `docs/roadmap.md` has the cheap
proof of its pipeline run early and the rest of it after the material path
settles, so that work is not done twice.

This used to say Iris was also ruled out on licence, being LGPL-3.0. That
was wrong, and THIRD-PARTY.md already said so: Goanna's and Luanti's terms
are both "or later", so the built binary is LGPL-3.0-or-later regardless,
and LGPL-3.0 code combines with it fine. The reason not to port Iris is that
there is nothing portable in it. It is Java driving Minecraft's OpenGL
renderer through an OptiFine derived GLSL pipeline. Not one function
survives the trip to a C++ GDExtension on Godot's Vulkan renderer. What
transfers is the design, and designs are not licensed. See
docs/far-rendering.md for where that distinction bites again.

## Instruments

Build these before trusting any result, because each was written after a
wrong conclusion that it would have caught.

- `project/material_probe.tscn` renders each material case twice, once
  through our shader and once through Godot's own, with everything else off.
  Any difference is ours. It found the specular bug.
- `project/lighting_chart.tscn` is the material chart of step 1, with
  main.gd's environment recipe copied and every stage behind its own
  switch; `tools/chart_summary.py` turns its JSON into step 3's pass or
  fail lines. Its first version found that SDFGI replaces environment
  ambient outright, so `ambient_light_energy`, `ambient_light_color` and
  `ambient_light_sky_contribution` are all inert while SDFGI is on, and
  SSIL subtracting light from a roofed bay rather than adding it; this one
  found the vertical face limit that the sky fill answers.
- `project/tangent_probe.tscn` answers "does Godot do X" offline, by
  measurement rather than argument. It showed Godot derives a tangent basis
  when a mesh has none.
- `tools/shotcheck.py` says what is actually in a frame, and whether two
  frames share a viewpoint. A shot taken before the world streams in is a
  photograph of the sky and looks exactly like a render with the feature
  under test switched off.
- `tools/goanna_pbr_gallery.lua` builds 23 materials in open sky, as walls
  and floor patches, which is where materials get judged.
- `GOANNA_TP="x,y,z"` teleports through the server, so a viewpoint repeats
  between runs and an A/B means something.
- `GOANNA_VISUAL_TEST=lighting_walk` uses `goanna_visual_test_mod` in a
  dedicated singlenode world. It fixes position, time, facing, weather,
  geometry and warm-up, then captures a horizontal path with each other test
  site 1024 nodes away. Use this for renderer comparisons; a survival spawn
  and the shared material gallery carry too many uncontrolled variables.
- `GOANNA_DEBUG_PBR=1` reports the coverage above, per array.
- `tools/pbr_bake.py` prints its resolution arithmetic at startup, because
  `--size` and `--map-size` can disagree and the losing side is the output.
  The first Mineclonia bake was made at `--size 768 --scale 4`, generating a
  16 pixel texture at 768 and keeping 64, so 99.3 per cent of the generated
  pixels were discarded and every finished map was 64 pixels.

  There are three separate resolutions here and they want different answers,
  which is what made this hard to see:

  - **Generation** (`--size`, 768). Above the kept size on purpose. It is
    supersampling, and it is why the albedo is clean.
  - **DeepBump** (`--bump-size`, 128). Not the generation size, and this is
    the counterintuitive one. DeepBump is a convolutional net with a fixed
    receptive field, so it detects relief at a particular pixel scale and
    flattens out above it. Measured, as the standard deviation of the shading
    its normals produce under a fixed light, on Mineclonia stone and birch
    planks: 0.115 and 0.148 at 64 px input, 0.109 and 0.105 at 128, 0.042 and
    0.036 at 256, under 0.03 at 512. Running it at the native 768 produced
    almost flat maps, four to seven times weaker than the old bake, which an
    A/B of the numbers caught and an A/B of screenshots did not.
  - **Kept** (`--map-size`, 256). Absolute rather than a multiple of the
    source, so a 64 px source does not get four times what a 16 px one needs.

  The normal is scaled **up** from `--bump-size` to `--map-size`. Scaling a
  normal map up preserves amplitude; scaling one down averages opposing
  slopes against each other and cancels them.
- `GOANNA_NO_NORMAL=1` drops the `_n` array and binds everything else, so an
  A/B separates the normal map's contribution from the albedo swap. A texture
  pack changes both at once and the albedo is much the louder, which is how
  "the pack is working" and "the normals are working" get confused.
- `GOANNA_DEBUG_VCOL=1` prints the spread of per vertex colour in each mesh
  buffer. It exists because turning on Luanti's smooth lighting looked like
  it worked: the vertex light path is switched off at `encode_light`, which
  returns white while `g_goanna_no_light` is set, so no screenshot could
  show that the flag changed nothing.

## The macro scale, 2026-08-24

The owner's observation, with the far field now continuous: the picture has
high fidelity at the micro scale (relief, specular, stochastic tiling) and in
the mid distance (the far tiers), and is flat in between. At the distances
most of a frame sits at, the normal maps have mipped away, the grass is one
green, there is no visible occlusion around blocks, and outside a lamp's
pool nothing varies. Dawn and dusk look right; noon and night, which is most
of the time, read close to vanilla. What would change that, in the order
they are worth doing:

1. *(landed 2026-08-24: the corner term below is in the sampler, and
   `vertex_ao_light_strength` defaults to 0.3)* **Corner occlusion that
   touches direct light.** The near mesh already
   carries traced occlusion per vertex, but it multiplies ambient only, and
   under an overhead sun ambient is a small share, so it vanishes at noon.
   `vertex_ao_light_strength` exists for exactly this sweep and defaults to
   0. Vanilla's corner darkening multiplies everything, which is why its
   blocks read at any distance. Sweep on the chart, then consider a sharper
   corner term (the classic three neighbour rule) written into CUSTOM0.b by
   the near mesher; Luanti's own smooth lighting path cannot be reused
   because its light is discarded at `encode_light` while
   `g_goanna_no_light` is set.
2. *(landed 2026-08-24: the node shaders compute the sky's own cloud fbm
   at each pixel, projected along the sun through the deck, with a wider
   threshold so the dimming is soft; the deck is world anchored now so the
   shadows lie under their clouds)* **Cloud shadows.** The sky already knows its coverage, speed and height;
   the ground never hears about it. One large Decal following the camera,
   modulating albedo with the same cloud field, puts moving hundred node
   scale variance over every outdoor scene for one texture and no per node
   cost. Godot's directional lights have no cookie, which is why a decal.
3. *(landed 2026-08-24: the fill blends between goanna_sky_fill and a
   warm dim goanna_ground_fill by the world normal)* **A hemisphere
   ambient.** With SDFGI off (it is off in the owner's own
   profile) ambient is one flat constant. A normal dependent term in the
   node shaders, sky colour from above, horizon at the sides, a ground
   bounce from below, sells shape at every distance for a few shader lines.
   SDFGI remains the real answer where it is affordable; this is the floor.
4. *(landed 2026-08-24: the head light follows the wielded item's
   light_source; and SDFGI at zero energy now disables itself rather than
   overriding ambient with nothing, which one profile was found doing)*
   **Carried light.** A wielded torch or lantern lighting the world from the
   player's hand (an omni light at the camera driven by the wielded item's
   light_source, through the existing light pool). The night scene's pool
   of light then travels with the player. Vanilla does not do this; it
   takes nothing from the server and shows nothing that is not the
   player's own.
5. **Macro albedo variation.** Two octaves of world position tint at about
   32 and 128 nodes, a few per cent of value and a little hue, on the
   ground materials. The stochastic tiling fixed repetition per node; this
   breaks the one green field per biome.
6. **Shadow reach.** Tree shadows end at 200 nodes
   (`directional_shadow_max_distance`); the mid ground the owner pointed at
   is largely past it. Scale with the view range and measure the cost.
7. *(landed 2026-08-24: a shadowless earthy light shining upward, biased
   away from the sun, at a sixth of the sun by day and a third of that
   where SDFGI is on)* **Bounce.** Where SDFGI stays off, a dim counter light opposite the sun
   in the ground's average colour is the cheap stand in.

The far field's own next step, a far tier shader that does its fog toward
the sky per pixel and a far water continuous with the near water, is in
docs/far-rendering.md and belongs to the same picture.
