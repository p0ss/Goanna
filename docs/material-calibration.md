# Material calibration

Two offline fixtures, added 2026-09-15 after feedback that Mineclonia in
full sun looked "plastic", measure what the renderer makes of a given
roughness, metalness and water depth before any texture is blamed. Both use
the world's own sky and lighting recipe as `lighting_chart.gd` copies it
from `main.gd`, with no server and no world. Godot 4.5.1, Vulkan Forward+,
RTX 3090. The ramps are the measurement; an in-world screenshot is only
confirmation (see `docs/materials.md` for the channel layout they decode).

## The material ramp

```sh
PROBE_OUT=/tmp/ramp RAMP_OUT=/tmp/ramp/ramp.json \
  godot --path project material_ramp.tscn
```

Three rows of node sized cubes through `nodes_array.gdshader`: a grey
dielectric at smoothness 0, 64, 128, 192, 230 and 255, the same as a metal,
and twelve baked sets from the pack. Three lighting cases: noon, afternoon,
and glint, where the sun is moved to the mirror direction of each column in
turn so every step is measured at the same angle. The first version put one
sun over the whole row and measured the layout instead of the roughness; a
smooth lobe is narrower than the few degrees between columns.
`GOANNA_VARIED_DIR` draws a second pack row from another directory, and
`GOANNA_BAKED_DIR` swaps the pack outright, which is the clean comparison
(same cubes, same pixels, two runs).

What it settled, patch means in sRGB, the sun at 1.0:

- **The sun glint dies above smoothness 230 on a dielectric.** Glint top
  face luma by step: 130, 151, 217, 255, 248, 145. Roughness 0.04 gives a
  lobe a pixel or two wide under a point sun, and `light_angular_distance`
  at the real sun's 0.53 degrees changes nothing (Godot widens shadows with
  it, not the specular lobe). Metals keep a glint at 255 only because the
  sky radiance map carries the sun disc, which a metal reflects at full
  strength and a dielectric at 4 percent. The usable top of the dielectric
  range is about 230.
- **The pack's terrain shows almost no specular in daylight.** Grass at
  smoothness 76 and planks at 56 sit between the first two steps, whose
  glint is 130 against 151. Stone, dirt, sand and gravel are lower still.
  Uniform sheen on terrain is not where the plastic look comes from.
- **Roughness variation at those levels is invisible in the sun.** With
  `tools/pbr_spec_variance.py` spreading the eight core dielectrics from a
  standard deviation of 0.01 to 0.04 up to 0.04 to 0.10, no patch moved by
  more than one count at noon or afternoon, top or front. The spread only
  matters where the lobe is narrow: wet surfaces (`goanna_wetness` pulls
  roughness to 0.13) and grazing low sun. The tool is kept for those; it
  is not a fix for the daylight look.
- **Metals reflect only the sky.** There is no screen space reflection and
  SDFGI carries no specular, so a metal at smoothness 255 is albedo times
  the sky radiance: the grey cube's top reads 82, 99, 137 under a sky whose
  top of frame is 144, 168, 205. A mirror finish cannot appear on any
  surface in this renderer as configured; the calibration says so rather
  than the maps.

## The water ramp

```sh
PROBE_OUT=/tmp/w WATER_OUT=/tmp/w/water.json \
  godot --path project water_ramp.tscn
```

A sheet of `water.gdshader` over sand stepped from half a node to eight
deep, beside the same sand dry, seen from thirty degrees down
(`GOANNA_PITCH` changes it). It prints each strip's colour, luma and
saturation next to the dry sand and the sky. The tile is Mineclonia's
water animation, first frame, from the game as installed.

Before, deep water read 113 to 120 luma against the dry sand's 162, at 0.45
saturation against the sand's 0.27: a sun lit blue floor at seven tenths of
the sand's brightness, which is the painted look. Two things in the shader
did that. The bed seen through the water went out through `ALBEDO`, so the
lamp lit it a second time, and the deep colour was the tile at half
strength, also lit by the full sun, when a real water column returns a few
percent of what falls on it.

The shader now splits the two: the transmitted bed is emission, attenuated
by the same absorption as before and never shaded again, and only the
column's own scatter (`body_gain`, 0.35 of the old half strength tile) is
an albedo the sun and sky light. After, at thirty degrees: the half node
shallow reads 159 against dry sand at 163 and shows the bed, the two node
strip 128, the eight node strip 48 to 79. Saturation rose to 0.55 to 0.60
in the deep strips, because what remains there is the bed transmitted
through an absorption that kills red first, which is what clear water does;
the grey blue of a hazy lake is the sky, not the body. From twelve degrees
the eight node strip reads 125, 151, 199 under a horizon sky of 145, 165,
187, converging on the reflection as it should.

Not changed, and worth knowing: the sky is reflected twice at small
amounts, once by the shader's own `reflected` term and once by Godot's
environment specular from the same radiance map, about five percent each at
thirty degrees. Setting `SPECULAR` to zero would remove the second but also
the sun glint, so it stays.

Confirmed only on the fixture. No Mineclonia server was up on the day, and
the working tree carried another session's uncommitted C++, which the
shared checkout rules say not to link for a measurement.

## The close-up, and what plastic turned out to mean

The wide ramp measures levels. The complaint was about structure, which
the wide ramp cannot show: a cube forty pixels across has no texel detail
left. `GOANNA_CLOSE=1` lays the pack row out four to a row with the camera
near enough that a cube is about three hundred pixels wide, and the ramp
applies the relief gain the client would (`GOANNA_NORMAL_GAIN` pins it),
which for the Mineclonia bake is 2.86.

Measured on the pack's normal maps, 2026-09-15: median texel tilt 5.9
degrees over 400 maps, stone 12.6, cobble 12.4, grass top 7.9, and the
occlusion channel never below 0.81 on any of them. A cobble with mortar
has facets at forty to sixty degrees along every joint and occlusion under
a third in the cracks. The bake's relief is the pixel grid embossed: each
16 px source texel a plateau with a soft edge, and at the client's gain
every texel outline becomes a ridge. That, not the specular level, is what
reads as moulded plastic. A correct BSDF on a surface with no structure.

Three sets of the same twelve stems were put on the close-up:

- the bake as it is, at gain 2.86;
- the bake lifted (`tools/pbr_relief_normalise.py`, new): tangent slope
  scaled to a class target tilt, occlusion recomputed from the height
  channel stretched to full range. Stone went 12.6 to 31.1 degrees and its
  occlusion floor from 0.81 to 0.03. It looks like the bake, deeper: the
  same embossed texel edges, more of them;
- authored (`tools/pbr_author/`, new): one script per stem builds a
  height field and a smoothness field from the game's 16 px art, deciding
  what the surface is (which texels are one stone, where the mortar runs,
  what the grain does inside a plank), and `lib.py` derives the normal,
  the occlusion and the `_s` map from those two fields so they agree.
  Written by three subagents against metric targets they could check
  without seeing: mean tilt by class, occlusion floor, smoothness spread,
  seam on every map.

Judged by eye on the close-up: sand and snow are the clear wins, real
grain and a soft crust where the bake had a plateau per texel. Planks
read as boards with grain. Stone, dirt and gravel are better than the
bake but still carry its signature, because the scripts dome each region
of the art with a distance field on the nearest upscaled label map, so
every dome has the square outline of the texels it came from. The next
step there is rounding the region silhouettes before the distance field
(a smooth upscale of each region mask, edges warped by noise), which is a
`lib.py` change and a rerun, not new authoring.

None of this reaches the distant view, where texel detail is under a
pixel and what makes a reference hillside read as a surface is variation
between blocks. That is a shader question and is not started.
