# Mineclonia texture census, September 2026

Which of the pack's 1021 stems a Mineclonia player actually looks at, and
the order the next authoring fleet should take the 844 that are still
baked. Measured 25 September 2026 with `tools/pbr_census/` (the method and
how to rerun it are in its README). Files beside this one:

- `mineclonia-2026-09.json`: every stem with its rank, score, exposure,
  build share, raw face counts per context, faces per sampled region, home
  node, family and material class, plus the textures the census met that
  the pack has no stem for, and the build evidence per item.
- `mineclonia-2026-09-batches.json`: the top 350 unauthored stems in 57
  batches, with the expected treatment and worked examples per batch, the
  two cut lines, the crack texture and the release's known failures.
- `mineclonia-2026-09-raw.json`: the worldmod's own output, for
  reweighing without a server.

## Method, briefly

A throwaway worldmod on a fresh world (Mineclonia release 38561, Luanti
5.17.0 Flatpak, mapgen v7, seed 20260925) emerged 300 overworld mapchunk
columns from y -128 to 191 spread over a 12 thousand node square, 40 Nether
columns and 8 End columns, and built 12 villages with Mineclonia's own
village code. It counted every node face that borders air, a liquid or any
other see through node: 8.5 million faces in sunlight, 12.1 million in
caves, 3.0 million under liquid, 3.4 million in the Nether, 90 thousand in
the End, and 94 thousand that the villages added. Faces were mapped to
tiles as Luanti maps them, top, bottom and sides, and every `.png` in a
tile string was credited.

The score is 0.88 of a weighted exposure share (surface 0.50, caves 0.17,
liquid 0.08, Nether 0.08, End 0.02, villages 0.15) plus 0.12 of a build
share taken from the item registry: creative category, whether it can be
crafted, cooked, cut or mined, colour families and shapes discounted, and
a hand list of utility blocks (crafting table, furnace, chest, doors,
glass, torches and the like) tripled. The weights are judgement; they are
recorded in the JSON so the same counts can be reweighed.

The overworld sample landed in 44 biomes; the most frequent were pale
garden (29 columns), savanna and forest (23 each) and lush caves (12). The
Nether columns were mostly warped forest (18) and basalt delta (14). The
villages stood in bamboo jungle, swamp, flower forest, birch forest, taiga,
desert, ice plains and roofed forest.

## What the top looks like

The authored 177 already cover 69 percent of the measured exposure: the
first five stems of the whole pack (stone, deepslate, grass top, dirt,
bedrock) are all authored, and so are 30 of the top 50. What is left is a
long tail. Among the 844 unauthored stems, 7 carry half of the remaining
exposure, 30 carry 80 percent, 85 carry 95 percent and 152 carry 99
percent. The top 250 carry 98.8 percent and the top 350 99.5 percent.

So below roughly rank 100 of the unauthored stems the order is the build
heuristic's, not the census's: 73 of the top 250 and 120 of the top 350
were never seen in the sample at all (planks of the newer woods, polished
and dressed stones, copper, workstations, stripped logs). Treat that part
of the ranking as an educated guess about what players build, and the top
100 as measured.

The top 30 unauthored stems:

| rank | stem | score | exposure | build | family |
| --- | --- | --- | --- | --- | --- |
| 1 | mcl_deepslate_top | 35190 | 39897 | 673 | natural rock |
| 2 | default_jungleleaves | 18809 | 21154 | 1616 | leaves |
| 3 | mcl_lush_caves_moss_block | 17954 | 20072 | 2424 | soils |
| 4 | mcl_end_end_stone | 15429 | 17116 | 3065 | natural rock |
| 5 | mcl_pale_oak_leaves | 14903 | 16715 | 1616 | leaves |
| 6 | default_jungletree | 12325 | 13503 | 3681 | logs and planks |
| 7 | mcl_pale_oak_log | 6494 | 6878 | 3681 | logs and planks |
| 8 | mcl_core_vine | 6342 | 6928 | 2044 | flora cut-outs |
| 9 | mcl_blackstone_basalt_side | 5581 | 6137 | 1504 | natural rock |
| 10 | mcl_deepslate_tuff | 5145 | 5407 | 3226 | natural rock |
| 11 | mcl_mangrove_leaves | 5030 | 5496 | 1616 | leaves |
| 12 | default_ice | 4363 | 4682 | 2020 | ice and snow |
| 13 | default_junglewood | 4327 | 4369 | 4020 | logs and planks |
| 14 | mcl_lush_caves_cave_vines_lit | 3877 | 4406 | 0 | glowing blocks |
| 15 | mcl_fences_fence_oak | 3670 | 4033 | 1010 | logs and planks |
| 16 | mcl_flowers_leaf_litter | 3478 | 3731 | 1616 | leaves |
| 17 | warped_wart_block | 3470 | 3767 | 1293 | organic blocks |
| 18 | mcl_lush_caves_cave_vines | 2992 | 3400 | 0 | flora cut-outs |
| 19 | warped_nylium | 2876 | 3257 | 81 | soils |
| 20 | mcl_cherry_blossom_leaves | 2794 | 2954 | 1616 | leaves |
| 21 | mcl_nether_nether_wart_block | 2668 | 2811 | 1616 | organic blocks |
| 22 | mcl_fences_fence_birch | 2611 | 2830 | 1010 | logs and planks |
| 23 | mcl_lush_caves_dripleaf_big | 2346 | 2578 | 646 | flora cut-outs |
| 24 | mcl_blackstone_side | 2059 | 2038 | 2211 | natural rock |
| 25 | dripstone_block | 2021 | 2076 | 1616 | natural rock |
| 26 | default_acacia_leaves | 1729 | 1744 | 1616 | leaves |
| 27 | default_glass | 1712 | 1181 | 5607 | glass and panes |
| 28 | mcl_deepslate_tuff_bricks | 1690 | 1488 | 3171 | masonry and dressed stone |
| 29 | mcl_walls_cobble_wall_side | 1547 | 1699 | 431 | masonry and dressed stone |
| 30 | mcl_pale_oak_moss | 1547 | 1438 | 2343 | soils |

Scores are parts per million of the weighted total.

## Batches and cut lines

57 batches cover the top 350 plus 69 faces of the same blocks that rank
lower (a smoker's front and top, a trapdoor's face beside its side). The
250 cut falls after batch 34 (253 stems) and the 350 cut after batch 48
(355 stems). Batches are ordered by their best ranked stem, so an early
batch can carry a few stems ranked lower in the same family. Where a
family ran out, its remainder joined another of the same broad group, so
batch 9 is the three glass stems with the warped trapdoor. Two batches
have fewer than five stems: calcite with pointed dripstone and the nether
brick fences, and the beehive's four faces.

## Surprises

- **The deepslate top face is the most seen unauthored texture**, at rank
  6 of the whole pack. The deepslate side is authored; its top, which every
  cave floor below y 0 shows, is not.
- **The grass side has no stem in the pack.** Grass block sides draw
  `default_dirt.png^mcl_dirt_grass_shadow.png` with
  `mcl_core_grass_block_side_overlay.png` over it. Neither overlay is a
  pack stem, and each carries an exposure of 28734 parts per million, which
  would place them sixth in the whole pack. Whether the client applies
  `default_dirt`'s maps under the overlay was not checked here.
- **Other textures the pack lacks that the census found heavily used:**
  water (`default_water_source_animated`, 46453, and flowing, 6553), lava
  (`default_lava_source_animated`, 8742, and flowing, 1415), the torch
  (`default_torch_on_floor_animated`, 3115), `mcl_lanterns_lantern` (2090),
  the nylium sides (`warped_nylium_side` 2006, `crimson_nylium_side` 758),
  `mcl_ocean_sea_lantern`, `mcl_nether_magma`, `mcl_copper_ore` (the
  deepslate copper ore is in the pack, the stone one is not),
  `mcl_ocean_prismarine_anim`, `mcl_sculk_sculk` and
  `mcl_core_crying_obsidian`. Most are animated strips, which the bake did
  not take. The full list is `missing_from_pack` in the JSON.
- **Newer biomes rank high.** Pale garden leaves and logs, cherry leaves,
  mangrove leaves, lush cave moss and vines are all in the top 30. The v7
  sample put pale garden in 29 of 300 columns. A world players have lived
  in for a while, near spawn, would weigh differently.
- **Bedrock ranks fifth** (it is authored), mostly from the lava lakes at
  the bottom of the overworld and the Nether's floor and roof. It is
  honestly exposed, but few players stand there.
- **The villages build with authored stems.** Their most added textures
  are grass top, cobble, dirt, oak and spruce planks, stone brick and grass
  path, all authored; jungle planks, the oak and birch fences and the
  cobble wall are the first unauthored ones.
- **Several authored sets rank low.** The iron door (392 to 551), wood
  door (408 to 577), furnace front (518), rails (513 to 594), concrete
  (598 to 684) and TNT top and bottom (811 and 812). Their build weight is
  spread over several faces and the census barely met them. This does not
  mean the effort was wasted; it means per stem exposure undervalues a
  block every base has, which is why the utility list exists.

## Also on the list, outside the ranking

- **An authored crack.** Mineclonia's `crack_anylength.png` is 16 by 160,
  ten 16 px stages, and `draw_crack` scales one stage over the 256 px
  base, so a block being dug shows 16 px cracks on a 256 px face. The pack
  overrides by filename, so an authored crack at 256 px per stage would fix
  it. It is not a node tile, so the census cannot rank it; every block a
  player digs shows it.
- **The eleven known failures** of `asset_bundles/recipes/mineclonia-pack-1.0.0.json`
  are all authored sets, and their ranks are: `default_dirt` 4,
  `default_clay` 31, `mcl_core_dirt_podzol_top` 39,
  `mcl_core_dirt_podzol_side` 58, `mcl_core_coarse_dirt` 99,
  `mcl_flowers_double_plant_grass_top` 173, `jeija_torches_on` 393,
  `default_rail_crossing` 513, `default_rail` 592, `default_rail_curved` 593
  and `default_rail_t_junction` 594. The soils are worth reworking before
  most new stems: dirt alone outranks every unauthored stem.

## What it cannot see

- Where players go and what they build. The sample is uniform over a 12
  thousand node square, and the villages and the build weight are proxies
  for building.
- Distance, time of day and how long anything is looked at.
- Entities, the wielded item, the inventory, particles and the sky.
- Anything a node timer or a player finishes later: village mobs and loot,
  crops that grow, copper that weathers.
- Rotation beyond the upright case: sides are spread evenly over tiles
  three to six, and a block turned on its side over all six.
- Build weight is spread per face, so a block with six distinct faces (a
  smoker, a cartography table) ranks each face lower than a block with one
  texture; batching by block puts the faces back together.
