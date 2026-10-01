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
the fetch, the stretch wind has to raise waves on. `sea_for` turns it into a
scale on the shader's wave strength, from a pond's (0.25 at 6 nodes or
less) to the open sea's (1.6 at 48 or more), 1 being what was drawn
everywhere before; `goanna_water_sea` carries it in x. Past 64 nodes from
the eye it hands back to a lake's, since the water out there may be another
body. The test measures a 6 node pond at 5 nodes (0.26) and the open sea at
the full 64 (1.59). The first version scaled the waves' length and speed
too, which multiplied the world position and the shader's clock, both
large: near a shore, where the measured size wavers as the eye moves, every
small change swept the whole pattern's phase and the sea strobed as if in
fast forward. Only the strength is scaled now.

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

The colour is the region's `murk_hue`: daylight after 3 nodes through the
water (the region's absorption, so red goes first, as it does to the bed
seen from above), times the region's tint, scaled so a beach's is (0.22,
0.62, 0.74) at its brightest, within a hundredth of the fixed cyan the owner
found right for a lake or deeper. A swamp's is a dark green. It is lit by
the light falling on the water (the sun and moon by their height and the
sky at the ambient energy) against a clear noon's, so it dims through the
evening, and darkens with depth. The scattering volume's albedo takes the
same hue. An earlier version used deep water's colour seen from above (the
tile's colour times the column's small body share, lit), which is right for
a pool seen from the bank and nearly black as the glow of daylit water all
round the eye: it drew the underside of the surface, and the sky beyond it,
as a void.

The underside of the surface draws the same waves as the top. Inside the
window straight up (about 48.6 degrees either side of the vertical) it
shows the sky the refracted ray reaches, from the sky gradient and the sun:
the sky the opaque pass drew behind the surface is fogged into the murk, so
the window had come out the murk's own flat colour. Past the critical angle
it is a mirror of the water below, total internal reflection: the bed and
whatever is in the water, marched for down the reflected ray in screen
space and faded into the murk by that ray's length (`goanna_water_fog`
carries the murk's colour and density), and the murk where the ray finds
nothing. Over deep water that mirror is the murk; over shallows it is the
lit bed, bent by the waves. Godot's own specular is off on the underside:
it reflects Godot's sky, which is above the surface.

Some details of the underside:

- Total internal reflection is only on the top of the water. On the sides of
  a water column seen from inside, it laid flat teal sheets across the view.
- Where the march leaves the screen without a hit, the mirror keeps the last
  sample it found on screen, fogged by the ray's length so far. Falling back
  to the flat murk colour there drew horizontal teal bands wherever the
  reflected ray ran off the top of the screen.
- Seen from below, the surface absorbs nothing more of what is behind it:
  the opaque pass already took the water between the eye and what it drew
  (below), and the sky in the window is absorbed over the distance to the
  surface. Measured by the depth behind it, as from above, it took up to
  64 nodes of air for water and came out nearly black.
- Godot gives a back face its normal already turned to the eye. The shader
  turns it back first, bends the surface's own normal and turns it to the
  eye at the end. Taken as it came, the check that a face is the top of the
  water failed from below, and the underside lost its ripples and mirror.
- Godot fogs the underside again over the distance to it, on top of the
  fog already over what it shows, which made looking up murkier than
  looking down. The shader sets its emission to what, once fogged, comes
  out as itself.

Every opaque surface also loses each colour by the water between it and the
eye (`shaders/underwater.gdshaderinc`, included by the node, plant, leaf,
grass and entity shaders): `exp(-absorption * path)`, the same absorption as
the bed seen from above. For something above the water seen up through it,
`path` is only the part under the surface, whose height `main.gd` passes in
`goanna_water_surface`. Before this the only loss was Godot's fog, one
channel at a few hundredths a node near the surface, and a bed three nodes
away was clearly brighter seen from in the water than from above it. The
fog and the scattering volume still lay the murk's glow over it, and in
doing so take their own `exp(-density * distance)` of its light; that share
is given back (`goanna_water_surface.y` carries the two densities), so a
surface loses only the absorption, as from above. With both, the water had
come out murkier from inside than from above.

## The game's water sky

Mineclonia, while the node at the player's head is water, sets every sky
and horizon colour and the fog tint to the water's colour and turns the
clouds off, standing in for underwater rendering a vanilla client lacks. In
third person, head in the water and camera above it, that drew the whole
open view water blue and dark; under the water it turned the sky seen up
through the surface water blue. While the head is in water, a sky of one
colour throughout with no clouds is taken to be that one, and the last
ordinary sky stands in for it (`main.gd`, `dry_sky`).

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
