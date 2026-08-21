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
- `project/lighting_chart.tscn` renders one stone cube in open sun and one
  dirt wall in a roofed bay, with main.gd's environment recipe copied and
  every stage behind its own switch, and prints what each surface actually
  rendered at. It found that SDFGI replaces environment ambient outright, so
  `ambient_light_energy`, `ambient_light_color` and
  `ambient_light_sky_contribution` are all inert while SDFGI is on, and a
  fix written against the documented sky contribution rule alone changes
  nothing. It also found SSIL subtracting light from that bay rather than
  adding it.
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
