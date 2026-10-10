# Far rendering

Goanna draws terrain beyond the range the server streams in full, so the
view runs on towards the horizon. This page is the map of how that works
today. The [plan](../design/far-rendering-plan.md) says why it is built
this way, and the [far rendering log](../history/far-rendering-log.md)
holds the dated record of each step, its measurements and its faults.
Where this page and the code disagree, the code is right and this page
wants fixing.

## The pieces

- **Near terrain** is meshed by Luanti's own mesher, block by block, and
  uploaded in regional batches of 4 by 4 by 4 mapblocks grouped by
  material. Alpha blended surfaces stay per block so Godot can sort them.
- **The store** keeps every mapblock the server sent, on disk, one
  directory per server, so terrain you have walked through stays drawable
  after the server forgets it for you. Prepared LOD data is cached beside
  it and loaded by a bounded background worker. See
  [prepared terrain storage](terrain-storage.md).
- **Summaries** cover what you have never seen. When the server runs
  `goanna_server_mod` and grants far rendering, the client asks for coarse
  voxel summaries of the terrain the server has generated, over the
  `goanna:v1` mod channel. An ordinary server grants nothing, and the far
  field is then limited to what the store remembers. The local server
  Goanna starts grants it by default. The grant and the mod's settings are
  described in `goanna_server_mod/README.md`.
- **The LOD chain and tiers.** Each block, live, stored or summarised, is
  reduced into a chain of coarser levels. Regions pick a level by the size
  they project on screen and by altitude, and are meshed into merged
  region meshes off the main thread. A cell keeps its own height, so a
  coarse tier follows the ground rather than stepping in whole cells (see
  "Cells are not cubes" below). The shape rules are in
  [terrain surfaces](terrain-surface.md).
- **Baked worlds.** Terrain Diffusion worlds can send compact surface
  tiles straight from their bake, and a forest layer for the trees, so the
  horizon fills before any mapblock exists there. See
  [baked terrain](baked-terrain.md) and
  [forest previews](forest-previews.md).
- **One shading path.** The far tiers run the same node array shader and
  vertex layout as near terrain ([mesh attributes](mesh-attributes.md)),
  and far water the same water material, so nothing changes look at a
  distance boundary.
- **Occlusion.** Near regions publish their opaque triangles as Godot
  occluders, so far regions hidden behind hills and cave walls are not
  drawn.
- **Handoffs.** A region keeps its old mesh until its replacement is
  published, so moving between tiers should not open holes.

## Settings

The far distance setting caps how far the tiers draw. By default it
tracks the server's grant. Terrain occlusion has a live toggle in the
video settings. The graphics tiers set both, see
[graphics tiers](graphics-tiers.md).

## Known limits

The [terrain surfaces](terrain-surface.md) and
[prepared terrain storage](terrain-storage.md) pages list what is still
wrong: coarse facets and stepped cliffs, a frontier that is not yet
guaranteed continuous, and main thread work in region capture and
publication. "Where this is most likely to fail" in the
[plan](../design/far-rendering-plan.md#where-this-is-most-likely-to-fail)
lists the structural risks.

## Cells are not cubes

A coarse cell used to draw as a full cube, so at cell 16 a hill snapped to
16 node steps and the vista read as a stack of boxes. Every cell in the chain
records the height its content reaches, and the region mesher now uses it:
a top face sits at that height, and a side face spans from the height the
neighbour reaches to the height this cell reaches, which is nothing where
the neighbour is as tall, a step where it is shorter, and the whole cell
where it is empty. Terrain at any tier follows its own surface with one node
of vertical resolution while keeping the horizontal cell size.

A partial height side face cannot merge with one in the row above (each sits
at its own height inside its own cell), so the face key carries its row and
only full height faces merge freely, which is the common case underground
and inside hills.

## Instruments

Per this repository's habit of building the instrument before trusting the
result:

- `lighting_chart.tscn` wants a distance case, so fog and aerial perspective
  are read off numbers rather than impressions, and an occlusion case: a pit,
  an overhang and a cave mouth, with the brute force hemisphere integral
  printed beside what the cone trace produced.
- `tools/dev/shotcheck.py` for viewpoint repeatability, which matters more here
  than anywhere else, because a vista shot before terrain streams in is a
  photograph of fog.
- A per tier readout, so rung 3 cannot regress rung 2 silently: `render_stats`
  reports blocks per tier, region meshes, quads before and after merging,
  surfaces and the build time, and `GOANNA_PERF=1` prints them each second.
  `GOANNA_DEBUG_LOD=1` prints every region build with its surfaces, which is
  what says whether a tier landed on the array shader or the flat fallback.
- `lod_partial` against `lod_faces` in `render_stats`: how much of a tier's
  geometry is the risers of a staircase rather than the treads. Just over half
  is what a summary heightfield drawn as boxes costs today; a surface mesher
  would take it to nothing. See "Strips, and what the merge can and cannot
  do".
- `far_extent` and `far_reach`: the lower and upper quartile of the eight
  sector histogram, so the raggedness of the frontier is a number rather than
  an impression. The gap between them is what the haze has to cover, and the
  ratio is how lopsided the field is at that moment.
- `GOANNA_DEBUG_LOD=1`'s request log answers the question that matters most
  about the summaries, which is not how fast they arrive but where they go:
  group `asked for area` by its middle coordinate and read off how much of a
  budget that fills half an area a second is being spent on layers the player
  cannot see. That measurement is what "Where the summary budget actually
  went" is.
- `project/material_field.tscn`, run as `godot --path project
  material_field.tscn`, draws strips of a pack's own textures through
  `nodes_array.gdshader` with no server, no streaming and no privileges, so a
  question about the shader can be answered when no client on the machine
  will hold enough blocks to draw the ground. `GOANNA_FIELD_LOD=<dir>` writes
  `lod_off.png` and `lod_on.png`, one strip drawn as the near mesh draws it
  and the same strip drawn as a far tier does, and prints the colour it read
  back off each frame beside the tile's own average in linear light, which is
  the near mesh against the far tiers on one surface under one sky.
  `GOANNA_FIELD_LAYER=<n>` puts the tile at array layer n with a flat magenta
  in every other layer and a different colour in every other
  `lod_avg_colour` entry, because layer 0 is the one layer an index that
  truncates cannot get wrong, so a fixture that only ever uses layer 0 cannot
  see the fault "The far field's albedo" was about. Both were added on
  2026-08-23 alongside the fixture's own detail mode, which they leave
  untouched.
