<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Performance inventory

Source audit of the working tree on 2026-09-27, including the experimental
local multiplayer implementation. This is an inventory and experiment
design, not a new benchmark result. At audit time, the proposed controls
and Lowest were not implemented. RAM is a capacity check here, not the first
optimisation target.

Follow-up: nineteen independent work controls, controlled feature scenes
and per-player terrain timing are now implemented in the working tree. See
[render feature switches](../render-feature-switches.md) for their exact scope,
validation and the proposed terrain-sharing experiment. The tables below
describe the audited baseline before those switches were added.

The main distinction is between work per player, work per visible pixel,
and work when new world data arrives. A smaller viewport reduces only some
of those costs. Current Low leaves substantial rendering features enabled;
setting an effect's strength to zero does not always remove its work.

## Evidence and estimates

- **Measured now:** the [local multiplayer report][local-report], Low at
  1920 by 1080 on an RTX 3090 and Ryzen 7 7800X3D, Godot 4.5.1 Forward+,
  Luanti 5.17.0 and Mineclonia release 38561. These are whole workloads,
  not isolated feature measurements.
- **Historical:** the measurements recorded in [graphics profiles][profiles]
  and the [grass report][grass-report]. Different scenes and revisions;
  useful leads, not predictions for current multiplayer.
- **Estimated:** source-based expectations below. High means a candidate
  for a substantial frame or hitch cost in a suitable scene; moderate means
  worth isolating; low means likely inexpensive relative to the larger
  systems. These labels are priorities, not measured milliseconds.

The Low run averaged 80.3 FPS with four players facing each other and
34.2 FPS while all four streamed terrain. Six players averaged 50.8 and
22.1 FPS respectively. Four-player streaming had a 27.01 ms median frame,
3.07 ms measured renderer CPU time and 6.08 ms summed viewport GPU time.
Those timers suggest investigating work outside rendering, but do not
identify the cause or partition the frame into exclusive CPU/GPU slices.

Peak client RSS was 7.45 GiB for four and 10.27 GiB for six. Whole-GPU memory
stayed below 4 GiB, including the desktop. No memory-pressure diagnosis was
collected. Allocated RAM alone does not establish a RAM bottleneck.

## What the profiles actually change

Values are from [graphics_profiles.gd][profiles]. View range and LOD
distance are in mapblocks; far distance is in nodes. LOD distance controls
terrain detail, not pixel quality.

| Setting | Low | Medium | High | Ultra |
| --- | ---: | ---: | ---: | ---: |
| `view_range` | 6 | 8 | 12 | 16 |
| `lod_distance` | 8 | 12 | 20 | 32 |
| `far_distance` | 128 | 256 | 1024 | Server grant |
| `light_pool` | 32 | 48 | 64 | 256 |
| `shadow_lamps` | 0 | 0 | 8 | 48 |
| `light_sdfgi` | 0 | 1.4 | 1.4 | 1.4 |
| `light_ssil` | 0 | 0 | 1.4 | 1.4 |
| `mat_parallax` | 0 | 1 | 1 | 1 |
| `mat_hair_shader` | 0 | 1 | 1 | 1 |
| `screen_space_detail` | 0 | 1 | 2 | 3 |
| `shadow_detail` | 0 | 1 | 1 | 2 |
| `terrain_occlusion` | On | On | On | On |
| `procedural_grass` | Off | Unchanged | Unchanged | Unchanged |

Screen detail 0, 1 and 2 use half-resolution SSAO/SSIL at increasing
quality; 3 uses full resolution. Directional shadow atlases are 2048,
4096 and 8192 for shadow detail 0, 1 and 2. Low still enables directional
shadows and SSAO. SSAO intensity zero leaves its enabled flag set.

Profiles are partial overlays. Unlisted settings retain existing values.
Switching Low to Ultra does not restore grass. Benchmarks must initialise
all settings from an explicit baseline, apply the profile, then record the
effective state. SSAO/SSIL quality and directional shadow atlas settings
are renderer-global, even though each player has its own environment.
Treat these as application-wide choices for local play.

Historical Ultra had 16 shadow lamps and a pool of 96; current Ultra has
48 and 256. Historical percentages do not describe current Ultra.

## How player count changes the cost

Let P be player count and A the total number of rendered screen pixels.
At fixed output resolution, splitting the screen keeps A roughly constant,
but adds view setup, culling, environments, shadow work and independent
world updates. Effects with fixed-size textures or volumes do not shrink
automatically with the viewport. Sky coverage and transparent overdraw can
also differ between views, so even pixel costs need matched scenes.

The current implementation has independent connections, worlds and client
resources. Nearby players can repeat receipt, preparation and rendering of
the same terrain. Distant players also put different regions under load on
the server. Some data could eventually be shared, but a shared world is
not permission to merge private session state or reveal unreceived data.

Actors add another dimension: P players each seeing the other P-1 players
can produce P(P-1) remote-player render instances. The inward-facing circle
therefore measures a different workload from everyone facing empty terrain.

The tables describe expected scaling, not a promise of linear growth.

## World data, geometry and CPU work

Source: [main loop][main], [native client][client], [mesh pool][mesh-pool],
[local play scheduler][local-play] and [entity renderer][entities].

| Feature or stage | Control and current behaviour | Estimated cost and scaling |
| --- | --- | --- |
| Network receipt, map decode and session stepping | One session per player; view range changes demand | High during arrival: session CPU, locks, bandwidth and retained RAM. Depends on data arrival, P and server load, not screen size. |
| Content preparation, texture decode and material creation | Initial media, packs and first use; not a graphics tier switch | High burst candidate: CPU, allocation and GPU upload. Separate startup/first-use costs from ongoing terrain streaming. |
| Mesh input capture and queue management | `poll_blocks`, session map lock, worker admission | High hitch candidate as queues grow; main CPU and lock wait. More worker threads do not remove capture or queue work. |
| Terrain meshing | `mesh_threads`, view/detail ranges, mesh complexity | High worker CPU during streaming; bevels and complex nodes increase work. Multiple per-player pools share the same CPU. |
| Near-region batching and mesh publication | `nearRebuild`, Godot arrays and resources | High main-thread/upload candidate. Finished worker output still needs publication; a growing ready queue distinguishes this from slow workers. |
| LOD selection, summaries and far-region rebuilds | `lod_distance`, `far_distance`, server grant, persistent store | High streaming candidate; moderate steady CPU/GPU. Depends on retained regions and travel. Distance is not proportional to cost. |
| Terrain occluder construction and swaps | `terrain_occlusion`, tied to mesh publication | Moderate arrival CPU; can save substantial rendering work. Keep enabled initially: historical disabling made frames slower. |
| Terrain draw submission and culling | Geometry/detail distance and regional batching | Moderate to high renderer CPU and GPU geometry per view. Fixed A does not fix draw calls or visible triangles. |
| Pruning, resource destruction and store I/O | Retention follows view range; periodic pruning | Moderate hitch candidate while travelling; CPU, allocation, disk and driver work. Lower retention can increase later reloads. |
| Physics, collision, pointing and interaction | Per local player, required for play | Moderate CPU candidate in complex terrain. Flight tests do not cover ordinary walking or combat. |
| Entity arrival, animation and synchronisation | `sync_entities`, server-visible actors; own-body preference | Moderate to high CPU/GPU in busy scenes; per-session actors and visible instances. First model/texture use may hitch. |
| Per-frame sky/environment updates and statistics | Shader uploads, dictionaries, `render_stats()` calls | Moderate CPU candidate. `render_stats()` walks retained terrain; `_update_environment_extras` calls it per frame. Measure before caching or narrowing these queries. |
| Light and mote selection | Per-frame `update_lights` and `update_motes` | Moderate CPU candidate as retained world and pools grow. Turning down light energy is not a selection-work switch. |

Local play currently divides a nominal 6 ms polling allowance among slots
and assigns worker counts from a shared allowance. That is not a hard
bound on all player work. Queue preparation, a non-preemptible operation,
minimum rebuild work and updates outside polling can exceed it. In
`poll_blocks`, content preparation and taking new blocks also precede the
main poll timer. Time the complete call as well as its existing stages.

Existing telemetry is useful: `poll_lock_ms`, `poll_queue_ms`,
`poll_blocks_ms`, `poll_near_ms`, `poll_lod_ms`, `poll_max_ms`,
`near_batch_worst_ms`, `occluder_worst_ms`, `mesh_queued`, `mesh_running`,
`mesh_ready`, `upload_ms` and LOD/store counters. Many timings are smoothed
or cover nested work; they must not be summed as exclusive frame slices.

## Lighting, sky and screen effects

Source: [environment setup and updates][main], [sky shader][sky],
[shaft shader][shafts] and [terrain shader helpers][node-common].

| Feature | Control and current Low state | Estimated cost and scaling |
| --- | --- | --- |
| SDFGI bounced light | `light_sdfgi = 0` truly disables it on Low | High GPU/resource candidate when enabled; per-world cascades and movement updates, not just visible pixels. |
| SSIL | `light_ssil = 0` truly disables it on Low/Medium | High GPU candidate, affected by pixels and quality plus per-view overhead. Historical off saved 15.9% in one vista. |
| SSAO | Enabled on Low at detail 0; `light_ssao` changes intensity | Moderate to high GPU candidate. Needs a true off control for Lowest; zero intensity alone is not an explicit pass disable. |
| Directional sun/moon shadows | Low reduces atlas to 2048; lights still have shadows enabled | Moderate to high GPU/geometry candidate per view and caster set. Needs an explicit shadow-off comparison, separate from atlas size. |
| Local lamp lights | Low pool 32, no lamp shadows | Moderate CPU and GPU; night villages exercise the pool. Selection, lit pixels and overlapping lamps matter. Preserve baked game light if extra lamps are disabled. |
| Local lamp shadows | Off on Low/Medium; 8 High, 48 Ultra | High GPU candidate at night, growing with views and lit geometry. Pool and shadow budget interact, so measure actual active lamps. |
| Sky volumetric clouds | Present on Low when cloud coverage permits; fixed shader march | High GPU candidate in sky-heavy views. Up to 24 view steps, 8 in the cubemap path, with four sun-density samples for self-shadowing. Independent of `atmosphere_quality`. |
| Sky radiance/cubemap work | Separate cubemap branch; updated sky parameters | Moderate to high GPU candidate per environment. Capture actual update frequency; do not assume only final screen pixels matter. |
| Local volumetric atmosphere | `atmosphere_quality`, untouched by profiles | High GPU/resource candidate: fog volume, cloud/mist density and noise. Distinct from visible sky clouds. |
| Underwater volumetrics | Underwater update enables volumetric fog even at atmosphere quality zero | Moderate to high scene-dependent GPU cost. Lowest needs a cheap murk fallback and a consistent true-off gate. |
| Terrain cloud shadows | World-space shader noise, not a named profile setting | Moderate fragment cost over exposed terrain. Strength has an early-out in the shader; expose a separate budget from cloud appearance. |
| Light shafts | Strength control; full-screen quad remains allocated/drawn | Moderate GPU candidate: up to 40 depth samples when active. Zero strength can skip the march but is not removal of the draw or depth dependency. |
| Bloom/glow | `bloom_strength`; environment glow remains enabled | Moderate GPU candidate. Add an explicit enable gate before claiming zero strength is a free baseline. |
| Ordinary fog, sky gradient, sun/moon discs and grading | Appearance controls; many remain in the existing passes | Low incremental estimate relative to volumetrics. Keep for readable depth and game atmosphere unless measurement shows otherwise. |
| Cloud and ice noise textures | Generated `NoiseTexture3D` resources in each scene | Startup CPU/resource cost, not streamed terrain. Avoid rebuilding per view where immutable sharing is valid. |

Historical measurements found half-resolution SSAO/SSIL worth 18.7% and
a 4096 rather than 8192 shadow atlas worth 5.8% in one single-player vista.
Those savings overlap and cannot be added. A test which turned many visual
strengths down together improved 7% against 9.9% control drift: that does
not establish either a saving or that the features are free.

## Materials, vegetation, water and other work

Source: [terrain material][nodes], [terrain helpers][node-common],
[water][water], [ice][ice], [ice capture][ice-capture], [grass][grass],
[weather][weather], [particles][particles], [wake][wake], [settings][ui]
and [audio][audio].

| Feature | Control and current behaviour | Estimated cost and scaling |
| --- | --- | --- |
| Base textures, baked node light and corner shading | Core material path | Low incremental steady estimate; texture preparation and mesh light sampling have arrival costs. Preserve visibility and game light semantics. |
| Authored PBR maps and parallax | Low sets `mat_parallax = 0`, a real branch; texture pack determines applicability | High close-up fragment candidate when authored height data is present. Normal/material maps also consume bandwidth and resources. A default-texture scene cannot establish pack cost. |
| Normal, AO, roughness, specular, emission and SSS strengths | Generally scale results in the existing material | Low expected saving from changing strength alone. This does not mean the underlying texture reads or shading are free. Audit shader variants for genuine removal. |
| Surface detail | `mat_detail` gates class-dependent treatment | Low to moderate fragment candidate; compare relevant soil, sand and stone. It is not interchangeable with PBR parallax. |
| Automatic bump generation | `auto_bump`; changes rebuild materials | Moderate preparation/resource candidate; steady cost depends on generated normal-map use. Separate rematerialisation from rendering. |
| Bevelled terrain | `bevel`, remeshing when changed | Moderate to high arrival CPU and added geometry; per retained/visible terrain, not viewport pixels alone. |
| Procedural grass | Low forces off; other tiers preserve preference | High GPU candidate in close views: analytic tracing and actor interaction. Also forces at least 4x MSAA plus FXAA. Measure grass and AA separately. |
| Ordinary game plants and foliage wind | Plant geometry remains when procedural grass is off | Moderate to high forest cost from geometry, alpha coverage and shadows; wind arithmetic is a smaller candidate. Keep gameplay plants visible. |
| Water waves, refraction and reflections | Dedicated shader; not controlled by current tiers | High water-heavy GPU candidate: procedural waves, screen/depth reads and up to 24 SSR steps with range/angle gates. Internal `waving` and `reflections` controls are not a complete player quality setting. |
| Frosted ice shading | `solid_ice` changes transmission behaviour | High close-up GPU candidate: 24-step volume shading remains even in solid mode. Needs a simpler material option. |
| Ice background capture | Runs when non-solid ice intersects the view | High scene-dependent renderer/GPU candidate: another world render at half width and height per player, with expensive environment effects disabled. `solid_ice` disables this capture, not all ice shading. |
| Lava | Dedicated shader and subdivided surface, outside profile controls | Moderate to high scene-dependent CPU/geometry/fragment candidate. Excluded from ordinary near-region batching; test a lava-heavy scene separately from water. |
| Glass and transparent terrain | Dedicated materials and sorted transparent geometry | Moderate overdraw/submission candidate with overlapping surfaces. Some transparent surfaces cannot use opaque regional batching. Preserve visibility when simplifying. |
| Dig cracks and carved geometry | Interactive updates and block invalidation | Moderate burst candidate during digging or simultaneous building; remeshing, added geometry and overlays. A stationary flight benchmark misses it. |
| Shader rain/snow and cover map | `shader_weather`; off restores game particle weather | Moderate CPU/GPU candidate during weather: cover queries, instances and overdraw. Switching it off is a backend comparison, not a weather-off test. |
| Wet surfaces, puddles and rain ripples | Driven by received weather and wetness | Moderate fragment candidate when wet; much is gated when dry. Clear-noon tests cannot price it. |
| Water wakes and actor interaction fields | Per-player updates and shader textures | Moderate CPU/upload/fragment candidate near moving actors and water. Test idle versus active, not just water present. |
| Motes and other particles | Mote strength; status-particle preference; game spawners | Low to moderate, potentially high under heavy spawners. Status-particle off preserves weather and dig particles. Retain essential feedback. |
| Animated tiles | Shader animation clock and frame lookup | Low steady incremental estimate; frame textures have preparation/storage costs. Keep required game animation. |
| HUD, names, inventory previews and menu blur | Per player; many elements conditional | Low in a plain scene, moderate with complex forms or previews. Benchmark gameplay and menus separately. |
| Audio | Per-session sources and mixing, outside graphics profiles | Usually lower priority CPU candidate; active sources scale with players. Measure in an active scene before adding quality policy. |
| Antialiasing, resolution and field of view | Viewport state, grass coupling, output layout | Potentially high GPU effect. FOV also changes geometry and sky coverage; record it, and vary resolution while holding FOV constant. |
| Telemetry and frame pacing | HUD counters, render timers, FPS cap and vsync | Instrumentation costs CPU; caps can hide a bottleneck. Use identical telemetry, uncapped measurement, then a capped comfort check. |

The grass report measured 17.25 ms viewport GPU time in an inside-grass
fixture at 1280 by 720, compared with 9.33 ms with interaction disabled.
That revision preceded later canopy changes, used 4x MSAA plus FXAA, and
was not a whole-client frame measurement. It demonstrates a relevant
stress case, not the current cost of enabling grass in every scene.

Likely inexpensive appearance choices include tint, exposure, saturation,
roughness multipliers, existing baked light and simple sky colours. Keep
them attractive unless a controlled test finds a cost. A shader multiplying
an already computed value by zero saves little; a feature gate which skips
texture reads, ray steps, a render pass or resource creation can save more.

## A proposed Lowest baseline

Lowest should mean the cheapest complete playable presentation. Establish
an experimental baseline before choosing the shipped preset. Preserve
terrain coverage, entities, game plants, HUD, interaction cues, baked game
lighting and appropriate underwater visibility. Removing these can produce
a fast but invalid comparison or reveal things a normal client cannot see.

Initial candidate, with every unmeasured choice recorded as such:

- Start with Low's distances and occlusion enabled. Separately test view
  range 4 and far distance 0; choose by terrain readiness and playability,
  not FPS alone. Do not disable LOD or occlusion merely because their
  names sound like extra work.
- Disable SDFGI, SSIL, SSAO, glow, shafts and volumetric fog through actual
  enable gates. Disable directional and local lamp shadows. Compare the
  extra dynamic light pool off against a small pool while retaining baked
  light and readable night scenes.
- Use a simple sky and cheap block clouds, with an off option for the
  diagnostic floor. Disable cloud-shadow noise separately. Replace
  volumetric underwater murk with ordinary fog rather than clear water.
- Disable procedural grass and optional AA. Use ordinary game foliage.
  Disable parallax, bevel and expensive material detail; test a simple
  material path which actually omits optional map sampling.
- Provide simple water and ice paths without SSR, volume tracing or the
  ice background viewport. Preserve surface boundaries and the intended
  ability to see through each material.
- Reduce cosmetic particle density with bounded budgets; preserve weather
  and status information using cheaper presentation where needed.

This needs implementation before benchmarking a preset named Lowest.
Today, setting all visible sliders to zero cannot produce it. Diagnostic
environment flags also need verification: for example, startup clears
`GOANNA_NO_PBR` unless `GOANNA_PBR_SET` is present. Record enabled passes and
resources, not just requested slider values. An off feature should skip
its update/draw work and avoid unnecessary resource creation where practical.

## Clouds as a style and a budget

The proposed visual progression makes sense, but style should be distinct
from the amount of work allowed. Block-shaped density inside the existing
24-step shader is not automatically a cheap block-cloud renderer.

| Proposed style | Starting implementation | Budget to expose |
| --- | --- | --- |
| Off | Sky gradient and celestial bodies only | Diagnostic floor; no cloud resources or draws |
| Blocky | Coarse cloud cells with exposed faces, simple lighting | Cell count, distance and infrequent shape updates; no volume march |
| Blocky fluffy | Same coarse silhouette with soft edge shading or a few bounded shell layers | Edge treatment and layer count; control transparent overdraw |
| Fluffy | Reduced-resolution volume rendering | Render scale, ray steps, sun samples and update rate |
| Majestic | Fuller volume detail and self-shadowing, optional local cloud fog | Higher measured budgets with independent atmosphere and shadow controls |

These are alternatives to prototype, not a guarantee of increasing cost:
too many translucent shells can be worse than a short volume march. Test
views from below, inside and above, with moving cameras and against terrain.
Avoid temporal trails and small-viewport edge artefacts when reducing rate
or resolution. The current shader has no such style ladder.

Use consistent world coordinates, cloud motion, coverage and received game
sky state across views. Share immutable noise/pattern resources where
appropriate. Camera-dependent visibility, history and parallax still belong
to each view. Cheap cloud shadows can be a separate projected approximation;
block clouds need not become expensive shadow-map casters. Players should
be able to prefer blocky art on a fast machine.

## Measurements needed to identify the limiting resource

| Suspected limit | Evidence to collect | Intervention which tests it |
| --- | --- | --- |
| Main CPU work | Complete main-loop phase timings, per-thread CPU, lock waits, queue ages and frame-correlated hitches | Hold pixels/effects fixed; vary streaming demand and bounded publication work. High one-core use matters even when total CPU use is low. |
| Mesh worker throughput | Queued/running/ready counts, job duration and age by stage | Controlled worker-count sweep. Growing queued work with busy workers differs from growing ready work waiting for the main thread. |
| GPU shading/fill | GPU pass timings, utilisation/clocks, stable geometry counts | Lower internal render resolution at fixed FOV and scene; disable individual real passes. Shadow/volume costs may not follow screen resolution. |
| GPU geometry/submission | Draw calls, primitives, renderer CPU and shadow timings | Reduce detail or caster counts with pixels held fixed. A resolution-insensitive frame is not automatically CPU-bound. |
| RAM capacity/pressure | Client and server RSS/PSS, available RAM, major faults, swap and memory pressure | Compare stalls with pressure events. Do not lower settings merely because RSS rises. |
| VRAM capacity or bandwidth | Device budget/usage, transfers and residency/eviction evidence where available | Compare texture/resource budgets, AA and render targets; distinguish allocation capacity from bandwidth. Integrated graphics shares system memory. |
| Disk/content I/O | Read/write volume, I/O wait and cold/warm cache state | Repeat the same route with a prepared cache, separate from fresh-world trials. |
| Server/network supply | Server step time, CPU, block arrival rate, network delay and terrain readiness | Compare prepared terrain with new terrain, nearby with separated players; record server costs outside client process stats. |

Keep raw per-frame timing and correlate events. Renderer CPU time excludes
much gameplay work. Summed viewport GPU timers are not an independent
wall-clock GPU critical path and may omit auxiliary views or share work.
The local recorder currently sums root/player view timers; audit the ice
capture and other auxiliary work before drawing resource conclusions.
Do not subtract GPU time from frame time and call the remainder CPU work.

For asynchronous timings, identify which rendered frame a sample belongs
to. Use GPU captures selectively to establish pass coverage and ordinary
recording for the repeatable timing runs. Include a recorder-off control
to quantify instrumentation overhead.

## Next benchmark sequence

First priorities are streaming stage attribution, true-off comparisons for
Low's retained cloud/atmosphere/screen effects, and current Ultra's night
lighting. Water, ice and grass need their own stress scenes. Treat the
per-frame statistics traversal as an early CPU investigation. Defer asset
deduplication for RAM savings until capacity measurements justify it, unless
sharing also removes demonstrated preparation or upload work.

1. Extend the local harness to select profiles and explicit baseline
   settings; it currently fixes Low. Export effective per-view settings,
   global renderer quality, AA, actual resolution, actual far grant and
   active effects. Run `tools/bench/check-bench-plans.py` before a profile
   sweep.
2. Run Low, Medium, High and current Ultra first at one and four players,
   fixed 1920 by 1080 total output. Keep grass explicitly off for this
   comparison, then measure it separately. Repeat Low controls throughout
   and vary trial order. This prices the shipped profiles before redesign.
3. Include the inward circle and separated views, then matched streaming
   routes. Retain the eight-node/second flight for comparison and add
   ordinary ground movement. Use identical initial world copies and client
   cache policy for streaming; distinguish fresh from revisited terrain.
4. Run targeted feature comparisons in scenes that exercise them: an open
   cloudy vista; a lamp-filled village at night; forest/grass close-ups;
   water and ice, including underwater; rain/snow; and an authored PBR pack.
   Use the same base profile for one-feature-at-a-time changes. Verify that
   the feature is active before pricing it and truly disabled afterwards.
5. Add two and six players to the profile matrix, and the most consequential
   feature comparisons. Include deliberate combinations such as grass/AA,
   clouds/atmosphere, lamps/shadows and distance/streaming budgets. Individual
   savings do not add, and changing one limit can expose another.
6. Implement the missing true-off gates and candidate Lowest, then run it
   through the same scenes. Compare both the full preset and its important
   ingredients. Check visual/gameplay correctness alongside performance.

Record median, p95/p99 frame time, slowest-1% mean, hitch counts, terrain
readiness, load time, resource telemetry and per-player work. Retain raw
data, source/build hashes, game/server versions and screenshots. Never count
missing terrain as an optimisation. Use repeated trials to establish noise
before promoting a small difference into a preset decision.

Measure two scaling questions separately: fixed total screen pixels for
normal couch play, then fixed pixels per player for an intentional GPU
stress test. Record viewport aspect ratios and visible geometry in both.

All render runs must follow the [test-client rules][agent-rules]: one GPU
client at a time, a GPU availability check, and headless gamescope. Do not
start simultaneous GPU clients to simulate the players; local play already
hosts their views in one process.

## Towards per-machine recommendations

Recommend for a target frame rate, output resolution and player count.
Keep three independent budgets: CPU world/streaming work, GPU rendering
quality, and memory capacity headroom. A single global tier can remain the
simple UI, but the recommended values need not all come from the same tier.

For example, a strong GPU with a main-thread streaming limit may keep nice
materials/clouds while reducing world demand or publication bursts. A weak
GPU with spare CPU may retain distance but use cheaper clouds, shadows and
screen effects. A memory-constrained machine needs smaller retention and
resource budgets, validated against reload hitches. These are hypotheses
to test, not diagnoses from adapter type alone.

The current hardware choice uses discrete-adapter status and CPU count.
Replace that heuristic only after representative calibration exists. A
short opt-in calibration should include settled rendering and movement,
choose against tail frame time and terrain readiness with headroom, and
retain user style preferences. Store its hardware/driver/build/context so
stale results can be recognised. This one desktop cannot validate a
general recommendation model; integrated and lower-power machines remain
essential follow-up tests.

[profiles]: ../../project/graphics_profiles.gd
[local-report]: ../perf/local-multiplayer-2026-09-27/report.md
[grass-report]: ../perf/procedural-grass-wind-2026-09-25.md
[main]: ../../project/main.gd
[client]: ../../src/goanna_client.cpp
[mesh-pool]: ../../src/goanna_mesh_pool.cpp
[local-play]: ../../project/local_play.gd
[entities]: ../../src/goanna_entities.cpp
[sky]: ../../project/shaders/sky.gdshader
[shafts]: ../../project/shaders/light_shafts.gdshader
[node-common]: ../../project/shaders/nodes_array_common.gdshaderinc
[nodes]: ../../project/shaders/nodes_array.gdshader
[water]: ../../project/shaders/water.gdshader
[ice]: ../../project/shaders/ice.gdshader
[ice-capture]: ../../project/ice_transmission.gd
[grass]: ../systems/procedural-grass.md
[weather]: ../../project/ui/weather.gd
[particles]: ../../project/ui/particles.gd
[wake]: ../../project/ui/wake.gd
[ui]: ../../project/ui/game_ui.gd
[audio]: ../../project/ui/audio.gd
[agent-rules]: ../agents/agent-interfaces.md#rules-for-test-clients

## Tier controls implemented after this inventory

The [graphics tier contract](../systems/graphics-tiers.md) supersedes the
baseline setting descriptions above. Lowest now exists. Plain block clouds avoid
the volume texture. Fluffy rounded blocks and full volumetric clouds use the
density texture; cloud lighting samples remain independent of style. Direct lamp
admission and shadow count/distance have separate budgets. Grass has density,
draw distance, interaction range/count and AA controls. Medium through Ultra
enable graded grass; Lowest and Low retain native plants. These changes need
fresh calibration, not reuse of the historical percentages in this inventory.
