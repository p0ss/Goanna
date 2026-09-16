# PBR authoring playbook

How to give a Luanti game hand authored material maps with a fleet of
agents, the way Mineclonia got its 177 sets on 2026-09-15 and 16. This is
the operating procedure; `tools/pbr_author/README.md` is the brief the
authoring agents read, and `docs/material-calibration.md` is the record of
what was measured and why the rules are what they are. Read all three
before running a fleet for a new game.

## What you are making

For each texture stem the game draws, three files at 256 px beside its art:
the albedo (the game's own art upscaled, never repainted), a `_n` map
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
