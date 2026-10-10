# Entity PBR companions, 2026-10-01

A check, before LabPBR companions are authored for Mineclonia's mob skins,
that the client draws an entity's `_n` and `_s` where the art is. It did
not, in three ways. The rules as they now stand are in `docs/systems/materials.md`,
"Mob, player and item companions".

Rendered on the CPU (lavapipe, llvmpipe LLVM 22.1.8) under headless
gamescope with Godot 4.5.1, because another client held the GPU. Live
shots against a Luanti 5.17.0 server (flatpak) running Mineclonia, in a
fixture world of frozen statues: the game's own meshes, sizes and texture
strings at frame 0, time of day 0.3 with time stopped, sun low in the
east. Before is 7487da7; after is this branch.

## 1. Entity normal maps had no tangent frame

Luanti's skinned and item meshes carry no tangents; Godot then builds a
frame from the vertex normal alone. entity_common.gdshaderinc rebuilt it
from the UVs only for gem items. project/entity_normal_probe.tscn renders
mob-style quads (no tangent array), six face directions plain and mirrored,
beside a SurfaceTool reference, with one probe dome lit from the right and
the top.

- probe-before.png: 19 of 28 checks wrong. Faces along Z show the dome
  turned a quarter; the others are mirrored on one axis or both.
- probe-after.png: every quad matches the reference.

Encoding settled: red above 128 tilts toward plus U, green above 128
toward the top of the image, no green flip (as the node path).

## 2. Inferred relief was upside down along V

The last two quads of probe-after.png are a bright disc with relief from a
port of inferNormalImage, on the reference frame and an entity frame. With
the old green sign both lit like a pit along V. The LabPBR variant kept its
green from before 0e3fa49 turned the binormal to minus V; it now flips.
Unauthored node layers use the same function, so terrain's inferred relief
turns over too; reasoned, not photographed in play.

## 3. Overlay stacks took only the base layer's companions

A villager wore the base skin's relief and sheen over its clothes, a
golem's crack had no maps of its own, and a player found none (the base
name came out as "(mcl_skins_base_1_mask.png"). Companions are now
composited layer by layer (src/goanna_overlay_companions.h, tested by
goanna_overlay_companions_test). Two scratch sets, neither committed:
probe maps (a bevel per art texel at 4x and a smooth metal _s for golem,
villager base, mcl_skins_base_1 and mcl_skins_top_1), and the authoring
agent's prototype maps for the golem, its cracks and the villager base at
8x. Images, before / after / after with GOANNA_NO_PBR=1:

- villager-probe.png: before, relief and metal over the clothes; after,
  only on the uncovered skin.
- player-probe.png: before, no companions; after, the base bevels on face
  and hands and a metal shirt through the mask to part name fallback (the
  bright spot is the sun on that throwaway metal).
- cracked-golem-authored.png: the crack layer's own maps composited.

## 4. Smaller things

- _s was sampled linearly; metal beside cloth would interpolate into a
  maximal-specular dielectric rim. Now nearest with mipmaps. Reasoned, not
  photographed.
- The scissor variant decodes _n and _s exactly as the opaque one.
- GOANNA_NO_PBR=1 needs GOANNA_PBR_SET=1 from main.gd; inferred relief
  still applies under it.

## Not done

- Not on the GPU, not with moving mobs in a village.
- Mineclonia's separate hand node parses but was not seen drawn; Goanna's
  first person arm is the player model and takes the player path.
- Linear _n filtering bleeds half a map texel across UV island edges.
