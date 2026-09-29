# Graphics tiers

Goanna's lowest tier is the least expensive presentation that still earns
its place in this client. All five tiers use Forward+. An all-off render is
an experiment, not a shipping tier. Luanti clients can still join the same
server; supporting older Android hardware does not define this ladder.

These are candidate presets as of 2026-09-27. Their hardware roles express
intent, not measured compatibility. Desktop results cannot establish Deck
frame times by multiplying by a single GPU performance ratio.

## Tier contract

| Tier | Intended reference | Visual priority |
| --- | --- | --- |
| Lowest | Steam Deck-class hardware, four local players, 1280x800 total, 30 FPS | Readable nearby world, convincing materials and sky, reliable local lighting |
| Low | The same handheld, one player | Spend the released per-view budget on distance and atmosphere |
| Medium | Modest gaming laptop | More world, indirect light and authored surface depth |
| High | Midrange desktop | Long views, richer indirect lighting and nearby lamp shadows |
| Ultra | Powerful desktop with spare frame budget | Longest views, full sampling and broad lamp shadow coverage |

Thirty FPS gives 33.3 ms per frame. For the handheld multiplayer target,
use 25-27 ms as a provisional ordinary-frame budget so streaming has room.
This is a design allowance, not a measured result. Resolution, player count
and desired frame rate must accompany any future recommendation. Other
tiers do not promise a particular frame rate until calibrated.

Every tier must retain terrain silhouettes, readable interactable nodes,
night navigation, underwater visibility limits, transparent ice, moving
water, foliage movement, weather response and a recognisable clouded sky.
Sun shadows, material normals and material response remain available at
Lowest. Exposure, night visibility and appearance strength remain player
preferences. A screenshot alone cannot establish acceptable motion,
streaming, weather transitions or small split-screen readability.

## Current implementation

[graphics_profiles.gd](../project/graphics_profiles.gd) is the source of
truth. Every preset names the same controlled keys, including all 19
feature gates. Applying Ultra after Lowest restores its effects; applying
Lowest after an experiment restores its intended features. Quality edits
outside those values show Custom. Player preferences remain separate.
Renderer-wide screen-space quality and directional shadow atlas size still
apply to the whole process; local play
uses one shared preset. View-local feature gates and cloud materials can
be varied independently for controlled tests.

| Control | Lowest | Low | Medium | High | Ultra |
| --- | ---: | ---: | ---: | ---: | ---: |
| Near distance, 16-node blocks | 4 | 6 | 8 | 12 | 16 |
| LOD distance | 6 | 8 | 12 | 20 | 32 |
| Far cap, nodes | 96 | 128 | 256 | 1024 | Server grant |
| Cloud style | Block | Fluffy block | Volume | Volume | Volume |
| Cloud layers | 1 | 1 | 2 | 3 | 3 |
| Volume view samples | n/a | n/a | 24 | 24 | 24 |
| Volume sun samples | n/a | n/a | 3 | 4 | 4 |
| Volume cubemap samples | n/a | n/a | 8 | 8 | 8 |
| Volumetric atmosphere quality | Off | 0.35 | 0.65 | 1 | 1 |
| SSAO | Off | On | On | On | On |
| Light shafts | Off | On | On | On | On |
| SDFGI strength | Off | Off | 1.4 | 1.4 | 1.4 |
| Parallax | Off | Off | On | On | On |
| SSIL strength | Off | Off | Off | 1.4 | 1.4 |
| Screen-space detail | 0 | 0 | 1 | 2 | 3 |
| Directional shadow detail | 0 | 0 | 1 | 1 | 2 |
| Lamp pool | 24 | 32 | 48 | 64 | 256 |
| Lamp shadow budget | 0 | 0 | 0 | 8 | 48 |
| Lamp shadow distance, nodes | 16 | 24 | 32 | 48 | 64 |
| Procedural grass | Off | Off | On | On | On |
| Blade density, fraction of full | 0.2 | 0.3 | 0.4 | 0.7 | 1 |
| Grass distance, nodes | 12 | 20 | 32 | 48 | 80 |
| Bending distance, nodes | 0 | 4 | 6 | 10 | 16 |
| Bending actors | 0 | 1 | 2 | 4 | 8 |
| Grass AA when enabled | Existing | FXAA | 2x MSAA + FXAA | 2x MSAA + FXAA | 4x MSAA + FXAA |

Cloud layer count, style and lighting quality are independent controls.
The Advanced Lighting setting **Cloud layers** saves a count from one to
three as `cloud_layer_count`. Lowest and Low use one, Medium two, and High
and Ultra three. Reducing the count skips inactive layers in both the sky
and local cloud fog. Reduced budgets prioritise layers above the regional
terrain, so high mountains retain overhead clouds; existing layers keep
their heights and patterns when the count changes. The separate Sky clouds
switch still turns sky clouds off. These counts are provisional budgets,
not measured performance guarantees.

Cloud style and cloud lighting quality retain their existing budgets. Plain
blocks use solid cells without a 3D noise texture. Fluffy blocks fill rounded
box envelopes with noisy density, translucent edges and internal sun
attenuation. Their quality levels now select 12/16/24 view samples per
occupied cell and 2/3/4 local sun samples. Low currently uses 16 and three;
the lower budget is a calibration candidate. The radiance cubemap uses
eight view samples. Empty cells are skipped and nearly opaque rays stop
early. Sun attenuation is local to each cell, so neighbouring cells do not
cast shadows into one another.

Fluffy blocks and the full volume style allocate the same kind of 3D noise
texture lazily and reuse it when switching styles within a view. The full
volume style retains its existing silhouette sampling; reducing it
previously produced unacceptable grain at 800p. Its lighting quality still
selects two, three or four sun samples. The fluffy style's performance has
not been calibrated against the full volume style or target hardware.
See the [fluffy cloud review](perf/fluffy-block-clouds-2026-09-27/report.md).

Ordinary sky and distance fog remain when volumetric atmosphere is off;
underwater murk also remains. Cloud style is a candidate artistic choice,
not a guarantee of a particular saving in every scene.

All tiers retain bloom, cloud shadows, dynamic and carried lights, water
waves and reflections, wet surfaces, foliage wind, ice detail and
transmission, and lava detail. Keeping a feature is not a claim it is free.
The existing screening did not establish a worthwhile visual trade for
removing these from the baseline.

Grass density widens the procedural blade grid, reducing the number of
candidate roots searched. Draw distance clips tracing and collapses fully
distant proxy geometry before rasterisation. Grass fades back to ordinary
terrain over the final fifth of its range. Bending range and actor count
bound the interaction work separately; zero disables it. AA quality is
independent of density and restores the original viewport settings when
lowered or disabled. Stronger pre-existing AA remains respected.

Lowest and Low keep procedural grass off, with inexpensive budgets ready
if enabled in Advanced. Medium, High and Ultra now add progressively denser
and longer-range grass. These are calibration candidates. Native game
plants remain at every tier and none of these controls changes the world.

Lamp admission now obeys the light pool alone. A separate shadow selection
ranks admitted lamps by distance to their lit region, bounded by shadow
count and distance. Existing shadow owners get a two-node preference to
reduce switching. Other admitted lamps remain lit without maps; propagated
block light remains the fallback outside the direct pool. Ultra retains
48 shadow lamps and a 256-light pool.

Unshadowed point lights can shine through walls. An experimental
`lamp_occlusion` switch now checks nearby full opaque blocks along each
node lamp's ray. It uses only the owning connection's received map, in a
64-node cube refreshed at most ten times per second. A static grid avoids
repeated uploads. It is off in all presets while correctness and cost are
measured in the [tier cycle](perf/tier-cycle-2026-09-27/plan.md).

This is a coarse supplement to shadow maps. Partial nodes, carved openings,
carried lights, water, ice and volumetric fog retain their existing paths.
Unknown cells and unmatched lights keep ordinary lighting. The shader has
only a light direction, so exactly collinear sources cannot always be
distinguished. Emission and propagated block light remain separate. Dense
builds, motion and openings need review before enabling this in a tier.

The initial hardware heuristic now chooses Medium for a discrete adapter
and Low for shared graphics. This is deliberately only a starting choice.
Core count cannot establish GPU capability. Existing saved settings still
win; opening the client does not overwrite a user's chosen configuration.
Local play retains its existing Low default until Lowest is calibrated.

## Evidence and next implementation work

The [feature screening](perf/render-features-2026-09-27/report.md),
[scene controls](perf/feature-controls-2026-09-27/report.md) and
[streaming report](perf/streaming-2026-09-27/report.md) describe the exact
configurations recorded there. Those results do not benchmark the revised
presets in this document. In particular, cloud sample reductions are a new
control, not an established percentage saving.

The first three implementation steps are now present: cloud alternatives,
independent lamp shadows and graded grass. Remaining work is visual review
across weather and motion, tuning the preset values, and calibration on the
actual target hardware. A full-block lamp visibility prototype is available
behind `lamp_occlusion`; it remains off in the presets while its visual
limits and performance are evaluated. See the
[tier cycle](perf/tier-cycle-2026-09-27/report.md).

World demand and presentation quality still need separate internal budgets.
View range, terrain sharing and streaming scheduling address CPU work;
cloud, screen-space and shadow sampling address GPU work. Worker count and
main-thread time budgets are machine-wide scheduling controls. Shared
terrain must be tested with overlapping views and players travelling apart.

For each candidate, record CPU frame time, renderer CPU time, GPU time,
median and tail frame time, terrain queues and publication time, RAM and
VRAM. Compare one and four players, stationary and streaming, with warm and
cold state labelled. Include day, sunset, wet weather, night lamps,
underwater, close grass and foliage, ice and magma. A feature that happens
to be inactive at noon is not evidence of a free effect.

Use resolution changes and isolated feature changes to distinguish GPU
cost from CPU work. CPU and GPU overlap, so their timings are not additive.
Memory capacity is a separate constraint: avoid paging and allocation
spikes without treating smaller RAM use as a frame-time saving by itself.
A future recommendation should select world and rendering budgets from
measured limits, then expose a simple preset with optional advanced tuning.

The three profile benchmark plans and the Deck plan now include Lowest
and the complete settings for their named tiers. Run
`tools/check-bench-plans.py` before collecting a report. The local-play
harness also accepts `--profile lowest`; scene overrides must be reported
because they can change a preset's actual configuration.

`--setting-sweep` accepts named numeric overrides, for example
`'{"sparse":{"grass_density":0.2},"dense":{"grass_density":1}}'`.
The harness records the effective per-view settings, restores the starting
values between variants, and brackets them with controls. Use stationary
phases; streaming comparisons still require fresh runs.

`--software` uses CPU rendering for visual checks when the GPU is occupied.
Its results carry `software_renderer: true` and are not GPU benchmarks.

See the
[validation and screenshots](perf/quality-options-2026-09-27/report.md)
for the cloud, lamp and grass changes.
