# Attribution for these maps

Built from the creature textures of DorfCraft's `deeprock` modpack by
DorfCraft contributors (a private repository at the time of writing), at
DorfCraft commit
`c4149783d89703d681e2f532fd68d4e964e15b6e`. DorfCraft's
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

The art and the maps' recipes are uncommitted local work at that commit:
`mods/deeprock/tools/art/` (including `goanna_maps.py`) was modified in the
working tree, and 186 of the 455 source textures were new or modified
there. The per texture record, with each source path, its build argument
and whether it was committed, is
`pbr_packs/manifests/deeprock-v1.sources.json`.

455 skins: 270 carved forms and 185 coat variants on those forms, at 4 map
pixels per art texel (Goanna's mob skins use 8; at 4 the pack is 190 MB in
place of over 600 MB, and the difference in game was hard to see).

The models are read only for their UV layout and are not copied.
