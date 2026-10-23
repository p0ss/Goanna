# Light volume

An experimental replacement for the lamp pool: coloured block light that
spreads through the world around the camera by Luanti's own rules. It is
off in every preset. **Coloured block light** under Graphics, Lamps turns
it on (`light_volume` in a profile).

## What it does

Every node with a `light_source` lights its neighbours one level less per
node, through nodes whose `light_propagates` is set, and each node keeps
the brightest arrival. That is how Luanti spreads block light. The volume
runs the same flood fill again on the client, over the map it has
received, in a box 128 by 64 by 128 nodes round the camera, and carries
each source's colour along with its level:

- every node gets exactly the light level Luanti gives it, so a light
  level reads the same as it does in play;
- a light keeps its hue as it dims;
- where two lights arrive at the same level their colours are averaged, so
  a red and a blue lamp meet in a blend rather than a seam;
- light does not pass walls, because solid nodes stop the flood, which the
  unshadowed lamps of the pool do not manage.

A source's colour is the average of its first tile, each texel weighted by
its brightness squared and its saturation, so the flame decides a torch's
colour rather than its stick, and scaled so its brightest channel is 1.

The result is decoded with Luanti's light curve, as the node mesh's block
light is, and uploaded as a 3D texture (`goanna_light_volume`). The node,
plant, leaf and procedural grass shaders read it
(`project/shaders/light_volume.gdshaderinc`) in place of the lamp pool and
the baked block light: a face reads the cell half a node in front of it,
and the gradient of the light's brightness gives a direction the face's
relief-mapped normal is shaded against, so a face turned from a lamp is
darker and brick relief reads. Past the box's last eight nodes the baked
block light takes over again. The lamp pool is off while the volume is on,
or every lamp would count twice.

The code: the flood fill is `src/goanna_light_volume.cpp`, checked by
`goanna_light_volume_test`; the box is built and uploaded by
`GoannaClient::updateLightVolume` in `src/goanna_client_light.cpp`.

## Cost

The box is rebuilt only when it moves a mapblock or a block in it changes,
and at most four times a second. On the RTX 3090 machine (Ryzen 7 7800X3D,
Godot 4.5.1, Luanti 5.17.0, Mineclonia), a rebuild in the client took 10 to
17 ms on the main thread: 5 to 9 ms reading the map and 3 to 5 ms for the
flood itself, then the upload. The native test's flood of the full box with
400 lamps takes about 17 ms. A frame's shading reads seven texture samples
per lit pixel. No frame time has been measured against the lamp pool.

## What was seen

On 2026-10-23, through the render service (Luanti 5.17.0, Mineclonia,
Godot 4.5.1, RTX 3090), at midnight:

- A closed stone room with soul torches, a sea lantern and glowstone in
  one half and redstone torches, torches, a shroomlight and lava in the
  other: cyan light in the first half, orange in the second, warm white at
  the back, brick relief visible, no light through the outer wall from two
  torches pressed against its inside, and the one torch outside lighting
  the wall's outer face.
- The coastal village of `goanna_coastal_reference_20261013`: houses, the
  church and the streets lit in warm light, more evenly and further across
  the village than the pool's pools of light, with no seam where the box
  ends.

It is dimmer and softer than the lamp pool: Luanti's levels fall off
faster than the pool's point lights, which also add specular highlights.
`GOANNA_LIGHT_VOLUME_GAIN` scales the light for comparison (1.5 was tried);
`GOANNA_LIGHT_VOLUME_DEBUG=1` paints the volume's light alone on the node
shaders and logs each source's colour.

## Not done

- Torches, lanterns and other nodes drawn with Godot's standard material,
  water, glass, ice, lava and entities do not read the volume, so with the
  pool off they lose the lamplight it gave them. Torches and lanterns still
  glow from their own emission.
- No shadows from lamps; the light is as soft as Luanti's.
- The rebuild runs on the main thread and redoes the whole box.
- Tinted glass does not colour the light passing through it.
- The local multiplayer render scopes have not been tried with it.
