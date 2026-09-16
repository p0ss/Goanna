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

## Parallax occlusion and self shadow

Shown at the close-up, even the authored sets read crisp but flat: a
normal map shades a surface, it does not put depth in it. Godot has no
tessellation, so the depth is read in the fragment. `nodes_array.gdshader`
now marches the eye ray through the `_n` height channel and moves the tile
coordinate to where the ray meets the surface, so the albedo, the normal
and the material are all read at the texel actually seen, and then climbs
from that point toward `goanna_sun_dir` through the same field to find
whether the texel is in its own shade. The shadow reaches direct light by
folding into `AO` with `AO_LIGHT_AFFECT` raised to `(1 - shadow) / (1 -
AO)`, which makes Godot's direct light scale exactly the shadow wherever
the occlusion is at or above it, and the specular is scaled by it too.

Two things about it that were not obvious:

- The tangent basis is solved from the screen derivatives of world
  position against those of the tile coordinate, after the per node turn
  and shift. That is exact inside a node whatever `goanna_node_uv` did, and
  it asks nothing of the mesh's tangent convention, which this shader has
  a history with (see the green flip note in the decode).
- LabPBR carries no depth scale, and one depth for every material turned
  sand into fur: a sand grain's height byte spans the same range as a
  cobble joint's. Depth comes from the class (`goanna_class_depth` in the
  include): a tenth of a node for stone and gravel, a hundredth for sand,
  cloth and metal, `parallax_depth` scaling the table. The better answer
  is to measure each map's own depth in the client from the ratio of its
  normal slope to its height gradient, the way `pack_normal_gain` is
  measured, and pass it per layer; that is C++ and waits for a clean tree.

The march fades out over the second half of `parallax_range` (40 nodes)
and hands the relief back to the normal map, which the far flatten later
trades for roughness, so the relief has a continuous story from the eye to
the horizon. Within range it costs up to 24 height reads for the march
and 8 for the shadow per fragment; not measured against the benchmark
yet. The scissor variant (leaves, plants) is untouched, and the moon and
lamps cast no self shadow.

On the close-up the bake with parallax is the embossing with depth, which
is worse; the authored sets with parallax are surfaces. Sand is sand and
snow is snow at any angle, planks are boards, and the stony three show
real joints with sun on one wall and shade on the other, still with the
square silhouettes noted above. The ramp's `low` case (sun at 0.18 from
the camera's right) is the one to judge the self shadow on.

## The authored pack

With the close-up and parallax in place the user's judgement was that the
authored sets look better under every setting for no measurable cost, so
the authoring was scaled out: eight subagents in parallel, one material
family each (soils, sands and sandstone, natural rock, masonry, logs,
planks, leaves, and obsidian, bedrock and lapis), forty one more stems on
top of the first nine, every script in `tools/pbr_author/` and every set
judged on the close-up ramp before install. `tools/pbr_author/build_pack.py`
rebuilds all of them from the scripts and installs into
`pbr_packs/mineclonia/textures`, appending an attribution note.

What the review caught, for the next fleet:

- The seam measure is blind to phase. Several scripts rolled the art a few
  texels to move a joint off the wrap so the seam number would pass. On a
  cobble that only changes which stone is at the corner; on the polished
  stones, whose drawn bevel lives on the tile's edge, it moved the relief
  into the middle of the block as a cross. The roll came out of the three
  polished stones and they passed the seam without it, so the trap was
  never real there. A masonry course must not move at all: the brick and
  stone brick scripts keep the art's rows.
- Segmentation tolerance is the whole design decision for a mosaic. Cobble
  at 0.06 found two stones and read as a slab with holes; at 0.03 it found
  eighty three and read as cobbles.
- `lib.class_of` reads the class back out of the bake, which carries the
  bake's own mistakes: coarse dirt came back as leaves from a stray
  scattering byte and mud as cloth from a tie on the smoothness level. The
  scripts override where the art is plainly something else and say so.
- Three stems whose art does not wrap by design (podzol side, sandstone
  bottom, the polished stones) show a high albedo seam. That is the art,
  so the albedo seam is reported and never fails.
- The output directory is shared with the ramp and the other authors. One
  early agent cleared it. The brief now says never to.

The far look is unchanged by all of this: texel detail is under a pixel
past a few dozen nodes and what makes a hillside read there is variation
between blocks, which is a shader question still not started.

The user's review of the first fleet found five defects, each traced to
the script rather than the art and fixed the same day: sandstone beds
were domed per dash and stopped partway (now a per row profile), stone
brick's lower course joint was a slit because one cut never separates a
wrapped ring (the flood fill now cuts at the tile seam when a course has
exactly one joint), brick's joint geometry came from warped brick labels
rather than the mortar mask, the polished stones were speckled by crystal
noise at stone's parallax depth (the crystal is now in the smoothness
only, and their tilt sits at 21 degrees by choice), and mossy cobble was a
Voronoi jigsaw (now cobble's own segmentation). The log tops had radial
cracks converging on the pith, which read as a pinch; they now start a
third of the way out and are shallow. The ramp takes "side+top" entries so
a log renders with bark on its sides and the cut face on its ends, the way
the world dresses it, since a single stem wrapped around all six faces
had the cut on the sides too.

## The second fleet: the built world

With the surface set judged better under every setting, the authoring
went to what a village is made of once you stand inside it: five
subagents, one family each, for the furniture (crafting table, furnace
and lit furnace, bookshelf, hay bale, TNT), the doors and cut-outs (wood
and iron doors, trapdoors, ladder, rails, torch), the colour families
(wool, terracotta, concrete, concrete powder, sixteen dyes each behind one
module and a one line script per stem), and the stone variants with the
glowing blocks (cracked, mossy and carved stone brick, carved and smooth
sandstone, glowstone, pumpkins). About a hundred and twenty stems, all in
`tools/pbr_author/`, `build_pack.py` skipping the family modules.

Three things the packer and the ramp learnt from it:

- `pack` takes an `emission` field, the art's bright texels as a 0..1
  glow, written to the `_s` alpha as LabPBR has it. The lit furnace, the
  torch, glowstone and the jack o'lantern use it; the shader multiplies
  the albedo by it, so the glow keeps the art's colour.
- A nearly flat material must not fill the height range. The shader gives
  the full 0..1 range the depth of the class, so terracotta stretched to
  the byte rendered as pumice on the ramp. `lib.band` holds such a field
  in a narrow band about the middle; `normalise01` is for surfaces that
  really have the class's depth.
- The ramp now sets each cube's class from its maps, so the parallax
  depth on the ramp is the world's. Every cube had been marching at class
  none, which is half stone's depth and four times sand's; concrete powder
  looked like grit and, once corrected, the stony blocks looked like
  rubble at stone's own 0.08. The class depth table came down to 0.045 for
  stone, which is where a joint reads as a joint and where the frames the
  look was settled on had been.

Manufactured blocks came out better than the natural surfaces did,
because their art carries designed structure a script can honour:
recessed door panels, rivets found as luminance peaks, a crafting grid
read as saw kerfs, book spines as chips. The cut-outs draw through the
scissor variant, which has no parallax march, so their relief reads from
shading. The seam and tilt measures do not apply to a face that is mostly
transparent or a door whose top and bottom edges differ by design, and
those scripts say where they miss and why. The pack install into the
tracked `pbr_packs/mineclonia` is still refused by the permission
classifier; the standalone authored pack at
`baked/authored-mineclonia/textures`, linked into the launcher's texture
pack list as `mineclonia_authored`, carries the whole set.

The second fleet's review found the same failure four times over:
scripts reaching for domes and grain where the art wants flat faces and
thin lines. The furnace got cobble lumps, TNT's paper a concrete grain,
book spines the shape of chocolate blocks, and the crafting table's
engraved motif was raised as a steel tool. All four were rebuilt as flat
faces in a narrow band with joints, creases or lines recessed into them,
and the rule is in the brief. The ores were reworked to be reflective,
metal veins and gems carrying their own F0 through a new packer argument,
and redstone glows at a quarter strength; the packer's smoothness mean is
now taken over the ordinary texels so a vein at 0.9 no longer drags its
matrix down. Grass plants, the grass path and the snowed side were added.
The grass block side cannot take maps: the game draws it as the dirt side
with an overlay composited on, and companions are looked up by the base
name. Lava is a liquid on its own material and never reads these maps.

## Kythen

The first game after Mineclonia, run to the playbook on 2026-09-16 and
17: fifteen agents in two waves, batched by culture and family, 228 stems
against the 286 the bake covered, every batch rendered on the close-up
ramp under sun and lamp before commit. Kythen's art is 32 px, so a source
texel is eight map texels, and the library scaled without change; the
culture recipes in the game's own `materials.json` files gave the agents
the layout of masonry and bark where the art alone was ambiguous. Three
things came back into the library and the playbook: the smooth upscale
now wraps, a sharp periodic feature that lands on the tile edge fools the
seam measure and wants a wide taper plus a narrow kerf rather than a
roll, and a soil's occlusion comes from a sparse flat floored hollow, not
from its clods. Two reworks from review: ash bark's diamond lattice read
as chain link and became furrows, and the Gondar rubble's recess read as
a waffle and was banded. The standalone pack is
`baked/authored-kythen/textures`, in the launcher's list as
`kythen_authored`; the production path is a new terrain bundle version.
