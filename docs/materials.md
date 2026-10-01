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
  dropping the composite. Anything else (`[combine`, `[transform`,
  `[mask`, `[resize`, a frame cut, `[opacity` over the whole stack, nested
  groups, escaped characters) is not composited: the texture takes the
  companions of the image before its first `^`, as every entity texture
  did before.

**Sampling.** `_n` is linear with mipmaps, like the node path. At a
companion resolution of four or more map texels per art texel the half
texel a linear filter reaches across a UV island's edge is an eighth of an
art texel or less; at the art's own resolution it is half a texel and
shows as a soft rim along box edges up close. Mipmaps average across
islands at a distance, where the relief is below a pixel anyway. `_s` is
nearest with mipmaps, because a linear filter between a metal and a cloth
texel passes through values that decode as a dielectric at the largest
specular, a shiny rim round every metal plate.

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
material strength, which the Low profile's `mat_parallax 0` sets to 0;
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

**Where companions do not reach.** A surface the server marks
`use_texture_alpha` (a charged creeper's aura, a slime's outer body, a
spider's eyes) keeps the plain `StandardMaterial3D` path, with no
companions and no node light. A double sided surface draws through
`entity_double_sided.gdshader` (or its scissor variant) with everything
above, parallax included. Until 2026-10-02 it kept the plain path too, and
Mineclonia draws its players double sided, so the local player's body and
first person arms, the entity nearest the eye, had none of it while a
statue of the same skin had all of it.
`GOANNA_NO_PBR=1` withholds companions (from `main.gd` it needs
`GOANNA_PBR_SET=1` too, or the launcher clears it). With no `_n` in any
layer, the relief inferred from the texture's brightness applies, as it
does to an unauthored node tile; an authored `_n` in any layer turns it off
for that texture. The inference wraps at the image's edges and reads across
UV islands, which is right for a tile and wrong at an atlas's island edges.
It was also upside down along V, on node tiles and entities alike, from
0e3fa49 (which turned the mesher's binormal to minus V) until 2026-10-01:
a bright, raised texel lit from below the light. The probe's auto bump
quads check it.

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
