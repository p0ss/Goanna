# Vertex attributes on node meshes

Every mesh Goanna builds from map data carries the same attributes, whether
it came from Luanti's mesher at full detail or from Goanna's own LOD mesher
several hundred nodes away. This file is that contract. It exists because
two pieces of work depend on it and neither can wait for the other:
`docs/pbr-plan.md` step 3 revives Luanti's baked light and adds near field
ambient occlusion, `docs/far-rendering.md` builds the LOD tiers, and
`docs/iris-compat.md` rung 5 translates a pack's `gbuffers_terrain` into the
shader that reads all of it. If the two meshers disagree, a shader pack
lights the near bubble and leaves the horizon flat, which is the failure
`docs/roadmap.md` orders the work to avoid.

Anything not on this list is not carried. Adding to it means changing both
meshers, both node array shaders and the LOD material in the same commit.

## The layout

| Array | Contents | Notes |
| --- | --- | --- |
| `ARRAY_VERTEX` | position in Godot space, nodes, world absolute | z is mirrored against Luanti's |
| `ARRAY_NORMAL` | face normal, z mirrored | |
| `ARRAY_TEX_UV` | tile UV | |
| `ARRAY_TEX_UV2` | `x` array layer index, `y` block semantic ID | see below |
| `ARRAY_COLOR` | tile tint only, never light | grass and foliage colourisation, `param2` colour |
| `ARRAY_CUSTOM0` | `RGBA8_UNORM`: block light, sky light, ambient occlusion, freshness | see below |
| `ARRAY_INDEX` | triangles, Godot winding | |

`ARRAY_CUSTOM0` is declared with
`Mesh::ARRAY_CUSTOM_RGBA8_UNORM << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT` in the
flags argument of `add_surface_from_arrays`, and its data is a
`PackedByteArray` of four bytes per vertex. The shader reads it as `CUSTOM0`,
a `vec4` already scaled to 0 to 1.

## Why light is not in ARRAY_COLOR

Luanti's own mesher multiplies the baked light into the vertex colour and
then multiplies the tile tint into the same channel, so upstream's
`ARRAY_COLOR` is light times tint. Goanna cannot use that, because Godot
lights the world: multiplying Luanti's light into albedo and then lighting
the result gives the light twice, once as a darkening of the surface and
once as illumination.

So the two are separated. `g_goanna_no_light` stays set, which is what makes
`encode_light` return white and leaves `ARRAY_COLOR` holding the tile tint
alone. The light values are sampled separately, by Goanna's own code, from
the same node data Luanti would have read, and put in `CUSTOM0` where the
shader can apply them as light rather than as albedo.

That also settles the question `docs/roadmap.md` used to open with. Godot
owns lighting. Luanti's values ride alongside, and the shader decides what
they mean.

## The four bytes

- **`CUSTOM0.r`, block light.** Luanti's `LIGHTBANK_NIGHT` at the vertex,
  decoded through `decode_light` and averaged over the surrounding nodes.
  This is torches, lava and glowstone: light that exists at night and
  underground. The shader adds it as an ambient floor, which is what makes a
  cave dark and a torch matter, and it is one half of an Iris pack's
  `lmcoord`.
- **`CUSTOM0.g`, sky light.** Luanti's `LIGHTBANK_DAY`, same treatment. How
  much of the sky reaches this vertex, before the time of day is applied.
  The shader scales the sky ambient by it, so an interior stops being lit by
  the sky through its own roof, and since 2026-08-21 also adds a flat fill
  in the sky's colour scaled by it (`goanna_sky_fill`, `pbr-plan.md` step
  3), which is what the vanilla client's own light is and what lifts a wall
  under open sky that Godot's GI leaves near black. The other half of
  `lmcoord`.
- **`CUSTOM0.b`, ambient occlusion.** 1.0 is unoccluded. Goanna's own
  hemisphere trace against node occupancy, described in
  `docs/far-rendering.md`. It multiplies into ambient and never into direct
  sun, which is what separates occlusion from shadow. It replaces the corner
  darkening Luanti computes under smooth lighting, which is why
  `m_smooth_lighting` stays off: that path would bake its own occlusion into
  a channel we do not read.
- **`CUSTOM0.a`, freshness.** 255 on every vertex of a live block. The far
  tiers write 96 on faces of a block drawn from the local store rather than
  received this session (`docs/far-rendering.md`, rung 5), and the shaders
  pull such surfaces toward grey by `stale_strength`, so remembered terrain
  reads as remembered. Values between are unused so far; a second use
  (wetness for weather) would take another byte rather than share this one.

## The block semantic ID

`UV2.y` holds an integer, as a float, naming what kind of thing the surface
is: 0 for unclassified, and otherwise an index into a table Goanna keeps.
`docs/pbr-plan.md` step 2 fills it from the same nodedef read that assigns a
material class, and `docs/iris-compat.md` needs it to answer `mc_Entity.x`,
which is how a shader pack knows that this surface is leaves and should
wave, that one is water and should refract.

Zero is the correct failure. A node with no classification renders
unremarkably rather than wrongly.

`UV2.x` keeps its existing meaning, the layer index into the array texture,
and is 0 on a surface whose material is not an array texture. Every node
surface now carries `UV2` whether or not its material is an array, because
the block ID has to be there either way.

## What the LOD mesher does with it

The same, at lower resolution, which is the whole point.

- Position, normal, UV and array layer: as now, per merged face.
- Tile tint: the representative node's tint, as now.
- Light and occlusion: sampled per cell from the coarse chain rather than
  per node, so a distant hillside still darkens into its valleys and a lit
  window at 400 nodes still reads as lit.
- Block ID: the representative node's, so a pack's waving water and waving
  leaves reach the horizon.

A tier that cannot sample something writes the neutral value, which is 255
for sky light and occlusion and 0 for block light, never anything that
darkens or glows. Block light's neutral differs from the near mesh's because
the far tiers add it as emission, being past the reach of the node light
pool, and 255 there would make every unknown face a lamp. A missing
attribute should look unremarkable.

Sky light's neutral of 255 stays 255 even though the near mesh answers 0 for
a face with every neighbour solid, and the difference is not an
inconsistency. The far mesher never draws a buried face: a top face needs an
unfilled cell in front of it and a side face a shorter one, so a far face
that reaches the fallback has no light record rather than no light. Answering
0 there was tried on 2026-08-22 and put 53 per cent of far vertices at zero
sky light with black patches across the far field
(`docs/far-rendering.md`, "One light, from your feet to the horizon").

## Status, 2026-08-21

Landed: the layout above on Luanti meshed blocks, the sampler
(`src/goanna_light.cpp`), the occlusion tracer and its offline check
(`src/goanna_occlusion.cpp`, `src/goanna_light_test.cpp`), and both node array
shaders reading the channels.

Also landed, later the same day: the LOD tiers (`src/goanna_lod.cpp`) emit
this layout and run the same array shader, so the "what the LOD mesher does
with it" section above is what it does. Light is sampled per cell face from
the air in front of it, occlusion is traced per face against the tier's own
occupancy, and both are quantised to sixteen levels so that faces can merge.
The block semantic ID is filled from the classifier's block column
(`MaterialTable::blockOf`, `src/goanna_materials.h`) on both meshers since
later the same day: for the near mesh from the node a triangle belongs to,
for the far tiers from the cell's representative node. It is an index into
`MaterialTable::block_names`, built from the texture map, 0 where the map
has nothing to say; against Mineclonia with `project/texture_maps/mineclonia.csv`
that is 200 names.

Two things were found by building the instrument first, and both had been
invisible.

**Luanti's light decode table was never initialised.** `light_decode_table` in
`luanti/src/light.cpp` is a static array of zeros that only `set_light_curve()`
fills, and Luanti's own client calls it during startup. Goanna never did, so
`decode_light()` returned 0 for every light level including full sun, and
every path that turns a stored light level into a brightness produced black.
`g_goanna_no_light` discarded the result anyway, so the two faults concealed
each other: this is also why turning on Luanti's smooth lighting could not have
worked even with that flag cleared, which the earlier investigation recorded as
a property of the flag. Found by printing `param1` off the wire (14) beside
what `getLight` and `decode_light` made of the same node (0).
`GoannaSession` now calls `set_light_curve()` when it creates the settings.

**Point sampling along a ray tunnels through thin walls.** The first tracer
stepped at fixed distances and read the floor of a one node deep pit 0.17 too
bright, at every ray count from 8 to 48: rays leaving at a shallow angle
stepped straight over the rim without landing in it. More rays cannot fix a
step size. Walking the grid cell by cell cannot miss a cell, and is also
cheaper: worst error against the dense reference fell from 0.167 to 0.014 at
24 rays, and the cost per sample fell from 0.72 to 0.28 microseconds.

**What it looks like so far: almost nothing, and that is informative.**
Measured in one run, same frame, channels toggled at runtime (`GOANNA_AB`), at
two fixed absolute viewpoints in daylight: turning sky light and occlusion off
changes 0.1 per cent of pixels and the frame mean not at all. The channels are
not idle, and the same test proves it: allowing occlusion to touch direct light
as well (`vertex_ao_light`) changes 44.5 per cent of pixels and halves their
brightness. So occlusion reaches the shading correctly, and what is missing is
something to occlude. Ambient is a negligible share of the current image, which
is the balance `docs/pbr-plan.md` step 3 exists to rework, and it agrees with
the earlier finding that SDFGI replaces environment ambient outright. The
default stays honest rather than flattering: occlusion multiplies ambient only,
because occlusion is not shadow, and it will become visible when ambient is
worth occluding rather than by being allowed to darken the sun.

## What it costs

Measured against a local Mineclonia server, Godot 4.5.1, a 20 second run with
`GOANNA_PERF=1`, comparing against `GOANNA_NO_VERTEX_LIGHT=1` which skips the
sample and writes the neutral values:

| | with | without |
| --- | --- | --- |
| per block conversion | 4.95 ms | 2.42 ms |
| frames per second | 288 | 295 |

So the trace costs about 2.5 ms per block, on the main thread, for a block of
roughly twenty thousand vertices. That is affordable at the few blocks a frame
streaming actually meshes, and it is the obvious thing to optimise if block
arrival ever becomes the frame time problem: vertices in a block share their
corners heavily, so memoising by quantised position and normal should remove
most of it without changing a single output value. Not done, because it is not
yet the bottleneck and an optimisation without a measurement to justify it is
how the cheap correct version gets lost.

## Instruments

- `GOANNA_DEBUG_VCOL=1` prints the spread of per vertex values per mesh
  buffer. It exists because turning on Luanti's smooth lighting looked like
  it worked and changed nothing measurable, and it is the check that the
  light path is live: one distinct value per buffer means it is not.
- `GOANNA_DEBUG_LIGHT=1` prints, per block, the mean and range of each channel
  and how much of the field carried light at all, which is what separated the
  dead decode table from a sampling fault.
- `GOANNA_MAT="channel=value,..."` sets a material strength channel at
  startup, and `GOANNA_AB="channel,channel"` saves a second frame per view with
  those channels at zero. Both frames come from one run: two runs stream blocks
  in a different order and the difference that shows up is the streaming, which
  is how a 103 luma "result" was nearly recorded here before the pair was moved
  into a single run.
- `debug_nodelight` paints the three channels straight onto the world as
  emission, red block light, green sky, blue occlusion, which answers "is this
  arriving" in a way no lit frame can.
- `build/goanna_light_test` checks the tracer against a dense reference
  integral on shapes whose answer is known by inspection, and fails on an
  ordering inversion or an error over 0.12.
- `project/lighting_chart.tscn` is where the shader's treatment of these
  channels is judged, per `docs/pbr-plan.md`, against printed numbers rather
  than screenshots.
