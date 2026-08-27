# Rendering baseline

The baseline is the control condition for renderer work. It answers one
question: does a change improve the world without making the client slower,
less contiguous or less stable?

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

## Required captures

Run each view for at least 60 seconds after the initial scene has arrived, and
save the one-second `GOANNA_PERF` lines. Capture an open landscape, dense
vegetation, an enclosed cave, a coastline with a visible seabed, and a
near/far transition while moving toward and away from a landmark.

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
