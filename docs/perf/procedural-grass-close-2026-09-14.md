# Procedural grass: camera inside the block

Godot 4.5.1, Vulkan, NVIDIA GeForce RTX 3090; isolated Minetest Game fixture,
1280×720 internal viewport, 4× MSAA and FXAA, 70° camera FOV. Measurements are
median viewport **GPU milliseconds**, not whole-client FPS. The ordinary
terrain/world cost with the grass shader disabled is approximately 2.4 ms.

The original shader reproduced the reported slowdown when the camera entered
the grass volume. Each patch extended 0.9 nodes in every horizontal direction,
and even weak actor influence selected a 17×17 blade search at every grid step.
Visible bending was not necessary to incur that search cost.

The optimised shader:

- Expands each patch only as far as its actual maximum actor influence needs.
- Bounds the blade search by the ray segment's height and possible bending.
- Restricts candidate cells to the patch's planted footprint.
- Rejects ray segments outside an enclosing blade cylinder before evaluating
  wind and quadratic intersections, in the rotated frame that preserves length.

The reproduced camera at `(6,80.1,0)`, with the ordinary player interaction
state, improved from **103.20 to 12.38 ms**. At root height `(6,79.65,0)`, it
improved from **76.50 to 9.59 ms**. These use 60 GPU samples after 45 warm frames
per case; artifacts are in `build/grass-review/close/{before,height-bounds}`.

A separate comparison alternated original and optimised shader code while
holding the scene updates still. Six camera/actor/wind poses were captured with
interaction explicitly disabled and with a full-strength actor at root height.
This distinguishes the general tracing improvement from actor search savings.

| Camera / interaction | Original GPU ms | Optimised GPU ms |
| --- | ---: | ---: |
| Inside, interaction disabled, pose 0 | 17.76 | 10.27 |
| Inside, full-strength actor, pose 0 | 107.16 | 34.96 |
| Near roots, interaction disabled, pose 3 | 14.25 | 8.41 |
| Near roots, full-strength actor, pose 3 | 68.08 | 17.70 |

Full-strength bending remains expensive when it fills the camera. These changes
do not reduce blade density, shorten blades, disable interaction, or reduce AA.

The 12 matched image pairs were checked for blade loss and clipping. In the
grass region below the HUD (x=40..1239, y=230..649), mean absolute RGB differences
were 0.0008–0.0257 on the 0–255 scale; at most 0.109% of pixels differed by more
than 10 in any channel. This is a bounded pose comparison, not a claim that all
camera paths or terrain transitions have been exhaustively tested.

Reproduce against a saved pre-change shader:

```sh
python3 tools/grass-review/run.py --keep --grass saved
python3 tools/grass-review/close.py current --modes off unbent natural bent
python3 tools/grass-review/compare.py /path/to/reference.gdshader
```

The comparison restores the shader from the workspace afterward. It captures
24 GPU samples after 20 warm frames for each variant; output is under
`build/grass-review/close/validation`. The saved graphics toggle regression also
passes with zero failures. The separate water/grass transparency issue is not
addressed by this optimisation.
