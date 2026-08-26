# Materials and shading

This document describes Goanna's material pipeline and the remaining work. It
is a system plan, not a record of implementation history.

## Design

Every visible node receives a complete material, even when a server provides
no authored maps. Goanna derives a material class from the node definition,
footstep sound, groups, drawtype and name. The class supplies sensible
defaults for roughness, specular, metalness, subsurface scattering, emission
and normal strength.

Authored LabPBR companion textures override those defaults. The supported
companions are diffuse plus `_n` (normal/height), `_s` (roughness, metalness,
ambient occlusion and emission) and the material channels described in
[materials.md](materials.md). Missing companions are generated from the
classified defaults or from diffuse brightness. Authored data is optional and
never required for a node to look coherent.

Godot owns direct lighting, global illumination, shadows and tonemapping.
Luanti's block light, sky light and Goanna's stable occupancy/occlusion term
travel with the mesh in `CUSTOM0`; they are lighting inputs, not albedo. This
keeps caves and interiors faithful without multiplying baked light into the
texture colour.

The near and far paths use the same material interpretation and vertex
attributes. Far terrain may reduce texture detail, but it must not switch to a
different lighting model or an unlit colour path. This is what prevents the
near/far boundary from reading as two different worlds.

## Current implementation

- `src/goanna_materials.{h,cpp}` classifies nodes and builds texture material
  tables.
- `nodes_array.gdshader` consumes normals, UVs, vertex colour, `CUSTOM0` light
  data and authored material channels.
- The automatic bump path derives relief from diffuse luminance when no normal
  map exists.
- Lighting defaults are judged with the standalone chart in
  `project/lighting_chart.tscn` rather than by an uncontrolled world view.
- Settings expose normal, AO, roughness, specular, emission, surface detail,
  bevel and leaf-translucency strengths.

## Remaining work

1. Expand the per-game audit so every registered node has a recorded class,
   material source and representative rendered swatch.
2. Improve semantic matching for texture packs where one texture is shared by
   many nodes. Block identity must come from nodedefs, not texture names alone.
3. Bring the far shader to parity with the near shader while retaining a
   bounded texture-read budget.
4. Validate more games and packs, especially water, translucent nodes,
   emissive blocks and animated textures.
5. Keep Iris integration at the compositor boundary until the gbuffers path
   has a stable material and light contract.

## Performance rules

Material quality must be paid for where it is visible. Near geometry can use
full normal and PBR channels. Distant terrain should share atlases and batches,
reduce channel precision or texture frequency, and prioritise silhouette and
lighting continuity over unseen detail. A new channel is not complete until
the chart, a representative world view and the performance overlay show its
cost and benefit.

The authoritative vertex layout is documented in
[mesh-attributes.md](mesh-attributes.md). Changes to it require updating both
near and far mesh builders, shaders, tests and any Iris compatibility notes.
