# Attribution for these maps

Built from the creature textures of DorfCraft's `deeprock` modpack by
DorfCraft contributors (a private repository at the time of writing), at
DorfCraft commit
`a94c9af9b5134f702e4fff24025d410338d7ac0a`. DorfCraft's
`mods/deeprock/tools/art/goanna_maps.py` wrote one atlas spec per stem
(`tools/pbr/pbr_author/specs/deeprock/`) from each form's own build recipe,
naming a material for every texel, and called this repository's
`tools/pbr/pbr_author/atlas.build` on it. The normal, occlusion, height and
specular maps are derived from that recipe and from the art; the art itself
is not included. They are derivative works of that art, not new art.

The art was painted by DorfCraft's own tools from recipes, with AI-assisted
authoring. DorfCraft's `LICENSE-MEDIA` licenses all its media under the
Creative Commons Attribution-ShareAlike 4.0 International licence (CC BY-SA
4.0), and its `ATTRIBUTION.md` records the creature textures the same way.
These maps are offered under CC BY-SA 4.0:
<https://creativecommons.org/licenses/by-sa/4.0/legalcode>.

The maps' recipes, including `goanna_maps.py`, are committed at that
commit. Seven source textures, the hominin bodies' (`denisovan`, `erectus`,
`floresiensis`, `heidelbergensis`, `naledi`, `neanderthalensis`, `sapiens`),
were modified in the working tree there. The per texture record, with each
source path, its build argument and whether it was committed, is
`pbr_packs/manifests/deeprock-v1.sources.json`.

465 skins: 280 carved forms and 185 coat variants on those forms, at 4 map
pixels per art texel (Goanna's mob skins use 8; at 4 the pack is 194 MB in
place of over 600 MB, and the difference in game was hard to see).

The models are read only for their UV layout and are not copied.
