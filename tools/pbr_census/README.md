# PBR census

Measures which textures a player actually sees in a Luanti game, so a
texture pack is authored in the order it is looked at rather than the order
a name list suggests. Two parts:

- `init.lua` and `mod.conf`, a throwaway worldmod. On server start it
  emerges a seeded sample of mapchunks, counts every node face that borders
  something see through, builds a few villages with the game's own village
  code and counts what they added, dumps every item's tiles, groups and
  recipe evidence to `<world>/pbr_census.json`, and shuts the server down.
  No client and no player are involved.
- `rank.py`, which turns that JSON into a per stem ranking of a pack and
  batches the stems still to be authored by material family, for
  `docs/pbr-authoring-playbook.md`.

The Mineclonia result of 25 September 2026 is in `pbr_packs/census/`, with
a summary in `pbr_packs/census/mineclonia-2026-09.md`.

## Running it

Always on a fresh world made for the purpose: the mod generates a great
deal of map and builds villages into it.

```sh
W=~/.var/app/org.luanti.luanti/.minetest/worlds/pbr_census_2026_09
mkdir -p "$W/worldmods/pbr_census"
cp tools/pbr_census/init.lua tools/pbr_census/mod.conf "$W/worldmods/pbr_census/"
printf 'gameid = mineclonia\nworld_name = pbr_census_2026_09\nbackend = sqlite3\n' > "$W/world.mt"
printf 'mg_name = v7\nfixed_map_seed = 20260925\n' > "$W/census.conf"
flatpak run --command=luanti org.luanti.luanti --server --gameid mineclonia \
    --world "$W" --port 30577 --config "$W/census.conf" \
    --logfile "$W/server.log"
python3 tools/pbr_census/rank.py --census "$W/pbr_census.json" \
    --pack pbr_packs/mineclonia/textures \
    --out pbr_packs/census/mineclonia-2026-09.json \
    --batches pbr_packs/census/mineclonia-2026-09-batches.json
```

The config file lives inside the world so the Flatpak sandbox can read it.
With the defaults (300 overworld columns, 40 Nether, 8 End, 12 villages)
the server run took 496 seconds on this machine with Luanti 5.17.0 and left
a 169 MB world. `pbr_census_*` settings in the config file change the
sample; the header of `init.lua` lists them. The raw output of the
committed run is `pbr_packs/census/mineclonia-2026-09-raw.json`, so the
ranking can be reweighed without running the server again.

`rank.py` needs numpy and Pillow only for the class column, which it reads
through `tools/pbr_author/lib.py`; `--no-class` skips it.

## What is counted

A face is counted when it borders a node that does not hide it: air, a
liquid, a plant, glass, leaves, a slab, anything not drawn as a full opaque
cube. Two faces of the same see through node against each other (glass
against glass, leaves against leaves, water against water) are not
counted, which is what the engine does with them. Billboards (plantlike,
torchlike, raillike and the like) are counted once per node.

Each overworld face is put in one context by what is in front of it: a
liquid, a place with day light 10 or more (`surface`), or anywhere darker
(`cave`). The Nether, the End and the villages are contexts of their own.
The village count takes a snapshot of the site first and counts only nodes
the village changed.

Faces map to tiles the way Luanti maps them: top, bottom, then four sides,
which `rank.py` spreads evenly over tiles three to six because a facedir
block can face any way. A facedir block turned off its upright axis, and
every wallmounted node, is spread evenly over all six tiles. Every `.png`
named in a tile string (the base and each overlay) is credited with the
face; overlay tiles are credited with the face beneath them.

## How it is weighed

Everything in this section is judgement, and all of it is written into the
output beside the raw counts, so the same counts can be reweighed.

- **Contexts.** Each context's faces become shares of that context, then a
  weighted sum: surface 0.50, cave 0.17, liquid 0.08, Nether 0.08, End
  0.02, villages 0.15.
- **Build weight.** Natural generation barely contains what players build,
  so a second share comes from the item registry. Each placeable item that
  is in the creative inventory, or places nodes named after it (a door
  item places `_b_1`, `_t_1` and so on), gets a weight: 1.0 for the
  `building_block` category, 0.8 for `deco_block`, 0.4 otherwise; times
  0.3 if it has no recipe of any kind (crafting, cooking, stonecutter) and
  is not the drop of a node the census met; times 0.25 for one colour of a
  sixteen colour family; times 0.5 for stairs, slabs, walls, fences and
  panes; times 3 for the utility blocks every base has (crafting table,
  furnace, chest, doors, glass, torch and so on, the pattern is in
  `rank.py`); times `1 + 0.25 log2(1 + n)` where n is the number of recipes
  that take the item. The weight is spread over the block's faces as a
  cube shows them. When several items draw one stem (waxed and plain
  copper, every stair and slab of a stone) the strongest counts in full
  and the rest at 0.25 each.
- **Score** is 0.88 of the exposure share plus 0.12 of the build share, in
  parts per million.

## Batching

The top 350 stems not yet authored (the PNG `goanna_pipeline=authored`
chunk decides, cross-checked against the script names in
`tools/pbr_author/`) are grouped into units: a stem with every other
unauthored face of its home block (the node that contributes most of its
score) and of the nodes the same item places, so a door's halves and a
furnace's faces stay together. Faces pulled in this way can lie below the
cut and are marked. Units are sorted into material families by name
(`FAMILIES` in `rank.py`, first match wins) and cut into batches of up to
eight in rank order; a family's remainder under five joins another
remainder of the same broader group (stone, earth, wood, plant and so on).
Batches are ordered by their best ranked stem, and the cut lines fall at
the first batch that takes the running total past 250 and past 350.

## What it cannot see

- Where players actually go. The sample is uniform over a 12 thousand node
  square; real players live near spawn and in a few biomes.
- What players build. The villages and the build weight are proxies.
- Distance and time. A face on a far hillside counts as much as the one in
  front of the player, and a cave face as much at night as by day.
- Entities, items in the hand and the inventory, the sky and particles.
- Structures that need a player or an active block to finish: village
  mobs, loot, anything placed by a node timer.
- Rotation other than the upright case, beyond the even spread above.
