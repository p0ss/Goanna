# Climate field

A temperature, wetness and air humidity value for each cell of the world
round the player, sent by a paired server mod, for the shaders that will
draw frost, wet and dry ground, dust and mist from it. Against any other
server nothing is sent and nothing changes: an unmodified Luanti client
sees nothing new, and Goanna only renders better where the field exists.

Today the client receives the field, keeps it and uploads it as a 3D
texture, and the terrain shaders draw dry, damp, mossy, glistening and
frosted ground from it. The rest of what it will draw is under "Not done
yet".

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

## The ground

The node shaders (`nodes_array.gdshader` and `nodes_array_scissor.gdshader`)
sample the field once a fragment, half a node out from the face, and hand
it to three functions in the include. Each grades with the field's value
rather than switching at one band, so ground a few nodes from a stream
looks different from ground beside it, and a dry biome from a rainy one.

`goanna_climate_tint()`, before rain's film:

| Field | Ground |
| --- | --- |
| parching to dry (under 0.42) | soil, sand and gravel pale and matt, stone a little dusty, grass and leaves toward straw; soil (the `Soil` class only) cracks into plates about a node across, the cracks a texel wide at "dry" and two at "parching" |
| comfortable (about 0.45) | as drawn |
| humid to damp (0.48 to 0.85) | darker, by up to a third on porous soil and a tenth on stone, and a little richer in colour |
| damp and above, above freezing | moss on stone and gravel, in the hollows first, three times as much where the sky light is dim as in the open, so a cave fall grows a green rim; on roofs too, a fifth thinner |
| still dry air out of the sky (under about 0.58) | dust settled on up facing floors and ledges, the face's own colour paled, hollows first; not where the sky reaches, which the wind keeps swept |
| saturated and condensing (0.9 and over) | glistening: smoother, with one texel in six a mirror smooth bead, walls and ceilings included |

`goanna_climate_ground()` gives rain's block a damp film, from 0.74 and
whole at 0.95, and standing water from 0.93, each the larger of rain's and
the field's. The film is not gated on open sky, as rain's is: the server
already settles covered cells dry unless water is near, so a room with a
basin goes damp and a sealed dry room does not. Standing water still needs
open, level ground.

`goanna_climate_frost()`, after settled snow: frost grown texel by texel
from 1 C, more as it gets colder and the air more humid, hollows first,
up facing surfaces a little more than walls, most of every open face by
-6 C, and nearly all of it rimed below -20 C. On glass it grows in from the pane's edges.

Every pattern lies on the art's grid of sixteen texels a node, on the
face's own plane, so it reads as part of the pixel art.

### Build up

Moss, settled dust and settled snow fill the face's relief rather than
being painted on it. Each has a level, and each texel ranks by its relief
height mixed with a grain of its own (`goanna_climate_build` and
`goanna_climate_fill` in `climate.gdshaderinc`, `goanna_snow_fill` in
`weather_common.gdshaderinc`). A texel that ranks under the level is
covered, and the parallax march in `nodes_array.gdshader` draws it filled
up to the height where its rank meets the level: the march stops on the
fill, the sun's self shadow climbs over it, and the texel drawn takes a
level top, the stone's normal and occlusion mostly gone. So moss and dust
come up out of the joints and hollows a texel at a time, until at a fill
of 1 the face is flush.

The march cannot rise past the face, and its depth is the class's (under
a texel for stone), so the build up shows close by and not as a change of
outline. A full face is where a game's own layers (snow layers, a moss
carpet) take over. Only layers with an authored height build up; the
others take the colour alone. The scissor shader has no march and draws
the colour. The self shadow is the sun's, so in a cave the fill shows by
its edge and its lamp shading, not by a shadow.

## Testing it

`goanna_climate_test` checks the store on cases whose answer is known by
inspection, and is part of `cmake --build build --target check`.

For fake data without a server, `GoannaClient.climate_inject(message)`
takes a message as the server would send it, `climate_stats()` reports
whether the channel is joined, whether there is a header, how many blocks
are held and the build time, and `climate_at(world)` gives the field at a
Godot world position.
`set_climate_enabled(false)` hides the field from the shaders while the
store keeps taking what the server sends, so `true` shows it again at the
next build: the same place with and without it, in one client.

`project/studies/material_field.tscn` with `GOANNA_FIELD_CLIMATE=<dir>`
lays a field over the material strips in seven zones, one for each
wetness band from parching to condensing, and writes the field off, on at
12 C, on at -12 C, and rain at 0.8 for comparison, printing each zone's
brightness on each strip.

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

## The air

`atmosphere_volume.gdshader`, the volumetric fog main.gd shows on Low and
up, reads the field too (it includes the field part of the include only,
under `GOANNA_CLIMATE_FIELD_ONLY`):

- Mist where the air is near saturated (humidity 0.8 and up) and cool
  (thinning out from 8 C to 24 C), lying in banks on the ground or the
  water a few nodes deep. Its strength rides main.gd's mist cycle, so it
  is thickest at night and dawn. Peak extinction 0.2 a node. Under a
  roof, as in a cave by a fall, it is a third as thick and dark (0.15 of
  the fog colour), for the reason the dry haze below is: at the fog
  colour, lit by the sky's ambient underground, it filled a wet cave as
  opaque pale steam.
- Dust where the ground is dry (from wetness 0.5, fully at 0.25),
  lifted with the square of the wind, higher in a strong wind, and
  streaming with it. Peak 0.14 a node.
- Under a roof (or in an open column with roofs over it all round, as a
  shaft down into a cave is), a still haze that thickens from 2 to 8
  nodes down, so a sunbeam down a shaft or a lamp's light stands in a
  dry cave. Cave air settles damper than the open ground over it (a
  mesa's dry cave reads about 0.42), so it starts at 0.58 and is whole
  at 0.32. Peak 0.1 a node, dark (0.12 of the dust's albedo) so the
  sky's ambient light, which the volume takes underground too, does not
  light the whole cave; the sun and lamps do.
- The existing valley mist follows the field's humidity where the field
  is known: none in dry country, up to 1.6 times over wet. It stays out
  from under a roof (more than a couple of nodes under the cover map's
  top), field or no field: its band is set by the inhabited elevation,
  so it used to fill caves a few tens of nodes down with big pale blobs.

The ground under a point is the rain cover map (`rain_cover.gd`, 64
nodes round the player, which `weather.gd` keeps in fair weather too
while a field is drawn: without it nothing tells a cave from the open)
where it reaches, and the regional ground
(`mist_level` less 18) beyond. Dry and damp are bands apart, so a place
has mist or dust, never both. The study's `air_off`, `air_mist` and
`air_dust` frames show them over the strips from low down.

### Things in the air

Some of it is too small or too sudden for a froxel.
`game/effects/climate_particles.gd`, made by `particles.gd` beside the
wake, draws it with particles, reading the field at a point through
`climate_at`:

- Dust kicked up where a foot comes down on dry ground, more for a run
  and most for a landing, drifting downwind and settling, the colour of
  the ground it rose from. The steps come
  from `game/effects/footfalls.gd`, the land half of the wake's
  reckoning: one each 0.8 nodes a body travels on footing that is not
  water, for the player and the entities round it, and none along a
  teleport.
- A low spatter (`splashes.gd`, the `step` kind) where a foot comes down
  on soaked ground.
- Breath in front of the player's face below 4 C, every few seconds,
  plainer in humid air.
- Drips off a roof where the field there is saturated, tried at a few
  places round the eye each tenth of a second.
- Motes in dry air under a roof (the cave haze's band): fine specks in a box round the eye,
  added to what is behind them by the light that reaches them, so they
  are seen in a beam through a door or a shaft, or by a torch, and not
  in the dark. None in the open, where every speck is in the sun and a
  thousand of them read as snow, and none within a node of the lens.
- Grit blown low over dry ground once the wind (main.gd's grass wind,
  from the clouds' speed) passes 0.45, all of it in a gale: matt streaks
  along the wind in a box round the feet.

All of it is bounded (24 puffs, 16 drips, 1600 motes, 900 grit) and presentation
only. `tests/footfalls.gd` checks the steps and how the field is read.

Dust takes the ground's colour, paled a little, from `client.ground_dust`:
the average colour of the face under the surface node rather than its
top, so dry grass gives the soil's colour and not green, and sand or stone
their own. A puff takes the column under the foot. The grit and the fog's
dust (`climate_dust_albedo`) take the ground round the player, eased over
a few seconds, so the fog's dust is one colour at a time, not one per
place.

### Heat

`shaders/heat_shimmer.gdshader`, a full screen pass on the camera, bends
what is seen through hot air. Each pixel takes the field's temperature a
node over the surface it sees: from 24 C, fully at 36 C (the field is
the air's, and sunlit ground runs far hotter), it wavers when seen at a
glancing angle over tens of nodes, as hot air does over a road; from 40 C
to 80 C it wavers at any angle within about 30 nodes, by up to 4 pixels
at 1080 lines. The server counts lava as 60 C over the air round it, and
furnaces and campfires less, but a field cell averages the source with
the air round it: beside a lava pool on a summer mesa it read 54 C. Past 30 C, far off and glancing, the ground gives way to
the sky mirrored under the horizon: a mirage. Like the flame shimmer it
adds a difference, so water and glass in front keep their colour.

It shares the `render_fire_shimmer` switch, off on Lowest and Low, and
`game/effects/heat_shimmer.gd` shows it only while the field round the
player (the eye and rings out to 120 nodes) holds 23 C or more: it reads
the screen, and Godot copies the screen for it whenever it is drawn.

## What it costs

Timed on 26 October 2026, before the graded ground above replaced the
threshold, so to be timed again: through the render service on the RTX
3090, High tier, 1920 by 1080, a stone floor and wall filling most of the
frame, with a uniform field injected over the whole grid (`client_run`).
Headless, so relative only: per draw GPU time, median of six rounds of
600 draws.

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

The rest of the agreed look:

| Field state | Shows as |
| --- | --- |
| Saturated cool air | wisps over forest after rain |
