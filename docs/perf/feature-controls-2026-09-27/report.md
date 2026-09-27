<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Feature performance screening, 2026-09-27

The largest measured costs were four-player grass interaction and night
node lights. Disabling grass interaction raised mean throughput from
16.7-19.1 to 39.0 FPS. Disabling node lights raised it from 53.9-54.5 to
95.7 FPS. Streaming reduced throughput from 123.1 to 85.1 FPS, with terrain
polling and LOD spikes despite little change in median GPU time.

These are 30 short recordings of the expanded
[feature switches](../../render-feature-switches.md). Each recording lasts
about three seconds, with one-second warmups after live changes. The checks
use Godot 4.5.1 Forward+, Luanti 5.17.0, Mineclonia and the same RTX 3090
desktop as the earlier local-play run, at 1920x1080. Each trial has its own
configuration and world copy. Only one headless GPU client runs at a time.
Four-player cases render the complete four-view composition.

The selected profile is Low, with scene overrides: night uses 16 node
lights and 16 lamp shadows per player; grass enables procedural grass and
fixes 4x MSAA plus FXAA. These are feature comparisons within each scene,
not measurements of the unchanged Low preset. Each scene has only one
player count, so this dataset does not establish scaling with player count
or compare Low, Medium, High and Ultra.

## Feature costs

All timings below are milliseconds. Each triple is **enabled before /
feature off / enabled after**. Frame saving compares the off median with
the arithmetic mean of the two enabled medians. Control drift is the
percentage change from the first enabled median to the last. These are
observed differences, not confidence intervals or additive feature costs.
Controls bracket each scene's whole sweep, not every individual variant.
GPU time sums the active view timers. Renderer CPU time is rendering setup
plus active view CPU timers, not total main-thread time. Neither is an
exclusive portion of the frame interval.

| Feature disabled | Players | Frame median: before / off / after | Frame saving: ms (%) | Control drift | GPU median: before / off / after |
| --- | --- | --- | --- | --- | --- |
| Dusk shafts | 1 | 2.405 / 2.313 / 2.409 | 0.094 (3.9%) | +0.2% | 2.290 / 2.039 / 2.302 |
| Underwater volume | 1 | 2.281 / 2.279 / 2.301 | 0.012 (0.5%) | +0.9% | 1.696 / 1.424 / 1.693 |
| Wet surface detail | 1 | 2.614 / 2.607 / 2.640 | 0.020 (0.8%) | +1.0% | 2.473 / 2.466 / 2.495 |
| Water reflections | 1 | 2.614 / 2.623 / 2.640 | 0.004 (0.2%) | +1.0% | 2.473 / 2.495 / 2.495 |
| Water waves | 1 | 2.614 / 2.623 / 2.640 | 0.004 (0.2%) | +1.0% | 2.473 / 2.482 / 2.495 |
| Node lights | 4 | 18.309 / 10.239 / 18.187 | 8.009 (43.9%) | -0.7% | 10.241 / 4.862 / 10.122 |
| Carried light | 4 | 18.309 / 17.794 / 18.187 | 0.454 (2.5%) | -0.7% | 10.241 / 10.072 / 10.122 |
| Foliage wind | 1 | 2.491 / 2.498 / 2.704 | 0.100 (3.8%) | +8.6% | 2.043 / 2.093 / 2.058 |
| Grass interaction | 4 | 59.635 / 25.707 / 52.209 | 30.215 (54.0%) | -12.5% | 59.578 / 25.626 / 52.629 |
| Ice detail | 1 | 3.382 / 2.890 / 3.120 | 0.361 (11.1%) | -7.7% | 3.271 / 2.274 / 3.016 |
| Ice transmission | 1 | 3.382 / 2.614 / 3.120 | 0.637 (19.6%) | -7.7% | 3.271 / 2.462 / 3.016 |
| Lava detail | 1 | 3.380 / 3.227 / 3.386 | 0.156 (4.6%) | +0.2% | 3.284 / 3.125 / 3.290 |

The measurements suggest the following priorities:

- **Grass interaction is expensive in this close-grass scene.** Turning it
  off saved 50.8-56.9% of median frame time against either enabled control,
  despite 12.5% control drift. GPU time fell from 52.6-59.6 to 25.6 ms,
  while renderer CPU time stayed around 2.0-2.3 ms. Sampled GPU utilisation
  was 99-100%. This is strong evidence of a GPU cost. Grass geometry and AA
  remain enabled; the remaining 25.7 ms frame time is still substantial.
- **Night node lights cost both renderer CPU and GPU time.** Renderer CPU
  fell from 6.11-6.16 to 2.02 ms; GPU fell from 10.12-10.24 to 4.86 ms.
  Sampled median draw calls fell from 12,592-12,775 to 1,318. This variant
  removes the node-light pool and its shadows together and changes the
  near-terrain lighting fallback. It does not isolate shadow cost, nor
  show that light-candidate scanning caused the CPU difference.
- **Ice has measurable costs in both controls.** Removing transmission
  saved 16.2-22.7% of frame time against the two enabled controls, and
  sampled median draw calls fell from 907 to 487. Removing ice detail
  saved 7.4-14.5%. Control drift was 7.7%, so the exact ranking and size
  need repetition. These separate savings must not be added together.
- **Dusk shafts and lava detail showed small savings above control drift.**
  They saved 0.094 ms (3.9%) and 0.156 ms (4.6%), with about 0.2% control
  drift in each scene. These short runs warrant longer confirmation.
- **Underwater volume saves GPU work without a clear throughput gain.**
  GPU time fell from about 1.695 to 1.424 ms, roughly 16%, but frame time
  changed only 0.012 ms (0.5%), below the 0.9% control drift. A GPU saving
  is not automatically an FPS saving on this machine.
- **Carried light showed a modest lead:** 0.454 ms (2.5%) frame saving,
  against 0.7% control drift. Wet surface detail, water waves and water
  reflections changed frame time by less than or about control drift.
  Foliage wind was 0.3% slower than the first control but 7.6% faster than
  the last. These cases do not establish useful frame savings, and do not
  establish that the effects are free in other scenes.

The [individual recordings](measurements.md) show all 30 runs, including
frame counts, mean FPS, renderer CPU time, p99 and maximum frame time.
The [CSV](measurements.csv) contains unrounded values and sampled counters.
The grass controls contain only 51 and 58 measured frames; their tails are
particularly weak evidence.

## Streaming and per-player terrain work

Four players were spread 192 nodes from the centre, then moved at
8 nodes/second for about 24.5 nodes. Both recordings use one mesh worker
and a 1 ms poll budget per player, from totals of four workers and 4 ms.

| Phase | Frames | Mean FPS | Frame median ms | Frame p99 ms | Frame maximum ms | Renderer CPU median ms | GPU median ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| apart | 378 | 123.1 | 7.916 | 11.721 | 17.482 | 1.711 | 5.413 |
| streaming | 261 | 85.1 | 9.584 | 38.280 | 62.167 | 1.895 | 5.258 |

Mean throughput fell 30.8%. The frame p99 rose from 11.7 to 38.3 ms and
maximum from 17.5 to 62.2 ms, while median GPU time fell slightly. The
recorder counted 2 hitches while stationary and 21 while moving. These are
frames exceeding the larger of twice the phase median or median plus 8 ms.
These are counts over about three seconds, not a long-run hitch rate.

The table below shows the largest captured interval maximum for each
player's main-process stage, in milliseconds. There are four snapshots per
recording. Each stage maximum can occur on a different frame: **do not sum
columns or players**. The final fraction of a sampling interval may be
absent, so these are captured maxima, not guaranteed whole-run maxima.

| Phase | Player | Poll terrain max ms | LOD update max ms | Prune max ms | Main process total max ms | Resident mapblocks: first to last sample |
| --- | --- | --- | --- | --- | --- | --- |
| apart | 1 | 1.935 | 0.086 | 0.028 | 2.384 | 663 to 663 |
| apart | 2 | 0.008 | 0.010 | 0.027 | 1.160 | 603 to 603 |
| apart | 3 | 4.069 | 0.008 | 0.027 | 4.373 | 563 to 563 |
| apart | 4 | 0.010 | 0.006 | 0.026 | 0.797 | 537 to 537 |
| streaming | 1 | 28.505 | 38.945 | 0.289 | 39.845 | 663 to 794 |
| streaming | 2 | 35.061 | 9.291 | 0.322 | 35.868 | 603 to 676 |
| streaming | 3 | 18.865 | 13.769 | 0.611 | 19.345 | 563 to 600 |
| streaming | 4 | 26.075 | 5.352 | 0.255 | 28.081 | 537 to 612 |

Terrain polling reached 18.9-35.1 ms per player despite the requested
1 ms budget. LOD updates reached 38.9 ms for player 1. Pruning stayed below
0.7 ms in the captured intervals. This points to expensive polling and LOD
operations on the main thread as targets for a stricter work budget and
shared terrain processing. It does not identify the exact internal
operation, measure duplicated work, or prove the benefit of a shared cache.
A shared cache still needs an overlap-controlled comparison.

The prior local-play benchmark used different worker and poll budgets
(default totals of eight workers and 6 ms). Its 34 FPS four-player
streaming result and this 85 FPS result are not a measured optimisation.
This route also has only one stationary/moving pair, not repeated trials.

## Memory observations

Ranges below cover all sampled readings across each scene's variants.
RSS is the client process's resident memory; Godot video memory is its
renderer counter; whole-GPU memory is the device-wide `nvidia-smi` reading.
They measure different things and must not be added together.

| Scene | Players | Client RSS GiB | Godot video memory MiB | Whole-GPU memory MiB |
| --- | --- | --- | --- | --- |
| dusk | 1 | 2.445 to 2.446 | 463.6 to 463.7 | 3574 to 3574 |
| underwater | 1 | 2.240 to 2.249 | 360.4 to 418.9 | 3574 to 3574 |
| wet | 1 | 2.245 to 2.249 | 412.3 to 412.4 | 3616 to 3616 |
| night | 4 | 5.970 to 5.971 | 762.1 to 762.2 | 3977 to 3977 |
| foliage | 1 | 2.402 to 2.403 | 416.7 to 416.7 | 3610 to 3629 |
| grass | 4 | 5.992 to 5.992 | 884.1 to 884.2 | 3595 to 3735 |
| ice | 1 | 2.299 to 2.325 | 444.5 to 444.5 | 3616 to 3625 |
| magma | 1 | 2.259 to 2.268 | 427.0 to 427.0 | 3508 to 3531 |
| circle | 4 | 7.008 to 7.027 | 883.0 to 902.3 | 3632 to 3687 |

Turning underwater volume off reduced Godot's video-memory counter from
about 419 to 360 MiB, while whole-GPU allocation remained 3,574 MiB. Ice
transmission off left the renderer allocation at about 445 MiB, despite
removing a render pass. Disabling work does not necessarily release its
resources or reduce the driver's allocation.

The large grass and night performance changes occurred with essentially
unchanged client RSS and renderer memory counters. These measurements give
no evidence that RAM capacity caused those slowdowns. They do not test
memory pressure: host usage, paging and memory bandwidth were not measured,
and temporary worlds on tmpfs sit outside client RSS. There are only about
three hardware samples per recording, so the ranges are not true peaks.

## Completed scene checks

All nine final scene cases passed, with 30 short recordings in total.
Stationary variants include enabled controls before and after each sweep.
Every starting scene reported settled terrain, and every client passed
script, shader and shutdown-log checks.

| Scene capture | Players | Recordings |
| --- | --- | --- |
| [Dusk](dusk.png) | 1 | 3 |
| [Underwater](underwater.png) | 1 | 3 |
| [Wet stone and water](wet.png) | 1 | 5 |
| [Night lighting](night.png) | 4 | 4 |
| [Close foliage](foliage.png) | 1 | 3 |
| [Close grass](grass.png) | 4 | 3 |
| [Ice](ice.png) | 1 | 4 |
| [Magma](magma.png) | 1 | 3 |
| [Separated streaming](circle.png) | 4 | 2 |

The streaming check verified one mesh worker and a 1 ms poll budget per
player, from explicitly requested totals of four workers and 4 ms. The
recorded route covered about 24.5 nodes at 8 nodes/second. The night check
verified each direct-light pool changing from 16 to zero and back; carried
torches remained independent. Grass kept the same MSAA and FXAA throughout
its interaction comparison.

[Raw validation data](raw-validation.tar.gz) contains frame CSVs, hardware
samples, per-player counters and timings, effective settings, scene evidence,
logs and invocation plans. [Validation state](validation.json) lists the
cases. [Source metadata](source-metadata.json) records the final working tree.
Earlier development attempts are excluded, including the restored-rain
runs and shutdown crashes that led to the fixes below.

## What the controls now separate

- Underwater volumetric fog from ordinary water murk.
- Wet material detail from falling rain, and water waves from screen-space
  reflections.
- Node lights from the carried light, and lamp shadows from lamp count.
- Foliage wind from geometry, and grass interaction from grass and AA.
- Ice material detail from its additional background render.
- Lava shader detail from its retained subdivided mesh.
- Streaming routes, worker count and main-thread poll budget, with native
  terrain counters and main-process stage timings for each player.

The native node-light off path skips candidate scanning and ranking,
releases the direct-light pool, and allows the existing propagated terrain
light nearby. It is a measurable fallback, not a replacement for the full
lighting model. It does not establish acceptable night-time shading for
all entities and materials.

## Problems caught by the checks

The old noon circle cannot price screen-space shafts. Their strength falls
to zero as the sun rises. The dusk case now also faces the sun and checks
both its glow and its presence in the view; a nonzero strength setting
alone is insufficient.

The old weather configuration did not stop Mineclonia restoring rain from
the source world. Screenshot review caught rain in the grass test. The
fixture now clears weather on the server's first step, disables its cycle,
and rejects unexpected precipitation. The wet scene alone injects a
synthetic rain spawner and holds wetness at 0.8. Earlier attempts with
restored rain are excluded from the final evidence.

Disabling lamp shadows can increase the admitted light count. The night
fixture fixes the pool and shadow budget at 16 before changing either. It
also equips every player with a torch so the carried-light comparison has
an active light to remove.

Procedural grass normally promotes AA automatically. The grass fixture
instead fixes 4x MSAA and FXAA explicitly, allowing grass geometry,
interaction and each AA method to be compared independently.

Godot retains the last render timing of an inactive viewport. Summing that
value after disabling ice transmission overcounted GPU work. The recorder
now includes active ice views and skips disabled auxiliary views.

Disconnect released animated textures while the main scene could still
advance their animation. A native backtrace exposed the stale frame
pointers. Disconnect now clears animated-material references before
releasing the session, and material animation updates return when
disconnected. The standalone shader clock remains usable by renderer
fixtures.
The harness checks the shutdown log as well as recording success.

## Interpreting the data

Feature-state checks, scene evidence and composition captures establish
that the controls reached the intended work. Material gates still require
visual inspection; a material being allocated does not establish its
screen coverage. Grass interaction in particular changes with camera
height, nearby actors and coverage.

The per-player stage readings include the latest frame and independent
interval maxima. Do not sum those maxima, add nested native timers, or
subtract summed GPU time from frame time to claim exclusive CPU time.
The inherited bottleneck label in raw summaries is only a heuristic.

Client RSS and renderer memory counters do not include every host resource.
Disposable worlds here were stored on `/tmp`, which is tmpfs on this
machine. These short functional checks are not a test of available host RAM
or a basis for an automatic machine recommendation.

Longer isolated runs should bracket variants with repeated controls, then
repeat the scene matrix across player counts and profiles. The close-grass
and night-light cases deserve particular attention before changing defaults.

## Regression checks

The native extension built successfully. Feature-state, local-play scene
and menu regressions each finished with zero failures using the dummy
renderer and disposable settings. The existing
[node-animation GPU fixture](node-animation.log) also passed, including
its standalone clock, wrap, frame-selection and companion-texture checks.
`git diff --check`, `tools/check-style.sh`, Python compilation and the
shipped graphics-profile plan consistency check passed.

All test clients, servers and headless compositors were stopped. Large
throwaway world/media copies were removed after preserving the evidence.
