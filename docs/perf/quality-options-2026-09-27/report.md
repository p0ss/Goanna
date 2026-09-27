<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Cloud, lamp and grass controls, 2026-09-27

Implemented the next controls in the
[graphics tier contract](../../graphics-tiers.md). This record validates
behaviour and appearance; it does not calibrate hardware targets.

Tests used Godot 4.5.1 Forward+, a local Luanti 5.17.0 server and the
installed Mineclonia game, running disposable copies of test_world.
Clients used headless gamescope. The source world was not changed.

## Lamp admission and shadows

The GPU night fixture used four players at 1280x800, a direct-light pool of
32, and a starting shadow budget of eight. The observed counts were the
same in all four views:

| Variant | Lit lamps per view | Shadow maps per view |
| --- | ---: | ---: |
| Initial control | 32 | 8 |
| Shadows disabled | 32 | 0 |
| Two-shadow budget | 32 | 2 |
| Sixteen-shadow budget | 32 | 16 |
| Four-node shadow reach | 32 | 4 |
| Restored control | 32 | 8 |

The distance case includes the two-node retention margin for existing
shadow owners. All swept settings and AA matched after restoration.
[The night view](night.png) retains lamp illumination across the room.

These were short, three-second captures. The control median frame time
changed from 14.1 to 24.4 ms, so performance differences cannot be assigned
to the settings alone. No speedup is claimed. Unshadowed direct lamps can
still leak through walls; independent budgets do not provide a general
occlusion solution. Propagated node lighting remains the fallback beyond
the direct pool.

## Cloud styles

Block and rounded block styles use solid cells and no 3D density texture.
The first soft-block version only changed lighting normals; that was not
the requested shape. Its replacement intersects rounded boxes, with flat
faces and curved edges and corners that change the silhouette. The rounded
surface search is bounded at 32 steps per occupied cell.
The volume style retains its existing density march and independently
adjustable sun sampling.

The early circle view was near Mineclonia's cloud altitude, so thin block
clouds appeared as a horizon band. The cloud fixture instead sets a layer
at 128 nodes and cameras at 64, tilted slightly upward. The first 160-node
cells looked like oversized slabs and were reduced to 64-node cells.
The block path fades between 1800 and 2800 nodes.

The initial four-view comparison used CPU software rendering at 960x600:
[block](cloud-block.png),
[rejected lighting-only version](cloud-soft-block.png),
and [volume](cloud-volume.png).

The corrected shape was checked on the GPU at 960x600 in a close view:
[sharp blocks](cloud-block-close.png) and
[rounded blocks](cloud-rounded-close.png). These short captures establish
appearance, not performance scaling. Further art review in motion and
varied weather remains useful.

A four-player GPU follow-up exited during startup with native
`std::bad_alloc`, before the rounded-style override ran. It provides no
four-player evidence for the corrected shape. The successful close-view
capture and failed startup logs are in
[the rounded-cloud recording](rounded-cloud-data.tar.gz).

## Grass budgets

The close-grass visual comparison uses one view, 640x400, CPU software
rendering and fixed 2x MSAA plus FXAA. A four-view software attempt was
stopped because it was too slow for an efficient visual review; it is not
reported as a successful test.

[The sparse case](grass-sparse.png) uses density 0.2, 16-node reach and no
actor bending. [The full case](grass-full.png) uses density 1, 80-node reach
and up to eight actors within 16 nodes. Both retain continuous ground
coverage and visibly different blade density. The control uses density
0.4, 32-node reach and two actors within six nodes. All settings and AA
returned to their starting values after the sweep.

Software recordings are labelled `software_renderer: true`. Their frame
times, GPU-named renderer timers and memory counters do not describe the
physical GPU. Some one-second recordings contain too few frames for a
summary; the screenshots and setting state are the evidence here.

## Automated checks

- Native extension build passed.
- All 25 tier transitions passed, including per-view feature state and
  retained appearance preferences.
- Block-cloud startup skips 3D noise allocation; changing to volume creates
  it lazily.
- Grass toggling preserves terrain surfaces and applies budgets to existing
  materials. Raising and lowering AA restores its original baseline.
- Diagnostic feature sweeps restore the preset's actual on/off values.
- Lowest menu persistence, shader compilation, benchmark settle tests,
  profile-plan consistency, Python syntax and text-style checks passed.

[Raw plans, settings, counters, images and logs](raw-data.tar.gz) are
retained with the [implementation patch](implementation.patch) and
[profile snapshot](profiles.gd.txt). All owned clients and servers exited.
The temporary copied worlds and media were removed after review.
