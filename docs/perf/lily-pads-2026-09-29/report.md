# Lily pads and vines off the water shader, 2026-09-29

`waving = 3` gives a node Luanti's waving liquid material, so it bobs with
the water. Goanna gave every tile of that material the water shader, so
minetest_game's and Asuna's `flowers:waterlily_waving` and Asuna's
Everness `wall_vine_cave_*` were drawn as water. Now only tiles of nodes
that draw as a liquid take the water shader; the rest take the plants
shader, with its sway off, since plant sway is not the bob the node asks
for.

- `mtg-before.png`: the fixture pool with `flowers:waterlily_waving` and
  `flowers:waterlily` side by side. Only the non-waving pad (right) shows;
  the waving one is drawn by the water shader and disappears into the pool.
  `mtg-before-shaders.txt` has it as `WATER 'flowers_waterlily.png'
  mtype=7`.
- `mtg-after.png`: both pads show, the waving one as crisp pixel art on the
  plants shader (`mtg-after-shaders.txt`). Water and lava are unchanged.
- `asuna-vines-after.png`: the three Everness cave vines on the plants
  shader (`asuna-after-shaders.txt`). No before image was taken for Asuna;
  that the vines were on the water shader rests on the same rule the
  minetest_game log shows for the lily pads.

Software rendered (lavapipe) under headless gamescope with Godot 4.5.1,
against Luanti 5.17.0 servers, in fixture worlds. The waving lily pad no
longer bobs.
