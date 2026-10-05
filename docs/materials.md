# Materials

Goanna reads authored material data out of ordinary server media. Beside a
node texture `<name>.png` it looks for `<name>_n.png` and `<name>_s.png`,
which is the LabPBR convention used by Minecraft shader packs. A server that
ships those files gets physically based materials on a Goanna client, and a
vanilla client ignores them as media it has no use for.

This needs no protocol change and no engine change. Luanti already transfers
whatever media a game or mod puts in its `textures` directory, so the naming
convention is the only agreement required. Where a texture has no companion
we fall back to relief inferred from the diffuse image, so coverage can be
partial without looking broken.

Upstream has an open request for a materials API, [luanti-org/luanti#8854],
which this document is meant to inform rather than pre-empt.

[luanti-org/luanti#8854]: https://github.com/luanti-org/luanti/issues/8854

## What LabPBR carries

Two companion images per texture, eight channels in total.

`<name>_n.png`:

| Channel | Meaning |
| --- | --- |
| R | Tangent normal X |
| G | Tangent normal Y, pointing down |
| B | Material ambient occlusion, 0 fully occluded |
| A | Height for displacement, 0 deepest at 25 per cent, 255 flat |

`<name>_s.png`:

| Channel | Meaning |
| --- | --- |
| R | Perceptual smoothness, so the GGX roughness is `(1 - smoothness)` squared |
| G | 0 to 229 linear F0, 230 to 254 a predefined metal, 255 albedo as F0 |
| B | 0 to 64 porosity, 65 to 255 subsurface scattering |
| A | Emission, 0 to 254 for none to full, 255 meaning no emission at all |

Three of these are worth calling out because they are easy to get wrong.

The green channel of the normal map points **down**, which is usually called
the DirectX convention, against the Y up that glTF specifies and that most
descriptions of a normal map assume. Whether that needs correcting depends
on which way V runs in the mesh being shaded, and nothing in the file name
tells you either fact. In Goanna it needs no correcting: Luanti's tile UVs
run V down as well, so the two agree. Flipping to match the usual
description turns block sides black. This is worth stating in any agreement,
because it is invisible until someone renders it and then it is glaring.

The blue channel of the specular map is two materials sharing one range. A
surface is either porous or subsurface scattering, never both, and the split
sits at 64. In the pack we test against, leaves, grass, ice, obsidian and
diamond are authored as scattering, while dirt, stone, sand and logs sit in
the porosity range.

The red channel is perceptual and so is Godot's `ROUGHNESS`, which Godot
squares itself to reach the GGX roughness. The shaders therefore write
`1 - smoothness` and must not square it first. Squaring it here as well
takes the exponent to four and reads every surface with a `_s` map as
polished; Goanna did exactly that until September 2026. The distant
material averages in `GoannaTexture::layerSpecMeans` are averaged in the
same space the shaders write, so the two must be changed together.

The green channel is linear F0, and Godot's `SPECULAR` is not. Godot's
dielectric reflectance is `0.16 * SPECULAR * SPECULAR` (as is
`direct_light.gdshaderinc`, which copies it), so the decoders write
`SPECULAR = sqrt(F0 / 0.16)`, clamped to 1, which caps a dielectric at
Godot's ceiling of F0 0.16. Until October 2026 they wrote `F0 / 0.08`,
which is right only at F0 0.04: amethyst's byte 20 (F0 0.078) rendered at
0.154, the eye byte 15 (0.059) at 0.087, hair's 12 (0.047) at 0.055, and
the enderman's eye byte 6 (0.024) at 0.014. The plain byte 10 moved from
0.038 to 0.039. `specular_strength` multiplies `SPECULAR` after the decode,
as it always has and as the far averages, the gem path and ice do, so it
scales F0 by its square and its default of 1 changes nothing. The metal
branch is unchanged: a metal's F0 is its albedo whatever `SPECULAR` says.
`project/material_probe.tscn` checks the decode against
`StandardMaterial3D` at F0 bytes 6, 10, 15, 20 and 26. The record is
`docs/perf/specular-mapping-2026-10-03/`.

## What Goanna decodes today

| Channel | Status |
| --- | --- |
| Normal X and Y | Decoded as stored. No green flip, see above |
| Material AO | Decoded, at 0.4 light affect |
| Height | Decoded for the parallax march, in `nodes_array.gdshader` only; see below |
| Smoothness | Decoded as roughness |
| F0 and metalness | Decoded, but metals are binary rather than the metal table |
| Porosity | Decoded, read by the rain wetness term |
| Subsurface scattering | Decoded as backlight |
| Emission | Decoded, honouring 255 as none |

Scattering is fed to `BACKLIGHT` rather than `SSS_STRENGTH`. Godot's
subsurface scattering is a screen space pass built for skin, and pointed at
a solid block it eats the diffuse and leaves it near black. Backlight adds
the light arriving from behind a surface, which is the whole of what a leaf
or a pane of ice wants, and it costs one term instead of a screen space pass.

Normal maps are tangent space, so the block mesher gives every surface a
tangent frame derived from its UV layout. Without one the maps are silently
inert, whatever else is correct.

## Which shader draws a tile

Two shaders draw node arrays, and they differ by more than the alpha
test. `nodes_array.gdshader` has the parallax occlusion march and its sun
self shadow (`parallax_strength`, `parallax_depth`, `parallax_range`,
`parallax_shadow_strength`, `parallax_silhouette`, the per layer
`layer_depth` and the class table `goanna_class_depth`), and folds that
shadow into `AO` and `AO_LIGHT_AFFECT`. `nodes_array_scissor.gdshader` has
none of it and writes `ALPHA` and `ALPHA_SCISSOR_THRESHOLD`. Everything
else (the LabPBR decode, per class tiling, far flattening, rain, fill,
lamp bake) is the same code in both. The uniforms all live in
`nodes_array_common.gdshaderinc`, so both declare every one of them, and
a slider such as `mat_parallax` reaches both but only moves the first.

That a cut-out has no march is deliberate: a march would have to alpha
test at the offset coordinate, so a leaf's holes would move with the view,
and nobody has judged whether that reads better. What was not deliberate,
until 2026-09-27, was which tiles counted as cut-outs.
`GoannaClient::materialFor` chose by the array: any layer with alpha sent
the whole array to the scissor shader. Upstream's
`NodeVisuals::fillNodeVisuals` bunches tiles by size alone, 256 to an
array, and 1160 of Mineclonia's 1841 16 pixel textures have some alpha, so
every array had a cut-out in it and all the ground, sand, stone and planks
included, was drawn by the scissor shader. The authored pack's depth, which
was judged on the close-up ramp through `nodes_array.gdshader`, had never
drawn in play.

Now the near mesh chooses per face, by the face's own layer
(`arrayTileKey`, and `GoannaTexture::tileHasAlpha`, which for an animated
tile looks at every frame). An opaque face in an array with alpha gets a
material key with `opaque_tile` set: the same arrays and uniforms, drawn
by `nodes_array.gdshader`, with no alpha test at all. An array with no
alpha anywhere is not split and keeps its one key. The cost is one extra
material per array that has alpha, and one extra surface in a near region
wherever that region holds both opaque and cut-out faces of the same
array (a grass side's overlay beside dirt, say); nothing else changes
about the batching.

That grass side is the one hazard in the split. An overlay tile is the
same quad as its base at the same depth, so whichever is drawn last is
what shows. In one surface the base came first; in two, Godot orders
opaque draws by shader id unless told otherwise. Scissor array materials
therefore carry `render_priority` 1: Godot 4.5's opaque sort key has the
priority in its top bits (`render_forward_clustered.h`), so every cut-out
draws after every opaque tile. Read from the engine source, not seen in a
frame. Two cut-outs on one quad from different arrays are still ordered
by material, as they always were.

The far tiers still choose by the array, because they merge a whole array
into one surface per tier. That costs an alpha test there and nothing
visible: the march ends at `parallax_range` (40 nodes), and the far tiers
start past the detail distance, 128 nodes even on Low.

`GoannaClient::top_surface_at` reports the shader the near mesh gives a
node's top face, with `layer_alpha` for its own layer and `array_alpha`
for the array. The checks are `goanna_array_route_test` (native) and
`project/tests/node_array_shaders.gd` (headless: both shaders compile and
declare every uniform the client sets). Neither renders; whether the
relief now shows on sand, stone and planks in play has not been seen.

### Glass, ice and faces that leave the array, 2026-09-29

Clear glass is cut out rather than blended in every game checked
(minetest_game, Mineclonia, VoxeLibre, Kythen and Asuna), so it stayed on
the array path with no reflection. A cut-out tile now takes the glass
shader when its node is glass: a `glass` or `material_glass` group, or
`glass` or `pane` as a whole word of the node name (`nameHasWord`). The
glasslike drawtype is not evidence on its own: Asuna draws quicksand, mud,
clouds and termite blocks with it, and Mineclonia its spawner. Glowing
nodes keep the emissive path. Culled clear glass takes
`glass_clear.gdshader` and double sided clear glass, such as a door,
`glass_double_sided.gdshader`; both share `glass_common.gdshaderinc` with
the stained glass shader and write no depth. With `depth_draw_always`, as
stained glass has, a clear texel hid whatever glass drew after it, so the
back edges of a window two blocks thick came and went as surfaces were
sorted. `depth_prepass_alpha` kept the edges but put the glass in the
shadow pass, and the floor under a glass block went dark.

A face that leaves its array is still in a buffer holding every tile
upstream merged under that array, because `TileLayer` equality ignores the
layer. `keyForIrr` only sees the buffer's first vertex, so the choice is
made per face in the near mesher's `tile_key`: clear glass by
`clearGlassLayer`, and every face of a buffer that left its array (a double
sided tile, or a special shader's) by its own layer's image. Before this,
such a buffer drew all its faces with the first face's image: in
minetest_game the yellow dandelion drew as a tulip, the jungle sapling as a
sapling and the viola as a geranium, and in Asuna a tulip as a rose.

See-through ice takes the ice shader by the `ice` group, or when a blended
or fake liquid block names ice in its node name or footstep, which is how
Asuna's two `thin_ice` nodes say it. The node classifier now puts `ice` in
a name ahead of the footstep, because Kythen gives its ice
`kythen_hard_footstep`, which classed it as stone. `tools/pbr_bake.py` has
its own classifier and was not changed.

Rendered checks are in `perf/cross-game-glass-ice-2026-09-29/`.

## Diamond surfaces

Diamond blocks, ore, held tools and worn armour share
`project/shaders/diamond.gdshaderinc`. The texture name opts in, separately
from the bulk material class, so diamond ore remains stone. Solid diamond
blocks use the whole surface; ore, tools and armour select cyan pixels from
the rendered texture. The mask follows the displaced UV on opaque nodes,
so it stays attached to the gems during parallax and mining.

Small planar tilts follow the art's shade plateaus and retain the authored
normal relief. The surface is a polished dielectric, with a bounded coloured
secondary highlight that approximates diamond fire. This is not optical
refraction. Both highlights receive ordinary light colour, attenuation,
shadows and the underground sunlight gate. Neither adds emission. Fine
facets fade as their footprint becomes unresolved. `diamond_strength = 0`
disables the treatment; normal, roughness and specular strengths still apply.

A shallow apparent interior now sits behind the polished skin. Two internal
planes are sampled along a refracted ray, bounded by the same gem mask.
Thicker paths absorb more red light, while thin edges transmit more of the
internal light. An inner facet highlight and a wrapped scattering term use
the existing light colours, shadows and sunlight gate. The treatment adds
no emission. `diamond_interior_strength = 0` restores the surface-only
version. Both node shaders sample from the parallax-displaced coordinate;
entities use their tile or armour atlas scale.

Placed blocks and ore retain backed interiors, so they cannot reveal hidden
terrain. Ore now traces a short refracted ray through a crystal-filled
recess. The cyan mask defines its side walls, and neighbouring stone texels
supply a reconstructed rock backing where the combined art painted over
it. The crystal transmits that local rock with depth-dependent absorption.
`diamond_ore_transmission = 0` restores the earlier cyan interior;
`diamond_ore_depth` sets the recess depth in source texels. This adds no mesh
vertices or silhouette changes, and follows the existing parallax UV. The
[interior comparison](perf/diamond-interior-2026-09-29/index.html) shows the
previous backed treatment at three viewing angles.

Held and dropped diamond items and worn armour now use dedicated blended
shaders. Face-on gem pixels have 24% opacity (32% for held blocks), rising
towards 90% at grazing angles. Wood handles and dark joins remain opaque;
empty texels are discarded. `diamond_transparency = 0` restores full opacity.
The [transparency comparison](perf/diamond-transparency-2026-09-29/index.html)
shows the background through items and clothing through live armour.

Items now refract the opaque scene behind them using their facet normal and
a source-texel-scaled thickness. A depth check rejects foreground samples,
and the offset fades at screen edges. The prelit transmitted colour is
composed with the lit crystal surface. `diamond_refraction = 0` restores
straight alpha transmission. See the
[refraction comparison](perf/diamond-refraction-2026-09-29/index.html).

This is a screen-space thin-slab approximation, not a trace through the
object's back-face geometry. Offscreen and other transparent objects are
absent from the sampled background. Blended surfaces retain Godot's object
sorting limitations and do not cast the former cut-out shadows or coloured
transmission shadows. Ordinary opaque entities and terrain arrays retain
their original render pipelines.

The entity shader body lives in `entity_common.gdshaderinc`, with separate
opaque, cut-out and double-sided entry points. Diamond armour uses the
double-sided transmission variant when the server's player model requires
it; entities already marked alpha-blended by the server retain their previous
material path.

Diamond entities reconstruct their tangent frame from the rendered surface
and its UVs, and since 2026-10-01 so does every entity surface with a normal
map (see "Mob, player and item companions" below). Luanti's item and skinned
model streams omit tangents, while
terrain supplies them. Godot fills in a fallback frame which need not match
the UVs: the inspected loose diamond had a vertical tangent for horizontal
U. Without this correction the normal map and facet tilt are misaligned.
The frame follows skin deformation and mirrored UVs, using Godot's -V
binormal convention. Narrow square bevels follow source-art colour changes
to give native armour and loose diamonds the edge highlights of the ore
relief. They fade as texels become unresolved and retain the cyan mask.
Items also use a deeper refractive path, 3.5 source texels, while held blocks
retain their previous six-texel path. Held and dropped items share this
shader through the same item-mesh material binding. See the
[item and armour comparison](perf/diamond-items-2026-09-29/index.html),
including real dropped entities.

The mask assumes cyan diamond art and familiar tile/player-atlas scales.
Unusually recoloured packs, blue non-diamond parts in a combined armour
texture, and other atlas layouts need an authored semantic mask in future.
The texture-name check keeps unrelated blue textures out of the treatment.
Inventory icons remain the existing CPU-rendered art.

See [the diamond study](perf/diamond-2026-09-29/report.md) for captures and
validation, including live Mineclonia armour and ore.

### Other gems, 2026-09-29

The same treatment now covers emerald, amethyst, mese and nether quartz.
`gemTextureCode` in `src/goanna_materials.cpp` returns mode | kind << 2,
where the mode is as before (1 masks gem pixels out of a host, 2 is a solid
gem block) and the kind indexes the tables at the top of
`diamond.gdshaderinc`. Diamond is kind 0 and keeps every constant it had.
Other gems are matched by whole word, because Mineclonia names textures
after their mod: `mcl_amethyst_calcite_block` is calcite, and `mesecons` is
wiring. Lamps, glass, ice, glowing variants and amethyst buds are never
gems. Quartz is a gem as ore and as the loose item, not as the polished
blocks.

| Gem      | Mask                         | Host max | Gem p25 | Index | Clarity |
|----------|------------------------------|---------:|--------:|------:|--------:|
| Diamond  | min(g, b) - r (unchanged)    |   -0.019 |    0.19 |  2.42 |    1.0  |
| Emerald  | chroma along its own colour  |    0.006 |    0.10 |  1.58 |    0.6  |
| Amethyst | chroma along its own colour  |    0.008 |    0.31 |  1.54 |    0.55 |
| Mese     | chroma along its own colour  |    0.077 |    0.36 |  1.55 |    0.35 |
| Quartz   | luminance - 2 x chroma       |   -0.078 |    0.16 |  1.54 |    0.25 |

The masks were measured on the games' own art in linear colour: gem pixels
from the ore minus its host stone (or the mineral overlay's alpha), and
host pixels from stone, deepslate, netherrack and the tool handle's stick.
The host maximum sits below each mask's lower edge. Quartz is white on red
netherrack, so a colour direction pointed at the rock; brightness without
colour separates it instead. Mese is fictional and borrows citrine's
optics. Specular follows each index, so the lower index gems reflect less
than diamond.

Clarity scales how much the gem lets through: the ore recess's view of the
rock, the mix between its inner planes, and an item's transparency. Mese
and quartz at full clarity turned the colour of the rock behind them.

`project/gem_study.tscn` renders every kind as ore, block and item from
the games' art, and can render the same scene with an older copy of the
shaders. See [the gem study](perf/gems-2026-09-29/report.md). Glowing and
blended gems (caverealms, Everness crystal blocks, `too_many_stones`) take
the emissive and glass paths and are not covered.

## Mob, player and item companions

A mesh entity (a mob, a player, a held or dropped item) takes `_n` and `_s`
companions by its texture's image name, from the server's media or a
client side pack, and draws through `entity.gdshader`, or
`entity_scissor.gdshader` when the skin has cut out texels; both decode
the companions identically. The code is
`EntityRenderer::materialForMeshTexture` in `src/goanna_entities.cpp`. The
record of the 2026-10-01 pass is in
`docs/perf/entity-pbr-2026-10-01/`.

**Encoding.** The same as a node tile: red above 128 tilts the normal
toward plus U (right in the image), green above 128 toward the top of the
image, with no green flip. B is ambient occlusion, A height (255 the
crest), which the parallax march below reads. `_s` is as in the table above. `project/entity_normal_probe.tscn`
renders a probe dome in that encoding on all six face directions of a mob
box, plain and mirrored, beside a quad on SurfaceTool's tangents (the frame
the node mesher matches), and fails unless every quad lights on the side
the light comes from. Until 2026-10-01 only gem items had a frame rebuilt
from their UVs; every other entity normal map was decoded against the
fallback frame Godot derives from the vertex normal alone, which turned or
mirrored the relief per face and flattened it on faces along Z.

**Overlay stacks.** Many skins are built on the server as overlays. In
Mineclonia, a villager, a damaged iron golem, a sheep's body and a player:

```
mobs_mc_villager_base.png^<biome>.png^<profession>.png^<badge>.png
mobs_mc_iron_golem.png^(mobs_mc_iron_golem_crack_low.png^[opacity:180)
mobs_mc_sheep.png^(mobs_mc_sheep_sheared.png^[colorize:#rrggbbD0)
(mcl_skins_base_1_mask.png^[colorize:#rrggbbFF:alpha)^mcl_skins_base_1.png^...
```

For such a stack Goanna composites the companions the
way the albedo was composited, bottom layer first, each layer over the ones
below by its own albedo alpha (times its `[opacity`), sampled nearest at
the largest size among the inputs, so a map authored at eight texels per
art texel keeps its resolution over 64 or 128 pixel art
(`src/goanna_overlay_companions.h`).

- A layer with no companion of its own contributes a neutral one where it
  covers: a flat normal with no occlusion, and a rough dielectric `_s`
  (smoothness 0, F0 10, no porosity or scattering, A 255 for no emission).
  Clothes with nothing authored are flat and rough, not the relief and
  sheen of the skin under them.
- `_n` channels mix by the mask. Of `_s`, only smoothness mixes; F0 or
  metal, porosity or scattering, and emission are categorical and are taken
  whole from whichever layer covers the texel at 0.5 or more. Mixing them
  invented materials: a crack's dielectric over the golem's metal at 180/255
  blended green to about 84, a dielectric with the largest specular the
  shader gives.
- A colouring mask takes its own companion name when one exists and the
  part's otherwise: `mcl_skins_hair_3_mask.png` tries
  `mcl_skins_hair_3_mask_n.png`, then `mcl_skins_hair_3_n.png`. Colour is
  not material, and the part's shading layer drawn over the mask takes the
  part's name too, so author the part's name.
- What is read: plain image names, a bracketed group of one image with
  `[opacity` or colour only modifiers, and colour only modifiers anywhere
  (`[brighten`, `[colorize`, `[multiply`, `[screen`, `[hsl`,
  `[colorizehsl`, `[contrast`), which is also what keeps a damage tint from
  dropping the composite. A texture built any other way that the texture
  language reader can follow (`[combine`, `[transform`, `[resize`, nested
  groups, escaped parts) is composed by it instead; see "Companions of
  texture expressions" below. What neither reads (`[mask`, a frame cut, a
  crack) takes the companions of the image before its first `^`, as every
  entity texture did before.

**Sampling.** `_n` is nearest with mipmaps, like the albedo
(`entity_common.gdshaderinc`). A skin with no `_n` takes the relief inferred
from its own 64 pixel art, and a linear filter spread each texel's tilt
across its neighbours: the shading ran in soft bands across the texel grid
and the mob looked out of focus beside the same mob with maps. An authored
map at eight map texels per art texel loses nothing by it. Mipmaps average
across islands at a distance, where the relief is below a pixel anyway.
`_s` is nearest with mipmaps too, because a linear filter between a metal
and a cloth texel passes through values that decode as a dielectric at the
largest specular, a shiny rim round every metal plate. (This paragraph said
`_n` was linear until 2026-10-06; the shader had already been changed.)

**Parallax occlusion.** A mesh entity with an authored `_n` gets the node
tile's parallax march and self shadow (`entity_common.gdshaderinc`, the
same steps, chord refinement, shadow and fade as `nodes_array.gdshader`).
Its depth is measured from the map by the node path's own `reliefDepth`
(`src/goanna_textures.cpp`), with a node counted as sixteen art texels and
the same 0.10 node cap, and only inside each face: on an atlas the texel
beside a face's edge in the image belongs to another face, and counting
those jumps put the creeper and the cow at a tenth of an art texel. A
skin's pack set is its `_n` and `_s` only and the albedo is the game's own
art, so the art's size is the albedo's (or the composite's) wherever the
map is larger; only an albedo shipped at map size has its texel grid
measured, from whole blocks of one colour. Shipping skin albedos upscaled
broke mcl_skins: its `(mask^[colorize:...)` groups are blitted at their
own 64 x 32 size into the corner of the 1024 wide part, and the player
drew bare skin colour all over. The frame is solved per fragment from the UV and position
derivatives, so a mirrored limb marches the mirrored way by itself.
Heights are marched relative to each face's highest drawn texel, which
is lifted to sit on the face (`height_lift`, and per face `lift_tex` at
the art's resolution): skins authored before parallax keep their main
surfaces at 0.4 to 0.7 and drew sunk into the box with their edge texel
smeared, and one lift for the whole skin was not enough, because one
part stands well above the rest (the player's hair at 0.95 over clothes
at 0.60). For a stack the whole-skin value comes from each layer's own
map, since the composite fills a layer without one at 255. Node layers
are unchanged.
Containment, which blocks never needed: `buildGodotModel` writes each
face's UV rectangle into `CUSTOM0` (the bounds of the triangles joined by
shared vertices, a box face on a mob) and every sample of the march and
the shadow is clamped inside it, so the march stops at the face's edge
texel instead of reading the neighbouring island. A hit on a transparent
texel inside the rectangle is pulled back toward the drawn point. In the
scissor variant the cut stays the art's own alpha at the un-marched UV,
so the silhouette is the vanilla client's. A mesh without `CUSTOM0` (an
item, a model preview) gets no parallax. It follows the `parallax`
material strength, which the Lowest profile's `mat_parallax 0` sets to 0;
`GOANNA_ENTITY_PARALLAX=0` turns it off for entities alone. Entities
march at most 32 steps (the nodes 48), then halve the last step five
times and take the hit at its end under the surface, plus 8 steps for the
shadow. The node march's chord alone suits a smooth field; on a skin's
plateaus it landed either side of a wall from pixel to pixel, and the
creeper's eye pits (a drop of 0.76 of the range inside one face) drew as
vertical slices of rim and floor
(`docs/perf/entity-parallax-2026-10-02/creeper-walls-*`).
`GOANNA_ENTITY_PARALLAX_REFINE=0` restores the chord. The node path keeps
its chord: its baked and authored fields are smooth enough that the chord
is better there, and stepped node maps were not tested. Gems keep no
parallax. `project/entity_parallax_probe.tscn` checks containment, the
mirrored march, the shadow, the silhouette and the walls. Not handled: a face whose
connected UVs are not a rectangle clamps to their bounding box, and a
skin whose albedo is painted rather than pixel art takes its own pixels
as art texels. See `docs/perf/entity-parallax-2026-10-02/`.

**Hair's highlight.** Hair reads as hair mostly by its highlight, a
narrow band lying across the strands, and an authored map cannot draw one
at sixteen map pixels per art texel: the band comes from orientations far
finer than a texel, and mipmaps average away what relief there is. So a
hair texel takes a different specular lobe in `light()`
(`direct_light.gdshaderinc`, `GOANNA_HAIR`, which only the entity shaders
define). A texel is hair when its `_s` green byte is exactly 12 (F0 0.047,
`atlas.HAIR_F0_BYTE`, written only by a material with `"hair_mark"`, or
for any material naming it when the pack is built with
`GOANNA_PBR_HAIR_MARK=1`). `_s` is sampled nearest and the overlay
composite takes F0 whole from the covering layer, so the byte arrives as
written; a mip level that averages hair with anything else is not 12 and
gets the isotropic lobe.

- The strand direction is the image's vertical, from the UV frame the
  entity shader already solves: on these atlases image down is model down
  on a side face, and on a top or bottom face image up runs from the
  model's front to its back (`atlas.face_frames`). A face whose normal is
  within 45 degrees of world up or down counts as a top. It is
  orthogonalised against the mapped normal in `light()`, so the normal
  map's tilt turns it. A mirrored face reverses U, never V, and needs
  nothing. A head pitched beyond 45 degrees would swap the rule.
- The lobe is Godot's anisotropic GGX (`D_GGX_anisotropic`,
  `V_GGX_anisotropic`), smooth along the strand and rough across it,
  `alpha * hair_aspect` and `alpha / hair_aspect` (0.35), so the product
  and the peak stay the isotropic lobe's. A second lobe, half again as
  rough along the strand and tinted by the albedo (`hair_secondary` 0.6),
  is Marschner's TRT; the first is tilted toward the root by
  `hair_shift_root` (0.08 rad), the second toward the tip by
  `hair_shift_tip` (0.14 rad). Fresnel and the multiscatter term are the
  isotropic lobe's. Integrated over the hemisphere at hair's roughness
  (0.58) the primary returns 0.54 of light where the isotropic lobe
  returns 0.68 to 0.82, so with the tinted lobe on top the hair gives back
  a little less than before, not more.
- A box has no curvature along a strand for a band to travel over, so for
  the specular only the normal is turned along the strand from -45 degrees
  at a face's root edge to +45 at its tip edge, as if the box were
  rounded; two faces meet at the same normal on their shared edge. The
  diffuse keeps the box. The box's own normal still gates the light.
- The diffuse is untouched, and a texel that is not hair runs exactly the
  code it ran before.
- The `hair` material strength (`mat_hair`) scales it, and
  `GOANNA_HAIR_ANISO` multiplies that for entities alone; 0 is the old
  isotropic lobe on hair too. It is 0 by default: the frames so far are
  from lavapipe, and it stays off until it has been judged on the GPU.
  `GOANNA_MAT=hair=1` or `set mat_hair 1` turns it on. See
  `docs/perf/hair-aniso-2026-10-02/`.

**Hair drawn by the shader.** Six rounds of authored maps for the
player's hair read as wood, decking, bevels, grubby fibre or plastic. A
strand at sixteen map pixels per art texel is two map pixels wide, and
what survives the mipmaps is grain. So on the same hair texels the shader
can draw the strands itself (`hair_strands.gdshaderinc`, called from
`entity_common.gdshaderinc`), at the screen's own frequency:

- Strands, `hair_strand_density` (10) across an art texel, each a small
  cylinder whose normal tilts across it, with its own brightness, its own
  shine and a darker gap beside it, brightness also wandering along its
  length. Clumps (two to a texel) and faint fibres (2.3 times the strand
  density) over and under them. A column of art texels is a lock: its
  strands bend together along a slow wave (`hair_strand_wave`, 0.01 of a
  texel) and are seeded by the column. At 0.07 of a texel the bend read
  as wood grain, and at 18 strands to a texel they fade out at a 1.25
  node view and leave a smooth, plastic face.
- Each layer fades out by the UV derivatives as its period nears two
  pixels, so nothing finer than a pixel is drawn and a distant head is the
  plain texel with the anisotropic sheen. Tips and lock shadows fade by
  the pixel's size along the strand, a little later.
- Ragged tips: where the texel next along the strand (down on a side face,
  toward the back on a top) is not hair, or is hair standing more than `hair_tip_step` (0.1) lower in
  the stored height, each strand stops at its own length, up to
  `hair_tip_depth` (0.45) of a texel short of the edge, thinning as it
  goes, and past its end is darker hair beneath (`hair_tip_shadow` 0.3).
  With every step a tip, the player's hair ended each texel in a dark
  ragged band and read as bark. A side face's bottom
  edge counts as a tip; a top's edge does not.
- The shadow under a lock: where the texel toward the root is hair
  standing higher, a ragged shadow (`hair_lock_shadow` 0.3) falls from
  that edge, a quarter to a half of a texel.
- Shading: the highlight's two lobes above, at full weight whatever
  `mat_hair` says, with each strand's shift jittered by up to 0.17 rad and
  its shine scaled 0.3 to 1.7, so the band breaks up; and a wrapped
  diffuse (`hair_wrap` 0.3) in place of Burley for hair, so the hair has
  no hard terminator. The wrapped term drops the rim and backlight terms
  for hair texels. The owner read the first frames' highlight as too
  shiny, so the lobes are shaped with `hair_shader_rough` (0.15) added to
  the roughness and weighted by `hair_shader_sheen` (0.5).
- Every term is a multiplier on the art's colour with a mean near 1 that
  fades to exactly 1, so the art's texel colours stay the base. The lock
  heights, the parallax and its self shadow are the map's.
- Its cost on a hair fragment is four `textureLod` reads (the `_s` and
  `_n` of the texels either side along the strand) and about forty hash and
  noise operations; see `docs/perf/hair-shader-2026-10-03/`.
- The `hair_shader` material strength (`mat_hair_shader`) scales it, and
  `GOANNA_HAIR_SHADER` multiplies that for entities alone. With no profile
  it is 0; the Lowest and Low profiles set it to 0 and the others to 1.
  It needs the hair mark, which pack 1.3.0 does not carry; the hair spec
  writes it from 2026-10-03, so the next pack built from it does.
- A texel that is not hair runs the code it ran before. The live frames
  in `docs/perf/hair-shader-2026-10-03/` show changes beyond the repeat
  noise only on the hair, but the sky and the lantern flames move between
  repeats, so they are not a pixel exact proof.
- How it looks is in `docs/perf/hair-shader-2026-10-03/`. The owner
  judged the shader over the simplified maps best of the first round, and
  every column blobby; the second round's crisp locks step with walls.

The maps for it are simpler: the shader replaces the fine strand normals,
so the hair's `_n` carries only its locks, each a flat plateau at its
level with a one pixel chamfer, the dark gap texels sunk, and an
occlusion with contact darkness under every lock step and in the gaps
(`"lock_occlusion"`, `"gap_occlusion"`, see `tools/pbr_author/README.md`).
The first round's locks were rounded by a gaussian over every step and
read as melted. The earlier specs stay reachable as variants:
`GOANNA_PBR_VARIANT=old` builds the authored strand maps from before the
shader, `round1` the rounded maps of the first round, `no_contact` the
crisp locks without the contact occlusion.

**Where companions do not reach.** A surface the server marks
`use_texture_alpha` (a charged creeper's aura, a slime's outer body, a
spider's eyes) keeps the plain `StandardMaterial3D` path, with no
companions and no node light. A double sided surface draws through
`entity_double_sided.gdshader` (or its scissor variant) with everything
above, parallax included. Until 2026-10-02 it kept the plain path too, and
Mineclonia draws its players double sided, so the local player's body and
first person arms, the entity nearest the eye, had none of it while a
statue of the same skin had all of it. A cube visual (a Mineclonia
painting) goes the same way, each face with its own texture and the unit
square as its UV rectangle for the parallax march; until 2026-10-05 it
kept the plain material, so a painting had no maps and no node light.
`GOANNA_NO_PBR=1` withholds companions (from `main.gd` it needs
`GOANNA_PBR_SET=1` too, or the launcher clears it). With no `_n` in any
layer, the relief inferred from the texture's brightness applies, as it
does to an unauthored node tile; an authored `_n` in any layer turns it off
for that texture. `GOANNA_AUTO_BUMP=<strength>` sets the inference's
strength for nodes and entities alike, 0 turning it off, and holds for the
whole run: a saved profile and the settings slider leave it alone, as they
leave the other `GOANNA_` material switches alone. Until 2026-10-05 the
profile's 0.95 was put back at start, so an A/B run with
`GOANNA_AUTO_BUMP=0` still inferred relief on every mob. The inference
wraps at the image's edges and reads across UV islands, which is right for
a tile and wrong at an atlas's island edges.
It was also upside down along V, on node tiles and entities alike, from
0e3fa49 (which turned the mesher's binormal to minus V) until 2026-10-01:
a bright, raised texel lit from below the light. The probe's auto bump
quads check it.

## Companions of texture expressions

A Luanti texture is an expression, not a file name, and until 2026-10-05
the client looked a companion up for one image of it only: the image
before the first `^` on a node face, and the same for an item or entity
unless the whole texture was a plain overlay stack. So Crimson nylium's
side (`mcl_nether_netherrack.png^crimson_nylium_side.png`) drew with
netherrack's maps under its nylium, the chiseled bookshelf's
`[combine:16x16:...` front had no maps at all, and a carrot on a stick
held as `mcl_mobitems_carrot_on_a_stick.png^[transformFY^[transformR90`
would have had its maps lying across the art at right angles.

`composeCompanion` (`src/goanna_overlay_companions.h`) now builds the
companion of an expression the way `ImageSource::generateImage` builds the
texture: the same split at the last `^` outside brackets, the same escape
rule, and per part the same operation applied to the part's companion.
Every intermediate carries its companion at its own scale over its art,
and putting one into another keeps the finer scale, so a 256 pixel map on
a 16 texel part stays 256 pixels per 16 texels inside a composite.

| In the expression | What the companion gets |
| --- | --- |
| `a.png^b.png` | as the albedo: the smaller scaled up to the larger by area, then `b`'s companion mixed over `a`'s by `b`'s albedo alpha, by the channel rules of "Overlay stacks" above |
| `(...)` | composed on its own, then laid into the corner at its own size, unscaled, as Luanti blits a group |
| `[combine:WxH:x,y=part:...` | a transparent canvas, neutral companion; each part composed (escaped `\^` and `\:` included, nested combines included) and placed at its offset times the scale, clipped; laid onto the image before it instead when there is one |
| `[transformN` | moved as the texels move (`imageTransform`), and for `_n` the tangent turned with them; see below |
| `[resize:WxH` | scaled nearest, keeping its scale over the art |
| `[opacity:R`, `[noalpha` | the albedo's alpha changes, which is the mask when this part lies over another |
| `[mask:m` | the mask composed, the smaller of the two scaled up to the other by area, and the albedo ANDed with it byte by byte (`imageApplyMask`); the companion is untouched, and shows only where the masked art covers once the part lies over another |
| colour only modifiers | nothing |
| anything else (`[verticalframe`, `[sheet`, `[crack`, `[fill`, `[inventorycube`, `[lowpart`, `[invert`, `[overlay`, `[png`) | not read: the old lookup, the first image the expression names |

A part with no companion of its own is neutral where it covers, and canvas
nothing covers is neutral, as for an overlay stack. With no companion in any
part there is no companion, so the inferred relief and the classified `_s`
still apply as before.

**Depth without colour.** A part covers by its albedo's alpha, so until
2026-10-06 a part could carry relief only where it also painted over the
colour beneath it. A carving wants the reverse: the stone's own colour on
the floor of the cut, one level down. DorfCraft's engravings showed it: each
glyph's `_n` arrived only where the glyph painted its flat grey, and the cuts
drew as pale panels. So an image that is transparent in every texel and has
an `_n` of its own is a cut:

- Its `_n` is laid in by height rather than by alpha. At each texel the lower
  of the two heights is kept, the cut's normal is taken where the cut is the
  lower or where it leans (the lip of a cut stands at the face but slopes
  into it), and the two occlusions multiply. A flat uncut texel (128, 128,
  255, 255) changes nothing.
- A value a cut was placed into (a `[combine` canvas of cut glyphs, the
  group round it, a recolour of that group) carries the cut on through its
  own transparent texels into whatever it is laid over.
- The albedo is untouched, since a transparent image blits nothing, and so
  is `_s`: a cut changes no material.
- `[noalpha` ends it; the image then covers by its alpha like any other.
- A vanilla client draws a transparent image as nothing. A Goanna pack can
  therefore swap a server's baked glyph for a transparent one with the same
  name plus the server's `_n`, and every other client keeps the baked glyph.
  A server can also send a transparent layer of its own over its art; no
  other client sees it.

It applies to overlay stacks (`compositeCompanions`) and to every
expression `composeCompanion` reads, node tiles included.
`goanna_overlay_companions_test` checks it on an engraving built the way
DorfCraft builds one.

**Rotating a normal map.** `_n` red tilts toward plus x of the image and
green toward its top. A transform moves each texel as `imageTransform`
does, and turns the vector at it by the same map's linear part, which is a
signed permutation. Negating a byte is `255 - v`, exact about the 127.5
the decode treats as zero, so a flat 128 comes back 127, a lean of 1/255.
Blue (occlusion) and alpha (height) only move.

| Transform | Red | Green |
| --- | --- | --- |
| `FX` (4) | 255 - R | G |
| `FY` (6) | R | 255 - G |
| `R180` (2) | 255 - R | 255 - G |
| `R90` (1), counter-clockwise | 255 - G | R |
| `R270` (3) | G | 255 - R |
| `FXR90` (5) | 255 - G | 255 - R |
| `FYR90` (7) | G | R |

Two transforms in a row are applied in turn, which gives their product:
the carrot's `FY` then `R90` is `FYR90`, a reflection in the diagonal that
swaps red and green. `goanna_overlay_companions_test` checks the table for
all eight against a height field: the normals of the transformed height
equal the transformed normals.

**Where it is used.**

- Node tiles: `GoannaTextureSource::tileCompanion`, for the array layers
  (`godotArraySuffixed`) and for the glass, ice, leaves and plants
  materials. A tile string with modifiers is already its own array layer, so
  its composed companion goes into that layer's slot and nothing about the
  batching changes. A plain stack whose overlays have no companion of their
  own keeps the base image's maps everywhere, as before: Mineclonia's grass
  side is dirt under a translucent shading overlay, and composing it would
  flatten the dirt under the shade for no authored gain. An overlay with
  its own maps composes: the nylium sides once their overlays are authored,
  and with the pack as shipped the comparator's sides and ends in compare
  mode (`mcl_comparators_sides_comp` and `_ends_comp` have maps) and the
  redstone cross, whose first line takes its own maps where it is drawn
  (`redstone_redstone_dust_line0`) and whose rotated second line is neutral
  until `redstone_redstone_dust_line1` is authored. An animation frame
  (`^[verticalframe`) is not read and keeps the frame cut of its strip's
  companion.
- `overlay_tiles`, Luanti's separate overlay layer, needs none of this: it
  is a second `TileLayer` drawn as its own quad over the base, with its own
  texture, so its array layer is named by the overlay image and takes that
  image's own companions by the ordinary lookup. Its maps and the base's
  never mix; each draws where its own layer is drawn. This was already so.
- Items and entities: `EntityRenderer::materialForMeshTexture`. A plain
  stack keeps the compositing above; any other expression the reader
  follows is composed: a shield or banner as an item, the trident's held
  image (`blank.png^[resize:5x32^[combine:5x32:-19,0=...`), a carrot or
  warped fungus on a stick, the screwdriver (`^[transformFX`), and a
  standing banner, whose pole is `banner_base^[mask:base_inverted`, whose
  cloth is a recoloured `banner_base^[mask:base` and whose patterns are
  each cut by their own image. Until 2026-10-05 `[mask` was not read and
  the fallback asked for `(mcl_banners_banner_base.png`, bracket and all,
  which no pack has, so the banner drew with the relief inferred from its
  own brightness: the creeper sunk into the cloth, its outline shaded, the
  white top border raised.
- Each composed companion is built once per texture string and suffix, on
  the main thread, and kept as a texture of its own
  (`GoannaTextureSource::composedCompanion`). `GOANNA_DEBUG_PBR=1` logs each
  one; `GOANNA_DUMP_COMPOSED=<dir>` also writes it as a PNG.

**A trap for packs.** Luanti blits a `[combine` part at its own size into a
canvas of the declared size. A pack that ships a part's albedo at map size
(the Mineclonia pack ships `mcl_books_chiseled_bookshelf_empty.png` at 256
pixels) makes the chiseled bookshelf's 16 texel canvas show the top left
16 pixels of it, one art texel's flat colour, in the vanilla client too
(checked through the transplanted `imagesource.cpp` with a synthetic 256
pixel part, not seen in a frame). The composed companion follows
the albedo exactly, crop and all, so it cannot hide this; the fix is to
ship only the `_n` and `_s` of a texture that is used as a `[combine`
part, as the skins already do
(`tools/pbr_author/stems/<game>.maps_only.txt`). It was seen in a frame on
2026-10-05: the review pack shipped `mcl_tridents_trident_entity.png` at
256 pixels, the held trident's five texel cut took art column 2 of it,
opaque from end to end, and the trident drew as a solid pale slab, in
maps on and maps off runs alike.

**Sprites.** A `sprite` visual is a true billboard and draws through a
plain `StandardMaterial3D` with no companions. It could be given a `_n`,
but the quad turns to face the camera and its tangent frame turns with it,
so the relief would be lit from a direction that swings round as the player
walks past, and the parallax would slide with the view. Nothing in the
art says which way the surface faces, because it faces wherever the
player is. It stays as it is. Mineclonia's fishing bobber is one of these:
its entity names no visual, so it takes Luanti's default, `sprite`.

An `upright_sprite` is not a billboard. The vanilla client
(`GenericCAO::addToScene`, `updateTextures` and `updateTexturePos` in
`luanti/src/client/content_cao.cpp`) builds two quads in the object's own
XY plane, `BS * visual_size` across (Z unused), centred on the object, or
standing on its feet for a player. The front faces the object's +Z with
`textures[0]`; the back faces -Z with `textures[1]`, or `textures[0]` when
there is no second, and is the front's mirror, so the image reads the right
way round from either side. Each quad is culled from behind, as Irrlicht's
default material culls it, and the object's `backface_culling` is never
applied to them. The object's rotation turns them and nothing else does.
With `spritediv` both quads show the same cell of the sheet. The light is
the brightest of the nodes at the collision box's corners and centre, with
`glow` added to both banks and again to the night bank as an emissive
boost; a negative `glow` leaves the quads at full light.

Goanna draws it that way since 2026-10-05 (`goanna_upright_sprite.h`, with
`EntityRenderer::buildUprightSpriteMesh`): the same two quads, the same
textures, the same culling and the same light positions and glow, each
quad through the entity shader with its texture's companions, the node
light and parallax, and its sheet cell as its UV rectangle (CUSTOM0) for
the parallax march. Each cell of a sheet is a face of its own for the
relief measure. Before that it drew one quad locked to the Y axis that
turned to face the camera, with `textures[0]` on both sides and a plain
material, so a decorated pot's sherd faces swung round with the player and
could take no maps. The selection box was never tied to the visual: it is
`selectionbox` for every visual, upstream and here, and
`rotate_selectionbox` is not honoured for any visual yet. What is still
not like the vanilla client: `glow` above 0 or `shaded = false` makes
upstream drop the directional shading (`TILE_MATERIAL_PLAIN`), and the
entity shader keeps it; and `glow` is applied to upright sprites only,
not yet to the other visuals.

`goanna_upright_sprite_test` checks the quads against upstream's vertex
table and against a camera on each side: one quad drawn from each side,
neither mirrored, the right way up, each with its own texture, a player's
standing on its feet, a sheet cell's coordinates and rectangle. None of
this has been seen in a frame yet: the GPU check (a decorated pot from five
sides, the bobber in water, before and after) was set up on 2026-10-05 and
not run, because another client held the GPU for the whole of the time
it was waited for.

**Composed upright sprites.** An upright sprite whose texture is an
expression (DorfCraft's engraving plate, below) takes its material class
from the first image the expression names, read through brackets and into
a `[combine`'s first part (`firstImage`, `goanna_overlay_companions.h`):
the plate `([combine:128x64:0,0=mcl_stairs_stone_slab_top.png\^[resize
\:16x16:...)^(glyphs)` is stone, where before 2026-10-06 the lookup asked
for `[combine:128x64:0,0=mcl_stairs_stone_slab_top.png\`, found nothing
and took class None. When that first image is a node tile (its class is
in the node table) and has an `_n`, the march's depth is that `_n`'s,
measured as the node path measures the tile's layer, not the composite's:
on the composite the glyphs' steep cut walls, laid in at the stone's finer
map scale, read about twice as deep as they are, every plate hit the 0.10
cap, and its stone marched deeper and drew darker than the same stone in
the wall. In the software run below the plate measured 0.10 before and
0.085 after, the wall's own figure.

**Wall plates.** DorfCraft cuts engravings into walls as an upright sprite
showing a stone plate, set a hundredth of a node in front of the face
because a vanilla client needs the gap or the two fight for depth. Drawn as
any other entity, the plate floated in front of the wall's relief and took
one light level for the whole entity, so a plate four nodes across beside a
torch was evenly lit where the wall beside it was not. Since 2026-10-06
(`EntityRenderer::updateWallPlate`, `goanna_upright_sprite.h`):

- An upright sprite is a wall plate when it is not blended
  (`use_texture_alpha` false) and not attached, its quads face along a
  world axis with no tilt, its plane is within 0.03 of a node face, and at
  five or more of nine points over it (a three by three grid) the node
  behind that face is solid and the node in front is not. Either quad may
  be the one facing out of the wall: DorfCraft turns its plates so that the
  back quad is the one seen.
- It is drawn on the face itself. Its position is put on the face, and the
  entity shader moves each vertex a thousandth of its distance toward the
  eye (`wall_plate_bias`), which leaves it on the same pixel and wins the
  depth test against the wall it lies on. The plate's march then cuts into
  the face.
- The quad seen is cut at every node boundary it crosses and each vertex
  takes its light from the map as the node mesher gives the wall's
  vertices (`BlockLightField::sample` with the wall's outward normal: block
  light, sky light and Goanna's occlusion, in `CUSTOM1`). The light is read
  again when a block around the plate changes (`blockRevision`), at most
  twice a second.
- The entity shader then lights it as `nodes_array.gdshader` lights the
  wall (`wall_plate` instance uniform): occlusion and sky visibility on
  ambient, the sky fill as emission shaped by the mapped normal between the
  sky and ground colours, the cloud shadow (now
  `cloud_shadow.gdshaderinc`, shared with the node shaders), and the baked
  block light only past the lamp pool's reach, where every other entity
  adds a warm fill from its one block light value on top of the lamps.
- It casts no shadow: the wall behind it casts that one.
- `GOANNA_NO_WALL_PLATE=1` turns all of this off, for an A/B.
- Not handled: a plate on a floor or ceiling, a plate turned off the world
  axes, one whose wall has holes over more than four of the nine points,
  and seams where the plate's march meets the wall's at the plate's edge.

`goanna_upright_sprite_test` checks the plane test, the node boundary cuts
and the grid. Seen in a frame on 2026-10-06 on lavapipe only (Godot 4.5.1,
a Luanti 5.17.0 server on a scratch Mineclonia world, release 38561,
holding DorfCraft's `dorfcraft_runes` mod and two engravings on a smooth
stone wall): the plates were found (`wall plate: ... seen quad=1`) and drew
on the face. Not yet seen on the GPU.

**Node layers sized from their companions.** Shipping maps only costs the
node forms of those stems their relief resolution, unless the client makes
up for it: a texture array layer is the size of the generated albedo, and
`godotArraySuffixed` resizes every companion down to the layer, so a mob
head, a disconnected melon or pumpkin stem or the chiseled bookshelf's
front drew a 16 pixel layer with 16 pixel maps. Since 2026-10-05
`GoannaTextureSource::nodeLayerScale` enlarges such a layer instead. When
a node tile's companion (`tileCompanion`, the `_n`, else the `_s`, composed
ones included) is exactly k times the generated albedo in both axes, with
1 < k <= 32, the layer is the albedo enlarged nearest by k, so each art
texel is a k by k block and the companion resize does nothing.

- It applies to array layers only. `addArrayTexture` enlarges, and it is
  called only for node arrays (node_visuals' bunches and
  `buildNodeAnimations`, which groups frames by the enlarged size so a
  bunch never mixes sizes). The image itself is never changed, so items,
  the HUD, entities and every `[combine` that uses it as a part still see
  the game's size.
- node_visuals groups its tiles by `getTextureDimensions`, which is
  transplanted code calling an upstream interface. Goanna takes upstream's
  `setImageCaching(true)`, which fillNodeVisuals calls just before pooling,
  as the start of the grouping, and reports enlarged sizes only until the
  first `addArrayTexture`, the first name asked twice or
  `setImageCaching(false)`. Autoscale, the wield mesh, the crack and
  everything else keep real sizes.
- A tile with a map sized albedo (k = 1), with no companion, with a
  companion that is not a whole multiple, or past the cap keeps exactly the
  layer it had. `goanna_tile_companion_test` checks a maps only tile, a
  `[combine` front whose composed `_s` is eight times it, and those
  unchanged cases through the real texture source.
- Memory: an enlarged layer joins the array of its companion's size, and
  its maps keep their full size rather than being shrunk. Mineclonia's
  heads are 64 by 32 skins with 256 by 128 maps, so each head face becomes
  a 64 pixel layer (k = 4), which is small. The two stems become 256 pixel
  layers (k = 16). The chiseled bookshelf is the large one: Mineclonia
  registers 64 nodes, one per fill state, each with its own `[combine`
  front, so up to 64 layers of 256 pixels, 16 MiB of albedo and 16 MiB
  for each of `_n` and `_s`, about 64 MiB with mipmaps, where the 16 pixel
  layers cost under 1 MiB. An array goes to the GPU whole the first time
  any of its layers is drawn, so these layers cost that whenever the 256
  pixel array they share with the pack's other tiles is in use, bookshelf
  in view or not.
- Not yet checked: the per node detail shift (`goanna_node_uv`) snaps to
  the layer's texel, which on an enlarged layer is finer than the art's.
  It only runs on granular classes, which none of these tiles are. Inferred
  relief for a layer with an `_s` but no `_n` is now read from the enlarged
  albedo. Not yet seen in a frame: the GPU was taken when the check was due.
- The texture resolution tier caps the enlargement: k never passes the
  tier's pixels per art texel (8 at 128), so the bookshelf's fronts are
  128 pixel layers at 128. Its companions were already reduced when they
  were loaded (below), so the cap only matters for a companion whose art
  the reduction could not count.

**Texture resolution.** Since 2026-10-05 the client holds every albedo and
companion to the tier's `texture_size` (128, 256 or 512 map pixels per 16
art texels; [graphics tiers](graphics-tiers.md), "Texture resolution").
`GoannaTextureSource::capImage` (`src/goanna_textures.cpp`, with the
arithmetic in `src/goanna_texture_size.{h,cpp}`) does it as each image is
inserted, so every consumer starts from the reduced image: node arrays,
animation strips, entity companions, overlay composites and composed
companions alike.

- The art an image is counted against is the server's own image of the
  same name, recorded the first time a name is inserted as media, before
  a pack replaces it. A companion counts against the image it belongs to:
  `x_n.png` and `x_s.png` against the server's `x.png`, a mask's against
  the mask. Pixels per texel are the larger of the two axes' ratios, so a
  still map for an animation strip is held by its width. A companion
  inserted before its art (server media in name order) is reduced once
  the media and the pack are all in (`finishTextureCap`). An image whose
  art never arrives, a pack file the server has no image for, is left as
  it is; the join's log line counts them (`art_unknown`).
- The reduction is by area, each output pixel the weighted mean of the
  source pixels it covers, which is an exact box for the usual whole
  factor. The albedo's colour is weighted by its alpha, so a cut-out's
  hidden colour does not bleed into its edge. `_n` is averaged as unit
  vectors and renormalised, occlusion and height averaged. `_s` smoothness
  is averaged; F0 or metal, porosity or scattering, and emission are
  categorical, so each output pixel takes the value covering most of it.
  A block of one value comes through exactly. Mipmaps are built from the
  result as before.
- A layer's companion that is larger than the layer (rare once the cap
  has run) is reduced the same way in `godotArraySuffixed`, which before
  shrank `_n` bilinearly and `_s` by nearest, skipping texels and leaving
  the normals short.
- Parallax depth. The relief depth the client measures from a `_n`
  (`reliefDepth`, the normal's slope over the height's) is not the same on
  a reduced map: averaging puts a one pixel chamfer's slope into pixels
  twice as wide. Over Mineclonia's tiles brought from 256 to 128 it moved
  by 0.0075 node at the median and 0.047 at the 90th percentile, against a
  mean of 0.065. So a reduced `_n` keeps the depth it had before
  (`reducedReliefDepth`, the same measure), and a node array layer whose
  `_n` is a reduced plain image uses it. A composed companion, a frame
  cut and an entity skin are measured on the reduced map as before. On
  skins the measure moved by 0.005 node at the median and 0.026 at the
  90th percentile (gold armour 0.09 to 0.02, the dolphin 0 to 0.10); a
  correction from the tile measure did not restore it, because a skin is
  measured inside its faces. A pack built at 128 (`tools/pbr_author`)
  keeps it much closer: 0.0014 at the median, 0.012 at the 90th.
- The cap does nothing without a pack over it: a server's own 16 pixel
  art is 1 pixel to a texel. Raising the setting cannot bring back what
  a reduction threw away, which is why it applies at the next join.

Tests: `goanna_texture_size_test` checks the sizes, each filter against
hand worked pixels, the depth measure, and the cap through the texture
source with server media and a pack inserted as a join inserts them,
including a companion ahead of its art, one with no art, a skin part and
a node layer enlarged to the cap and no further.

Tests: `goanna_overlay_companions_test` (the reader and the arithmetic,
with the strings Mineclonia sends for the nylium, the bookshelf, the
trident, the shield, the screwdriver, the carrot and a redstone cross) and
`goanna_tile_companion_test` (the choice between the base image's
companion and a composed one through the extension's texture source, the
cache, and the fallbacks). Neither renders. None of this has been seen in
a frame yet: the one client run made for it failed at join on a fault in
its own test world, and the GPU was taken when it could have been repeated.

## How LabPBR maps onto glTF 2.0

Upstream discussion favours taking glTF 2.0 material semantics as the
starting point. The two standards overlap on the core of a PBR material and
diverge at the edges in both directions, so neither is a superset.

| LabPBR | glTF 2.0 | Notes |
| --- | --- | --- |
| Smoothness, `_s` R | `roughnessFactor` or roughness texture | The GGX roughness is `(1 - smoothness)` squared. glTF's `roughnessFactor` is perceptual, like Godot's `ROUGHNESS`, so it carries `1 - smoothness` |
| F0 and metal, `_s` G | `metallicFactor` or metallic texture | glTF has no metal table. Its model matches the LabPBR 255 case, albedo as F0 |
| Material AO, `_n` B | `occlusionTexture` | Direct equivalent |
| Normal, `_n` RG | `normalTexture` | **glTF specifies Y up, LabPBR stores Y down.** Whether a flip is needed depends on the mesh's V direction |
| Emission, `_s` A | `emissiveTexture` and `emissiveStrength` | LabPBR is a scalar mask read against albedo, glTF carries an emissive colour |
| Height, `_n` A | Nothing in core glTF | `KHR_materials_displacement` was never ratified |
| Porosity and SSS, `_s` B | Partly `KHR_materials_volume`, `KHR_materials_diffuse_transmission` | No single equivalent channel |
| Nothing | `transmission`, `ior` | LabPBR carries neither |
| Nothing | Anisotropy, clearcoat, sheen | glTF extensions with no LabPBR equivalent |

Read across, adopting LabPBR costs transmission and refraction and gains
height and scattering. The normal convention has to be reconciled either way.

## What a naming convention does not settle

A file name says which file. It says nothing about what the bytes mean, so
two clients can both support LabPBR and still disagree. These are the points
an agreement has to pin down, all of which we have hit in practice.

**Normal orientation.** As above, and note that the answer is not a property
of the texture alone. It cost us a day: first relief that did nothing we
could see, then, once we 'fixed' the orientation, black block sides.

**Colour space.** Which companions are sRGB and which are linear. Getting
this wrong is subtle, pervasive and hard to see in a screenshot.

**How texture modifiers propagate.** This is the Luanti specific question,
and the one no existing standard can answer, because Minecraft has no
equivalent. Luanti textures are expressions, not file names:
`default_stone.png^[colorize:#ff0000`, `^[crack:1:4:2`,
`[combine:16x16:0,0=a.png`, and the inventory cube form. An agreement has to
say what the companion of an
expression is. Reasonable answers exist: a colour only modifier leaves the
companions untouched, which is what makes one normal map serve every recolour
of a texture, and `[combine:` has to composite the companions in the same
layout as the diffuse. Until that is written down, every client will guess
differently.

That question also answers the standing objection to the naming convention
route, which is that it forces one normal map per texture and makes recoloured
variants duplicate their companions. Under Luanti's modifier syntax the base
image keeps its name, so the variants already share one companion for free.

**Palette interaction.** Luanti tints nodes per instance through `palette`
and `paramtype2 = color`. Whether that tint modulates only albedo, or also
F0 and emission, is undefined.

**Precedence.** What wins when the server serves `_n` for a texture and the
player's own client side texture pack also has one.

**Discovery.** Whether a client probes for companions, which is what Goanna
does and which needs nothing from the engine, or whether something declares
them up front. Probing works against every server that exists today.
Declaring is friendlier to a client that wants to plan its uploads or fall
back cleanly.

## A proposed shape

If the naming convention were formalised as the material agreement, the
smallest useful version is:

1. Companions are `<base>_n.png` and `<base>_s.png` beside `<base>.png`,
   with LabPBR channel assignments.
2. Normals are stored Y down as LabPBR has them, which matches the V
   direction of Luanti's tile UVs, so no client has to flip anything. State
   it explicitly rather than leaving it to be inferred from glTF.
3. All companions are linear. Only the diffuse is sRGB.
4. Companions attach to the base image of a texture expression. Modifiers
   that only change colour leave them alone. Modifiers that change layout
   apply the same layout to the companions.
5. Server media takes precedence over a client side pack, and a client may
   offer the player an override.

   Worth flagging before this is proposed anywhere: Luanti already does the
   opposite. `Client::loadMedia` inserts every media file with
   `prefer_local = true` (`client/texturesource.cpp:534`), so a player's
   `texture_path` overrides the server's art. That is what makes a texture
   pack a texture pack. Goanna matches upstream rather than this point, and
   the point should probably be rewritten to match reality: the local pack
   wins, and the interesting question is only whether a companion may be
   taken from a different source to the diffuse it dresses.
6. A client discovers companions by probing. No declaration is required.

Point 3 is the only place this departs from LabPBR, and it is one line in a
converter.

What this does not cover, and what a Lua side API would still be needed for,
is anything keyed to a node rather than to a texture: chamfer profiles, mote
emission, waving amplitude, whether a surface should be displaced at all.
Those are node properties, not surface properties, and no texture naming
scheme reaches them.

## Per channel strength

A pack's channels are authored for another renderer and another art style, and
they routinely arrive too strong for the game being dressed. The Mineclonia
bake's normals carry a per channel standard deviation over 40 of 255 and its
occlusion reaches 147, which on 16 pixel art reads as smeared blotches rather
than relief.

So every decoded channel is scaled by a uniform, settable live from the
settings panel's Material tab and through
`GoannaClient::set_material_strength`: `normal`, `ao`, `roughness`,
`specular`, `emission`, `sss`. 1.0 is the pack as authored. 0.0 gives back
exactly what a node with no companion gets, which makes each one an A/B
against its own absence rather than a fade to black.

These are presentation, not decode. The decode stays literal, so a pack that
looks wrong at 1.0 is reporting something true about itself.

### Occlusion has to reach the fill, 2026-08-30

Reported as AO and corner darkening never visibly working, at any slider.
The knobs worked; the light they modulate was the minority of the pixel.
The pack's `ao` and the traced `vertex_ao` fed Godot's `AO` output, which
multiplies ambient light only, and SSAO likewise darkens ambient. But most
of a Goanna surface's light is the sky fill, written as `EMISSION` so the
sun's shadow cannot darken it, and emission is outside every occlusion
path. Measured on a noon forest floor with the camera held still: turning
the sky fill off removed 57 per cent of the frame's mean luminance and 87
per cent of the darkest quartile's, while sweeping `vertex_ao` end to end
moved the frame by 0.1 of 255 and the whole SSAO slider by 3.

The fill in the two `nodes_array` shaders now multiplies
`clamp(pack_ao * occ, 0.0, 1.0)`, the same terms the `AO` output carries,
so a corner is dark in the light that actually reaches it. Same scene
after: sweeping `vertex_ao` moves the darkest quartile by 6.7 of 255
rather than 0.2. The far vista, checked from 110 nodes up over the same
world, does not collapse: the far tracer's heavier occlusion (a known
calibration debt) darkens the fill there too, and it wants the chart
before it is trusted, but the frame still reads as terrain under haze.
SSAO still cannot reach the fill; the traced term is the stable one and
is now the one doing the visible work.

### Micro shadows and the short march, 2026-10-05

Lowest and Low turned parallax off, and with it the self shadow that
makes mortar, lock gaps and sunk features read when the sun rakes across
them. Two cheaper ways back are now in the shaders. Micro shadows are on
at every tier and Low runs the short march; Lowest keeps parallax off and
Medium and above keep the full march. The measurements are below.

**Micro shadows** (`mat_micro_shadow`, the `micro_shadow` material
strength, 0 or 1). Naughty Dog's BRDF micro shadowing (Brinck and
Maximov, "The Technical Art of Uncharted 4", SIGGRAPH 2016), the same form
Unity HDRP ships as Micro Shadows: direct light is multiplied by
`clamp(abs(N.L) + 2 * ao * ao - 1, 0, 1)`, where `ao` is the pack's `_n`
blue after `mat_ao` and N.L uses the mapped normal. A texel with no
occlusion is untouched; one at 0.5 loses light arriving more than 60
degrees from its normal. It runs in `light()` (`direct_light.gdshaderinc`)
on both node array shaders, waving plants and leaves, and every mesh
entity shader, from a varying the fragment already had the value for: no
texture read. It is not applied to the vertex corner term, which is the
shape of the room rather than of a texel.

Where the parallax march's self shadow ran, the sun takes the micro
shadow only in proportion to how far the march has faded (`1 - pom`):
the march traces the real height field toward the sun, which is what
micro shadowing approximates from occlusion, and both together darken the
same joint twice. The moon, the bounce and every lamp are never traced by
the march, so they take the micro shadow in full at every tier. Beyond
`parallax_range`, and everywhere on a tier with parallax off, the sun
takes it in full too.

**The short march** (`mat_parallax_short`, the `parallax_short` material
strength, 0 or 1, read only where `mat_parallax` is on). Four steps, two
halvings of the step that crossed the surface, then the chord; four self
shadow steps instead of eight; and only within `parallax_short_range`
(8 nodes) of the eye, fading to the plain normal map over its outer half.
Mobs take the same: four steps and at most two halvings.

**Measured** 2026-10-05, RTX 3090, Godot 4.5.1, the Mineclonia pack from
`pbr_packs/mineclonia`, `test_world` copied to `goanna_occl_1005` with the
fixture in `docs/perf/low-tier-occlusion-2026-10-05/fixture/` (a floating
platform with cobble, stone, stone brick and brick walls and oak logs). A
fresh profile was written for each tier, and the held values were recorded
beside every sample. Low ran at 1280x800 and Medium at 1920x1080. The
driver is `run.py` and the tables come from `analyse.py`, both in that
directory.

Timing frames as the client presents them was worthless here. Headless
gamescope composites on the CPU at about 33 frames a second, so the GPU
idled in a low power state (P5, 900 to 1050 MHz) and the GPU time of a
single setting swung between 2.8 and 15 ms from second to second. One
setting's round medians ranged from 1.7 to 10.7 ms. So each sample is
instead 600 draws back to back, without presenting
(`RenderingServer.force_draw`), with the world frozen for that moment.
Variants were taken in rotation, sixteen rounds each, and every round's
median is compared with the baseline's median from the same round. The
"wall" pose is two nodes from the cobble wall, which fills about four
fifths of the frame, at a sun 20 degrees up. The "vista" is the benchmark
scene at noon. GPU milliseconds:

| Tier, pose | Variant | Median | p95 | Per round vs today | Spread |
| --- | --- | ---: | ---: | ---: | --- |
| Low, vista | today (no march) | 1.685 | 3.018 | | |
| Low, vista | micro | 1.693 | 2.931 | +0.000 | -0.020 to +0.083 |
| Low, vista | short march | 1.691 | 2.925 | +0.001 | -0.038 to +0.032 |
| Low, vista | short + micro | 1.691 | 3.056 | +0.004 | -0.031 to +0.051 |
| Low, wall | today (no march) | 1.295 | 2.657 | | |
| Low, wall | micro | 1.291 | 2.569 | -0.001 | -0.022 to +0.021 |
| Low, wall | short march | 1.364 | 2.720 | +0.075 | +0.059 to +0.102 |
| Low, wall | short + micro | 1.364 | 2.629 | +0.076 | +0.047 to +0.103 |
| Medium, vista | today (full march) | 4.880 | 6.314 | | |
| Medium, vista | micro | 4.900 | 6.429 | +0.009 | -0.244 to +0.348 |
| Medium, vista | short + micro | 4.896 | 6.359 | +0.016 | -0.256 to +0.191 |
| Medium, wall | today (full march) | 2.832 | 4.027 | | |
| Medium, wall | micro | 2.834 | 4.024 | +0.002 | -0.026 to +0.367 |
| Medium, wall | short + micro | 2.777 | 3.975 | -0.052 | -0.062 to +0.131 |

The Low wall rows are from a second run, after a storm arrived part way
through the first. The first run gave +0.004 (micro) and +0.077 (short)
there, the same within the spread.

So the micro shadow costs nothing that this method resolves, at either
tier. The short march costs Low 0.075 ms (spread 0.047 to 0.106) when a
near wall fills the frame, about 6 per cent of that frame's GPU time on
this card, and nothing measurable at the vista. On Medium it saves 0.05 ms
against the full march. These are desktop numbers. Nothing here says what
either costs on a Steam Deck, and they are not scaled to one.

**What it looks like.** Frames at a sun 20 degrees up, every variant at
every pose, are in
`~/.local/share/goanna-pbr-audit/low-tier-occlusion-2026-10-05/`.

- The micro shadow is subtle. Over the centre of each wall and log frame
  the darkest quarter of the pixels drops 0.5 to 3 levels of 255 at Low
  (most on brick) and at most 1.2 at Medium. It reads as slightly deeper
  mortar and bark furrows, not as new shadows: it does not restore the
  parallax self shadow's cast shapes. The zombie and the player animate
  between frames, so their pairs do not isolate it.
- The short march at Low gives the joints depth within a few nodes: a
  lip on the stone and a shaded wall inside the joint, where the plain
  normal map draws a flat line. Only still frames were taken, so how it
  holds up in motion has not been seen. At three nodes Medium's frames with
  the short march could not be told apart from the full march (mean
  difference 0.2 to 1.4 levels on the walls).
- Both marches draw a thin dark line along the horizontal boundary
  between two stacked stone brick nodes (the `stonebrick_west` frames).
  This is not new: Medium's full march draws it too. Not investigated.

Two faults showed during the run, neither in these shaders. A wall built
by `/occl_build` in the map block beyond the platform's own never reached
the client. After a run of teleports between poses, the near mesh of the
platform's western map block was gone and did not come back, although
`node_name_at` still returned its nodes.

Worth stating plainly, because the obvious assumption is wrong and this
repository has got licences wrong before.

The art a bake reads is not covered by the game's code licence, and not by
Luanti's media terms either. Mineclonia's `LEGAL.md` puts its **code** under
GPL-3.0 and its **textures** under CC BY-SA 4.0, being "based on Pixel
Perfection by XSSheep and Pixel Perfection Legacy by Nova Wostra", with "most
textures are verbatim copies". Other media there defaults to CC BY-SA 3.0.
So the lineage runs back to a Minecraft resource pack, under a copyleft
Creative Commons licence with a share-alike term and an attribution
requirement.

Everything `tools/pbr_bake.py` writes is a derivative of that art rather than
new art: stage one is a deliberately low denoise pass conditioned on the
source so the output stays the same texture, and the normal and spec maps are
derived from that output. The licence and the attribution travel with them.

Two practical consequences:

- `pbr_bake.py` writes an `ATTRIBUTION.md` beside its output naming the source
  game and its licence files. A folder of loose PNGs with no provenance is how
  this gets lost.
- `pbr_deploy.py` copies that file into the worldmod it builds. Serving a
  worldmod is distribution, to every client that connects, so it is the point
  at which the share-alike term actually bites.

The top level file is the floor, not the whole account. Individual mods carry
their own, naming authors the game wide statement does not:
`mcl_amethyst/textures/LICENSE.txt` credits Nova_Wostra by name,
`mcl_experience/textures/attributes.txt` points one texture at a third party
repository, and `mobs_mc/LICENSE-media.md` is a media credits file in its own
right. Mineclonia release 37652 has 27 such files. `write_attribution` sweeps
`mods/` for them and lists each with its first line.

Neither tool can tell you whether a given game's art permits any of this. Read
those files before redistributing a bake.

## Tooling

`tools/pbr_pack.py` composes LabPBR companions for a Luanti game from a
Minecraft pack, in either the built form or the PixelGraph source form, and
scales them to each target texture's own size. Mappings live in
`tools/pbr_maps/<pack>-<game>.csv` as `pack_block,game_texture` rows, because
coverage and block naming differ per pack and per game.

Run with `--suggest` to get candidate rows. Review them. The suggester matches
on name, and a wrong pair silently dresses one block in another block's
material. It offers ambiguous names as commented rows rather than guessing.

Check the licence of any pack before redistributing what this produces. The
output is derived from the pack's own maps, so its terms follow. Some packs
that look permissive are not.
