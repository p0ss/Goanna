<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Streaming optimisation, 2026-09-27

Four-player streaming rose from 52.4-53.2 to 72.6-73.3 FPS in two runs per
build. Frame p99 fell from 55.9-57.7 to 31.7-31.8 ms. Both optimised runs
finished draining terrain work after movement stopped.

This is a first pass at main-thread terrain work: account for mesh-input
capture in the poll budget, limit time between finished region uploads, and
reduce packed-array access overhead. It does not share terrain between
players. Shared terrain processing remains a separate change that needs
comparisons with overlapping player views.

## What changed

`poll_blocks` previously counted only completed meshes against its work
limits. Capturing and submitting a mesh job to a worker then continued the
loop without increasing that count. A burst of incoming blocks could
therefore capture the whole burst while no finished mesh had yet been
published. The loop now counts attempted blocks, so worker submission also
consumes the count and time budget.

Finished near batches and LOD regions previously had a four-region count
limit but no time limit between uploads. Publication now also stops after
its time slice. It has a separate slice of the same size as the per-player
poll budget, so busy input capture cannot indefinitely prevent completed
geometry from reaching the screen.

Tangent generation and LOD array conversion now resolve packed-array
pointers once per array instead of crossing the GDExtension boundary for
each element. Vertex values, triangle order and tangent calculations are
unchanged. The three changes were measured together; this experiment does
not assign a separate saving to each.

These remain soft limits. One capture or upload can exceed its slice, and
near/LOD scheduling has additional work. There is no claim that all terrain
work fits inside the configured poll budget. Keeping old meshes until their
replacements publish still applies.

The [patch](optimisation.patch) isolates this turn's native changes from
other work already present in the checkout.

## Measured results

Godot 4.5.1 Forward+, Luanti 5.17.0 and Mineclonia on the RTX 3090 desktop.
Low profile, 1920x1080 total composition, four 960x540 views. Each player
has one mesh worker and a 1 ms poll budget. Settings match across all four
trials. Each trial starts a fresh client and disposable server/world copy;
the after trials use the before trials' frozen source-world snapshot.

Each trial records about 15.35 seconds stationary, then about 15.35 seconds
moving radially at 8 nodes/second from a radius of 192 nodes. Actual recorded
travel is 122.8-123.3 nodes. This is longer than the earlier three-second
feature check; compare the before and after rows here, not that check's
85 FPS against these results. All starts reported settled terrain.

| Build | Trial | Phase | Frames | Mean FPS | Frame median ms | Frame p99 ms | Frame max ms | Renderer CPU median ms | GPU median ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| before | 1 | apart | 1902 | 123.7 | 7.82 | 11.88 | 32.69 | 1.75 | 5.54 |
| before | 1 | streaming | 820 | 53.2 | 16.63 | 57.67 | 75.18 | 2.51 | 5.95 |
| before | 2 | apart | 1889 | 123.1 | 7.96 | 10.21 | 40.22 | 1.73 | 5.45 |
| before | 2 | streaming | 805 | 52.4 | 16.75 | 55.94 | 78.14 | 2.53 | 5.49 |
| after | 1 | apart | 1983 | 129.2 | 7.61 | 10.91 | 24.45 | 1.66 | 5.19 |
| after | 1 | streaming | 1126 | 73.3 | 12.73 | 31.81 | 38.61 | 2.11 | 5.34 |
| after | 2 | apart | 1982 | 129.0 | 7.63 | 9.65 | 27.53 | 1.66 | 5.20 |
| after | 2 | streaming | 1115 | 72.6 | 13.13 | 31.69 | 42.03 | 2.08 | 5.38 |

Mean streaming throughput increased about 38%. The p99 reduction was about
44%, and the worst frames fell from 75-78 to 39-42 ms. These are repeatable
results across these two runs per build, not confidence bounds for other
machines or routes.

Stationary throughput also shifted from about 123 to 129 FPS, a 4.6% change,
with lower GPU timings. The experiment does not isolate the cause of that
shift. It is smaller than the streaming gain, but prevents attributing the
whole throughput difference precisely to the code change. The matching
reductions in main-thread stage spikes below give more specific evidence.

Renderer CPU and summed active-view GPU timers are diagnostic readings,
not exclusive parts of the frame interval. The report does not use the raw
summary's heuristic bottleneck labels to establish a CPU/GPU diagnosis.

## Per-player streaming spikes

These are the largest captured interval maxima across the two streaming
runs for each build, in milliseconds. The recorder samples about once a
second. Different maxima can occur on different frames; do not sum them.
The final fraction of a sampling interval may be absent.

| Player | Poll max before / after ms | LOD max before / after ms | Prune max before / after ms |
| --- | --- | --- | --- |
| 1 | 35.33 / 7.90 | 41.15 / 18.08 | 0.88 / 0.76 |
| 2 | 33.04 / 5.78 | 25.20 / 12.01 | 0.53 / 0.39 |
| 3 | 28.58 / 5.10 | 24.69 / 10.89 | 0.53 / 0.52 |
| 4 | 26.57 / 4.06 | 12.59 / 5.93 | 0.35 / 0.43 |

Polling spikes decreased substantially. Region publication and other LOD
work still have larger indivisible operations, so they remain a target for
moving more preparation off the main thread or splitting uploads. The
results do not measure the possible gain from sharing identical terrain
between players.

## Completion, visual checks and limitations

`--check-stream-drain` stops movement after the recording and requires the
terrain queues to settle. This wait cannot improve the measured FPS.
Both optimised runs passed in 17.2 and 13.1 seconds, including the required
ten-second quiet window. The saved snapshots also have zero pending blocks,
ready near meshes and storage work. The final harness now includes
those counters in the continuous quiet-window check, with regression tests
for stalled work on the second player.

The [before](before.png) and [after](after.png) images are live four-view
captures from the first trial of each build. Inspection found no obvious
new terrain holes. They are not pixel-equivalence checks: server entities,
cloud animation, streaming progress and the small endpoint offset differ.
Queue drainage establishes completion, not unchanged pop-in latency during
motion. The baseline runs did not record endpoint drain time, so there is
no before/after claim for that latency.

Only this four-player route and profile were measured. There was no
per-feature ablation of the optimisation, single-player scaling run or
long-session memory-pressure test. No graphics-quality setting was lowered.

Sampled peak client RSS was 7.01 and 7.18 GiB before, and 7.06 and 6.98 GiB
after. Sampled median streaming draw calls were 1,494-1,497 before and
1,482-1,507 after. These sparse counters do not measure true memory peaks
or prove identical visible coverage, but the frame-time gain did not require
a substantial reduction in resident memory or draw calls.

## Evidence and checks

- [Measurements CSV](measurements.csv): all eight recordings, unrounded
  timings, durations, distances, sampled draw calls and client RSS.
- [Raw data](raw-data.tar.gz): frame CSVs, per-player samples, hardware
  samples, effective settings, plans, completion snapshots and logs.
- [Source metadata](source-metadata.json): before and after binary/source
  hashes, working-tree status and the harness diagnostic change.
- Native build passed. Rebuilt mesh-pool, LOD and LOD-storage tests passed.
- `python3 tools/bench/test-local-bench.py` passed all three tests, including
  checks for each pending queue and the post-drain quiet window.
- All four rendered clients passed script, shader and shutdown log checks.
- `tools/check-style.sh`, `git diff --check` and Python compilation passed.

All owned clients, servers and headless compositors stopped successfully.
The final GPU availability check was clear.
