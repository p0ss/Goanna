# Fire material

Flames have a material of their own. Until 2026-10-05 they were drawn as
any glowing tile: a cut-out with emission from its bright texels, which
showed hard pixel edges, cast a sun shadow of itself, and had one flat
brightness from base to tip. The game's own animated art is still the
flame. Goanna swaps the frame a vanilla client shows and only changes how
each texel is drawn.

## What is a flame

`src/goanna_flame.h` decides, from the node definitions the server sends,
never from a list of games:

- every tile of a node with the `firelike` drawtype;
- an animated tile of a glowing (`light_source` above 0) mesh, plantlike
  or nodebox node whose first image is named with the word `fire`,
  `flame` or `flames`;
- an upright sprite entity whose texture is named that way.

The word is a whole word between underscores, so `campfires`, `firefly`
and `fireworks` do not count. The animation and shape requirements keep
out fire coral, Ethereal's fire flower, Caverealms' fire vine and Kythen's
lamp faces, which are still images or cube faces. A torch is not a flame
here: its tile is the stick as well as the flame.

Checked against the node definition dumps of 2026-09-29
(`goanna_audit/w_*/matdump.json`), and in `src/goanna_flame_test.cpp`:

| Game | Taken | Needs nothing else |
| --- | --- | --- |
| Minetest Game | `fire:basic_flame`, `fire:permanent_flame` (firelike) | It has no campfire, candle or burning entity |
| Mineclonia | fire, eternal fire, soul fire (firelike); both campfires' flame tile; lit candles and candle cakes; the burning entity sprite | |
| VoxeLibre | fire, eternal fire, soul fire; both campfires; the burning entity (glow -1, still taken) | It has no candles |
| Asuna | MTG fire; Everness' three permanent flames (firelike); x_farming candles; Everness' candle skull and forsaken fire; Caverealms' constant flame (plantlike) | |
| Kythen | nothing | Its qulliq lamp's flame is a cube face and stays as it was |

Only Mineclonia was looked at in a running client. The rest is the rule
applied to the dumps.

A Mineclonia candle or campfire flame is a culled mesh tile, which Goanna
would otherwise draw from its animation array. A flame keeps its single
image instead (`GoannaClient::keyForIrr`), whose frames are swapped as
upstream swaps them, so it can take this material.

## How it is drawn

`project/shaders/flame.gdshader`, with `flame_glow.gdshader` as its next
pass; both share `flame_common.gdshaderinc`.

- **Edges.** The flame is blended, not cut out. Inside it every texel is
  whole, so close up it is still the art's pixels. Each texel on the edge
  fades over its outer half, from four reads of the base level. Once a
  texel is smaller than a pixel the mip's own alpha takes over.
- **Heat.** Each texel's heat is its own brightness against the art's
  luminance range, cooling towards the top of the frame. Hot texels are
  pulled towards a whitened core colour and brightened up to 2.8 times;
  cool ones towards the tip colour and dimmed. The core and tip colours
  are the mean of the brightest sixth and darkest quarter of the art's
  opaque texels over all its frames (`measureFlameRamp`). Soul fire's art
  is cyan, so it ramps from deep teal to pale cyan without being named.
  The hot core is nearly opaque and the tips let a third of what is behind
  them through.
- **Animation.** The game's frames and their timing are untouched. A
  flicker of three waves travelling up the flame modulates brightness and
  heat between frames, larger at the tips, with a phase per node. It runs
  on the node animation clock in whole cycles a minute, so it does not
  jump when the clock wraps, and pinning the clock pins it.
- **Halo.** The glow pass adds the core colour where a coarser mip of the
  art's alpha reaches past the sharp edge.
- **Shimmer.** The glow pass adds the difference between the opaque scene
  at a displaced point and at the pixel, over the flame and above it. A
  firelike quad's top edge is raised 0.6 nodes in that pass, with its
  texture coordinate, to make room above the flame. The bend is a few
  pixels at two nodes and fades out by 24. It is off on Lowest and Low
  (`render_fire_shimmer`, [render feature switches](render-feature-switches.md)).

Godot's screen texture is taken before the blended pass, so it holds no
water and no glass. Drawing it would cut a window through a lake behind a
fire. Added as a difference, the water or glass behind keeps its colour and
only the opaque detail through it wavers.

## Fitting in

- **Lighting.** The flame is unshaded. The light it casts is still the node
  lamp's, with its own flicker (`update_lights`), which this does not
  touch. The two flickers are not in step.
- **Shadows and depth.** Flames write no depth and cast no shadow, so the
  depth prepass, SSAO and the shadow maps do not see them. The cut-out
  flame used to cast a sun shadow of itself.
- **Fog and water.** Godot's fog applies to the flame pass as to any blended
  surface. Seen from under water, both passes take the water's absorption
  (`underwater.gdshaderinc`); the glow pass, which has Godot's fog off, also
  takes the fog's share.
- **Sorting.** Flames go on a mesh instance of their own under each block
  (`flames`), never into regional batches, so they sort by their own bounds
  rather than the whole block's water and glass. Within a frame, Godot still
  sorts blended instances by their centres; see Limits.
- **Micro shadows, parallax.** Neither touches a flame. The netherrack
  under a fire keeps its own.
- **SDFGI.** The cut-out flame fed its emission to SDFGI on Medium and
  above. A blended, unshaded surface does not; the lamp still lights the
  surroundings.

`GoannaClient.set_flame_material(false)`, or `GOANNA_FLAME_MATERIAL=0` at
launch, draws flames the old way, for comparison.

## Review

Not yet seen running. As of 2026-10-06 the material is built and its
routing tested, but no frame of it has been drawn: the GPU was in use by
other clients for the whole attempt, and the shaders have not been
compiled by a renderer. Until a review is recorded here, assume a shader
error is possible. `GOANNA_FLAME_MATERIAL=0` falls back to the old flame.

What has been run, with the 2026-10-05 build:

- `cmake --build build --target goanna_flame_test && build/goanna_flame_test`:
  the recognition rule on the names in the def dumps, passed.
- `project/tests/graphics_profiles.gd` and `project/tests/render_features.gd`,
  headless with a scratch profile, passed with the new gate.

The review to run is
[docs/perf/fire-shader-2026-10-05](perf/fire-shader-2026-10-05/README.md):
a Mineclonia fixture with a campfire, fire on netherrack, soul fire, a lit
candle, a burning zombie, fire in front of water, fire behind and beside
glass, and a nine by nine field of fire for the cost, old against new by
day and at night.

## Limits

- The halo and shimmer are a second pass over every flame quad. At Lowest
  and Low the halo is still drawn and the screen is not read, but the
  material still declares the screen texture, so Godot copies the screen
  whenever a flame is in view, as it does for water and glass.
- A firelike node is four quads, so the shimmer behind one is added up to
  four times, each with its own waves.
- Embers were not added.
- Godot sorts blended mesh instances by the centre of their bounds. A flame
  and a large water or glass instance that overlap on screen can still be
  drawn in the wrong order; see the review for what was seen.
- Kythen's qulliq flame, a cube face, is not recognised.
