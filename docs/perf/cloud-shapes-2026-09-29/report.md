# Larger cloud shapes, 2026-09-29

The previous block and fluffy cloud layers exposed their small, identical
cell footprints. From above they formed rows of tiles. The traversal also
advanced by only 0.001 nodes after each boundary. At large drifting
coordinates that increment could disappear when converted back to a world
position, revisiting a cell until the traversal budget ran out. Repeated
integration made soft edges opaque and left missing clouds behind them.

Cloud bodies now have independent widths and offsets inside much larger,
staggered cells. Footprints range from about 161 to 353 nodes in the low
layer, 266 to 583 in the middle and 371 to 812 in the high layer. The
minimum low-layer depth increases from 48 to 96 nodes. Height variation,
weather coverage and the configurable layer count remain in use.

Fluffy clouds use a rounded envelope normalised on each axis, with noise
carving uneven edges. Traversal advances explicit cell coordinates and
re-enters each staggered row without a world-position epsilon. Nearby fog
and the CPU opacity estimate use the same footprints and rounded envelope;
their interior noise remains an approximation of the sky's texture noise.

## Appearance comparison

These are offline production-shader studies, not live server screenshots.
Godot 4.5.1, Forward+, llvmpipe (LLVM 22.1.8), 960x540, three cloud layers,
medium cloud quality. They ran through `tools/goanna-headless --software`
inside the isolated compositor while another client occupied the GPU.
The same fair-weather scenarios were captured before and after the change;
the between/above camera heights follow the changed layer bounds.

| View | Before | After |
| --- | --- | --- |
| Below | [Before](before-below.png) | [After](after-below.png) |
| Between | [Before](before-between.png) | [After](after-between.png) |
| Above | [Before](before-above.png) | [After](after-above.png) |

The comparison views show larger bodies, irregular spacing and soft edges
without the previous square cut-offs and speckled patches. Clouds still
have a broad rectangular character, particularly with the plain block
style. The full volumetric style's density field is unchanged.

## Validation

- `tests/cloud_layers.gd`: zero failures, including elevated local fog,
  weather variation, hidden clouds and reduced layer budgets. The sample
  area now spans enough ground to contain the larger, sparser bodies.
- `tests/graphics_profiles.gd`: zero failures.
- `tests/cloud_layer_study.gd`: all three styles in fair weather, storm,
  between-layer, above-layer and mountain views. Hidden clouds and zero
  coverage produced identical images.
- `capture_edges()` in the same study: four cardinal views plus straight
  up/down, camera at (-18000, 3000, 21000), cloud offset (83.1, -61.7).
  Moving the camera 0.01 nodes changed the worst view's mean channel value
  by 0.0000356 on a normalised 0..1 scale. The original shader at the same
  updated layer bounds measured 0.000254. This is a motion diagnostic,
  not a timing benchmark.
- `tools/check-style.sh` and `git diff --check`: clean.

Ray and light sample counts have not increased. GPU performance has not
been measured for this revision; software rendering cannot establish the
cost on the player's GPU.
