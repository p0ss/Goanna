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

The green channel of the normal map points **down**, which is the DirectX
convention. Godot and glTF both want Y up. Feeding LabPBR through unflipped
lights every bump as a dent, and nothing in the file name warns you.

The blue channel of the specular map is two materials sharing one range. A
surface is either porous or subsurface scattering, never both, and the split
sits at 64. In the pack we test against, leaves, grass, ice, obsidian and
diamond are authored as scattering, while dirt, stone, sand and logs sit in
the porosity range.

## What Goanna decodes today

| Channel | Status |
| --- | --- |
| Normal X and Y | Decoded, with the green channel flipped for Godot |
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
| Normal, `_n` RG | `normalTexture` | **glTF requires Y up, LabPBR stores Y down** |
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

**Normal orientation.** As above. This one cost us an afternoon of relief
that lit backwards.

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
2. Normals are stored Y up, contrary to LabPBR, matching glTF and every
   engine that consumes glTF. Converters flip on import.
3. All companions are linear. Only the diffuse is sRGB.
4. Companions attach to the base image of a texture expression. Modifiers
   that only change colour leave them alone. Modifiers that change layout
   apply the same layout to the companions.
5. Server media takes precedence over a client side pack, and a client may
   offer the player an override.
6. A client discovers companions by probing. No declaration is required.

Points 2 and 3 are the only places this departs from LabPBR, and both are
one line in a converter.

What this does not cover, and what a Lua side API would still be needed for,
is anything keyed to a node rather than to a texture: chamfer profiles, mote
emission, waving amplitude, whether a surface should be displaced at all.
Those are node properties, not surface properties, and no texture naming
scheme reaches them.

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
