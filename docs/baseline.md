# Rendering baseline

The baseline is the control condition for renderer work. It answers one
question: does a change improve the world without making the client slower,
less contiguous or less stable?

For a frame cost question with a number at the end of it, use
[benchmark.md](benchmark.md) instead: it automates the discipline below, and
records every frame rather than one telemetry line a second, which is what a
1% low or a hitch count needs. This page remains the description of the
control condition, and the far rendering suite below is still the tool for
contiguity and residency over a long soak.

## Control condition

Use the same build, resolution, world, player position and camera path for
both sides of a comparison. Record the GPU, driver, CPU, display resolution,
game/server, view distance and whether a local server is generating terrain.
Do not compare a settled scene with one still streaming.

For a low-variance geometry baseline, run with authored material effects and
expensive atmosphere features disabled:

```sh
GOANNA_PERF=1 GOANNA_NO_SDFGI=1 GOANNA_NO_SSAO=1 GOANNA_NO_SSIL=1 \
GOANNA_ATMOSPHERE=0 GOANNA_NO_LIGHTS=1 \
/path/to/Godot --path project
```

The baseline is not the shipping look. It isolates geometry, streaming,
meshing, batching and visibility. Re-enable one visual system at a time when
measuring its cost.

## Recommended fixture: TDL showcase

For far-rendering work, use the bundled Terrain Diffusion showcase world
rather than a newly generated world. It has a fixed 1 m bake, persistent tile
coverage, and a spawn chosen to include coast, forest, swamp, desert and
badlands. This separates renderer behaviour from server generation speed and
means flying beyond the live mapblock radius still tests the far provider.

Keep the same build and cached tile archive between runs. Anchor routes to the
server-reported player spawn; the bake records the intended showcase location,
while its world coordinates are deliberately local to each generated world.
If the archive is absent, download the version named by
`LocalServer.DEFAULT_TERRAIN_ID` rather than substituting another bake.

Do not treat the first view as a result. Record one sample while the fixture is
streaming, then another after the queue has been idle for at least 30 seconds.
If the queue never settles, that is a streaming failure to report, not warm-up
to hide.

## Required captures

Run each view for at least 60 seconds after the initial scene has arrived, and
save the one-second `GOANNA_PERF` lines. Capture an open landscape, dense
vegetation, an enclosed cave, a coastline with a visible seabed, and a
near/far transition while moving toward and away from a landmark.

The automated TDL run photographs four compass horizons from a fixed aerial
position above the authoritative spawn. Hold each stationary for 60 seconds,
then leave the client stationary for ten minutes to expose unbounded queues,
resident-block growth or repeated LOD rebuilding. Add a manual enclosed-cave
capture for occlusion work, and capture the same positions with far rendering
disabled when a near-field control is required.

Report median and worst frame time, draw calls, objects, triangles, GPU time,
CPU render time, mesh/LOD time, queue depth, resident blocks and video memory.
Note any gap, flash, duplicate surface, or detail level that fails to arrive.

## Acceptance gates

- No visible hole or transparent slice in a settled landscape.
- A LOD replacement never removes the old mesh before the replacement is ready.
- Queue depth returns toward zero while the camera is stationary.
- Resident blocks, mesh memory and video memory remain bounded over ten minutes.
- Worst frame time does not increase by more than 10% in the cave or open
  control scene unless the visual improvement is intentional and documented.
- PBR, atmosphere and shader-pack changes are reported separately.

The in-game overlay is useful for a quick check; the one-second telemetry is
the authoritative record. See [control-channel.md](control-channel.md) for
fixed-position captures and [building.md](building.md) for test variables.

## Running the automated suite

Start the TDL showcase with a control channel, enable the geometry baseline
environment shown above, and wait until the player has reached the intended
surface spawn. Then run:

```sh
tools/far-baseline.py /tmp/goanna-far-baseline --port 30800 \
    --build-label "$(git rev-parse --short HEAD)"
```

The suite anchors itself to the server-reported player position, photographs
four compass horizons, samples each for 60 seconds and finishes with a
ten-minute stationary soak. `samples.jsonl` is the raw one-second record;
`summary.json` contains median, p95, maximum and final values. A view that does
not reach 30 continuous seconds with empty work queues within ten minutes is
recorded as unsettled rather than silently sampled as if it were complete.
