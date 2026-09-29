# Gem treatment beyond diamond, 2026-09-29

`project/gem_study.tscn` draws each gem kind as ore, block and item through
the production shaders (`nodes_array`, `nodes_array_scissor`,
`entity_diamond`), from the games' own textures: Mineclonia for diamond,
emerald, amethyst and quartz, minetest_game for mese. The mese ore is
`default_stone.png` with `default_mineral_mese.png` composited over it, as
its tile string asks. One lamp, a dark backdrop and a procedural sky for
reflections.

- `gems_off.png`: `diamond_strength = 0`, the textures as the array and
  item shaders draw them without the treatment.
- `gems_on.png`: the treatment.
- `gems_side.png`: the treatment with the lamp moved.
- `off-on.png`: the first two side by side.

## Diamond is unchanged, to within 23 pixels

The same scene was rendered with the shaders as of commit 6e31a179, before
the gem table, and compared pixel by pixel. The renderer is deterministic:
two runs of the old shaders were identical.

- Treatment off: identical over the whole frame.
- Treatment on: the diamond block and the pick are identical. On the diamond
  ore cube 23 isolated pixels differ, by at most 11 of 255 (29 pixels, at most
  16, with the lamp moved). `diamond-ore-old-new-diff.png` shows the old
  crop, the new crop and the differing pixels in white. They are single
  pixels at crystal edges.

Every diamond constant is kept, the refraction ratios are folded as before,
the mask keeps its literal edges and the per gem optics reach `light()`
through a flat varying. The remaining difference is attributed to the
compiler treating the edited shader's arithmetic differently in the last
bit, which the ore recess's stepped wall march can turn into a different
step. That is an inference; it was not traced further.

## What the other gems look like

The masks select the gem pixels and leave the host alone in every row:
emerald in stone, mese flecks in minetest_game stone, white quartz in red
netherrack. The first attempt let each gem transmit as freely as diamond,
and mese and quartz ore turned the colour of the rock behind them, and the
items the colour of the backdrop. A per gem clarity (diamond 1.0 down to
quartz 0.25) scales that transmission; the images are with it.

## How it was run

Godot 4.5.1 Forward+ on lavapipe (software Vulkan) under headless
gamescope, because another client held the GPU. Not yet seen on the GPU
renderer, and not yet seen in a live world.

## Limits

- The masks and clarity were set from these games' default art. A
  texture pack that recolours a gem away from its key colour will lose the
  treatment on that gem, as a recoloured diamond already did.
- Glowing and blended gems (caverealms, Everness crystal blocks,
  `too_many_stones`) take the emissive and glass paths and are not covered.
- Amethyst buds and clusters are plants, drawn double sided, and are not
  covered.
