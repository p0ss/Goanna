# Mineclonia lava and the stylised pack

The previous screenshots used Minetest Game or synthetic control textures.
They did not establish the appearance of Mineclonia's much darker orange
lava. A real Mineclonia cave with the user's `mineclonia_authored` pack
reproduced the reported near-black falling surface.

## Cause and correction

The fixed linear-luminance crust range ended at 0.50. Mineclonia's resolved
16 by 16 source frame only reaches 0.266, so almost the entire fall became
crust and its inverse glow mask suppressed emission. Native material setup
now measures the selected source image and uses its 20th and 80th luminance
percentiles. Low-contrast or wholly bright tiles reduce crust strength.
Both near and distant lava receive the same calibration.

Mineclonia's calibrated range is 0.0601 to 0.1644. The supplied stylised
artwork uses 0.0379 to 0.1555. Geometry and glow still use opposite sides of
one animated mask. Normals use that same mesh-filtered height field, with
central differences to avoid exposing every triangle as a hard facet.

## Actual game captures

- [Before: reported dark fall reproduced](before.png)
- [Corrected original Mineclonia artwork](calibrated.png)
- [New stylised artwork](stylised.png)

All views use the same sealed Mineclonia cave, camera and shader time of
three seconds, with the camera light and player body disabled. These are
native falling-liquid meshes, not preview quads. The world uses the same
authored terrain texture pack; the stylised version replaces only lava.

Four phase captures at 0, 3, 6 and 9 seconds were checked for both materials.
`measurements.json` records display luminance inside the waterfall; material
JSON files record texture sizes, emission and calibration parameters.

Native build, shader compilation, height/glow animation and seam/shoreline
checks pass. The final seam check has zero changed pixels and zero edge
flattening error. The captured clients have no shader or mesh errors.

## Reproduction

Use the disposable Mineclonia cave on server port 30581, with the fixture
from `tools/lava-review/cave.lua` adapted to `mcl_core:stone`,
`mcl_torches:torch` and `mcl_core:lava_source`. Raise the source to Y=6.

```sh
python3 tools/lava-review/run_mineclonia.py stylised baked/stylised-lava/textures
```

The runner starts its own client on control port 30882 and closes it after
the four captures. `project/tests/bake_stylised_lava.gd` regenerates the
stylised artwork from the supplied Material Maker shader export.
