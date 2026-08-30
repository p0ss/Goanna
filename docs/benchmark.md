# Benchmarking graphics settings

This is the harness that says what a setting costs. It exists so a graphics
profile can be built from measurements rather than from judgement, and so a
renderer change can be shown not to have made things worse.

[baseline.md](baseline.md) is the older, manual discipline for the same
question and its rules still hold. This is that discipline automated, with
per frame data instead of one telemetry line a second.

## What it measures

Four runs, in the order they are taken.

| Run | Question |
| --- | --- |
| `load` | How long from launching to a world you can stand in, and to one that has stopped arriving |
| `steady` | Settled, camera still: what a frame costs when nothing is streaming |
| `move_early` | Set off the moment the world is playable: does it hold together |
| `move_full` | From settled, how fast can you move before the world stops keeping up |

`load` and `move_early` each need their own process, because both measure a
world nobody has seen. `steady` and `move_full` share the settled one.

## Why per frame

`GOANNA_PERF=1` and `tools/far-baseline.py` both sample once a second and
read `Engine.get_frames_per_second()`, which is a smoothed average. A 1% low,
a frame time distribution and a hitch count cannot be recovered from it.

`project/bench.gd` records every frame into arrays sized once when a run
starts, so recording costs an index write and allocates nothing: elapsed
time, the frame period measured between consecutive `_process` calls, the
frame setup and viewport draw CPU time, the measured GPU time, the distance
travelled and which run it belongs to. `client.render_stats()` is never
called per frame. That call walks retained terrain, which is why the HUD
samples it four times a second; here it is on its own once a second clock,
written to `samples.jsonl` and correlated by elapsed time.

## Running one

The client needs a display, a server, and `project/bin` built.

```sh
tools/goanna-bench.py tools/bench_plans/graphics.json /tmp/bench-graphics
```

A plan names the scene and the variants. `tools/bench_plans/graphics.json`
moves one graphics setting at a time and measures the steady state.
`tools/bench_plans/profiles.json` and `tools/bench_plans/profiles-night.json`
measure the shipped profiles themselves, and between them they are one
answer in two halves. Both are steady state live sweeps: the first at the
vista by day, where the tiers differ on how much world is drawn, the second
in the village after dark, where they differ on how many lamps cast shadows.
Neither is complete on its own, because a scene that cannot exercise a
setting reports it as free.

**The variants in both are `project/graphics_profiles.gd` key for key, and
nothing enforces it.** A tier value therefore lives in three files, and
changing it in one is a silent failure: on 2026-08-30 three settings were
added to the profiles and not to the plans, and the sweep ran for
twenty-five minutes and reported the old tiers under the new names, with a
healthy noise floor and nothing anywhere to say the numbers were of
something else. If a report disagrees with a measurement you took by hand,
diff the plan's `set` blocks against `PROFILES` before believing either.
Generating the variants from `graphics_profiles.gd` would end this class of
mistake and is worth doing.

The report is printed and written to `report.md` in the output directory,
with `frames.csv`, `samples.jsonl` and `summary.json` beside each run.

Useful flags: `--only <name>` to run one variant, `--no-repeat` to skip the
control repeat and with it the noise floor, `--port` when another client is
already using the control channel, `--keep-profiles` to keep each run's
scratch settings directory.

## What makes a run comparable

Everything below is enforced by the harness rather than left to whoever runs
it. They are listed because a plan that changes one of them changes what the
numbers mean.

**Vsync off and the frame cap lifted.** With vsync on, every measurement
reads as the refresh rate and says nothing about headroom. `bench.gd` does
this in `_ready`, the same as `main.gd` does under `GOANNA_PERF`.

**A fresh profile per process.** Each run gets its own `XDG_DATA_HOME`, so
Godot puts `user://` under it: no stored settings, a cold terrain store, and
nothing of the player's own touched. The variant's settings are written into
that profile's `goanna.cfg` before launch, because a setting applied after
connecting would not be the one the load was measured under. To measure a
returning player instead of a first visit, point `GOANNA_STORE` at a shared
warm directory through the plan's `env`.

**Time of day and weather pinned.** Over a sixty second sample the sun moves,
and a storm arriving halfway through changes the lamp count, the wetness and
the cloud cover.

**Movement on the wall clock.** A route advances by elapsed seconds, not per
frame. A setting that halves the frame rate would otherwise cover half the
ground in the same wall clock, and the two runs would no longer be the same
traversal.

**Nothing sampled while the world is still arriving.** The camera is parked
on the anchor, the work queues are waited out, and a pad is left beyond that
for a shader recompile or a mesh upload to land. This is not optional and
not only for the settings that re-mesh: a pose change alone restarts block
streaming, re-sorts the light pool and rebuilds LOD. The first smoke run of
this harness measured that instead of the setting, and reported a whole
second of 30ms frames with the GPU at 4.6ms and the renderer CPU at 4.8ms.

**Settings restored between variants in a live sweep.** Anything a variant
moved goes back to the value the client started with, which the control
channel records before the first command lands. Not to the plan's own base,
which is usually empty: the control condition includes the hardware defaults
in `main.gd`, and only the client knows what those came out as.

## Reading the report

```
| variant | median | 1% low | 0.1% low | low/med | hitch/min | gpu | cpu | bound | fps | vs control |
```

Frame times in milliseconds.

**The 1% low is the mean of the slowest one frame in a hundred**, not the
99th percentile. Goanna prunes blocks every two seconds and the spike that
costs sits right where a p99 falls, so the percentile moves by half its
value depending on how many spikes a sample happened to catch. Measured on
one machine over two runs of the same settings, the p99 differed by 51% and
the tail mean by 0.3%.

**low/med** is the stability ratio, how much worse the bad frames are than
the ordinary ones. It is dimensionless, so it can be compared between
machines and between settings in a way a standard deviation cannot.

**hitch/min** counts frames longer than twice the median and at least 8ms
longer than it. Both halves are needed: without the floor a 400fps run
counts every 6ms frame as a stutter, without the ratio a 30fps run counts
nothing at all.

**bound** is what the frame was waiting on, from the per frame maximum of
measured GPU time against renderer CPU time. Where neither fills most of the
frame the cost is on the main thread, which is where meshing, LOD and block
upload land. This is the column to read first: it decides which settings can
possibly matter.

## The noise floor

Every plan runs its first variant again at the end, and the difference
between those two runs is printed above the table. A result smaller than it
is marked "under noise" rather than reported as a change.

This costs one variant's time and it removes the need to argue about
significance. It also catches a harness fault that no amount of statistics
would: if the two control runs disagree, something is leaking between
variants, and that is worth knowing before any of the other rows are
believed.

It has already earned that. The profiles plan was first written to run all
four tests with a process per variant against a shared warm store, and the
control repeat came back 45.7 per cent from the first control on the steady
median and 84.6 per cent on the moving one, with the tiers settling in 135,
19, 28 and 107 seconds in the order they happened to run. The store fills as
the plan runs, so each variant started from a fuller world than the one
before it and the plan was measuring its own ordering. Every tier result in
that report was under its own noise floor. Rerun as a live sweep, on one
process and one block set, the same comparison came back with an 8.4 per
cent floor and tiers cleanly separated.

The lesson generalises: **a shared warm store and a process per variant do
not mix.** Either give every run an identical pre-warmed store, which this
harness cannot yet do, or measure steady state as a live sweep. A cold store
per process is the third option and it is honest, but at an open vista it
does not converge: 400,000 blocks over twenty minutes, never settling.

## Writing a plan

```json
{
  "label": "what this plan is for",
  "host": "127.0.0.1", "port": 30000, "name": "bench",
  "resolution": [1920, 1080],
  "tests": ["steady"],
  "seconds": 45, "warmup_seconds": 60,
  "settle_quiet": 20, "settle_pad": 3, "settle_timeout": 900,
  "time_of_day": 0.78, "weather": "rain",
  "anchor": {"offset": [0, 2, 0]},
  "actors": [{"name": "mobs_mc:sheep", "at": [10, 1, 10], "count": 6}],
  "route": {"mode": "fly", "relative": true, "loop": true,
            "points": [[0, 8, 0], [128, 8, 0], [128, 8, 128], [0, 8, 128]]},
  "sweep": [4.317, 10, 20, 40, 80],
  "base": {},
  "variants": [{"name": "control"},
               {"name": "no-bounced-light", "set": {"light_sdfgi": 0}}]
}
```

`anchor` is an offset from the server reported player position by default, so
a plan is not tied to one world's coordinates. Give it `"at": [x, y, z]` to
pin it. `base` is applied to every variant, the control condition on top of
the client's own defaults. Every key in `set` is a settings panel key; the
`settings` control command lists them.

A steady state only plan with no `texture_pack` in it runs as a **live
sweep**: one process, every variant switched over the channel. That is the
better measurement, not merely the faster one. Two processes stream their
blocks in a different order and settle to a slightly different scene, so a
small difference between them is partly the streaming. Switched live, the
geometry, the block set and the light pool are identical and the setting is
the only thing that moved. `--no-live` forces a process each.

Route mode `walk` goes through the real player physics instead of moving the
camera, which is truer but needs walkable ground the whole way; `fly` at
walking speed makes the same streaming demand and repeats exactly.

## Driving it by hand

The recorder is reachable from the control channel when the client is
launched with `GOANNA_BENCH=1`:

```sh
tools/goanna-control bench start label=my-change
tools/goanna-control bench stop dir=/tmp/run
tools/goanna-control route mode=fly speed=8 points='[[0,70,0],[128,70,0]]'
tools/goanna-control bench stamps
```

`bench stop` returns the same summary it writes to `summary.json`, so a
single question does not need a plan or the Python driver.
