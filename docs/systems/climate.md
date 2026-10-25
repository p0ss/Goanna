# Climate field

A temperature, wetness and air humidity value for each cell of the world
round the player, sent by a paired server mod, for the shaders that will
draw frost, wet and dry ground, dust and mist from it. Against any other
server nothing is sent and nothing changes: an unmodified Luanti client
sees nothing new, and Goanna only renders better where the field exists.

Today the client receives the field, keeps it and uploads it as a 3D
texture, and the terrain shaders draw wet ground from it. The rest of what
it will draw is under "Not done yet".

## Where it comes from

DorfCraft's kindred seasons field (`mods/kindred/world/seasons/field.lua`
and `field_net.lua` in the DorfCraft repository) is the only sender. It is
optional for the server too: the field rides on a mod channel, which an
ordinary client never joins.

- The server grants a per player channel, `kindred:f:` and 32 lower case
  hex characters, through a HUD element named `kindred:field` whose text
  is the channel name. The client joins only a name granted that way, and
  leaves it if the element goes away or names another channel.
- The server cannot see a join, so on joining the client sends `hello 1`.
  The server answers with a header, then the blocks in range.
- Only messages with an empty sender, which the engine uses for the
  server, are taken. Relayed player messages are dropped.

### Messages

All are JSON with `"v": 1`; anything else is ignored.

| Kind | Content |
| --- | --- |
| `header` | `order` (`"x,y,z"`), and for each of `temp`, `wet` and `hum` the band `edges`, the representative value of each level (`rep`, in C or 0 to 1) and the band `names` |
| `blocks` | `b`: a list of `[bx, by, bz, s, base64]`, map block position, cell size in nodes and the cells; batches stay under 60000 bytes |
| `drop` | `b`: a list of `[bx, by, bz]` for blocks the player has left |

Each cell is two bytes, x fastest, then y, then z: the temperature level
times 16 plus the wetness level, then the air humidity level. Levels run
1 to 15, and 0 means unknown. Cells are 16 nodes in the wild and 4 inside
a fortress claim. The server sends 12 map blocks round the player, 2 below
and 3 above.

## How the client keeps it

`src/goanna_climate.{h,cpp}` holds the store, with no Godot or Luanti in
it. It turns levels into real degrees and fractions through the header's
representative values before it interpolates, because the bands are
uneven: blending band numbers would put the halfway point between -20 and
30 C in the wrong place. Each point is interpolated at the resolution of
the block it lies in, reading across into neighbours of other
resolutions, so a 16-node field shows no edge at a block boundary and a
claim keeps its 4-node detail. Where a claim meets the wild the step is
a fraction of a degree, not the 7 C a cell size jump gave before.

`src/goanna_client_climate.cpp` joins the channel, decodes the messages
and samples the store onto a grid of 100 by 24 by 100 texels at 4 nodes a
texel, the range the server sends, round the map block the camera is in.
The build runs on its own thread, about 9 ms for a full grid, when the
camera crosses a map block, or at most four times a second when the store
changes: the server resends a block each time it recomputes one, and a
build per message kept the store building nearly all the time. Messages
that arrive during a build wait and are applied after it.

## Reading it in a shader

`project/shaders/climate.gdshaderinc` gives `goanna_climate_at(world)`,
which takes a Godot world position and returns the temperature in C, the
wetness, the humidity and, in `w`, how much of the value is known, 0 to 1.
Off the grid, or with the field off, `w` is 0 and the rest a mild,
middling day, so a reader that forgets to weigh by `w` draws little.

The global uniforms behind it are `goanna_climate` (the texture),
`goanna_climate_box` (the grid's low corner and nodes per texel) and
`goanna_climate_size` (texels, and 1 in `w` while the field is on). The
texture is premultiplied by how known each texel is, so filtering against
an unknown texel blends only what is known.

## Wet ground

`goanna_climate_ground()` in the include turns the field's wetness into
the two inputs the terrain shaders already had for rain
(`nodes_array.gdshader` and `nodes_array_scissor.gdshader`): a damp film,
which darkens and smooths, and a wetness for standing water. Each takes
the larger of rain's value and the field's.

The bands are the server's. Open ground in a rainy biome settles "humid",
about 0.76, and rain alone cannot lift it past 0.9; only water nearby
does. So:

| Field wetness | Ground |
| --- | --- |
| below 0.8 (humid and drier) | as it is |
| 0.8 to 0.95 (damp) | a film that grows to full |
| 0.93 and over (saturated, condensing) | standing water in the relief and in basins as well, less than heavy rain gives |

The film is not gated on open sky, as rain's is: the server already
settles covered cells dry unless there is water near, so a room with a
basin goes damp and a sealed dry room does not. Walls take the film at
0.4 of a floor's strength. Standing water still needs open, level ground,
through rain's own gating.

## Testing it

`goanna_climate_test` checks the store on cases whose answer is known by
inspection, and is part of `cmake --build build --target check`.

For fake data without a server, `GoannaClient.climate_inject(message)`
takes a message as the server would send it, `climate_stats()` reports
whether the channel is joined, whether there is a header, how many blocks
are held and the build time, and `climate_at(world)` gives the field at a
Godot world position.

`project/studies/material_field.tscn` with `GOANNA_FIELD_CLIMATE=<dir>`
lays a field over the material strips in four zones (humid, damp,
saturated, condensing) and writes the field off, on, and rain at 0.8 for
comparison.

Tested so far: the native test; injected messages through the real
extension under Godot 4.5.1 `--headless`; and the wet ground in that
study, rendered on lavapipe through `tools/goanna-headless fixture`, where
humid ground is unchanged, damp is slightly darkened, and saturated shows
a sheen and a few small puddles.

Live on 26 October 2026, against a Luanti 5.17.0 server running DorfCraft
on Mineclonia (stream 15's water scene: a pond, a stream, a fall, a sealed
dry room and a room with a basin, in a claim), with Goanna under Godot
4.5.1 `--headless`: the client joined the granted channel, took the header
and 40 blocks, built the texture in 5 to 9 ms, and read the field as the
server did, within 0.007 (open ground 0.76 on both; beside the fall 0.928
on the server, 0.921 on the client). The wet ground has not yet been seen
in the world.

## What it costs

Timed on 26 October 2026 through the render service on the RTX 3090, High
tier, 1920 by 1080, a stone floor and wall filling most of the frame, with
a uniform field injected over the whole grid (`client_run`). Headless, so
relative only: per draw GPU time, median of six rounds of 600 draws.

| Field | GPU ms | Over off |
| --- | --- | --- |
| off | 4.214 | |
| on, dry (0.45) | 4.222 | 0.2 per cent, inside the noise |
| on, damp (0.84) | 4.255 | 1.0 per cent |
| on, soaked (0.965) everywhere | 4.323 | 2.6 per cent |

Dry ground pays one 3D texture read a fragment. Damp ground takes the rain
film's few lines as well, and soaked ground the standing water. In the
world only banks and wet rooms are damp or soaked, so a real frame pays
well under the soaked figure. The texture is 960 kB.

On the main thread, a rebuild costs about 0.04 ms making the slices and
0.13 ms uploading them; the 8 ms build itself is on its own thread. Parsing
the messages is the largest share: about 0.8 ms for a 40 kB batch of
blocks, on the main thread, as each message arrives.

## Not done yet

The agreed look, none of it drawn yet:

| Field state | Shows as |
| --- | --- |
| Wet | drips from saturated ceilings, moss tint on stone in wet dim caves (the film and standing water are done) |
| Dry | cracks on the `Soil` material class only, loose pale sand, dust lifted by wind and by moving entities, motes where a light beam crosses dust in a dry cave |
| Cold | frost grown texel by texel like settled snow, heavier when humid and below -20 C; frost on glass; breath vapour |
| Hot | heat shimmer behind a graphics tier; mild mirage from about 35 C at noon, strong only near lava and forges |
| Saturated cool air | mist pooling in low ground, steam fog over water at dawn, wisps over forest after rain |

Mist, dust and motes are to share one fog volume driven by this texture:
dry and windy gives dust, damp and cool gives mist, never both. Footfalls
are to come from one land detector split out of `wake.gd`, throwing up
what the ground under them holds.
