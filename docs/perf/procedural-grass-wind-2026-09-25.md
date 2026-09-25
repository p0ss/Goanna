# Grass: close-up search, clumps, wind and first person

The analytic tracer now searches 0.96-node ray intervals, bounding candidate
roots against the entire interval and the possible actor/wind displacement.
It rejects against an enclosing cylinder before evaluating clump height and
wind, and constructs one rotation per candidate for both the ray origin and
direction. Blade spacing remains 0.12 nodes. The distance-estimator diagnostic
still traverses 0.12-node cells.

Heights now range approximately 0.25–1.10 nodes, combining two smooth world-space
clump waves with independent blade randomness. The field never restarts at a
voxel, patch or terrain tier. The distant canopy follows the broad height field,
flattening toward grazing angles to avoid unstable intersections. Its blend
runs from 25 to 65 nodes instead of 35 to 95; distant subpixel blades become the
continuous canopy earlier.

Wind now has travelling fronts and a smaller oblique ripple, anchored at each
root. The existing cloud motion supplies direction and a base strength, while
precipitation increases strength through the smoothed storm coverage. Direction
and strength ease over three seconds. This is a client-side inference from
existing sky/particle data, not a new server weather protocol. Wetness continues
to affect material appearance separately, so drying soil does not prolong wind.
The maximum wind envelope is included in ray search, proxy and CPU culling
bounds.

The local player's collision footprint always occupies the first interaction
slot, even when the rendered body is hidden. Its rendered entity is excluded
from the remaining slots so showing the body does not double the pressure.
Animals and other nearby actors continue to occupy the remaining seven slots.

## Measurements and limits

Godot 4.5.1, Vulkan, RTX 3090, isolated Minetest Game fixture, 1280×720,
4× MSAA plus FXAA, 70° FOV. Values are median viewport GPU milliseconds from
60 samples after 45 warm frames, not whole-client frame rates.

| View | Original | Revised tracer + clumps + wind |
| --- | ---: | ---: |
| Inside, full-strength actor | 33.88 | 17.25 |
| Root height, full-strength actor | 17.78 | 12.21 |
| Above, full-strength actor | 14.09 | 12.68 |
| Inside, interaction disabled | 9.41 | 9.33 |
| Distant, interaction disabled | 7.68 | 10.40 |

These captures precede the final earlier canopy transition and grazing-angle
correction. In particular the distant regression shown here motivated the
25–65-node transition; its GPU benefit has **not** been measured. The local
player/weather integration required restarting the client; the NVIDIA driver
then failed `vkCreateDevice` before the scene loaded, preventing final GPU
measurements and a final first-person visual capture. Earlier images were
reviewed, but no claim is made that temporal strobing is completely eliminated.

Artifacts: `build/grass-review/close/sept25-before` and
`build/grass-review/close/sept25-clumps`. The build and headless toggle regression
pass. Live first-person/body-toggle/movement/weather and water results are
recorded under `build/grass-review/sept25-features` and `sept25-water`.

Reproduce the live checks:

```sh
python3 tools/grass-review/run.py --keep
python3 tools/grass-review/close.py revised --modes off unbent natural bent
python3 tools/grass-review/features.py
python3 tools/grass-review/water.py --port 30867
```

For a headless fixture, use `run.py --headless` and `--no-shots` on the feature
and water scripts. These verify live state and geometry, not GPU rendering.
