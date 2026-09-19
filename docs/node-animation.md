# Animated node tiles

A tile definition can animate: a vertical strip of frames
(`vertical_frames`) or a sheet (`sheet_2d`), with a length in seconds.
Luanti's own `node_visuals.cpp` already cuts every animated tile into one
texture per frame when Goanna fills the node visuals, and works out the
frame count and the length of one frame in whole milliseconds
(`TileAnimationParams::determineParams`). Until September 2026 Goanna drew
only the first of those frames. This document is what it does now, how that
matches the vanilla client, and what is left.

## What the vanilla client does

Checked against `luanti/` at 5.17.0:

- One clock for the whole client. `Client::step` adds each frame's `dtime`,
  capped at `DTIME_LIMIT` (2.5 s), to `m_animation_time` and keeps it in
  [0, 60) with `fmodf`.
- One rule for the frame. `AnimationInfo::getTexture` in
  `src/client/tile.cpp` draws frame
  `(u32)(time * 1000 / frame_length_ms) % frame_count`.
- No per node or per block offset. Every animated tile in view shows the same
  frame of its cycle. Older releases had a
  `desynchronize_mapblock_texture_animation` setting; 5.17.0 does not.
- The frame is applied by swapping the texture on each mesh buffer's
  material, in `MapBlockMesh::animate`, called from `ClientMap::renderMap`.
  A block more than 50 nodes away is only re-animated while fewer than 50
  blocks (200 with the whole range shown) have been animated that frame, or
  when its random force timer runs out, so distant animation can hold a
  frame for a while.

The clock starts when the client starts, so two vanilla clients side by side
do not show the same frame either. Matching vanilla timing means the same
frame lengths, frame counts, rule and 60 second wrap, not the same phase.

## What Goanna does

Two paths, because Goanna draws node tiles two ways.

### The array path: the shader picks the frame

Cube-like tiles that `nodes_array.gdshader` can draw (back face culled, not
waving, not a liquid, not alpha blended: `arrayPathTile` in
`src/goanna_textures.h`) are the common case, and upstream keeps animated
tiles out of its own arrays because it swaps their textures. Goanna does not
patch that. Once the node visuals are filled, on the session thread and
before anything is meshed with them,
`GoannaTextureSource::buildNodeAnimations` collects every animated
`TileLayer` and packs the frames of these tiles into Goanna's own animation
arrays: each tile's frames as consecutive layers, grouped by frame size and
by whether any frame has alpha, at most 256 layers to an array. The first
layer of each tile records its frame count and frame length.

`GoannaClient::keyForIrr` then points a buffer whose texture is an animated
tile's first frame at that animation array, and the near mesher writes the
tile's first layer into `UV2.x` (`docs/mesh-attributes.md`). The material
hands the per layer frame counts and lengths to the shader as `layer_anim`,
and the shader turns the base layer into the frame's layer with the vanilla
rule and the clock in the global uniform `goanna_node_anim_time`
(`goanna_anim_layer` in `nodes_array_common.gdshaderinc`). Everything the
fragment reads per layer follows the frame: the colour, the LabPBR `_n` and
`_s` companions, and the class tables.

Nothing changes per frame on the CPU for these tiles. Animated tiles of the
same size and alpha share one material where they used to take one
material each, so they also merge into fewer surfaces per near region.
Faces of light emitting nodes are still drawn apart from the rest, as for
every tile (`docs/mesh-attributes.md`).

A companion follows the frame where a pack ships one per frame.
`GoannaTextureSource::companionImage` cuts the same frame
(`^[verticalframe:N:i` or `^[sheet:WxH:x,y`) from the companion when the
companion has the base strip's aspect ratio, at any resolution. A companion
with a different shape is taken to be one still map and is used whole for
every frame, which is what a pack with a single normal map for an animated
tile means. Before this, the companion of an animation frame was always the
whole strip, so a per frame `_n` was squeezed into one tile.

### The single image path: one texture swap per material

Everything else keeps the single image materials it had: double sided tiles
(torches, lanterns and campfires are mesh nodes, fire is `firelike`, kelp and
seagrass are plants, and a nether portal is an alpha blended node box), and
tiles on the glass, ice, leaves and plants shaders. Goanna shares one
material per tile across every block, so when a frame changes,
`GoannaClient::step_node_animation` sets that frame's textures on the one
shared material: the colour, and for a standard material the inferred relief
and the emission mask derived from that frame, or for a special shader the
frame's companions. The frame comes from upstream's own
`AnimationInfo::getTexture`, the function `MapBlockMesh::animate` calls. It
is the vanilla mechanism, applied once per material instead of once per mesh
buffer. No material is created or swapped on any surface.

### Liquids are left alone

Water and lava have their own shaders (`water.gdshader`, `lava.gdshader`,
`docs/lava-material.md`), which animate their surfaces themselves. They keep
drawing the first frame they always drew, and no liquid material is ever
swapped. That includes the fake liquids drawn as ice or glass.

### The far field

A tile in an animation array is drawn by the far tiers from the same array
and layer (`tileFor` in `src/goanna_lod.cpp`), so it stays textured and keeps
moving past the near range instead of turning into its first frame's average
colour at the hand-off. The far flatten blends each frame toward that
frame's own average colour. Tiles on the single image path keep the flat
colour fallback in the far tiers, as before. Water and lava go through
rung 6's water and lava materials, unchanged.

Goanna gives every tile the frame the rule names on every rendered frame,
near and far, where the vanilla client may leave a block past 50 nodes on
an older frame for a while. Distant animation is therefore steadier than
vanilla's; the frame shown is never one the rule would not give.

## The clock

`main.gd` calls `GoannaClient.step_node_animation(delta)` once per rendered
frame. It caps `delta` at 2.5 s, wraps at 60 s, publishes the time as
`goanna_node_anim_time` (registered in `project.godot`) and moves the single
image materials. `set_node_animation_time(t)` pins the clock, for a capture
that has to show a known frame; a negative value releases it.
`node_animation()` reports the clock, every animated tile with the frame it
shows now, its frame count and length, and the array and base layer it was
given, and every single image material with the frame on it.

`set_node_animation_enabled(false)`, or `GOANNA_NO_NODE_ANIM=1` at startup,
puts every animated tile back on its first frame, drawn as it was before this
existed, and rebuilds the near meshes and materials. It is a kill switch and
the lever for an A/B in one process.

On the first connection Godot's output says what was found, for example on
Mineclonia:

```
Goanna node animation: 41 tiles (594 layers), 11 in 2 animation arrays,
23 double sided and 1 on special shaders change frame per material,
6 liquids keep their own shaders, 0 over 256 frames
```

`GOANNA_DEBUG_ANIM=1` lists every tile.

## Verified

With Godot 4.5.1 on an RTX 3090, against the Luanti 5.17.0 Flatpak server,
2026-09-19.

- `project/tests/node_animation.gd` (`--path project --script
  res://tests/node_animation.gd`) builds an animation array the way the
  texture source does, sets the clock through `GoannaClient` itself and reads
  back which frame each quad drew, through both `nodes_array.gdshader` and
  `nodes_array_scissor.gdshader`. It checks eight clock times against the
  vanilla rule, that a still layer beside animated ones never changes, that a
  companion's emission follows the frame, that `dtime` is capped at 2.5 s and
  that the clock wraps at 60 s. 0 failures.
- devtest, fresh world: `testnodes:anim` placed through the ordinary place
  path went into an animation array (4 frames of 1000 ms) and showed A, B, C
  and D at 0.5, 1.5, 2.5 and 3.5 seconds on the clock.
- Mineclonia, fresh world: 41 animated tiles, 11 of them in two animation
  arrays (prismarine, 22 frames of 2045 ms; magma, sea lantern, sculk, the
  end portal, the reinforced deepslate, the respawn anchor top, the stone
  cutter's saw, the command block and the lit furnace fronts). A wall of
  magma, sea lantern, prismarine, sculk, netherrack with eternal fire, kelp,
  seagrass, a torch, both lanterns, both campfires and portal nodes, captured
  at 0.0, 0.5, 1.0 and 2.2 seconds, changes where the frame lengths say it
  should: fire, both campfires, seagrass, magma and the portal by 0.5 s,
  sculk and prismarine only by 2.2 s. All eleven single image materials that
  scene built (kelp, seagrass, torch, both lanterns, fire, both campfires'
  flames and logs, and the portal) reported the frame the vanilla rule gives
  for the clock at the moment of reading.
- The far tiers, with the LOD distance set to one mapblock so that wall,
  38 nodes away, drew from a far tier (its torches, lanterns and campfires
  disappear, as far cells draw only cubes): magma, sea lantern, prismarine
  and sculk stayed textured, magma and sea lantern changed between 0.0 and
  0.5 s while prismarine, sculk, netherrack and sand did not, and with
  animation switched off and the tiers rebuilt the four drew as flat
  colours, the old fallback.
- The lava suite (`lava_material.gd`, `lava_continuity.gd`,
  `lava_coupling.gd`) reports 0 failures and the same pixel counts as before
  the change.

### Cost

Measured in one client at a fixed pose over that Mineclonia scene,
switching animation on and off with `set_node_animation_enabled` and
alternating the order, four samples each, six seconds per sample, vsync off
(`GOANNA_PERF=1`), 1600x900. The GPU was shared with other sessions'
clients, which is why the comparison is made inside one process rather
than between runs.

| At the wall, 267 block meshes | Animation on | Animation off |
| --- | --- | --- |
| Camera pass draw calls | 570 | 573 |
| Draw calls, all passes | 3358 | 3435 |
| Materials | 61 | 64 |
| Frame time, median | 13.45 ms | 13.59 ms |
| GPU time, median | 12.37 ms | 12.42 ms |
| Render thread CPU, median | 1.47 ms | 1.43 ms |

| From above, 332 block meshes, two samples each | Animation on | Animation off |
| --- | --- | --- |
| Camera pass draw calls | 652.5 | 658 |
| Draw calls, all passes | 1762.5 | 1765 |
| Frame time, median | 14.51 ms | 14.52 ms |
| GPU time, median | 12.99 ms | 13.15 ms |

Separate processes of the unmodified build (a5da4db, three runs) and this
one (four runs) at the same poses gave camera pass draw calls of 741 to 756
against 743 to 748 at the wall and 663 to 674 against 664 to 678 from
above, and 67 or 68 materials against 64 or 65. Their frame times moved by
up to 10 ms between runs of the same build as the other clients' load
changed, which is why they are not quoted as a result.

`step_node_animation` itself costs 0.26 microseconds a frame on the main
thread when no frame changes and 1.6 microseconds when most of the ten
single image materials change on every call. The frame lookup in the shader
was measured separately, in one process, on 40 full screen layers of
overdraw through `nodes_array.gdshader` with and without it: 3.435 ms and
3.426 ms median GPU time over 560 frames each, which is noise.

## What does not work yet

- A node being dug shows its first frame with the crack on it, because the
  crack is composited onto a still copy of the tile. The vanilla client keeps
  animating a cracked tile.
- Animated inventory, wield and dropped item images still show their first
  frame (`item_visuals_manager.cpp` asks the stand-in client for an
  animation time that nothing advances).
- Water and lava do not play the animation strip their tiles define; their
  own shaders animate them instead.
- Tiles on the single image path are a flat colour in the far tiers.
- A tile with more than 256 frames is kept out of the arrays and animates
  on the single image path instead. None has been seen.
- The companion frame cut has only been exercised by the fixture's own
  arrays and by name construction. No pack with per frame `_n` or `_s`
  strips for an animated tile has been tried in a live client.
- Sea lantern, magma and the other array path tiles used to take the
  standard material, with its emission mask cut from the tile's brightness;
  they now take the array shader's material, the same as every static cube,
  including glowstone. That changes how they look, and the change has not
  been reviewed on its own.
