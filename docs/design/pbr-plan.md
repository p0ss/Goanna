# Materials and shading

This document describes Goanna's material pipeline and the work that remains.
It is a system plan, not a record of implementation history; how it got here
is in the [materials log](../history/materials-log.md).

## Design

Every visible node receives a complete material, even when a server provides
no authored maps. Goanna derives a material class from the node definition,
footstep sound, groups, drawtype and name. The class supplies sensible
defaults for roughness, specular, metalness, subsurface scattering, emission
and normal strength.

Authored LabPBR companion textures override those defaults. The supported
companions are diffuse plus `_n` (normal/height), `_s` (roughness, metalness,
ambient occlusion and emission) and the material channels described in
[materials.md](../systems/materials.md). Missing companions are generated from
the classified defaults or from diffuse brightness. Authored data is optional
and never required for a node to look coherent.

Godot owns direct lighting, global illumination, shadows and tonemapping.
Luanti's block light, sky light and Goanna's stable occupancy/occlusion term
travel with the mesh in `CUSTOM0`; they are lighting inputs, not albedo. This
keeps caves and interiors faithful without multiplying baked light into the
texture colour.

The near and far paths use the same material interpretation and vertex
attributes. Far terrain may reduce texture detail, but it must not switch to a
different lighting model or an unlit colour path. This is what prevents the
near/far boundary from reading as two different worlds.

## The material chart

Lighting and material defaults are judged on a standalone chart, not on an
uncontrolled world view. `project/studies/lighting_chart.tscn` has no world
and no server: a fixed camera, fixed lights, one row per material class and
one column per lighting condition, each cell a node sized cube wearing a
LabPBR set through `nodes_array.gdshader` itself, on the vertex layout in
[mesh-attributes.md](../systems/mesh-attributes.md).

- Rows are twelve materials: stone, dirt, sand, gravel, snow, wood, leaves,
  ice, gold, steel, wool and glowstone.
- Columns are the open (sky light full), a roofed bay with a wall behind
  (real occluding geometry, sky light 0.7) and dark (the open cubes with sky
  light 0), at noon, afternoon, dawn and night, driven through the same sky
  blend `main.gd` uses.
- Per cell and face it prints the rendered sRGB, luma, clipping, the
  texture contrast kept against the albedo's own, and the albedo mean.
  `CHART_OUT` writes the lot as JSON, and `tools/bench/chart_summary.py`
  reduces a run to pass or fail lines, or two runs to a table of what moved.

Run it through the launcher:
`tools/goanna-headless fixture res://studies/lighting_chart.tscn --env
CHART_OUT=/tmp/chart.json`. A change to the shader or the environment then
shows up as a number before anyone looks at a screenshot.

## A material for every node

`src/goanna_materials.{h,cpp}` is the per node classifier: one table with two
columns, built once per session on the main thread in
`GoannaSession::prepareContentIfReady`, before the first block is meshed.

- **Material class.** `classifyNode` reads the footstep sound first, then
  groups (Mineclonia's `material_*`, `axey`, `shearsy`, `hoey`, Minetest
  Game's `cracky`, `crumbly`, `choppy`, `snappy`), then drawtype, and the
  node's name only as a last resort. The classes are stone, wood, leaves,
  glass, sand, gravel, snow, ice, soil, metal and cloth. `buildMaterialTable`
  votes the class down to each base texture and keeps the minimum light
  level a texture is shown at, for emission. The class tables mirror
  `tools/pbr/pbr_bake.py`, which classifies the same way offline.
- **Block column.** The Minecraft block a node most resembles, voted from its
  tiles through the texture map (`tools/pbr/mc_texture_map.py`), for the
  semantic ID a shader pack reads as `mc_Entity.x`. It rides in `UV2.y`
  ([mesh-attributes.md](../systems/mesh-attributes.md), "The block semantic
  ID").

The texture source reads the table when it builds an array's companions. A
layer with no authored `_s` gets one from its class (smoothness, F0 or metal,
scattering, emission); a layer with no authored `_n` gets relief inferred from
its own brightness. Authored data overrides by being there. The material class
of each array layer also reaches the shader, so per class treatments (surface
detail, relief depth) are chosen by what a surface is rather than by which
pack dressed it. `GOANNA_DEBUG_PBR=1` prints the classifier's coverage per
signal and, per array texture, how many layers are authored, classed or left
neutral.

## Lighting and exposure

Godot lights; Luanti's values ride along. Sun, sky, GI and tonemap are Godot's
environment, set in `project/game/main.gd`. The per vertex block and sky
light, and the traced occlusion term, travel in `CUSTOM0`
([mesh-attributes.md](../systems/mesh-attributes.md)), and the node shaders
decide what each multiplies.

The recipe, settled on the chart and set in `main.gd`:

- **Exposure.** Sun 1.0, ACES white 4.0, base exposure 0.46 scaled by the
  server's exposure correction.
- **Sky radiance.** What the sky feeds to lighting is not what it shows.
  `sky.gdshader` changes the pass Godot samples for radiance
  (`AT_CUBEMAP_PASS`): the lower half of the dome lifted to the horizon
  colour, the colour partly desaturated so shade is less blue, and a dim
  floor at night (`radiance_*`, set by `_apply_sky`).
- **Sky fill.** SDFGI gives a vertical face about 0.27 of a horizontal face's
  ambient, so a wall under an overhead sun cannot be lifted by exposure or GI
  energy without washing the tops. The node shaders add a flat fill in the
  horizon colour scaled by Luanti's sky light byte (`goanna_sky_fill`, the
  Lighting tab's Sky fill, default 0.4), which is what the vanilla client's
  own light is.
- **Vertex occlusion.** The traced term multiplies ambient and the fill in
  full (`vertex_ao`, 1.0) and direct light at 0.3 (`vertex_ao_light`), so
  corners still read under the sun. Both are entries in
  `kMatStrengthDefaults` (`src/goanna_client_materials.cpp`), which sets them
  on every material and so is what play gets; the shader's own defaults must
  agree with it. The 0.3 is recorded in
  [vertex-ao-2026-10-11](../perf/vertex-ao-2026-10-11/README.md).
- **Entities** take the node light at their position as a per instance
  uniform (`node_light` in `entity_common.gdshaderinc`), so a mob in shade is
  lit like the terrain around it.

What the chart checks, as `tools/bench/chart_summary.py` writes it in numbers:
the classes are told apart at noon, afternoon and dawn (the smallest colour
distance between two classes on a vertical face, over the stone top's luma);
snow keeps its texture and does not clip; clipping below the horizon stays
under a tenth of the frame; a roofed bay reads dark without the head light;
an open wall carries no strong blue cast and reaches 0.3 of the top at noon;
night is visible but not day; and sky light 0 visibly darkens a face.

## Far terrain

The far tiers draw with the same `nodes_array` shader, the same
`Texture2DArray` and companions and the same vertex layout as the near mesh,
through `GoannaClient::materialFor` with a LOD flag. The only far specific
work is bounding texture detail: past `lod_flatten_near` a far material blends
each layer toward its own averages (colour, roughness, metalness, specular,
from `lod_avg_*`), turns lost relief into roughness (`lod_normal_variance`) and
darkens alpha tested tiles by their coverage, reaching the averages by
`lod_flatten_far`. Per class surface detail is not paid for in the far tiers.
Tiles with no array texture fall back to a flat sRGB average colour material.
The far field's own design is in
[far-rendering-plan.md](far-rendering-plan.md).

## Settings

The Materials tab exposes normal, occlusion, roughness, specular and emission
strength, surface detail, surface depth (parallax) and its short march, micro
shadows, edge bevel and hair strands; leaf translucency is under Grass and
foliage. Each strength is a uniform set live on every built material through
`GoannaClient::set_material_strength`, 1.0 being the pack as authored
([materials.md](../systems/materials.md), "Per channel strength").

## Remaining work

1. **The audit.** Per game and per node: the class assigned, its signal,
   whether authored data exists, and a representative rendered swatch, as a
   generated table over every registered node. Today the coverage counts are
   a debug log and `tools/pbr/pbr_review_from_defs.py` drafts a per texture
   review from a definition dump; neither renders a swatch per node.
2. **Semantic matching for shared textures.** The block column is per node,
   but its vote reads only the texture map, so nodes that share every tile
   get the same block. Telling them apart needs the nodedef's other signals
   (name, groups, drawtype) in the vote.
3. **More games and packs**, especially water, translucent nodes, emissive
   blocks and animated textures. The chart has rows only for the array path;
   water, glass, ice and the other shaders that leave it are not on it.
4. **Iris at the compositor boundary.** Keep Iris integration there until the
   gbuffers path has a stable material and light contract
   ([iris-compat.md](iris-compat.md)).

## Performance rules

Material quality must be paid for where it is visible. Near geometry can use
full normal and PBR channels. Distant terrain should share atlases and batches,
reduce channel precision or texture frequency, and prioritise silhouette and
lighting continuity over unseen detail. A new channel is not complete until
the chart, a representative world view and the performance overlay show its
cost and benefit.

The authoritative vertex layout is documented in
[mesh-attributes.md](../systems/mesh-attributes.md). Changes to it require
updating both near and far mesh builders, shaders, tests and any Iris
compatibility notes.
