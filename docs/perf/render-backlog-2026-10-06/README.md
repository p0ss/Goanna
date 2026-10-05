# Render backlog through the render service, 2026-10-06

The first run of `tools/goanna-render` on the GPU, then a backlog of looks
nobody had seen. Only the first part ran: the GPU went to another session's
services for the rest of the window, and the backlog jobs are written but
not shot.

Setup: RTX 3090, Godot 4.5.1, Luanti 5.17.0 server, Mineclonia release
38561, profile High read back at every launch, adapter "NVIDIA GeForce RTX
3090", `mat_parallax` 1. The build was main's checkout as it stood (HEAD
dec70408, then 019bc7d1, each with `project/material_ramp.gd` and
`project/project.godot` dirty), the pack its `pbr_packs/mineclonia`.

## What broke on the GPU, and the fixes

- **Frames of sky.** The first wall job reported success and drew no
  wall and no floor. Every node lookup matched, but the client had 0 to 5
  blocks meshed for minutes. `main.teleport_to` streams blocks with the
  camera still at the old place and only then moves it; the stage's blocks
  arrived tiered against a camera 1200 nodes away at the parking place and
  were never meshed. Reproduced by hand: 0 blocks meshed for 12 s after a
  `tp`, 8 once the camera was posed there. The service now poses the camera
  at the target before each `tp`, and an arrival also needs a block
  meshed. The client's own `teleport_to` order is unchanged.
- **Every pose waited out its 60 s settle timeout.** The far field's
  storage queues (`lod_storage_*`) never stayed at zero, so the settle
  test rarely held for 3 s. The far field is no longer granted on the
  fixture world, which has nothing past the stage (`--far` grants it).
  Each sidecar now says whether its pose settled and how long it waited.
- The player started at the stage, so the stage was held from the client's
  start; it now starts at the parking place.

After the fixes the wall job took 71 s (was 182 s with sky), the zombie job
101 s (was 288 s).

## 1. Validation

![validation](validate-gpu.png)

- Stone brick and cobble wall, noon and dusk (time 0.74): both drawn, the
  pack's relief on bricks, mortar and floor visible. Dusk is only a little
  warmer and darker than noon at this time of day.
- Zombie statue, maps on and off: maps on shows relief on the floor and
  shaded skin; maps off is flat art on a flat floor. The maps off sidecar
  has `maps_off_verified` true and no entity material with a normal map;
  maps on has the zombie's skin built with `normal=true spec=true`. The
  statue floats half a node: an entity's position is the bottom of its
  collision box, so a statue on the floor wants y -0.5 (now in the docs).
- Timing, the wall filling the frame at 1280 by 720, six rounds of 600
  `force_draw` draws: 1.85 ms per draw median with parallax on (range over
  rounds 1.845 to 1.853, p95 1.95) and 1.66 ms with it off (1.655 to
  1.661, p95 1.74). The earlier run of this job, before the fixes, gave
  1.97 ms for both: it was timing sky.
- Restart cost: 20 to 21 s for the first launch, 22.5 to 26.5 s for a
  restart (maps off, then back on).

The sidecar's material counts read 0 on every frame: they count only the
client's per texture material map, which node arrays do not use. The
documentation now says so.

## Not run

Jobs for the rest are in
`~/.local/share/goanna-pbr-audit/render-backlog-2026-10-06/jobs/`
(`make_backlog.py` writes them): Nether and End portals afternoon and
night, the fire branch old against new with timing, worn armour, a
pickaxe, a minecart, a decorated pot, heads and a chiseled bookshelf, and
faces with `sculpt_crisp` against shipped. Their packs are built there
under `packs/`. None of them has been shot.
