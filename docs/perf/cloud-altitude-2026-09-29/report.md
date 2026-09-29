# Upper cloud scale, 2026-09-29

Higher cloud layers now use progressively broader horizontal shapes:
low 1x, middle 4x, high 9x. The previous block scales were 1x, 1.65x and
2.3x; regular volumetric clouds used 1x at every height. In the latter,
the distant upper layer still looked like hundreds of small repeated flecks.

The scale applies to block footprints, fluffy surface noise, volumetric
body noise and the weather envelope. Nearby fog, the CPU opacity estimate
and the terrain-shadow approximation follow the same scale. Layer heights,
vertical thickness, layer-count settings and sampling budgets are unchanged.
Scaling follows the fixed layer slot, so flying or changing the enabled
layer count cannot resize the clouds around the player.

## Ground-level comparison

Offline production-shader captures, Godot 4.5.1, Forward+, llvmpipe
(LLVM 22.1.8), 960x540, medium cloud quality. The launcher still detected a
GPU client, so these used `tools/goanna-headless --software` in its isolated
compositor. They are appearance checks, not GPU benchmarks or live-server
screenshots.

Only the highest layer is visible in these comparisons, with the same
camera at (0, 64, 0), view slope 0.5, server base height 128, thickness 16,
coverage 0.7 and fair weather. The upper layer has its usual reduced
coverage and opacity. Isolating it makes its apparent size easy to compare.

| Style | Before | After |
| --- | --- | --- |
| Regular volumetric | [Before](volume-before.png) | [After](volume-after.png) |
| Fluffy blocks | [Before](fluffy-before.png) | [After](fluffy-after.png) |

The regular upper deck now forms a few broad banks rather than a carpet of
small patches. Fluffy upper clouds are also much broader and more widely
spaced. All three styles were additionally rendered with all layers in
fair weather, storm, between-layer, above-layer and mountain views.

`tests/cloud_layers.gd` passes, including fog occupancy over the enlarged
sample areas, height bounds, weather changes and reduced layer budgets.
Hidden clouds still match zero coverage exactly in the rendered study.
The shader runs logged no shader errors. Style and whitespace checks pass.
