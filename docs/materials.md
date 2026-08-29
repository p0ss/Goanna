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
| R | Perceptual smoothness, so roughness is `(1 - smoothness)` squared |
| G | 0 to 229 linear F0, 230 to 254 a predefined metal, 255 albedo as F0 |
| B | 0 to 64 porosity, 65 to 255 subsurface scattering |
| A | Emission, 0 to 254 for none to full, 255 meaning no emission at all |

Two of these are worth calling out because they are easy to get wrong.

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

## What Goanna decodes today

| Channel | Status |
| --- | --- |
| Normal X and Y | Decoded as stored. No green flip, see above |
| Material AO | Decoded, at 0.4 light affect |
| Height | **Not decoded.** Wanted for parallax and for terrain blending |
| Smoothness | Decoded as roughness |
| F0 and metalness | Decoded, but metals are binary rather than the metal table |
| Porosity | **Not decoded.** Nothing to show until weather can wet a surface |
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

## How LabPBR maps onto glTF 2.0

Upstream discussion favours taking glTF 2.0 material semantics as the
starting point. The two standards overlap on the core of a PBR material and
diverge at the edges in both directions, so neither is a superset.

| LabPBR | glTF 2.0 | Notes |
| --- | --- | --- |
| Smoothness, `_s` R | `roughnessFactor` or roughness texture | `roughness = (1 - smoothness)` squared |
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
