# Water optics

One description of the water round the eye, for both sides of its surface.
`project/water_optics.gd` holds it; the water shader and the underwater fog
both read it. Tested headless only (`project/tests/water_optics.gd`); how it
looks has not been observed at the time of writing.

## Why

Looked down into from above, `water.gdshader` absorbed the bed by its own
constants, and a beach or a reef read right. From inside the water,
`main.gd` drew one fixed cyan fog, 0.05 dense from the surface down, plus a
0.03 scattering volume. The two never agreed. The owner found the fog right
for a lake or deeper water but far too murky just under the surface, when
the same shallows were glass from above. Nothing varied from place to place
either: a sandy beach and a swamp were the same water.

The aim, in the owner's words: clear surface visibility in the shallows,
tending towards the murky in the depths, with each region changing how fast
that happens and the colour.

## Regions

`WaterOptics.REGIONS` has four, each with:

| | absorption per node (r, g, b) | underwater fog at the surface → deep | over a depth of | tint |
|---|---|---|---|---|
| clear (beach, reef) | 0.45, 0.11, 0.05 | 0.012 → 0.05 | 16 nodes | the tile's own |
| lake | 0.55, 0.17, 0.12 | 0.025 → 0.07 | 8 | a little greener |
| river | 0.6, 0.24, 0.2 | 0.035 → 0.08 | 5 | greener, siltier |
| swamp | 1.0, 0.55, 0.7 | 0.1 → 0.2 | 2.5 | brown-green |

"clear" keeps the absorption the water shader always had, which reads right
on a beach or a reef, and its deep fog is as dense as the old fixed fog.
The scattering volume runs from shallow to deep the same way.

**Which region** is what a player can see of the water round them: the
server sends no biome. A 7 by 7 grid of columns 2 nodes apart round the eye
is looked down, four columns a frame (a full sweep in about 0.2 seconds at
60 frames a second). A column finds its water and then its bed:

- sand, gravel, stone and the like: clear (a beach, a reef);
- clay, dirt, grass: a lake;
- mud, peat and the like: a swamp;
- lily pads on the surface make a swamp whatever the bed;
- river water is a river's, unless its bed is a swamp's.

Names are matched by substring, like the water itself (`is_water_name`, which
now leaves out lily pads, named `waterlily`; `wake.gd`'s had the same slip).
The optics are the columns' regions blended by share, and ease towards a new
sweep's over about two seconds, so wading from a beach into a swamp is a
gradual change: halfway after 1.6 seconds in the test.

## How big the water is

The background waves were one pattern at one strength and length on every
water, which made a five node pond as busy as the sea. `water_optics.gd`
also looks out along 16 directions from the eye, 4 nodes a step to 64, for
where the open water at its surface ends (8 samples a frame); the mean is
the fetch, the stretch wind has to raise waves on. `sea_for` turns it into
scales on the shader's wave strength and length, from a pond's (0.25 as
strong, 0.4 as long, at 6 nodes or less) to the open sea's (1.6 and 1.5, at
48 or more), 1 being what was drawn everywhere before; `goanna_water_sea`
carries them (a vec4, since the per view globals take no vec2). Longer
waves are slower, their time scaled by the root of the length. Past 64
nodes from the eye the scales hand back to a lake's, since the water out
there may be another body. The test measures a 6 node pond at 5 nodes
(waves 0.26 strong) and the open sea at the full 64 (1.59).

## From above

`water.gdshader` reads `goanna_water_absorption` and `goanna_water_tint`
(per view), in place of its own `absorption` uniform: the bed through
`thick` nodes of water is scaled by `exp(-absorption * thick)`, and the
column's own light is the tile's colour times the tint. Registered in
`project.godot` at the beach's values, so a view without the node draws the
water as before.

## From below

`main.gd`'s `_apply_water_murk` sets the fog every frame while the eye is
under: `WaterOptics.murk(optics, eye_depth)` gives the fog's density and the
scattering volume's, from the region's shallow value at the surface towards
its deep one as `1 - exp(-depth / region depth)`, and a light factor, 1 at
the surface to 0.45 far down, for the daylight that reaches that deep.
`eye_depth` is measured up from the eye through the water to the first node
that is not.

The colour is the one deep water shows from above, so the two views agree:
the water tile's average colour (`GoannaClient.node_tile_color`, the tile
image averaged in linear light times the tile's colour) times the region's
tint times the water shader's `0.5 * body_gain` (`WATER_BODY_GAIN`, tied to
the shader by the test), lit by what lights an upward face at the water:
the sun and the moon each by its height, and the sky's zenith colour at the
ambient energy. The scattering volume's albedo takes the same hue at 0.6.
The fixed bright cyan fog and cyan volume it replaces were tuned by eye and
drew the same pool dark blue from the bank and bright teal from in it.

The underside of the surface now draws the same waves as the top (it had
them at a third of the strength, against aliasing), and past the critical
angle it is a mirror: from under water the sky is seen only through a
window about 48.6 degrees either side of straight up, and outside it the
underside reflects the water below, which through the murk is the murk's own
colour (`goanna_water_fog`, set with the fog). The waves tilt the surface,
so the window's edge breaks up into their pattern. Before, the whole
underside showed the sky. Godot's own specular is off on the underside: it
reflects Godot's sky, which is above the surface, and lit the mirror far
brighter than the murk it stands for.

The bed's refraction by the waves is capped too: only the first 1.5 nodes
of depth count, at 0.12 rather than 0.18 (see `water.gdshader`'s
`refraction`). At the full depth, deep pools swung about under the
background waves enough to be queasy to look at.

## Crossing the surface

The volumetric fog blends each frame with the frames before (temporal
reprojection). Left on across the surface, it carried the dense water volume
into the open air for about a second after the eye came up. It is turned off
for the three frames after the eye crosses the surface either way, and put
back as it was.

## Not done

- One set of optics per view, round the eye. A swamp seen from a sandy beach
  looks like the beach's water until the eye is near it. Per water body
  optics would need the optics in the water meshes, set when they are built.
- The bed cues are names. A game naming its beds otherwise reads as clear.
- Biome grass colour (Mineclonia colours grass and leaves per biome, and a
  swamp's is distinctive) is not read: the client's map lookup gives node
  names, not the palette index.
