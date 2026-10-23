# Coloured block light

Colour for the baked block light the node meshes carry, past the reach of
the lamp pool and as a soft fill under it. Experimental, and off in every
preset: **Coloured block light** under Graphics, Lamps turns it on
(`light_colour` in a profile), and **Coloured glow** sets how much shows
under the pool (`light_colour_fill`, 0.3 by default).

## What it does

Near the player, the lamp pool's real point lights light the world, in the
colour of their lamps (`docs/systems/graphics-tiers.md`). Past the pool's
reach (`goanna_lamp_reach`) the meshes fall back to their baked block
light: Luanti's own level at each vertex, right in brightness and
occlusion, but white. With the setting on:

- past the pool's reach the baked light takes the colour of the lamps
  that give it, so a village in the middle distance keeps the warm, cyan
  or red light its torches, soul torches and redstone give it near to;
- under the pool the same coloured light is added at the fill strength,
  as a soft glow in the colour of the room's lamps where their direct
  light does not reach;
- the node, plant, leaf and procedural grass shaders all take it, so the
  ground and its foliage agree.

Only the colour is new. Brightness stays the baked light's, so light
levels, and where light stops at walls, are as Luanti computes them.

## Glowing liquids, whatever the setting

The pool stands a few point lamps a node above a lava pool's surface, and
a point lamp lights a bank level with it at a grazing angle, which is
barely at all: the floor round a sunken lava pool stayed dark although
Luanti gives it level 13. Beside a glowing liquid the meshes now use their
baked block light in full, in the liquid's colour, with the setting on or
off. The grid records how near each cell is to the nearest liquid cell, so
a wide lake reaches no further than one cell of it: full while the liquid
would still give 12 of its 14 levels, nothing from 8 down. Over 4-node
cells that edge is soft, so the glow fades out four to six nodes from the
bank.

The colour comes from a coarse grid round the camera, 128 by 32 by 128
cells of 4 nodes (512 by 128 by 512 nodes), built from the lamps the pool
already collects as blocks are meshed (`harvestLights`), in the colours the
pool gives them. Each cell holds the colour of the lamps within reach of
it, every lamp weighted by the square of the light it would still give
there, its level less the distance, so the nearest and brightest lamp
decides and two equal lamps blend. Cells no lamp reaches are white, which
leaves the baked light as it was. The grid ignores walls, which is safe
because it only colours light the baked level already lets through.

The code: `src/goanna_light_hue.cpp` builds the grid, checked by
`goanna_light_hue_test`; `GoannaClient::updateLightHue` in
`src/goanna_client_light.cpp` collects the lamps and uploads it as a 3D
texture (`goanna_light_hue`); `project/shaders/block_light_colour.gdshaderinc`
holds the shading. With the setting off, the colour is white and the fill
is zero, so every surface is lit exactly as before. The procedural grass
now carries its patch's block light in the spare slot of its roots
attribute for this.

## Cost

Measured on 2026-10-24 on the RTX 3090 (Ryzen 7 7800X3D, Godot 4.5.1,
Luanti 5.17.0, Mineclonia) through the render service, at midnight on a
copy of `goanna_coastal_reference_20261013`, 1280 by 720, live range 40,
far terrain to 2048 nodes. GPU frame time, median of six rounds of 600
draws:

| Pose | Off | On, fill 0.3 |
| --- | --- | --- |
| Coastal village | 4.57 ms (4.55 to 4.75) | 4.62 ms (4.48 to 4.63) |
| Shore by the church | 11.51 ms (11.31 to 11.95) | 11.53 ms (11.34 to 11.99) |

The ranges overlap: no difference measurable at this precision. Building
the grid took 1.4 to 2.4 ms on the main thread from 397 lamps, and it is
rebuilt only when the lamps or the grid's position change, at most twice
a second. `goanna_light_hue_test` builds it from 3000 lamps in about 7 ms.

## What was seen

On the same machine and server, at midnight:

- The coastal village from 100 nodes out, mostly past the pool's reach:
  houses and streets in warm light where they had the white bake.
- The shore by the church: the pool lights the door and the grass as
  before, and the fill adds warm light up the tower and walls, which were
  dark.
- A stone room lit by soul torches, a sea lantern, glowstone, redstone
  torches, torches and lava: a warm wash on the ceiling and the shadowed
  brick under the pool's lamps; stronger at a fill of 0.6.
- The same room's 3 by 3 lava pool, sunk into the floor: dark banks
  before; with the liquid fix, the floor and walls round it lit in lava
  orange, falling away within a few nodes, with the setting on or off.

## An earlier attempt

The first prototype, on 2026-10-23, replaced the lamp pool with a light
volume: Luanti's block light flooded again over a 128 by 64 by 128 node box
with each source's colour carried along. It kept the game's light levels
and stopped light at walls, but it read dimmer and flatter than the pool,
which has real falloff, highlights and shadows, and it left torches, water,
glass and entities without the light the pool gave them. Its code is in
the history of this page, in the commit that first added it.

## Not done

- The liquid fix adds the baked light beside lava to the pool's own lava
  lamps, so a bank is a little brighter than either alone; the lamps'
  2.5 times energy for liquids has not been retuned.

- Entities, water, glass and ice keep the pool's light only; past its
  reach they take no block light, coloured or not, as before.
- The lamps come from blocks meshed near the player, so far tiers past the
  near mesh stay white.
- The colour is the pool's: a texture average drawn towards warm white,
  which turns a soul torch's cyan pale.
- The local multiplayer render scopes have not been tried with it.
