# Goanna v0.8.0-alpha

Goanna 0.8.0 is about what a block looks like from a metre away. Surfaces
have depth, the Mineclonia pack is hand authored rather than baked, and a
block being mined is carved instead of cracked.

## Changes

- **Normal maps the right way up.** The mesher wrote the binormal sign
  opposite to Godot's, so every normal map in play was flipped along V.
  Relief now sits on the art it was derived from.
- **Parallax occlusion with self shadow** in the node shader, with depth
  set per material class. On the ramp, one material filling a 1600 by 900
  frame on an RTX 3090 costs under a millisecond. Its cost across a whole
  scene in play is not measured.
- **The authored Mineclonia pack.** 177 stems built by `tools/pbr_author/`
  from the game's own 16 px art replace the bake in the shipped pack. Ores
  are metal, gems reflect, redstone and the lit blocks glow. Judged on the
  close-up ramp under sun and lamp and in the maintainer's own play. No
  other game has an authored pack; Minetest Game still uses its bake.
- **Mining carves the block.** Damage is cut out of the block, the
  neighbours' exposed faces are drawn, and the stroke, sound, chips and
  carve volume follow one contact cycle tied to block damage. Carved faces
  keep the tile's PBR material instead of falling back to a crack tile.
  Carving is visual only: selection and collision still use the whole cube.
- **Water lit once.** The bed seen through water was lit a second time and
  read as a painted floor. Measured on the water fixture; no server run.
- **Distant forests and the fine scheduler.** Fine blocks stream alongside
  predicted forests, and the candidate scan is spread across frames. On
  copies of a Mineclonia world at the saved position, Godot 4.5.1, RTX
  3090, that took one scene from 1.7 fps to 66 fps. Loading hitches during
  fast travel remain.
- **Worlds and games.** The six Terrain Diffusion worlds are republished as
  `worlds-2026.09.2` with their rivers recomputed, previews draw the rivers,
  and games are named by their `game.conf` title, so VoxeLibre no longer
  appears as mineclone2.

## Still alpha

Linux, Godot 4.5, Vulkan. Mineclonia is the most tested game. A Windows
package is exported beside the Linux one, but no Windows export has ever
been launched by anyone; a report either way would be useful. macOS is not
built.
