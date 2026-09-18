# Lava brightness and shoreline review

Godot 4.5.1, Forward+, RTX 3090, Minetest Game default textures.
Two sealed stone rooms have matching geometry: a torch in one, a single
source of lava spreading naturally across the floor in the other. The camera
light, player body and lamp flicker are disabled. Lava animation is frozen
at two seconds for each capture, then restored. This compares the resulting
scenes; the spread lava occupies a much larger emitting area than the torch.

## Captures

- [Lava before](lava-before.png)
- [Lava after](lava-after.png)
- [Torch reference](torch-after.png)

The surface emission doubles from 2.4 to 4.8 before node-level scaling.
Spaced lava lamps receive 2.5 times their previous energy and move 0.3 nodes
higher. Range, attenuation and shadow budget remain unchanged. The torch
lamp retains energy 3.1256845 and its original position.

## Flat floor beyond the flow

Probes follow world X=21, Y=0.51, Z=-r. The node immediately above each
listed probe is air. Values are mean display-image luminance over 9 by 9
pixels, on a 0 to 1 scale, rather than physical illumination measurements.
The before and after runs use separate client processes; small ambient
colour differences also appear in the torch reference.

| Distance r | Before | After |
| --- | ---: | ---: |
| 8, first exposed floor sample | 0.1995 | 0.4143 |
| 9 | 0.1225 | 0.2920 |
| 10 | 0.0419 | 0.1499 |
| 11 | 0.0107 | 0.0690 |

Raw lamp positions, energies, projected probe positions and sampled RGB
are in [before.json](before.json) and [after.json](after.json).

## Shoreline and regressions

The native mesh now carries 6,794 vertices with zero crust coverage and
9,918 with full coverage, with intermediate values across the taper. Before,
all 19,170 vertices carried full coverage. Outer edges settle to the liquid
surface over 0.6 nodes; interior relief remains up to 0.14 nodes high.

- Native extension builds successfully.
- GPU seam comparison: zero changed pixels and zero mean error.
- Raised crust adds 7,783 silhouette pixels compared with flat lava.
- Zero shoreline coverage matches flat geometry and normals with zero
  mean image error.
- Real-time playback: 90,609 changed pixels over three seconds, zero test
  failures; rocky and molten control textures remain distinct.

## Reproduction

Install `tools/lava-review/cave.lua` as a worldmod in a **disposable**
Minetest Game world. It replaces the two room volumes on the first join
after each server start. Run the server on port 30580 and connect a client
with control port 30880, then run:

```sh
python3 tools/lava-review/cave_capture.py after
```

The capture tool's `--gain`, `--lift` and `--glow-gain` flags allow temporary
lighting comparisons. Lamp and shader changes are restored in `finally`.
Lighting still uses the shared shadow lamp budget, so very large pools or
scenes with many competing lights can have less even coverage.
