# Materials log

Investigations and measurements behind the material system, dated. The
current behaviour is in [materials](../systems/materials.md); the earlier
calibration work is in [material calibration](material-calibration.md).

## Occlusion has to reach the fill, 2026-08-30

Reported as AO and corner darkening never visibly working, at any slider.
The knobs worked; the light they modulate was the minority of the pixel.
The pack's `ao` and the traced `vertex_ao` fed Godot's `AO` output, which
multiplies ambient light only, and SSAO likewise darkens ambient. But most
of a Goanna surface's light is the sky fill, written as `EMISSION` so the
sun's shadow cannot darken it, and emission is outside every occlusion
path. Measured on a noon forest floor with the camera held still: turning
the sky fill off removed 57 per cent of the frame's mean luminance and 87
per cent of the darkest quartile's, while sweeping `vertex_ao` end to end
moved the frame by 0.1 of 255 and the whole SSAO slider by 3.

The fill in the two `nodes_array` shaders now multiplies
`clamp(pack_ao * occ, 0.0, 1.0)`, the same terms the `AO` output carries,
so a corner is dark in the light that actually reaches it. Same scene
after: sweeping `vertex_ao` moves the darkest quartile by 6.7 of 255
rather than 0.2. The far vista, checked from 110 nodes up over the same
world, does not collapse: the far tracer's heavier occlusion (a known
calibration debt) darkens the fill there too, and it wants the chart
before it is trusted, but the frame still reads as terrain under haze.
SSAO still cannot reach the fill; the traced term is the stable one and
is now the one doing the visible work.

## Micro shadows and the short march, measured 2026-10-05

**Measured** 2026-10-05, RTX 3090, Godot 4.5.1, the Mineclonia pack from
`pbr_packs/mineclonia`, `test_world` copied to `goanna_occl_1005` with the
fixture in `docs/perf/low-tier-occlusion-2026-10-05/fixture/` (a floating
platform with cobble, stone, stone brick and brick walls and oak logs). A
fresh profile was written for each tier, and the held values were recorded
beside every sample. Low ran at 1280x800 and Medium at 1920x1080. The
driver is `run.py` and the tables come from `analyse.py`, both in that
directory.

Timing frames as the client presents them was worthless here. Headless
gamescope composites on the CPU at about 33 frames a second, so the GPU
idled in a low power state (P5, 900 to 1050 MHz) and the GPU time of a
single setting swung between 2.8 and 15 ms from second to second. One
setting's round medians ranged from 1.7 to 10.7 ms. So each sample is
instead 600 draws back to back, without presenting
(`RenderingServer.force_draw`), with the world frozen for that moment.
Variants were taken in rotation, sixteen rounds each, and every round's
median is compared with the baseline's median from the same round. The
"wall" pose is two nodes from the cobble wall, which fills about four
fifths of the frame, at a sun 20 degrees up. The "vista" is the benchmark
scene at noon. GPU milliseconds:

| Tier, pose | Variant | Median | p95 | Per round vs today | Spread |
| --- | --- | ---: | ---: | ---: | --- |
| Low, vista | today (no march) | 1.685 | 3.018 | | |
| Low, vista | micro | 1.693 | 2.931 | +0.000 | -0.020 to +0.083 |
| Low, vista | short march | 1.691 | 2.925 | +0.001 | -0.038 to +0.032 |
| Low, vista | short + micro | 1.691 | 3.056 | +0.004 | -0.031 to +0.051 |
| Low, wall | today (no march) | 1.295 | 2.657 | | |
| Low, wall | micro | 1.291 | 2.569 | -0.001 | -0.022 to +0.021 |
| Low, wall | short march | 1.364 | 2.720 | +0.075 | +0.059 to +0.102 |
| Low, wall | short + micro | 1.364 | 2.629 | +0.076 | +0.047 to +0.103 |
| Medium, vista | today (full march) | 4.880 | 6.314 | | |
| Medium, vista | micro | 4.900 | 6.429 | +0.009 | -0.244 to +0.348 |
| Medium, vista | short + micro | 4.896 | 6.359 | +0.016 | -0.256 to +0.191 |
| Medium, wall | today (full march) | 2.832 | 4.027 | | |
| Medium, wall | micro | 2.834 | 4.024 | +0.002 | -0.026 to +0.367 |
| Medium, wall | short + micro | 2.777 | 3.975 | -0.052 | -0.062 to +0.131 |

The Low wall rows are from a second run, after a storm arrived part way
through the first. The first run gave +0.004 (micro) and +0.077 (short)
there, the same within the spread.

So the micro shadow costs nothing that this method resolves, at either
tier. The short march costs Low 0.075 ms (spread 0.047 to 0.106) when a
near wall fills the frame, about 6 per cent of that frame's GPU time on
this card, and nothing measurable at the vista. On Medium it saves 0.05 ms
against the full march. These are desktop numbers. Nothing here says what
either costs on a Steam Deck, and they are not scaled to one.

**What it looks like.** Frames at a sun 20 degrees up, every variant at
every pose, are in
`~/.local/share/goanna-pbr-audit/low-tier-occlusion-2026-10-05/`.

- The micro shadow is subtle. Over the centre of each wall and log frame
  the darkest quarter of the pixels drops 0.5 to 3 levels of 255 at Low
  (most on brick) and at most 1.2 at Medium. It reads as slightly deeper
  mortar and bark furrows, not as new shadows: it does not restore the
  parallax self shadow's cast shapes. The zombie and the player animate
  between frames, so their pairs do not isolate it.
- The short march at Low gives the joints depth within a few nodes: a
  lip on the stone and a shaded wall inside the joint, where the plain
  normal map draws a flat line. Only still frames were taken, so how it
  holds up in motion has not been seen. At three nodes Medium's frames with
  the short march could not be told apart from the full march (mean
  difference 0.2 to 1.4 levels on the walls).
- Both marches draw a thin dark line along the horizontal boundary
  between two stacked stone brick nodes (the `stonebrick_west` frames).
  This is not new: Medium's full march draws it too. Not investigated.

Two faults showed during the run, neither in these shaders. A wall built
by `/occl_build` in the map block beyond the platform's own never reached
the client. After a run of teleports between poses, the near mesh of the
platform's western map block was gone and did not come back, although
`node_name_at` still returned its nodes.
