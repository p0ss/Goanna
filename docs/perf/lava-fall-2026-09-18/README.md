# Falling lava, crust and moving lights

Godot 4.5.1 Forward+, RTX 3090. The native Minetest Game fixture has a
source spilling over a raised platform. [Capture](view-0.png) and
[mesh/lamp measurements](state.json) show the revised surface.

## Changes

- Select spaced liquid lights in world-key order before camera ranking.
  A two-node score improvement is required for liquid-to-liquid replacement
  inside the retained lamp set. Ordinary torch admission is unchanged.
- Remove specular from the liquid point lamps: their travelling highlights
  on cave walls do not represent a broad emitting surface. Raise lava
  roughness and reduce its own specular response too.
- Use luminance for the texture heat estimate, preserving relief in cool
  saturated red areas. Brightest-channel classification lost this detail.
- Exempt descending liquid from shoreline taper and displace outward using
  a shared occupancy-gradient direction, including vertical falls.
- Filter the height mask to mesh resolution, use that same mask to darken
  raised crust, and shade the actual geometry. Independent fine normals and
  fine bright texels had made raised areas read as glowing or inverted.

Height and glow are opposite sides of one animated world-space mask: the
height uses crust coverage, while emission uses its inverse squared. The
shader has no separate glow pulse or fine heat mask that can drift away
from the moving geometry.

## Verification

- GPU height-versus-emission check at two animation times: highest-fifth
  brightness 0.0000/0.0056 versus lowest-fifth 0.5559/0.2671. Both height
  and glow move across separately submitted adjacent tiles.

- Native build passed; live client has no mesh or shader errors.
- All 16 active lamps retained identical positions, energies and zero
  specular across three camera positions spanning 1.2 nodes.
- 175,025 native vertical-face vertices retained outward relief coverage.
- Zero displacement mismatches at shared native mesh positions.
- Saturated-red GPU fixture: zero seam error, zero shoreline flattening
  error, 4,660 raised silhouette pixels.

The live test is `tools/lava-review/fall_capture.py`, using disposable control
port 30881. `GOANNA_LAVA_RED_TEST=1` enables the saturated-red control texture
for `project/tests/lava_continuity.gd`. Run
`project/tests/lava_coupling.gd` for the height-versus-emission check.

Large camera moves, changes to liquid occupancy and exhaustion of the
shared shadow budget can still change which lamps are active. These checks
cover the local camera-movement case and default game artwork; they do not
establish compatibility with every texture pack.
