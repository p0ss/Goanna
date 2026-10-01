# PBR authoring playbook

## Mineclonia now uses one rule, not a fleet of scripts

On 2026-09-25 the owner rejected the scripted look on review (high
definition grain and domed stones, out of place in a blocky world) and
chose crisp extrusion of the art's own texels instead. Mineclonia's 228
authored stems are now built by `tools/pbr_author/extrude.py` from
`tools/pbr_author/stems/mineclonia.txt`, with per stem specs in
`tools/pbr_author/specs/mineclonia/` where one shaded material is wrong.
`tools/pbr_author/README.md` explains the rule and the specs. A fleet for
a new game now writes specs, not scripts: an agent per material family
reads each stem's palette map and preview, writes a spec where the rule
fails, and checks each with `extrude.check`. No GPU for the agents; the
session running them renders the ramp one client at a time.

## Mob skins

Mob skins are model atlases and are built by `tools/pbr_author/atlas.py`
from `tools/pbr_author/stems/mineclonia.mobs.txt`, with specs in the same
directory as the blocks' (`tools/pbr_author/README.md`, "Mob skins").
A skin's pack set is its `_n` and `_s` only, never an albedo: the client
draws the game's own art, at its own size, which server mods colour, crop
and combine by coordinates. The iron golem, its three crack overlays and the bare villager were the
prototypes, on 2026-10-01; none of them has been judged in game yet.

For a fleet doing the rest, an agent per mob family (villagers and their
profession overlays; cow, pig, sheep; zombie, skeleton, creeper; chicken)
works like a block agent with two extra steps:

1. Add the skin to `stems/mineclonia.mobs.txt` with the model it is drawn
   on (`grep mesh mods/ENTITIES/mobs_mc/<mob>.lua`) and, when the model
   draws several textures, the brush. Freeze its class in
   `stems/mineclonia.classes.json`.
2. Read `atlas.py x <stem> --faces`: the palette and every face's texels.
   Assign colours to materials face by face, because one colour can be
   skin on a head and cloth on a sleeve. A grid in the spec settles that.

Overlays drawn with `^` (villager professions, the golem's cracks) are
their own stems with `"overlay": true`. The client composites their maps
over the base skin's; how is the client's business, not the spec's.

A face reads by its albedo, not its relief. The renderer's probe of
2026-10-01 put a bevel on every texel and polished metal on a villager's
skin, and the owner read the result as "a checkerboard with different
coloured squares", not a face with a nose and eyes. So on a face: the skin
is one `flat` material, never `shade` (a height per texel is the same
checkerboard, softer); only the features (brow, eyes, mouth, a nose box)
take their own heights; nothing on a face is metal or highly polished
except the eyes; and the face's bevel is the box edge only. A metal face
(the iron golem's) is the open case: judge it on the GPU before a fleet
copies it.

The default player (mcl_skins' six parts on `mcl_armor_character.b3d`)
was authored on 2026-10-01 against the owner's mockups: each art texel's
colour kept, material inside it. Each material piece is one height and
pieces stand at different heights (hair proud of the head, belt, cuffs,
strap and clasps proud of the cloth), except the hair, which keeps a
height per art shade so its locks stack with dark gaps between. Inside a
piece the detail is the material's own micro kind (knit shirt, coarse
weave trousers, leather with stitching inside every edge, each hair lock
a rounded bundle with a few soft strand grooves and a sheen band across
it, near nothing on skin, one small soft rise on each flat iris for a
catch light), in the normal and smoothness only. It has been judged only
on `tools/pbr_author/preview_figure.py`'s offline figure, not in game.

Second round, from the owner's review of the first: parallel straight
strands at one spacing on a flat lock read as wood planks; sunk seam
texels on the trousers read as plaid (the darker lines are now shading
on one flat panel); knit and weave showed only under a low sun, so their
strength was raised to read in ordinary light; and a dome over the whole
iris drew a ring at its edge.

Third round of the hair (2026-10-02): the owner found the rounded
bundles plastic tree bark, and the first round's straight grain closer.
A few wide wavy grooves carved into a surface read as bark, and a sheen
band with a round across each lock read as plastic. The hair now takes
the `bristle` kind: each lock is about ten fine straight strands to a
texel, each a thin cylinder whose normal tilts across it and not along
it, with no groove between them, and the strands end raggedly short of
a tip that stands over a lower texel. A strand is under two map pixels
wide, which a central difference of a height cannot draw (a two pixel
ridge has no difference across it), so the kind gives its normal as
slopes averaged over sixteen points per pixel, and an occlusion for the
gaps between strand ends; `atlas.py` and `lib.pack` take both. The lock
layout and levels are the second round's. Most of the strands are gone
by the second mip level (four map pixels per art texel), which is about
a player a dozen nodes away on a 1080 line screen at a 72 degree field
of view (estimated, not measured in game), so at a distance the hair is
its lock steps and its smoothness only.

The plains farmer villager was authored on 2026-10-02 after the first
villager pass looked no different in game with maps on: only the base
had maps, and the plains and farmer overlays, which cover nearly all of
it, composite flat and rough when they have none. Its biome clothes,
profession and stone badge are now overlay stems with the base, all at
16 map pixels per art texel like the player. The face is the player's
rule (flat skin, a flat dark brow, flat glossy eyes, a sunk mouth, a
nose box with a little sheen); the hat is plaited straw, each texel a
tile at a slightly different height; the cloth is linen, wool, coarse
weave and canvas with a very shallow outline per texel; belt and shoes
are stitched. Judged only on the offline figure, not in game.

The iron golem was re-authored on 2026-10-02 against the owner's riveted
plate mockups, at 16 map pixels per art texel. It is armour, so unlike a
face every iron texel is its own plate: a crisp shallow bevel, a small
tilt and step per plate, scratches, hammer dents and its shine varying a
little (micro kinds `plate`, `scratches`, `dents`, summed with `mix`),
and rivet heads in the outer corners of plates along each piece's border
rows and columns (`rivets`). Its face is distinct pieces: the brow band
one flat dark dielectric piece standing proud, the nose box one smooth
metal plate, the eyes deep sockets with the red flat and glossy near
their floor. The art's dark iron and grime texels are rust (`rust`:
flaky, pitted, very rough, non metallic); the albedo is not repainted.
Vines stand proud with small overlapping leaves in the normal (`leaf`),
since they cannot change the silhouette. The crack overlays sink as
rough rust grooves. Judged only on `preview_mob.py`, not in game.

No GPU for the agents. Judge on the previews and the check, then render
one client at a time.

## Family brief: animals and monsters

The owner approved the player on the GPU on 2026-10-01. Animals and
monsters follow the same look with their own materials:

- the art's colours and texel grid kept exactly;
- each material piece one flat height (a lock of hair, or a tuft of a
  long coat drawn as its own shade, is the only exception);
- all fine detail inside the texels, in the normal and the smoothness
  only, through a material's `"micro"` kind;
- faces flat, eyes flat and glossy, with no domed iris and no raised dot;
- the detail strong enough to read in ordinary front light, not only
  under a grazing sun.

### Which kind for which part

- `fur`: cow, mooshroom, wolf, fox, cat and rabbit coats. `"length"` 0.8
  for a short coat (cow), 1.2 to 1.6 for a long one (wolf); polar bear
  and a sheared sheep longer, with more `"clump"`.
- `wool`: a sheep's fleece. Try a low `"cols"`; it is fleece, not
  knitting.
- `hide`: pig and hoglin skin, bare cow parts (the udder). Slightly waxy,
  `"smooth"` about 0.35.
- `feather`: chicken and parrot, about a texel per feather.
- `scale`: fish, guardians, anything scaled.
- `bone`: skeleton, stray, wither skeleton. Satin, `"smooth"` about 0.45.
- `rotten`: zombie, husk and drowned skin. The blotchy smoothness is the
  point.
- `mottle`: the creeper. Matte; the art already carries the blotches.
- `chitin`: spider, cave spider, endermite, silverfish. Glossy,
  `"smooth"` 0.55 to 0.65.
- `none`, `leather` or `bone`: a snout, beak, hoof or horn, each its own
  flat piece.
- `knit`, `coarse`, `linen`, `leather`: clothes (a zombie's shirt, a
  villager's robe), as on the player.

`python3 tools/pbr_author/micro.py <sheet.png> 8` draws every kind at a
mob's map density; each kind's parameters are in its docstring in
`micro.py`. The animal kinds are sized for 8 map pixels to a texel:
nothing in them repeats in under about 2 pixels. Keep it that way when
you change a parameter (fur `"strands"` and feather `"barbs"` alias at 8).
Raise `"micro_strength"` (the player's cloth took 1.8) rather than
inventing a new kind; ask for a new kind in your report if none fits.

`"micro_dir"` defaults to `"down"`: model down on a side face and front
to back on a top face, so fur and feathers lie from head to tail on the
back and down the flanks with no extra work. A mob whose model is not
upright in the file needs a check of which way that is on the preview.

### Faces

A face reads by its albedo. An animal's face is one flat skin or fur
material, never `shade` (a height per texel is a checkerboard). The
features are their own flat pieces at their own heights: a snout or a
beak a little proud of the face (`"flat"`, its own `"base"`), nostrils
sunk, a wattle its own piece. Eyes are flat and glossy: `"micro":
"none"`, `"smooth"` about 0.85 to 0.9, `"f0"` 0.025, never the `eye`
kind (its raised catch light was rejected on the player), never metal.
Only the face's box edge takes the bevel.

### What a family agent writes

Write only `tools/pbr_author/specs/mineclonia/<stem>.json`. Do not edit
`stems/mineclonia.mobs.txt` or `stems/mineclonia.classes.json`: three
families run at once and those files are shared. Put `"class"` in the
spec, build and check without the list by naming the model, and report
the lines for the merging session to add:

```sh
cd tools/pbr_author
python3 atlas.py x mobs_mc_cow --faces --model mobs_mc_cow.b3d
python3 atlas.py <out> mobs_mc_cow --model mobs_mc_cow.b3d --preview <out>/flat
python3 preview_mob.py mobs_mc_cow.b3d <out> <out>/view mobs_mc_cow.png blank.png
```

The texture strings per brush are in the mob's Lua file
(`mods/ENTITIES/mobs_mc/<mob>.lua`, `textures = {...}`); pass
`blank.png` for a brush it leaves empty, and the right `--brush` for the
skin (the zombie's is 1, the skeleton's 2, the spider's model has
`-1`). Report, per stem:

```
stems/mineclonia.mobs.txt:     mobs_mc_cow mobs_mc_cow.b3d
stems/mineclonia.classes.json: "mobs_mc_cow": "cloth",
```

and the paths of your `compare.png` previews. Never write into
`pbr_packs/`.

## Kythen's per stem scripts

The procedure below is the one Kythen's scripts were made with.

How to give a Luanti game hand authored material maps with a fleet of
agents, the way Mineclonia got its 177 sets on 2026-09-15 and 16. This is
the operating procedure; `tools/pbr_author/README.md` is the brief the
authoring agents read, and `docs/material-calibration.md` is the record of
what was measured and why the rules are what they are. Read all three
before running a fleet for a new game.

## What you are making

For each texture stem the game draws, three files at 256 px beside its art:
the albedo (the game's own art upscaled, never repainted; a mob skin ships
none, see "Mob skins"), a `_n` map
(tangent normal, occlusion, height) and a `_s` map (smoothness, F0 or
metal, scattering, emission), the LabPBR layout `docs/materials.md`
describes. The client reads them by name from a pack directory or from
server media. A script per stem in `tools/pbr_author/` builds a height
field and a smoothness field from the art and `lib.py` derives the rest, so
every set is reproducible from its script and the game's art alone.

The reason this exists rather than a generated bake: a bake embosses the
pixel grid, one plateau per source texel, and at the client's relief gain
every texel outline is a ridge. That is the look people call plastic. An
authored set decides what the surface is, which texels are one stone and
which the mortar, and puts real structure there.

## Before the fleet

1. **Add the game to `lib.GAMES`** in `tools/pbr_author/lib.py`: where its
   art is (a game root, indexed recursively), which pack of `_s` files the
   class can be read back from (a bake, if one exists; `class_of` falls back
   to the stem's name without one), and where the shipped pack lives.
   Check `lib.load_source(stem, game)` finds a stem and prints the art's
   size. Kythen is 32 px where Mineclonia is 16; every helper scales by the
   art's size but the scripts must pass `art_texels` to `pack`.
2. **Choose the stems and batch them by material family.** A batch is
   five to eight stems of one family, soils, sands, natural rock, masonry,
   logs and planks, leaves and grass, cut-outs, colour families, glowing
   blocks, furniture. One agent per batch. Faces of one block go to the
   same agent. Use a bake's stem list, a usage census, or the game's mapgen
   and building blocks as the ranking; the ores and the doors were missed
   the first time because a name check used the wrong prefixes, so check
   names against the pack, not against memory.
3. **Write the brief per batch** from the template below. Name the stems,
   the class treatment you expect for each, the worked example scripts to
   read, the output directory (one per agent, never cleared), and the
   rules the family is most likely to break.
4. **Have the judging ready.** The close-up ramp,
   `project/material_ramp.tscn` with `GOANNA_CLOSE=1`, takes
   `GOANNA_RAMP_STEMS` (comma separated, `side+top` pairs dress a block the
   way the world does) and `GOANNA_BAKED_DIR` pointing at the agent's
   output. Run it with `GOANNA_TIMES=afternoon,low,lamp`: the afternoon sun
   for levels, the low sun for self shadow, and the lamp for what a cave or
   a night village does to texel grain. Judge under all three. The agents
   cannot see; you can, and the user's eye caught what every metric passed.

## The brief, template

Fill in the parts in angle brackets; keep the rest.

    You are authoring hand made LabPBR material maps for <game> textures in
    /var/home/poss/Documents/Code/Godot/goanna. Read tools/pbr_author/README.md
    and tools/pbr_author/lib.py first: conventions, helpers, targets, the
    packing call and the rules. Read <two or three worked example scripts>.
    Follow CLAUDE.md text rules (Australian English, never an em dash, plain
    comments).

    Every script declares GAME = "<game>" at module level and passes it to
    lib.load_source and lib.class_of, and passes art_texels=src.shape[0] to
    lib.pack.

    Your stems (<family>): <list>.

    <One sentence per stem or per group saying what the surface is and how
    its art should be read: which texels are joints, beds, blades, rivets;
    what is flat; what glows; what is metal or gem.>

    For each, write tools/pbr_author/<stem>.py with the lib helpers
    (lib.segments, lib.warp_labels for natural surfaces only, never np.kron,
    never roll the art, lib.region_edges, lib.distance_to_edge, lib.fbm,
    lib.white_noise, lib.blur, lib.band for anything nearly flat, lib.pack,
    lib.check, lib.preview). Use lib.class_of(stem, GAME) unless the art is
    plainly something else, and say so. Albedo is lib.upscale(src[..., :3]),
    or lib.upscale(src) with alpha for a cut-out.

    Write outputs to <one directory for this agent> (never delete or clear
    any directory). Iterate until lib.check passes where it physically can
    (the albedo seam is informational; a mostly transparent cut-out, a
    polished face or a flat manufactured face may legitimately miss the tilt
    band, report it and say why). Do not touch lib.py, README.md or any
    existing script, and do not commit. You cannot see images; judge by
    metrics and physical plausibility.

    Report per stem: the layout found, the structure built, final metrics,
    check lines and normal_strength.

## The review loop

For each batch that reports:

1. Copy its output into one merged directory and render the batch on the
   close-up ramp under afternoon, low and lamp. Look at every block.
2. Sort what you see into the known failures before inventing new ones:
   - domes per region where the art wants flat faces and thin lines
     (masonry, paper, book spines, engraved panels);
   - texel scale grain reading as rubble under the lamp (the packer damps
     it, but a script can still put too much in the height; grit belongs in
     the smoothness);
   - full range relief on a nearly flat material (needs `lib.band`);
   - warped labels on dressed art (scribbles; amp 0 there);
   - a joint through the middle of a block (flood fill on a wrapped ring is
     not separated by one joint; build masonry from the mortar mask);
   - a rolled tile (a bevel on the edge moves into the block);
   - radial cracks meeting at a point (pinch);
   - one class chased for a face that is not that class (concrete and
     polished stone under the stone tilt band);
   - a sharp periodic feature whose phase puts a boundary exactly on the
     tile edge reading as a seam failure though it tiles (the measure
     dilutes the one wrap join against many flat inner joins): widen the
     taper or offset a synthetic pattern half a period, never roll the art.
3. Send the agent back with the verdicts and the causes, or fix the script
   yourself when it is a constant. Rerender. Only then commit the scripts.
4. Commit with `git add` on the named files, not the directory: several
   agents write there at once and a broad add sweeps their half finished
   scripts into your commit.

## Install

    python3 tools/pbr_author/build_pack.py --game <game> --check
    python3 tools/pbr_author/build_pack.py --game <game> --install

The first rebuilds every set from its script and prints the checks; the
second installs into the game's shipped pack (`lib.GAMES`) and appends an
attribution note, or into any directory you name. A standalone pack for
the launcher's list is a directory of the game's bake with the authored
sets copied over it, linked under the Luanti user directory's `textures`.
A server takes it as a worldmod's `textures` directory and needs a
restart. The client's asset updater takes a versioned bundle, which is a
release step (`docs/asset-bundles.md`).

## What the client does with the maps

- The node shader runs parallax occlusion with self shadow from the
  height channel, at a depth per material class (`goanna_class_depth` in
  `nodes_array_common.gdshaderinc`). A map that fills the height byte gets
  that whole depth; that is why nearly flat materials use `lib.band`.
- Cut-outs draw through the scissor variant, which has no parallax march;
  their relief reads from shading only.
- The relief gain `pack_normal_gain` lifts a flat pack; an authored pack
  reads near one and is left alone.
- The mesher's binormal handedness was wrong until 0e3fa49, so any
  judgement of normal maps in play before that build was of maps upside
  down along V. The ramp's `probe_bump` stem tells the conventions apart.

## Licence

Every set is a derivative of the game's art. Read the game's licence files
before authoring, and let `build_pack.py` write the attribution note.
Mineclonia's art is CC BY-SA 4.0; Kythen's is under the repository that
ships it. Never treat a generated or authored map as new art.

## When the art is generated from a recipe

Some games do not draw their art; they paint it from a recipe. Kythen's
blocks come from `materials.json` files per culture, painted by its
`tools/media/blocktex.py`: masonry with a course and a stone width, bark
with a seeded meander field, rubble as a seeded partition, planks, thatch,
weave, mat and mottle, each with a `surface` block naming smoothness,
porosity and emission. For a game like that, do not author maps from the
pictures. The recipe drew the relief and knows where the mortar is; a
script reading the picture back is solving the inverse problem the recipe
never had, and a fleet doing it is a second author of one thing.

The pipeline for a recipe game is the recipe's own painter emitting a
height and a smoothness field at map size from the same seeded layout it
paints the albedo from, and `lib.pack` turning those into the set. The
arithmetic recipes (masonry, planks, thatch, weave) scale to map size for
free; the seeded ones (bark, rubble) redraw their field at map size. What
the library holds is exactly what the painter lacks: the bevel profile, the
narrow band for flat materials, the sparse hollow that gives a soil its
occlusion, the texel grain damping, the class rules, the packing
convention and the checks. Call it; do not carry a second packer. Judge
the result on the ramp the same way, and retire the per stem scripts for
every stem a recipe covers. A change to a recipe then changes the block
and its relief together.

The Kythen fleet of 2026-09-16 predates this section. Its 228 scripts
stand until the painter emits maps, and the Siku batch, whose author read
the recipes rather than the pictures, is the one to compare against.
