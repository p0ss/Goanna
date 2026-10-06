# Hand authored LabPBR sets

## Current: the texel extrusion rule (Mineclonia)

Since 2026-09-26 Mineclonia's authored sets are not built by per stem
scripts. `extrude.py` applies one rule to every stem listed in
`stems/mineclonia.txt`: each source texel is a flat plateau with a one
pixel chamfer, lighter is higher inside a material (a few coarse levels
plus a smaller per texel step), very dark texels sink as joints. No noise,
no grain inside a texel, no rounded or warped outlines. The owner chose
this look over the domed, grained sets described below, which read as
high definition detail out of place in a blocky world.

A stem the rule gets wrong has a spec, `specs/mineclonia/<stem>.json`: it
maps the art's palette colours (or a per texel character grid) to
materials, each with a mode (`shade`, `parts` for pieces at one height
each, `flat`), a height range, smoothness, reflectance, metal and glow.
The docstring of `extrude.py` is the reference. Write a spec for mixed
materials (ore veins proud of stone), manufactured parts (books, beams,
rails), masonry (mortar is often lighter than the brick, so it needs its
own low material), glow, near uniform art, and wrong classes: the class
`lib.class_of` reads back from the bake falls to wood for any stem the
bake left unclassified.

The stem's micro surface (one kind for the whole tile, from the class or
the spec's `"micro"`) is wrong where a stem mixes materials: a hand
tool's wooden handle carried the head's brushed metal. A material may
name its own kind, as on a skin: `"micro": "wood"` with
`"micro_dir": "along"` (the long axis of each piece of the material, so
a diagonal handle's grain runs down the handle; also `"h"`, `"v"` or an
angle), `"micro_strength"`, `"micro_swing"` and `"micro_params"`. Any of
`micro.py`'s kinds or `extrude.MICRO_KINDS` will do, `"none"` is none,
and a material with its own kind takes nothing from the stem's
(`extrude.material_micro`). On a flat material a string `"micro"` turns
the per texel step off, so give `"step"` to keep it.

```sh
python3 tools/pbr_author/extrude.py --palette x <stem>   # palette and texel map
python3 tools/pbr_author/extrude.py <out dir> <stem>...  # build and check
python3 tools/pbr_author/build_pack.py --check           # every listed stem
python3 tools/pbr_author/build_pack.py --install         # into the pack
```

`extrude.check` replaces `lib.check` for these sets: height one value
inside each texel, several heights, the parallax depth the client derives
between 0.02 and its 0.10 cap, and the release gate on the same files.
Judge a change on the close-up ramp under afternoon, low sun and lamp.

A stem without a class in its spec takes the one frozen in
`stems/mineclonia.classes.json`. `lib.class_of` reads the class back from
the installed pack's `_s` bytes, which are this tool's own output once the
pack is authored: stone read back as gravel and four stems rebuilt
differently from the reviewed pack. A new stem missing from the file falls
back to the inference; add it to the file once it is reviewed.

### Smooth and polished stone

Mineclonia's finished stone (smooth stone, polished andesite, diorite,
granite, deepslate, tuff and blackstone, smooth basalt, smooth and cut
sandstone of both colours, smooth quartz) was built by the plain rule
until 2026-10-06, so a smoothed wall was as deep as raw rock and
DorfCraft's engravings, cut one glyph pixel per texel into such walls,
were lost in it. Each now has a spec with one `flat` material: a per
texel step of 0.03 from the art's own shades (`micro`), normal strength
12 instead of the class's 22, the stone micro surface at 0.2 (pores of
the concrete kind on sandstone), and a declared smoothness of 0.38 for
smooth stone, 0.40 to 0.50 for smooth basalt, the polished stones and
quartz, and 0.30 for sandstone, against 0.12 for raw stone. The texture
keeps its colour and mottling and is told apart from the rough block by
its flatness and sheen. Slab sides keep the art's seam as a second flat material 0.12
lower, set by `rects`. Polished basalt keeps a shallow version of its
drawn columns and rings (`shade`, span 0.12, two levels, no joints).
Chiseled and brick variants keep the plain rule. `mcl_core_sandstone_top`
and its red twin are also the top face of raw sandstone, and
`mcl_nether_quartz_block_bottom` the bottom of the quartz block, so those
faces went smooth too.

### The 128, 256 and 512 px packs

Texture resolution is a graphics tier (`docs/graphics-tiers.md`): 128 on
Lowest and Low, 256 on Medium and High, 512 on Ultra, the same for every
texture. `GOANNA_PBR_SIZE=128` or `512` builds every map at that size; 256
is the default, and nothing else is accepted. Pixel measures (the chamfer,
the normal strength, occlusion radius, bevels, the hair's contact
occlusion reach, micro feature sizes and densities, grain spacing) are
written for 256 and scale by `lib.PX`, so a 512 map has the same heights,
depths and features at twice the resolution and a 128 map at half. The
albedo is written at the map's size too, because the client sizes each
texture array by the albedo and resizes companions to it.

```sh
GOANNA_PBR_SIZE=128 python3 tools/pbr_author/build_pack.py --check --stage <dir>
GOANNA_PBR_SIZE=512 python3 tools/pbr_author/extrude.py <out dir> <stem>...
```

What changes at 128, where a measure would otherwise fall under a pixel:

- **Chamfers and bevels stay at least one pixel** (`lib.px`). Rounded,
  the default chamfer of 1 became 0 and every step a cliff. A one pixel
  chamfer at 128 is twice as wide on the block as at 256, so a step is
  half as steep; the heights and the depth the client measures are the
  256 build's.
- **The micro surface is drawn at 256 and averaged down** (`lib.SUPERSAMPLE`,
  `extrude.micro_field_px`, `atlas.material_surface_px`): the block
  kinds' pores, scratches, cracks and grain, and on skins every material
  kind, stitch, seam, rivet, strand and weave thread. A feature finer than
  a pixel fades instead of aliasing into stripes and dots: wood grain
  three pixels apart at 256 would be one and a half at 128, a cloth weave
  four pixels a period is two, and the player's bristle strands ten to a
  texel are over one to a pixel at eight pixels a texel.
- **The micro surface's slopes are faded by half** (`lib.MICRO_FADE`):
  since a step is half as steep at 128 and a pore is not, unfaded the
  micro surface stood twice as strong against the steps as in the
  reviewed look, and the client's depth measure read up to twice the
  relief on skins whose steps carry it (the chain mail leggings 0.12 node
  against 0.058). The smoothness swing is not faded.
- **The baked occlusion reads a rise per 256 px pixel** (`lib.AO_SCALE`):
  the horizon test took the rise per map pixel, so at 128 a step read
  twice as steep and stone's joints came out near black on the GPU against
  grey at 256. Over 150 tiles the 128 occlusion at half strength is within
  0.004 on average of the 256 occlusion averaged down (0.015 mean absolute
  difference), against 0.029 too dark at full strength. The 512 build keeps
  its reading as it was, which by the same arithmetic is lighter than
  256's; that has not been measured or changed.

Mob and player skins follow the size: `"texel_px"` is map pixels per art
texel at 256 and scales by the same factor, so the player's parts and
almost every mob (468 of 470 Mineclonia skins set 16) take 8 at 128 and 32
at 512, and the default of 8 takes 4 and 16.

The 256 build is byte for byte what it was before 128 existed: every
change above is behind `lib.PX < 1`. Checked 2026-10-05 over all 2,090
Mineclonia stems (`stems/mineclonia.txt` and `stems/mineclonia.mobs.txt`):
the same 6,270 files, by SHA-256.

`atlas.check` changed in two places for 128, neither failing a 256 skin
that passed before. A bevel's ring pixel counts as leaning out of its face
over any side that is off the face or undrawn, and a corner pixel (off the
face on two sides at right angles, flat at every size) is left out: at 256
corners were 2% of a ring and at 128 twice that share of a ring half as
long, which failed the tropical fish on their corners alone. And at 128 a
relief measure over the 0.10 cap passes when the authored depth (strength
over 256) is within it: the dolphin (0 at 256, too few steps to measure;
0.126 at 128) and the chain leggings (0.058 at 256, 0.109 at 128), both
authored at strength 24, 0.094 node, which the client's clip to 0.10
keeps within a few per cent.

Built 2026-10-05 and 06 at each size into scratch stages with
`build_pack.py --check`, over the 2,090 listed stems:

| Size | Stems passing | Pack files (the 3,859 the shipped pack holds) | Bundle archive (1,385 `_n`/`_s` pairs) |
| ---: | ---: | ---: | ---: |
| 128 | 2,090 | 58.7 MiB | 60.0 MB |
| 256 | 2,090 | 214.0 MiB | 219.4 MB |
| 512 | 2,083 | 660.1 MiB | 675.2 MB |

The archive is `tools/pbr_bundle.py build` on the scratch pack, so 128
is 27% of today's download and 512 is 3.1 times it. Seven skins fail at
512, every one of them the same way with the code before 128 existed
(rebuilt with main's `tools/` to check): the banner, the bamboo boat, the
piglin and its brute, the leatherworker zombie villager and the medium
cracked iron golem on their face border measures, and `mcl_skins_mouth_6`
on the release gate's directional bias, which it passes at 256.
On the banner the micro surface alone is the cause (with it off the bevel
leans out at every border pixel): at 512 a one pixel feature such as a
groove of the pole's grain is half as wide on the block and twice as
steep, the converse of the 128 case above, and it is not faded there.
Not fixed here; the 512 pack is not shipped.

### Mob skins (model atlases)

A mob skin is not a tile. It is a UV atlas of box faces, top and bottom
then the four sides of each box, and `atlas.py` builds it instead of
`extrude.py`, with the same rule and the same spec format. Skins are
listed in `stems/mineclonia.mobs.txt` as `<stem> <model.b3d> [brush]`,
never in `stems/mineclonia.txt`, and `build_pack.py` builds both lists.
The model may be an `.obj` too (the dragon head on `mcl_heads_dragon_*.obj`,
the armour stand on `3d_armor_stand.obj`): `atlas.read_obj` reads it into
mesh buffers the way Luanti's loader does, and brush is the buffer, which
for an `.obj` is not its `usemtl` name (every `g` starts one; a `usemtl`
with no `g` does not). `tools/test-pbr-atlas-obj.py` checks the reader.
Their classes are frozen in `stems/mineclonia.classes.json` like the
rest.

```sh
python3 tools/pbr_author/atlas.py x <stem> --faces            # faces and palette
python3 tools/pbr_author/atlas.py <out dir> <stem>... --preview <dir>
```

What differs from a tile:

- **Size.** The map is 8 map pixels per art texel at the 256 pack, 4 at
  the 128 one and 16 at the 512 one (a spec's `"texel_px"` scales the
  same way), whatever the art's size, where a tile is always 256
  wide (16 per texel for 16 px art). A 64 x 32 skin is 512 x 256, a
  64 x 64 one 512 square, the 128 px iron golem 1024 square. A mob texel
  is about a sixteenth of a block, like a node texel; half the node
  density keeps a flat top inside each one pixel chamfer at a quarter of
  the memory. `atlas.py` writes the art upscaled to the same size into
  the stage for previews, but `build_pack.py` installs only a skin's `_n`
  and `_s`: the client draws the game's own art at its own size and
  scales the companions to it. A pack albedo at map size broke
  mcl_skins, which colours a 64 x 32 mask in a bracketed group, and
  Luanti blits that group at its own size into the corner of the 1024
  wide part, so the player drew bare skin colour. Any server mod that
  combines or crops a skin by coordinates breaks the same way.
  `"texel_px"` in a spec overrides it. The iron golem and its crack
  overlays take 16, so 2048 square, about 16 MiB per map uncompressed
  before mipmaps against 4 MiB at 8, because its plates carry bevels,
  scratches and rivets a few map pixels across.
- **Islands.** The faces come from the model's own UVs, read from the
  `.b3d` or `.obj` the game draws the skin on. The chamfer, the normal and
  the occlusion never read across a face border or the image edge, so two
  faces packed side by side do not bevel into each other and nothing
  wraps. Drawn texels no face uses (a palette swatch, an unused limb
  layout) are islands of their own.
- **Face edges.** `"face_edge": "flat"` runs the relief flat to every
  face border. `"bevel"` slopes every border down (`bevel_depth`, a share
  of the height range, over `bevel_px` pixels at 256), which rounds the
  box's edges; every box edge is convex, so it is right without knowing
  which faces meet. The bevel goes to the normal only, so the stored
  height stays one value per texel and the occlusion does not darken a
  convex edge.
- **Strength** is in node units, so a skin and a block with the same
  number have the same rise per art texel. The entity shader marches the
  height as a block's does, to the depth measured from the map
  (`docs/materials.md`, "Mob, player and item companions").
- **Micro surface** goes on the materials `"micro_materials"` names: the
  golem's scratches are on its iron, not its vines. A material can also
  name its own kind, `"micro": "knit"` with `"micro_strength"`,
  `"micro_swing"`, `"micro_dir"` and `"micro_params"`, and carry
  `"stitch"`, `"seam"`, `"wear"`, `"texel_edge"` and `"scatter"`; then it
  takes nothing from the stem's `"micro"`. The kinds (knit, wool, weave,
  linen, canvas, coarse, twill, hair, bristle, tress, straw, leather,
  rope, skin, eye, bulge; for animals and monsters fur, hide, feather, scale, bone, rotten, mottle,
  chitin; for riveted iron, a plate per texel, plate, scratches, dents,
  rivets, rust and leaf, with mix to sum several on one material; paper;
  and wood, bark, glass, metal and metal_worn, which read the block
  kinds' own fields from `extrude.micro_field` at one block texel per art
  texel and at the blocks' rise) and the edge features are described in
  `micro.py`, and
  `python3 micro.py <sheet.png> [16|8]` draws a labelled swatch of each
  at 16 map pixels per texel (the player's parts) or 8 (a mob's). The
  animal kinds are sized for 8. They are
  evaluated per pixel along a direction per face (model down on a side,
  front to back on a top, read from the `.b3d`), never on a repeat, so a
  feature stops at its face's border. Like the stem's micro they reach
  the normal and the smoothness only. On a flat material a string
  `"micro"` turns the per texel step off; `"step"` puts one back.
- **Mirrored limbs** share one UV rectangle. The client builds the
  tangent frame per fragment from the UVs, so a mirrored limb's normal
  is mirrored with it. Author nothing that must lean one way in model
  space.
- **Overlays** drawn with `^` (the golem's cracks) take `"overlay": true`:
  their texels sink as joints into a surface at `"surface"` height, and
  everything they do not draw is the neutral fill, so the client can lay
  their maps over the skin's.
- **Metal.** Metal albedo is reflectance, so a near black metal texel is
  a black mirror (the hopper). Very dark iron is its own dielectric
  material; `atlas.check` fails a skin whose darkest metal texels are
  under 0.20 luminance.
- **Faces.** A face reads by its albedo. Skin is never `shade`: a
  height per texel at shade's steps turns a face into a checkerboard of
  coloured squares. Skin is `"mode": "soft"` (extrude.py; atlas.py's
  `soft_surface` and `edge_roll` do the rest), keys on the material:
  - `"span"` (0.08 of the height range) and `"detail"` (0.25): lighter
    texels higher in proportion to their shade, the top of the span at
    `"base"` plus half of it, no joints. Keep it small: blurred, a span
    of 0.08 stays under the client's depth measure, so it does not lift
    the march, while at 0.16 the dome and roll (normal only) raised the
    bare arm's measured depth to the cap and the march slid lighter
    texels over darker ones at a grazing view;
  - `"soft_edge"` (0.3 texels): the skin's steps between its own shades
    blurred by about that sigma in place of the crisp chamfer, in the
    stored height as well as the normal, so parallax sees the same soft
    step; steps to other materials keep the stem's chamfer;
  - `"round"` (degrees, 15; 6 on the player, 7.5 on the villagers, 5 on
    the undead, 4 on the pig, each half what it was before the owner's
    face rules of 2026-10-03): a membrane dome over each piece on each
    face, with the features it encloses filled in, its edges leaning that
    much; normal only;
  - `"edge_roll"` (texels, 2.5) and `"edge_lean"` (degrees, 25; 10 on the
    player's parts, 15 on the villagers, the trader, character_1 and the
    pig, 12 on the undead): in place of the bevel, the face falls away
    over its outer texels toward every box edge like a cushion, across and
    along added so the corners round without a crease; normal only;
    `"roll_rough"` takes smoothness off toward the edge, where a rolled
    edge can catch the sky at a grazing angle: 0.3 on the pig, 0.03
    elsewhere, because on an arm's four texel faces it left a smooth bar
    down the middle of each face, which the sun drew as stripes along
    the first person arm;
  - `"smooth_spread"` 0.02 (0.04 on the pig): barely smoother on the
    raised, lighter texels, since the arm's art runs in columns and more
    turned them into grain. No pores: `"micro": "none"` on human skin
    (the `skin` kind is off since 2026-10-03), and the undead's `rotten`
    takes `"micro_params": {"pits": 0}`, keeping its lumps and its wet and
    dry blotches. Skin smoothness is 0.25 (the husk's dry skin 0.2), with
    no sheen on the nose or the cheekbones.
  The roll's darkening at the face's edge is measured against the art's
  own: under a lamp from the view (`preview_mob.py`'s night light), the
  outermost skin texels of the head's front, against those two texels
  in, were 13 to 17% darker with maps on than with maps off at an
  `edge_lean` of 25 and a `"round"` of 12 (five of the faces study's
  seven heads), 7 to 8% at 15, about 6% at 12 and 5 to 6% at 10, so the
  player's parts take 10; the villager's head comes to 5% and the
  trader's 3% at 15. The art's own edge on those heads is between 10%
  lighter and 5% darker than its middle. A high sun from one side
  darkens the far edges more (7 to 15% at 10), as any rounding does.
  A material with `"ride": true` (the player's eye, mouth and hair
  shadow layers) takes the same dome over its whole face and the same
  roll, so the parts laid over skin curve with it; give it the skin's
  `"round"`, `"edge_roll"` and `"edge_lean"`. Only the features (brow,
  lashes, a nose box) take their own heights, and nothing on a face is
  metal or polished. The owner's face rules (2026-10-03, from the faces
  study's variant D):
  - eyes flush with the skin: the white at the skin's `"base"`, the iris
    at most 0.01 below it, never sunk; lashes and brows may stand proud;
  - no reflectance boost on eyes (no `"f0"`), the iris at smoothness
    0.8, the white at 0.6, `"micro": "none"`; a closed eye is a matte
    lash;
  - a mouth is a flat piece riding the skin at its base height, lips as
    skin, teeth at 0.35;
  - glasses lenses are their own material, dark glass set a little behind
    the frame (0.9 against 0.97), smoothness 0.86, F0 0.04, and the frame
    is not glossy (0.4);
  - the undead keep their eye and mouth pits half the height range under
    the skin: those are empty sockets, not eyes, and their floors are
    matte (smoothness 0.3, no `"f0"`).
  A part that reads a soft part's height through `"stack"` reads it flat
  at its base.
- **Heights under 1.** Parallax draws a height under 1 sunk below the
  box face; the client lifts each face's highest texel to the face
  (`docs/materials.md`), so a skin need not top out at 1. The zombie,
  husk, drowned and wandering trader skins are raised by one offset each
  so their highest part stands at 1 anyway, every relative height kept.
- **Players.** Mineclonia draws a player as layered parts, each part's
  shading over a mask coloured to the player's choice
  (`(mcl_skins_hair_1_mask.png^[colorize:#715D57FF:alpha)^mcl_skins_hair_1.png`).
  The client gives a mask the part's companions, so a part is authored
  once by its own name, with `"mask"` and `"tint"` in its spec: the
  materials are read from the art over the tinted mask, the part covers
  both, and the albedo written is still the art alone, so a player's own
  colour reaches it. `"stack"` lists every part in drawing order, so a
  part's edges slope to whatever is drawn beside it and its occlusion
  reads the parts drawn over it. List only parts that are always drawn
  there: the occlusion is baked into this part's maps and shows under
  whatever the player picks instead. mcl_skins_base_1 had eye_1 and
  hair_1 in its stack until 2026-10-03, and eye_1's lash row and
  hair_1's fringe showed in the base's occlusion under every other eye
  and hair; the base now has no stack, the eyes, mouths and hair 2 to
  11 stack only on the base, and hair_1 no longer lists eye_1. `"cover"` (an alpha) counts every art texel at
  that alpha or more as drawn: the client lays a part's maps over the
  base's by the part's albedo alpha, so a faint shading texel left
  neutral (a mouth's corner, a closed eye's lid, a fringe's shadow on the
  face) mixed a neutral map's full height and no smoothness into the
  skin; covered, it takes the maps of its material, skin like. The
  default player's parts take
  `"texel_px": 16` (1024 x 512 maps for the 64 x 32 art); mobs stay at 8.
  `preview_figure.py <maps> <out>` composites the six parts the way
  Luanti and the client do and lights the model's front faces offline;
  its docstring says what it leaves out.
- **Hair.** A material can take `"lock_round"` (a gaussian's sigma in
  texels): every step the hair stands over, to its own other levels and
  to whatever is beside it, rolls off over about that width in place of
  the crisp chamfer, in the stored height and the normal alike, and
  `"edge_roll"` rolls its box edges instead of the bevel, as skin's do.
  The player's hair took it until 2026-10-03 (variant `round1`).
  `atlas.check` holds a rounded material to keeping each texel's level at
  its middle rather than to the flat texel grid. `"hair_mark"` (off by
  default; `GOANNA_PBR_HAIR_MARK=1` turns it on for any material that
  names it) writes the `_s` green byte as 12, an F0 of 0.047 that no
  other map in the pack uses and that is hair's own reflectance, so a
  renderer can tell hair texels apart for an along the strand highlight
  (`atlas.HAIR_F0_BYTE`).
- **Hair drawn by the client.** Since 2026-10-03 the player's hair is
  built for a client that draws the strands itself
  (`project/shaders/hair_strands.gdshaderinc`): hair mark on, no micro,
  no detail, no rounding; each lock a flat plateau at its legend level
  with a one pixel chamfer and a two pixel box bevel, the dark gap texels
  sunk as joints. `"lock_occlusion"` (0.55) darkens the stored
  occlusion beside every higher pixel of the same island within
  `"lock_occlusion_px"` (6) map pixels, twice that reach from the
  image's up, in proportion to the rise; `"gap_occlusion"` [0.5, 0.25]
  darkens every pixel below height 0.5 by a quarter (`atlas.lock_occlusion`).
  Offline parallax keeps the art: `preview_mob.py --parallax
  --legibility` puts the worst face, the head's top, at 91 per cent of
  texels keeping half their area.
  The other hair styles (hair_2 to hair_11) are hair_1's spec with their
  own grid. A texel's shade is its luminance over the tinted mask
  averaged over a dark (#151515), a mid (#715D57) and a light (#EBE8E4)
  tint, since the player picks the colour. Inside each face, neighbouring
  runs of close shades merge into one lock, closest first, while the
  lock's shades span at most 0.45 of the style's own shade range, so a
  dark or low contrast style does not split on small differences and a
  smooth gradient does not chain into one lock. The locks, whole, then
  split into three runs as near thirds of the texels as can be (lightest
  `L` 0.88, `m` 0.74, darkest `g` 0.46), the darkest locks up to 3% of the
  texels `G` 0.42; opaque colours that are not shading (hair_9's gold
  beads) are the clasp, and a fringe's faint shadow on the face outside
  the mask is covered as skin. With no merging the rule gives every
  committed grid back texel for texel. Until 2026-10-03 the styles took
  one lock per run of a whole shade, and on dark, near uniform art
  (hair_2's beard and fringe at #151515) that made a bevelled square
  tile of almost every texel. Merging took the locks from 75 to 206 per
  style to 18 to 93 (hair_11's three shades are far apart and it keeps
  its 116). hair_1 keeps its grid: its strand columns are white
  highlights that show at every tint, and merging would join them into
  blobs. At `--yaw 35 --pitch 10` over base_1 and eye_1 the head's top
  keeps half the area of 60 to 100% of its texels (hair_5 60%, 69%
  before; hair_1 and hair_11 75%). Judged offline only.
- **Variants.** A spec's `"variants"` holds named alternatives;
  `GOANNA_PBR_VARIANT=<name>` lays one over the spec, its top level keys
  replacing the spec's and its `"materials"` entries laid over each
  material key by key, a null removing a key (`extrude.variant_spec`).
  The player's hair keeps `old` (the authored strand maps, rebuilt byte
  for byte with `GOANNA_PBR_HAIR_MARK=1`), `round1` (the first rounded
  maps for the shader) and `no_contact` (the crisp locks without the
  contact occlusion).
- **Sculpted faces (variant `sculpt`, not shipped).** The owner's
  suggestion of 2026-10-03: read the pixel artist's shading as form, lit
  from one side, so the light bits of a face and hands stand out and the
  dark bits go in. The illagers, the villager, the zombie, the zombie
  villager, the piglin, the player's base and character_1 carry it, with
  the seven mouths. `GOANNA_PBR_VARIANT=sculpt` builds it; the default
  build of every mob stem is byte for byte what it was. The variant sets:
  - skin `"span"` 0.22 (from 0.08), the soft step blur kept at 0.3 texels,
    the dome `"round"` down to 4 (the piglin keeps 3);
  - `"flush"` on the features (extrude.flush_features): each piece stands
    at the mean height of the skin 4 adjacent to it plus an offset, so
    eyes stay flush with the skin round them (the iris 0.01 under the
    white), brows 0.06 proud, the illagers' and villager's mouths 0.04
    in; the undead keep their sockets;
  - on the player, `"anchor": "top"` (the lightest skin at `"base"`, where
    the eye parts lie), `"stack_soft"` (the parts laid over the base read
    its sculpted heights, not its flat base, through `"stack"`), each
    mouth 0.025 under the skin it covers, and a nose `"ridge"`
    (atlas.nose_ridge): the light and dark pair either side of the head
    front's middle, two rows between the eyes, becomes a ridge a quarter
    of the span above the cheek, the light texel sloping up to it and the
    dark one falling away, where the shade alone read it as a dent.
  Spans of 0.15, 0.22, 0.3 and 0.45 were compared offline
  (`preview_mob.py --parallax --legibility --contrast --night`, front and
  35 degrees, the head front three times enlarged). The head fronts keep
  half the area of 94 to 100% of their texels at every span, as shipped.
  The relief reads only under a low sun or a lamp: the client measures
  about 0.05 nodes for the full range at strength 12, so 0.22 of it is a
  sixth of a texel. At 0.3 and over a lit rim showed along the villager's
  eye row, where the darker lower face drops below the eyes. On the GPU
  (2026-10-03, w_epbr_mcl's statues, parallax 1.0, SDFGI 1.4) the close
  head crops of shipped and sculpt differ by 1 to 2 levels in 255 on
  average, 6 to 27 at the 99th percentile: at 0.22 the sculpt barely
  shows in the game. Deeper relief needs a larger "strength" on the
  skin, which this variant does not try. The release
  gate warns on mcl_skins_mouth_6 (two texels on the head's bottom edge,
  a mean normal leaning off the rolled edge), as a whole tile measure on
  a two texel part.
- **Crisp sculpted faces (variant `sculpt_crisp`, not shipped).** The
  same idea as `sculpt` with the animals' treatment in place of soft
  skin, since a step blurred over 0.3 texel stays too gentle to show at
  any span. On the illagers, the villager, the zombie, the piglin, the
  player's base and the player's seven eyes and seven mouths:
  - skin in `shade` mode: 3 levels, the detail harmonic at 0.25, no
    joints, the stem's 2 pixel chamfer, a span of 0.3 at strength 12
    (a rise per texel of 3.6, against the cow's 0.14 at 24, 3.4, and
    the creeper's 0.18 at 18, 3.2; the piglin, at 24, takes half,
    and strength 22, because the crisp plateaus lifted the depth its
    check measures to 0.106 against the 0.10 cap);
  - `"merge": 0.2` on the skin (extrude.merge_plateaus): neighbouring
    close shades become one plateau first, closest first, while a
    plateau's shades span at most a fifth of the skin's range, so steps
    fall between the art's shading regions (the light face, the cheek
    shadow columns, the forehead) and not round every texel. Without
    it, or at the hair styles' 0.45, the illagers' 0.35 to 0.43 shades
    either tiled or merged into one flat face;
  - the skin `"ride"`s (the face's dome and edge roll, normal only, at a
    `"round"` of 4), and so do the brows, eyes, mouths and ear holes, so
    the face curves as one;
  - brows 0.08 proud of the skin round them (`flush`); on the player the
    darker band over the eyes is the brow, 0.04 over the light skin,
    where its shade alone sank it as a trench; mouths 0.1 under the skin
    round them (teeth 0.08; mouth_6, two texels on the head's bottom
    edge, 0.03, since at 0.1 the release gate failed its normal for a
    directional bias); ear holes, the darkest texels on each side
    of the head (`"rects"` in the variant), 0.1 under the lowest skin;
    the undead keep their sockets and the piglin its nostrils;
  - the player's nose pair kept as a ridge (`atlas.nose_ridge`), on a
    soft `"nose"` material over the two texels, flush with the skin;
  - eyes: the white and iris one material (`"mode": "soft"`, so the
    iris is smoother than the white by its shade, 0.8 against 0.6),
    flush with the skin under it, and gently convex as a whole through
    the micro kind `"bulge"` (micro.py): (1 - u^2)^2 across and along
    the eye's box, steepest lean 6 degrees, zero slope at the edge, so
    no rim and no dot. Normal only. The player's eye and mouth parts
    stand at the mean height of the base's skin under them in this
    variant, as numbers in their specs; change the base and they need
    recomputing.
  Judged offline with `preview_mob.py --parallax --legibility --night`,
  front and 35 degrees, the head front three times enlarged, beside the
  cow. Every head front keeps half the area of at least 97% of its
  texels through the march. Under a low sun and a lamp the plateau steps
  read as crisp edges at the cheek shadows, the brows and the mouth
  lines; under a high sun the face looks much as shipped.
- **The plains farmer villager** is four layers,
  `mobs_mc_villager_base^mobs_mc_villager_plains^mobs_mc_villager_profession_farmer^mobs_mc_stone`,
  each its own stem at `"texel_px": 16` with the same `"stack"`, so it
  matches the player beside it. That is 1024 x 1024 maps for the 64 x 64
  art, four times the memory of 8 per texel. The overlays carry
  `"overlay": true`. The base is drawn under every biome and profession,
  but its stack names the farmer's layers, so its occlusion next to a
  layer the farmer draws is right only for the farmer.
  `preview_figure.py <maps> <out> --figure villager` previews it, with a
  view from above for the hat's top and brim.
- **Any mob, offline.** `preview_mob.py <model.b3d> <maps> <out> <layers
  per brush>...` rasterises every box of the model in its bind pose from
  the front three quarters, with each brush's layer string composited as
  above, a sun, a sky ambient and a crude sky reflection, and writes
  `compare.png` (maps off, maps on, low sun on, low sun off). Pass
  `blank.png` for a brush the game leaves empty. Its docstring says what
  it leaves out: shadows, animation, alpha blending, perspective, the
  client's post process.

`atlas.check` measures one height per texel, several heights, the relief
in node units, no slope step at a face border (or, with a bevel, every
border pixel leaning outward), no extra occlusion at a border, the
smoothness range, transparent texels neutral in both maps, and the
release gate, whose wrap seam warning does not apply to an atlas.

Everything below describes the per stem scripts Kythen still uses.

## The per stem scripts (Kythen)

One script per texture stem, `tools/pbr_author/<stem>.py`, building the
height and smoothness fields for that surface from the game's own 16 px art
and packing them with `lib.py`. This exists because the bake's relief is an
embossing of the pixel grid: each source texel becomes a plateau with a
soft edge, and lifting it (`tools/pbr_relief_normalise.py`) only makes the
embossing deeper. A cobble is not sixteen square plateaus; it is domed
stones with mortar between them, and that is a decision about what the
surface is, which no amount of processing the picture makes.

The measurement that started this is in `docs/material-calibration.md`:
over the Mineclonia pack the mean texel tilt is six degrees and the
occlusion never falls below 0.81. The look people call plastic is a correct
BSDF on a surface with no structure on it.

## Which game

A script declares its game once, `GAME = "kythen"`, and passes it to
`lib.load_source(stem, GAME)` and `lib.class_of(stem, GAME)`; a script with
no declaration is Mineclonia's. `lib.GAMES` says where each game's art and
bake are. Art sizes differ (Mineclonia 16 px, Kythen 32 px); every helper
scales by the art's size, and `pack` takes `art_texels=src.shape[0]` for
the seam measure. The playbook for running a fleet on a new game is
`docs/pbr-authoring-playbook.md`.

## What a script does

```python
import lib
src = lib.load_source("default_cobble")          # 16 px RGBA, 0..1
albedo = lib.upscale(src[..., :3])               # 256 px, texel plateaus kept
height = ...                                     # 256 x 256, 0 deep, 1 high
smooth = ...                                     # 256 x 256, 0 rough, 1 smooth
m = lib.pack("default_cobble", out_dir, albedo, height, smooth, "stone",
        normal_strength=10)
print("\n".join(lib.check(m, "stone")))
```

`pack` derives the normal, the occlusion and the `_s` map from those two
fields, so they agree with each other, and returns `metrics`. `check` prints
pass or fail against the targets. `preview` writes a lit swatch for a person
to look at; the script itself cannot see, so it prints the numbers and stops.

Run with the output directory as the first argument. Use a directory of
your own; several scripts writing one directory is fine, but never clear
it, another author may be writing there too.

```sh
python3 tools/pbr_author/default_cobble.py /tmp/authored
```

## Rules

- **Start from the art.** The 16 px source is the design: it says where the
  stones are, where the planks meet, what is light and what is dark. Use
  `lib.segments` to find its regions, `lib.warp_labels` to bring the label
  map up to size with rounded, irregular silhouettes (never `np.kron`: the
  first stony sets used it and every dome carried the pixel grid), and
  `lib.region_edges` and `lib.distance_to_edge` to turn joints into grooves
  and regions into domes. Do not invent a different layout; a player
  recognises the block by its art and the relief has to sit on it.
- **Take the class from `lib.class_of(stem)`.** It is read back from the
  bake, and it decides the smoothness level, the scattering byte, the tilt
  target and the parallax depth in the shader.
- **Faces of one block match.** A log's side and its top, a podzol's top
  and side, sandstone's three faces: build them from the same ideas and
  the same noise seeds where they share material, so the block reads as
  one thing.
- **Masonry is built from its mortar.** Find the mortar texels by shade
  and let the joints be that mask, continuous into the mortar rows above
  and below; the bricks are whatever the mortar encloses, wrapped. Never
  find bricks by connected components (a narrow end brick that continues
  across the wrap becomes a standalone sliver) and never roll the art (a
  bevel drawn on the tile's edge moves into the middle of the block). If
  the seam measure reads high with a joint on the wrap, report the number;
  do not move the joint.
- **Strata are a profile, not regions.** Bedded rock (sandstone) takes its
  beds from a per row mean of the art, continuous across the tile, with the
  art's dashes as detail on the profile, or the beds come out as ledges
  that stop partway.
- **Nearly flat materials must not fill the height range.** The shader
  gives the full 0..1 range the depth of the class, a mortar joint for
  stone, so a fired tile or a cast slab whose faint texture is stretched
  to the byte by `lib.normalise01` renders as pumice. Use `lib.band` with a
  small half width for those; `normalise01` is for surfaces that really
  have the class's depth.
- **Polished faces are flat.** A polished stone's crystal texture goes into
  the smoothness field, not the height; with the class depth of stone every
  pore becomes a pit and the face reads as speckled.
- **Texel scale grain is scaled down by the packer** (`fine_detail`,
  default 0.35): under a grazing lamp in a cave every grain became a
  shadow and stone read as rubble. Keep grit for the roughness map, not
  the height; pass `fine_detail=1.0` only where texel detail is the point.
- **Do not warp dressed or manufactured art.** `lib.warp_labels` with any
  amplitude turns the drawn squares of a cut stone into scribbles; use
  amp 0 there and keep the warp for natural stone and soil.
- **No Voronoi.** If the art will not segment at one tolerance, try
  another; a partition invented by the script is a jigsaw of straight
  edged pieces that nobody laid.
- **Structure below the texel.** Inside each 16 px texel there are 256
  texels of the map. That is where grain, pores, scratches and chips live,
  from `lib.fbm`, `lib.white_noise` and `lib.blur`, at the scale the
  material really has: sand grains are a texel or two, wood grain runs the
  length of a plank, stone pores are a few texels across.
- **Roughness follows the height.** Recesses collect dust and stay rough;
  raised faces are what wears smooth. Build `smooth` from `height` and add
  the material's own variation on top. Keep the spread; the packer moves
  the mean onto the class level for you.
- **Tile.** Every helper in `lib.py` wraps. Anything you build by hand must
  wrap too, and `check` measures the seam on all three maps.
- **Only the height and smoothness are yours.** The albedo is the art,
  upscaled with `lib.upscale` (nearest, so its plateaus stay) or, for a
  surface where the bake's soft upscale is better, `lib.load_baked_albedo`.
  Do not repaint it. Tinted textures (grass top, leaves) are greyscale by
  design; the game colours them.
- **Glowing blocks pass `emission`** to `pack`: a 0..1 field of how much
  each texel glows, taken from the art's bright texels (lit coals, the
  body of glowstone, a pumpkin's cut face). Everything else leaves it
  unset. The shader multiplies the albedo by it, so the glow has the art's
  colour.
- **Reflective minerals pass `f0` or `metal_mask`** to `pack`: a metal ore
  vein is `metal_mask` on its texels with high smoothness (the shader
  reflects the sky through the albedo colour), a gem is `f0` on its texels
  (diamond 0.17, emerald 0.16) with smoothness near 0.9. The matrix around
  them stays at the class level.
- **Flat where the art is flat.** Dressed stone, paper, book spines, a
  plank panel with an engraved motif: thin joints and shallow lines on a
  face held nearly flat with `lib.band`, never domes per region and never
  the cobble recipe. The first furniture pass gave a furnace cobble lumps,
  TNT concrete grain and book spines the shape of chocolate blocks.
- **Cut-outs (doors, trapdoors, ladders, torches, rails) draw through the
  scissor shader**, which decodes the normal and specular maps but does not
  run the parallax march. Author them the same way; the relief will read
  from shading only.
- **Families share one module.** Sixteen wools are one weave: write
  `<family>_family.py` with a `run(stem)` and a one line `<stem>.py` per
  colour that calls it, so `build_pack.py` still finds a script per stem.
- **Text style of the repository applies** to the scripts: Australian
  English, no em dash, plain comments saying why.

## Targets

| class | mean tilt | ao min | smoothness sd |
|---|---|---|---|
| stone, cobble, gravel | 28 to 40 degrees | at or under 0.35 | at or over 0.08 |
| planks | 18 to 28 | at or under 0.35 | at or over 0.08 |
| dirt | 15 to 25 | at or under 0.35 | at or over 0.08 |
| sand | 8 to 16 | any | at or over 0.08 |
| leaves, grass top | 20 to 30 | any | at or over 0.08 |
| snow | 6 to 14 | any | at or over 0.08 |

`normal_strength` in `pack` is the height of the full 0..1 range in texels.
Ten means the deepest groove is ten texels below the highest dome on a 256
map, which is a real joint on a cobble and far too much for sand; it is the
main lever for tilt.

## Licence

The art is Mineclonia's, CC BY-SA 4.0, based on Pixel Perfection by XSSheep
and Pixel Perfection Legacy by Nova Wostra. A set built on it is a
derivative under the same terms and carries the same attribution; see
`pbr_packs/mineclonia/ATTRIBUTION.md`.
