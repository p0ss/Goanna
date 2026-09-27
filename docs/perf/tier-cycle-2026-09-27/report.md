<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Tier cycle: terrain sharing and lamp visibility

Status: the desktop comparison cycle is complete, including the original
and revised 40-workload matrices and the controlled follow-ups. Differences
between the matrices are not isolated cache speedups: the revised client
also repairs cancelled terrain work, and parts of the original run
overlapped builds.

## Method

RTX 3090, Ryzen 7 7800X3D, Godot 4.5.1 Forward+, Luanti 5.17.0 and
Mineclonia release 38561. Each trial uses a disposable copy of the same
SQLite world snapshot, its own loopback server and player data, and one
headless GPU client. Total output is 1280x800, with one player or four
640x400 views. No desktop window or desktop input is used.

The five presets are unchanged for the implementation comparison. Four
mesh workers and 4 ms of terrain polling are divided between players.
Stationary phases wait for ten seconds of quiet, with a 120-second timeout;
recording lasts 15 seconds after warmup. Day phases face nearby players,
spread them 192 nodes apart, then fly radially at eight nodes per second.
Movement is followed by a queue-drain check. Night uses each tier's lamp
and shadow budgets. Stores and asset updates are disabled.

Frame periods cover the whole application. GPU figures sum viewport work,
including composition and enabled auxiliary views; they are not measured
GPU wall time. CPU/GPU work overlaps, so do not subtract these figures to
invent a CPU remainder. Sampled main-thread stage timings are diagnostic
observations, not a complete CPU profile. See the [plan](plan.md).

This is not a Steam Deck measurement. Its 30 FPS target remains a 33.3 ms
budget to validate on that hardware. A single multiplier cannot translate
this desktop's CPU, GPU and streaming results.

## Original screening, step 0

Each cell is median / p99 frame time in milliseconds. All 40 rows, including
mean FPS and GPU/render CPU diagnostics, are in [baseline.csv](baseline.csv).
The [raw archive](baseline-raw.tar.gz) retains frames, counter samples,
settings, logs and screenshots. [source.json](source.json) identifies the
frozen original binary and dirty checkout state.

### 1 player

| Tier | Nearby | Apart | Streaming | Night |
| --- | ---: | ---: | ---: | ---: |
| Lowest | 2.97 / 16.27 | 1.99 / 2.63 | 2.05 / 9.55 | 1.87 / 2.47 |
| Low | 2.90 / 4.59 | 3.65 / 32.32 | 7.57 / 51.02 | 2.62 / 3.64 |
| Medium | 3.08 / 4.26 | 2.85 / 4.98 | 3.30 / 16.14 | 2.72 / 4.04 |
| High | 3.55 / 4.60 | 3.15 / 4.10 | 3.45 / 18.26 | 4.17 / 5.34 |
| Ultra | 10.64 / 22.22 | 4.68 / 19.89 | 7.83 / 19.67 | 7.19 / 9.22 |

### 4 players

| Tier | Nearby | Apart | Streaming | Night |
| --- | ---: | ---: | ---: | ---: |
| Lowest | 11.72 / 65.25 | 7.10 / 11.01 | 9.74 / 27.35 | 6.94 / 8.90 |
| Low | 11.02 / 14.72 | 9.20 / 16.14 | 11.65 / 23.62 | 10.15 / 14.14 |
| Medium | 12.44 / 17.28 | 8.78 / 17.02 | 28.20 / 42.74 | 11.44 / 17.65 |
| High | 15.31 / 22.99 | 15.32 / 65.50 * | 59.08 / 155.94 * | 15.85 / 26.42 |
| Ultra | 20.53 / 30.56 | 10.95 / 22.92 * | 37.36 / 52.38 * | 29.07 / 41.08 |

An asterisk marks an unsettled start. High and Ultra four-player apart
phases timed out; movement inherited that state. All original movement
runs eventually drained. High's moving image shows incomplete distant
coverage, so its timing does not establish acceptable world delivery.

The original screening overlapped some compilation and dummy-renderer
checks. Isolated night stalls reached about one second, attributed by the
instrumentation to the primary scene's `other` stage, not specifically to
terrain or GPU work. Their cause is not established. Repeated quiet
controls are required before assigning savings.

Four-player streaming peak process RSS ranged from 6.72 GiB at Lowest to
8.16 GiB at Ultra. This is allocation evidence, not evidence of a RAM
bottleneck. GPU temperatures ranged from 60 to 83 C during the screening.

## Implementation and correctness

The [architecture](../../local-multiplayer.md) describes cache identities,
budgets, per-player boundaries and remaining duplicated work. Near geometry,
LOD hierarchies and eligible near GPU buffers can be reused. Far-region
mesh assembly and drawing remain per player. A cache hit proves reuse,
not a frame-time saving.

The first GPU-cache prototype hashed complete vertex arrays during
publication on the main thread. Single-player streaming p99 regressed from
about 9.6 ms to 38.2 ms. Compact worker-input identities and bypassing
single-view near caches removed most of that regression in subsequent
diagnostic runs. Prototype results are not final tier results.

Wall checks exposed large missing terrain sections in both the original
client and the cache-bypassed prototype. Disabling terrain culling did not
restore them. Changing mesh-worker allocation stopped pending regional
jobs but left regions marked as building. The repair clears that state and
marks affected regions dirty. Settling now includes near-region dirty and
building counts, rather than relying on an empty worker queue alone.

A targeted four-player test interrupted six in-flight regions, changed one
worker to two, and reached zero pending regional work. All four connections
received and displayed closed, open and restored wall edits. This diagnostic
run also logged a separate character basis error during startup; it is not
labelled a clean performance run.

A subsequent clean GPU run passed the permanent worker-reset check and all
five wall states, with no client errors. Its raw evidence is retained with
the controlled comparisons. The native suite, profile-transition checks and
benchmark settling tests pass. A dummy-renderer server test checked four
independent inventories, ordinary actions affecting only their owner, and
remaining connections staying ready when another player leaves.

## Lamp visibility prototype

The experimental `lamp_occlusion` switch reduces direct light leaking
through received full cubes. Static 64-node grids avoid repeated uploads;
changes refresh at most ten times per second. It remains off in all presets
after the dense-light comparison below. Partial nodes, carved openings,
carried lights, water, ice and volumetric fog retain their existing paths.
Unknown cells and unmatched sources fail open. Exactly collinear lamps
cannot always be distinguished from a light direction alone. Emission and
propagated block light remain separate.

A four-player single-wall check of the earlier prototype measured 6.86 ms
median without this filter, 6.95 ms with it, 7.54 ms with one shadow map per
view, and 7.01 ms for the restored control. The occlusion change was within
control drift. This does not establish dense-light or streaming cost.
Software-rendered images were visual evidence only.

## Revised matrix, unchanged tiers

The complete 40-workload repeat used a frozen revised client, with no
concurrent builds or test suites. Each cell is median / p99 frame time in
milliseconds. An asterisk marks an unsettled start. Full counters, mean FPS
and timer data are in [revised.csv](revised.csv) and the
[raw archive](revised-raw.tar.gz).

### 1 player

| Tier | Nearby | Apart | Streaming | Night |
| --- | ---: | ---: | ---: | ---: |
| Lowest | 1.99 / 2.45 | 1.94 / 2.42 | 1.99 / 8.70 | 1.93 / 2.56 |
| Low | 2.97 / 3.71 | 2.90 / 3.86 | 3.58 / 19.38 | 2.42 / 3.22 |
| Medium | 3.10 / 3.80 | 2.78 / 3.95 | 3.15 / 16.11 | 2.74 / 3.66 |
| High | 3.51 / 4.25 | 3.20 / 4.13 | 3.55 / 17.83 | 4.30 / 6.35 |
| Ultra | 8.50 / 9.89 | 4.56 / 5.41 | 6.63 / 17.83 | 7.35 / 7.82 |

### 4 players

| Tier | Nearby | Apart | Streaming | Night |
| --- | ---: | ---: | ---: | ---: |
| Lowest | 7.54 / 9.23 | 7.04 / 10.36 | 8.54 / 18.64 | 7.02 / 8.90 |
| Low | 10.72 / 13.66 | 9.03 / 12.89 | 11.78 / 22.90 | 9.39 / 11.42 |
| Medium | 12.36 / 23.15 | 8.97 / 16.92 * | 29.84 / 46.34 * | 9.94 / 12.50 |
| High | 14.13 / 21.03 | 10.03 / 19.33 | 29.21 / 46.03 | 14.53 / 18.06 |
| Ultra | 19.44 / 28.32 | 10.77 / 22.75 * | 34.91 / 48.82 * | 25.55 / 29.74 |

All movement runs drained. Medium and Ultra four-player apart phases did
not complete the quiet window before the timeout. High did settle this
time; its lower streaming cost is therefore not an isolated cache saving
against the original unsettled run. High's single-player night case had a
139 ms maximum frame despite a 6.35 ms p99. Rare stalls remain unresolved.

During the separated movement routes, sampled near-cache hit increments
were zero. LOD hierarchy reuse occurred, including matching empty blocks,
but these tests do not exercise the intended overlap case for near terrain.
The GPU cache counter in this matrix also included empty glow meshes; do
not equate it with nonempty GPU uploads saved. The controlled-test build
excludes empty meshes and makes the cache bypass skip key construction.

The original [wall image](wall-original.png) and
[repaired image](wall-repaired.png) retain identical camera positions with
lamp occlusion off. The [open wall](wall-open.png) shows the edit with lamp
occlusion on. These come from the diagnostic runs described above, including
the noted startup animation error. The
[Medium endpoint](medium-streaming-drained.png) shows terrain after draining.

## Controlled comparisons and tuning

The implementation control uses [control-source.json](control-source.json).
It excludes empty GPU meshes from cache-hit counts and skips cache-key
construction when sharing is disabled. There were no concurrent builds or
test suites. The older `after-source.json` describes the superseded
full-array-hashing prototype.

### Shared terrain, overlapping travel

Four players start eight nodes from the centre, retain their own viewing
angles and move together along +Z. Each tier runs with sharing disabled,
enabled and disabled again. All six trials started settled and drained at
the endpoint. Values are median / p99 frame time in milliseconds.

| Tier | Phase | Off before | On | Off after |
| --- | --- | ---: | ---: | ---: |
| Low | Stationary | 10.96 / 14.27 | 10.86 / 15.11 | 11.03 / 15.24 |
| Low | Streaming | 14.88 / 28.56 | 14.92 / 28.87 | 15.24 / 31.59 |
| Medium | Stationary | 15.61 / 21.79 | 15.29 / 24.36 | 14.66 / 19.95 |
| Medium | Streaming | 40.97 / 59.51 | 40.93 / 66.05 | 37.84 / 63.47 |

Neither tier shows a clear frame-time saving beyond control drift. The
sampled moving intervals contained 21 near-cache hits at Low and 27 at
Medium, against 2,143 and 1,487 near-cache builds respectively. Nonempty GPU
mesh hits were zero and one. Process-wide LOD hits increased by 6,670 and
3,929; these include identical empty blocks and within-player reuse, so they
are not counts of cross-player meshes saved.

Matching the full received neighbourhood is deliberately conservative.
Different views, arrival order, edits and cache eviction can reduce reuse;
these trials do not isolate their individual contributions. Near first
misses can still build concurrently. Far-region capture, assembly and
publication remain per player. This is a foundation for sharing, not the
large general splitscreen saving originally hoped for.

The first Medium disabled control sampled 25.30 ms of summed main-thread
work across players, including 15.13 ms in LOD and 5.26 ms in terrain
polling. These one-second observations are diagnostic, not a complete CPU
profile. They point towards the remaining per-view region work.

Rare stalls persisted in enabled and disabled runs. Streaming maxima were
508, 509 and 193 ms for Low, and 102, 108 and 549 ms for Medium. The cache
comparison does not establish their cause or repair them.

### Lamp visibility in the night fixture

The Low night fixture uses 32 active lamps per player and no shadow maps.
Occlusion is bracketed by disabled controls. Values are median / p99 frame
time, followed by the summed viewport GPU diagnostic, all in milliseconds.

| Players | Off before | On | Off after | GPU off / on / off |
| --- | ---: | ---: | ---: | ---: |
| 1 | 2.57 / 3.49 | 3.28 / 4.46 | 2.65 / 3.47 | 2.23 / 3.19 / 2.37 |
| 4 | 10.31 / 15.70 | 9.78 / 13.45 | 9.75 / 13.66 | 6.73 / 8.09 / 6.67 |

Single-player frame time increases by about 24-28%. Four-player frame time
is within the control range, but its GPU diagnostic rises by about 20-21%.
This is not a free fallback. Static grid refresh averaged roughly 0.05 ms
in the single-player samples; that does not price rebuilding a moving grid.
The feature remains experimental and off in every preset.

The clean [closed wall without occlusion](wall-clean-off.png),
[closed wall with occlusion](wall-clean-on.png) and
[open wall](wall-clean-open.png) document the permanent correctness check.
All four players received every edit, and all five states settled. The
worker reset interrupted six building regions, changed the worker count,
restored it and drained. These runs logged no client errors. Small residual
visual gaps remain visible; this test does not certify every terrain edge.

### Cloud sampling

Low uses 16 view samples and three sun samples for its fluffy block clouds.
The candidate uses 12 and two. The first sweep let cloud position advance,
so its changing screen coverage makes it diagnostic only. The final sweep
holds the sky shader offset at `(0, 0)` for each variant, retaining ordinary
game updates. Its scene controls record the override. A control request can
read the game's temporary offset before the recorder applies the override;
that intermediate value is not the offset used for the rendered frame.

Values are median / p99 frame time, followed by the summed viewport GPU
diagnostic, in milliseconds.

| Players | 16/3 before | 12/2 | 16/3 after | GPU before / candidate / after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 2.08 / 2.73 | 2.09 / 2.75 | 2.12 / 5.22 | 1.71 / 1.60 / 1.71 |
| 4 | 9.28 / 12.44 | 9.29 / 13.59 | 9.36 / 13.00 | 5.83 / 5.36 / 5.86 |

The candidate reduces the GPU diagnostic by about 7% for one player and 8%
for four, but median frame times remain within the controls. The restored
single-player control has a noisier tail; it does not establish a p99 win.
The [16/3 image](cloud-16-3.png) and [12/2 image](cloud-12-2.png) retain the
same rounded silhouette, with subtle shading differences. Static images do
not establish equal quality during movement or inside clouds.

Keep Low at 16/3 for now. The 12/2 option remains available for a GPU-limited
machine to evaluate, without changing the cloud style. There is no measured
whole-frame improvement here that warrants spending its visual margin.

## Decisions and remaining limits

Keep the five preset budgets unchanged. The new baseline does not provide
clear shared-terrain headroom to raise view distances. Keep lamp occlusion
off by default, and retain Low's approved cloud sampling. These are tuning
decisions from this desktop cycle, not completed hardware calibration.

The next substantial terrain optimisation should address duplicated region
capture, assembly and publication, while retaining per-connection knowledge
and per-view materials. Near cache misses still duplicate work; persisted
carves conservatively bypass near sharing for the whole connection. Rare
long stalls and small visual gaps remain open findings.

Lowest and Low remain candidates for four-player and single-player Steam
Deck use respectively. Medium and High retain their provisional laptop and
desktop roles. Validate their 33.3 ms or chosen frame budgets on the actual
machines, including motion and adverse scenes, before promising them. This
cycle provides no automatic per-machine recommendation and no evidence
that memory capacity is the limiting factor.

[controls.csv](controls.csv) contains all 31 follow-up rows, including the
six diagnostic moving-cloud rows. The [raw archive](controls-raw.tar.gz)
retains their logs, frames, samples, settings, screenshots and correctness
checks, plus the native, profile and real-server validation logs. The
control-source manifest identifies the binary and frozen recorder versions.
Source and prose pass the style and whitespace checks; historical raw log
and patch snapshots retain their original whitespace.
