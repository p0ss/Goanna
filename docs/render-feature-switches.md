<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->
# Render feature switches

Nineteen independent switches from the [inventory][inventory] are
implemented in the working tree. They default to on, preserve existing
strength settings, persist in `goanna.cfg`, and appear in Advanced lighting
settings. The [five graphics tiers](graphics-tiers.md) now set these gates
explicitly and add cloud styles, lamp shadow budgets and grass budgets.

| Setting key | Work disabled |
| --- | --- |
| `render_sky_clouds` | Selected cloud renderer in both visible sky and cubemap paths |
| `render_cloud_shadows` | Terrain cloud-shadow noise, through its existing early-out |
| `render_atmosphere` | Environment volumetric fog, local fog volume and local cloud-density sampling, including underwater |
| `render_ssao` | Environment SSAO pass |
| `render_bloom` | Environment glow pass |
| `render_shafts` | Screen-space shaft quad draw |
| `render_sun_shadows` | Both sun and moon shadow casting |
| `render_underwater_volume` | Underwater volumetric fog, retaining ordinary water murk |
| `render_dynamic_lights` | Node-light selection, ranking and the entire direct-light pool; nearby terrain uses propagated block light |
| `render_carried_light` | The camera's carried-light node and its update |
| `render_water_waves` | Procedural water wave normals |
| `render_water_reflections` | Screen-space reflection lookups and ray march; retains analytic sky reflection |
| `render_wet_surfaces` | Wet-film material branches, ground rain detail and water rain rings; retains falling precipitation |
| `render_foliage_wind` | Leaf and plant vertex wind; retains vegetation geometry and shadows |
| `render_grass_interaction` | CPU interactor collection and grass interaction shader loops |
| `render_grass_aa` | Automatic grass MSAA/FXAA promotion, restoring the previous viewport AA |
| `render_ice_detail` | Ice volume tracing, facets and detailed material evaluation; uses a simple textured surface |
| `render_ice_transmission` | Ice visibility queries and its extra background render viewport |
| `render_lava_detail` | Lava crust displacement, normal reconstruction and layered texture advection |

Sky clouds, terrain cloud shadows and local atmospheric volumes are
independent for measurement. Turning off sky clouds can therefore leave
local cloud fog or ground shadows. Named presets group their defaults.
Ordinary distance fog and underwater murk remain when volumetrics are off.
Setting atmosphere quality to zero now also disables underwater volumetrics;
bloom strength zero disables glow, and shaft strength zero hides its quad.
The shaft switch does not disable scattering inside the fog volume. The
ridge-ray shader strength reaches zero above sun elevation 0.35, so a noon
comparison cannot price those rays. Use the dusk scene and inspect the
reported shaft strength.

These switches isolate specific work, not complete replacement renderers.
Water still uses refraction and screen/depth buffers. Lava still has the
subdivided CPU mesh. Ice retains its allocated noise textures and viewport
when disabled. Grass has its existing `procedural_grass` geometry toggle;
`render_grass_aa` controls its automatic AA policy, not arbitrary AA chosen
elsewhere. The direct-light fallback uses the existing propagated light on
terrain; it is not a new high-quality night-lighting solution. Turning off
node lights leaves the carried light available as an independent choice.

Cloud noise is generated lazily when fluffy blocks or the full volume
style is first enabled. Plain blocks do not allocate it at startup. Once
generated it is retained for fast restoration. Other small scene resources
also remain allocated when their pass is disabled. These are work switches,
not a promise to return every associated byte to the allocator immediately.
An external shader pack's compositor is outside these switches.

State belongs to each player scene. Global quality controls such as shadow
atlas size still apply to the whole renderer. The local shell currently
directs players to shared settings outside play; the development control
channel can target an individual player's UI for diagnostic comparisons.

`main.set_render_feature(key, enabled)` rejects unknown keys.
`main.render_feature_state()` reports requested values and actual environment,
shader and scene gates without traversing terrain. Enabled gates do not
prove a measurable GPU cost: cloud coverage, camera direction, sun position
and geometry still matter. Inspect captures and relevant counters as well.

## Isolated multiplayer comparisons

The local harness now accepts `--profile`, `--phases` and `--feature-sweep`.
A feature sweep enables all feature switches for its initial control, disables
one at a time, restores the others, then repeats the fully enabled control.
Grass is explicitly off for profile comparisons. Each player count starts
with fresh configuration and a disposable world copy.

```sh
tools/goanna-headless gpu-free
python3 tools/bench-local-play.py \
  --world /path/to/test_world --game /path/to/mineclonia \
  --output /tmp/render-features \
  --players 1 4 --profile low --phases together \
  --feature-sweep render_sky_clouds render_cloud_shadows \
    render_atmosphere render_ssao render_bloom render_shafts \
    render_sun_shadows \
  --seconds 45 --warmup 5
```

Run with host GPU visibility, one GPU client at a time. The launcher owns
the headless display and cleanup. The harness records effective numeric
settings, AA, feature state and viewport sizes for every player, alongside
frame CSVs, terrain counters, hardware samples and composition screenshots.
Per-trial results are saved incrementally, so a later failure does not erase
completed variants. `--dummy` validates orchestration without GPU rendering.

Live feature sweeps reject streaming phases: consecutive variants would
otherwise measure different terrain. Streaming still requires separate
fresh trials with matched routes. Use the controls below for those trials.

The initial circle is at noon. It cannot establish the cost of dusk shafts,
underwater fog, night lamps or every cloud view. The initial run is a
screening experiment and rendered validation, not enough evidence to choose
all shipped preset values. Repeat controls and scene coverage before
claiming a small saving. See the [inventory's benchmark sequence][inventory].

The [initial one- and four-player screening run][screening] completed on
2026-09-27. Clouds and atmosphere reduced GPU work without a clear whole-frame
gain in that scene; the report includes raw data and the control drift.

## Controlled scene coverage

`tools/local-feature-scenes.json` defines camera height, target, radius,
fixed time of day and explicit setting overrides. Select one with `--scene`
and `--phases together`. The original `circle` also supports separated and
streaming phases. `dusk` uses the original terrain at a low sun angle and
turns each camera towards the sun. Other stationary cases retain the inward-facing circle.

The other scenes use `tools/local-feature-fixture.lua`, installed only in
the disposable Mineclonia world copy. The harness waits for the server's
fixture-ready marker before positioning players. It rejects inactive
underwater, rain, lamp, grass, ice-capture and dusk-shaft cases, and records
scene evidence before timing. Client errors and shutdown crashes fail the
trial even if recording completed. Source worlds are never
edited. Mineclonia weather is explicitly cleared after mods load, its
weather cycle is disabled, and dry scenes reject precipitation restored
from the source world. These fixtures use Mineclonia node names and reject
missing nodes.

| Scene | Coverage and independent comparisons |
| --- | --- |
| `underwater` | Enclosed pool with every camera submerged; underwater volume versus ordinary murk |
| `wet` | Stone and water, synthetic rain spawner, wetness held at 0.8; wet detail, water reflections and waves |
| `night` | Roofed torch room at midnight, players holding torches; node lights, carried light and lamp shadows |
| `foliage` | Close leaf clusters; vertex wind and directional shadows |
| `grass` | Close grass floor with procedural grass enabled; interactions, geometry and AA |
| `ice` | Ice walls around the circle; material detail and background capture |
| `magma` | Close lava pool; shader detail and node lights |

Wetness is deliberately frozen only by the development harness. This
removes the multi-minute drying ramp as a confounder; it is a synthetic
rain fixture, not a replay of a server storm. Ordinary play retains its
weather response.

The night baseline fixes both `light_pool` and `shadow_lamps` at 16.
Compare a fresh trial with `--settings '{"shadow_lamps":0}'` to remove
shadows while keeping the same direct-light count cap. Light admission is
now independent of shadow selection; check `active_lights` and
`shadow_lights` in each view. Older reports predate this separation.

The grass baseline turns automatic grass AA off and explicitly fixes 4x
MSAA plus FXAA. Compare `--settings '{"procedural_grass":0}'` in a fresh
trial to remove grass with AA held fixed. Compare `--msaa 0` or
`--screen-aa 0` separately to price AA with grass still present. These are
Godot viewport enum values, recorded with each player. A live sweep of the
automatic AA switch is rejected when the scene explicitly fixes AA.

Any numeric settings can be overridden with `--settings`; unknown keys
are rejected. Feature sweeps restore the scene's feature overrides between
variants. Other settings and geometry comparisons use fresh invocations,
so a previous variant cannot leave a different terrain cache behind.

For streaming, keep `--scene circle --phases apart streaming`. The default
route starts at radius 192 and moves radially outward at 8 nodes/second.
`--spread-radius` and `--travel-speed` expose those controls. Compare fresh
runs with identical routes and duration while changing just one of:

- `--settings '{"view_range":4}'`, or another existing distance setting.
- `--poll-budget-ms 6`: total main-thread terrain poll budget, divided
  equally among players. This is a soft budget; individual jobs can exceed it.
- `--mesh-workers 8`: total requested workers, divided among players with
  a minimum of one each. Inspect actual per-player thread counts; division
  rounds down and the minimum can exceed the requested total.

Use `--check-stream-drain` to stop at the route endpoint after recording and
require the terrain queues to settle. The harness writes the final player
counters and elapsed wait to `streaming-drain.json`, and fails on timeout.
The wait includes the ten-second quiet window and is outside the FPS sample.
This checks that a scheduling change has not left terrain work undrained.
The [first streaming optimisation report](perf/streaming-2026-09-27/report.md)
records matching four-player before/after runs and the completion checks.

The terrain poll counts worker-input capture attempts as work, including
attempts that do not publish a finished mesh. Finished region uploads have
a separate soft time slice of the same per-player size (6 ms by default),
plus the existing four-region count cap. These are separate slices, not a
hard total frame-time limit. Each permits progress on one indivisible item,
which can exceed its time slice.

The recorder includes per-player terrain counters and opt-in main-process
stage timings for sky, simulation, block polling, pruning, lights, motes,
LOD, entities, environment and wield updates. `work_usec` is the latest
frame; `work_worst_usec` is each stage's maximum since the previous sample.
The maxima are independent and must not be summed into a fictitious frame.
`main_total` contains those stages, not an additional cost. Native terrain
sub-timers are also nested. These readings do not include every scene node,
worker thread or render-thread task.

Renderer timing now includes active ice background views as well as the
player views and root composition. Disabled auxiliary views are skipped:
Godot otherwise reports their stale last-render timings. GPU and renderer
CPU sums are diagnostic totals, not exclusive portions of frame time. The
recorder's inherited `bound` label is a heuristic; it does not establish a
CPU, GPU or RAM bottleneck on its own.

Screenshots and state checks are required alongside timings. An enabled
material gate does not prove that its geometry is visible. Grass interaction
also needs actors close enough to bend it, and a carried light needs an
appropriate held item. A stationary empty-handed circle cannot price all
possible interactions.

The [expanded validation report](perf/feature-controls-2026-09-27/report.md)
records the scene controls and issues found while exercising them.

## Terrain sharing: the next architectural experiment

The source trace supports testing shared preparation before making RAM
savings the objective. `GoannaClient::nearSubmit` captures a block and its
neighbourhood for each session, builds its light field, then submits a
`NearBlockJob`. The result still has session-owned mesh/material references.
Each player later publishes its own Godot resources and regional batches.
The [local shell][shell] apportions worker/poll budgets but does not deduplicate
these jobs. Nearby players can repeat the same work.

The safest initial sharing boundary is immutable, validated inputs and
CPU geometry, not a merged live map. A prototype should proceed as follows:

1. Measure duplicate candidate inputs for nearby and separated players.
   Count eligible jobs and estimated saved capture, meshing and publication
   time. Record cache-key construction time too; hashing a neighbourhood
   must not become the new main-thread bottleneck.
2. Introduce a bounded cache of immutable prepared results, with one job in
   flight for identical inputs and independent subscribers. Each player
   supplies and validates its own received input before accepting a result.
3. Extract results from session-owned texture IDs and pointers into a stable
   geometry representation. Rebind materials for each renderer scope.
   Retain per-player publication and culling initially, so the first test
   isolates saved preparation/meshing from shared GPU buffers.
4. Only then test shared uploaded geometry. [Render scopes][render-scope]
   currently use player-specific shader names; sharing a material or a whole
   `World3D` indiscriminately would break that isolation. Instance state,
   occlusion, view-dependent LOD and interactive overlays remain per player.

A cache key needs world/server identity, compatible node definitions and
material interpretation, input contents and lighting, known/unknown masks,
the complete neighbour halo, mesher revision and geometry options. For LOD
it also needs the relevant membership/boundary and detail specification.
Coordinates or a session-local generation number alone are insufficient.
Content equality must be validated across sessions; a cache hit must never
fill in data that a recipient has not received or retained legitimately.

Dig cracks and changing carve state should initially bypass sharing.
Changes to neighbours and lighting invalidate affected inputs. A departing
subscriber must not cancel another player's job, and a late completion must
still pass that subscriber's generation check. Bound both completed entries
and in-flight work, keep ownership explicit, and evict only unused results.

Validate shared versus unshared on the same routes with one, two and four
players: overlapping circles, moving together, separated travel, boundary
edits, incompatible materials and a player leaving during a job. The main
success measures are reduced frame tails and terrain latency, with identical
coverage and appearance. Cache hits and reduced RAM are supporting evidence.
Separate players exploring different terrain may see little reuse; the
benchmark should reveal that rather than assume a universal multiplier.

No shared terrain cache is implemented by this change.

## Regression checks

`project/tests/render_features.gd` uses real player scenes with Godot's
dummy renderer and no server connection. Run it with a disposable
`XDG_DATA_HOME` and `XDG_CONFIG_HOME`, because it writes test settings:

```sh
feature_data=$(mktemp -d)
XDG_DATA_HOME="$feature_data/data" XDG_CONFIG_HOME="$feature_data/config" \
  godot --headless --path project --script res://tests/render_features.gd
```

It checks saved startup state, lazy cloud-resource creation, per-player
isolation, pass restoration without changing strength, unknown-key
rejection, persistence, and switching volumetrics while already underwater.
The existing local-play scene and menu regressions also passed. These
checks exercise state and ownership; the rendered sweep checks the GPU path.

[inventory]: performance-inventory.md
[shell]: ../project/local_play.gd
[render-scope]: ../src/goanna_render_scope.cpp
[screening]: perf/render-features-2026-09-27/report.md
