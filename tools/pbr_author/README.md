# Hand authored LabPBR sets

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
