# Glass, ice and off-array faces across games, 2026-09-29

Each image is one fixture row, before the change above and after it below,
from the same pose at a fixed noon. The rows were built by a throwaway
worldmod on a stone floor at (0, 60, 0) in a fresh world per game:

- `mtg-glass.png`, minetest_game: glass, clear panes, obsidian glass and an
  obsidian pane in front of a wool wall, glass and obsidian glass doors at
  the ends, and a row of flowers and saplings.
- `asuna-ice.png`, Asuna: `ethereal:thin_ice`, `caverealms:thin_ice`,
  `everness:frosted_ice_translucent`, `default:ice`, `default:glass` and
  `everness:glass`, with wool and the same flowers.
- `kythen-ice.png`, Kythen: glacier, pressure and sea ice, the ice window,
  `kythen:glass` and the forest glass, in front of a brick wall.

The `*-shaders.txt` files are the client's `GOANNA_DEBUG_WHITE` lines for
the glass and ice shaders in each run: which texture took which shader,
and whether the face was culled.

## What changed

- minetest_game: the dandelion, viola and jungle sapling show their own
  textures. Before, they drew as a tulip, a geranium and an ordinary
  sapling, because a buffer that left its array took its first face's
  image. The glass doors take the glass shader (`cull=false` in the
  after log), which gives the obsidian door's pane its tint and a
  reflection.
- Asuna: the second flower is a tulip again, not a rose. Ethereal's
  thin ice (`default_ice.png^[opacity:80`) moved from the glass shader to
  the ice shader, and `caverealms_thin_ice.png` now reaches it too.
- Kythen: its ice is classed as ice rather than stone. The ice window
  gains a specular highlight; the glacier and pressure ice change only
  slightly. Its two glasses were already on the glass shader.

## How it was run

Godot 4.5.1 Forward+ on software Vulkan under headless gamescope
(`tools/goanna-headless start --software`), because another client held
the GPU. Luanti 5.17.0 servers from the flatpak. The "before" build is
commit d4a6ea1b; the "after" build is the working tree of the commit that
adds this report. Shaders were the same working tree for both.

## Limits

- Not seen on the GPU renderer.
- Lighting varies between runs: the Asuna glass measured a mean luminance
  of 117.7 before and 91.7 and then 109.5 on two runs of the same after
  build. The second run is shown. The textures matched in all three.
- Face on, glass reflects about 4 per cent, so the clear glass change from
  the previous commit is subtle in these poses.
- VoxeLibre was not rendered. Its glass and ice take the same paths as
  Mineclonia's by their definitions, which were read from a dump, not
  from a frame.
- `tools/pbr_bake.py` classifies nodes separately and was not changed.
