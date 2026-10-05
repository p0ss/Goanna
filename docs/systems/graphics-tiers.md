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

[graphics_profiles.gd](../../project/graphics_profiles.gd) is the source of
truth. Every preset names the same controlled keys, including all 20
feature gates and the texture resolution. Applying Ultra after Lowest restores its effects; applying
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
| Texture resolution, pixels per 16 art texels | 128 | 128 | 256 | 256 | 512 |
| Parallax | Off | On | On | On | On |
| Parallax march | n/a | Short | Full | Full | Full |
| Micro shadows | On | On | On | On | On |
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

Micro shadows (`mat_micro_shadow`) darken the pack's baked occlusion when
light rakes across it, in `light()`, with no texture reads. They are on at
every tier: on 2026-10-05 their GPU cost did not show above the noise at
Low or Medium. Low now runs the short parallax march
(`mat_parallax_short`): four steps plus two refinements, only within eight
nodes of the eye. It cost 0.075 ms per frame (spread 0.047 to 0.106 over
sixteen alternated rounds) with a near wall filling most of a 1280x800
frame, and nothing measurable at the benchmark vista. Those are RTX 3090
numbers, about 6 per cent of that close frame's GPU time; the Steam Deck
has not been measured. Medium keeps the full march: the short one saved
0.05 ms there and was not distinguishable at three nodes. Lowest keeps
parallax off. See [materials](materials.md), "Micro shadows and the short
march", and the
[measurement driver](../perf/low-tier-occlusion-2026-10-05/run.py).

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
See the [fluffy cloud review](../perf/fluffy-block-clouds-2026-09-27/report.md).

Ordinary sky and distance fog remain when volumetric atmosphere is off;
underwater murk also remains. Cloud style is a candidate artistic choice,
not a guarantee of a particular saving in every scene.

The heat shimmer over flames (`render_fire_shimmer`) is off on Lowest
and Low and on from Medium; the flame material itself is the same at
every tier. See [fire material](fire-material.md).

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
measured in the [tier cycle](../perf/tier-cycle-2026-09-27/plan.md).

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

### Texture resolution

`texture_size` (Advanced, Materials, **Texture resolution**) is 128, 256
or 512: the most map pixels an enhanced texture may have across 16 texels
of the game's art, so 8, 16 or 32 to an art texel. It applies evenly to
everything: block albedo and companions, animation strips, mob and player
skin companions, every chiseled bookshelf front. A texture over it is
reduced when a world's textures are loaded, before anything is drawn from
it; one under it is left alone, never enlarged. The art each image is
counted against is the server's own image of that name, before a pack
replaces it. How the reduction filters each map, and what it does to node
layers sized from their companions, is in [materials](materials.md),
"Texture resolution".

The setting takes effect at the next join, not live. The server's media
exists only in the source image cache, the reduced images replace the
pack's there, and every array, material and mesh of the session is built
from them; raising it would need the pack read again and every texture
rebuilt, which is what a rejoin does. The menu row says so when it is
changed in game. `GOANNA_TEXTURE_SIZE=128` (or 256, 512) pins it for a
scripted run, over any profile. A bench plan's tier variants carry it so
`tools/check-bench-plans.py` stays in step, but a live sweep cannot vary
it; measure it a session per value
([driver](../perf/texture-size-2026-10-05/run.py)).

The pack itself is built at 256 and shipped at 256 for now. With it, Low
and Lowest reduce on load and Ultra draws the 256 maps as they are. A pack
built at 128 or 512 (`GOANNA_PBR_SIZE`, `tools/pbr_author/README.md`) is
what each tier should download; the bundles and the catalogue gain them
with the next release.

Measured 2026-10-05 on the RTX 3090 (NVIDIA open module 615), Godot
4.5.1, test_world (Mineclonia) through the occlusion fixture's copy,
Medium profile at 1920x1080 with only `texture_size` and the pack changed,
a session per configuration, two rounds in rotation, four bursts of 400
back to back draws at each place
([driver](../perf/texture-size-2026-10-05/run.py),
[summary](../perf/texture-size-2026-10-05/analyse.py)). Texture memory is
Godot's `RENDER_TEXTURE_MEM_USED` at the benchmark vista, after the
platform for the wall:

| Configuration | Texture memory, MiB | Vista GPU ms, median (bursts) | Wall GPU ms, median (bursts) |
| --- | ---: | ---: | ---: |
| 256 pack reduced to 128 | 1282 to 1295 | 4.65 (4.34 to 5.02) | 2.88 (2.65 to 3.53) |
| 128 pack | 1279 to 1281 | 4.29 (4.21 to 4.32) | 2.84 (2.68 to 2.96) |
| 256 pack | 2522 to 2561 | 4.11 (3.89 to 4.29) | 2.76 (2.72 to 2.84) |

Texture memory falls by about 1,240 MiB at 128, to half. The join's log
line counts the images the cap reduced: 4,067 MiB of RGBA8 source images
brought to 1,016, before mipmaps and before only the arrays drawn reach
the card; the server's own copies of the companions, which this test
world's server mod sends at 256, are counted there too. What is left at
128 includes the renderer's own targets, shadow maps and SDFGI, which no
texture setting moves. A reduced 256 pack and a pack built at 128 cost
the same. GPU time does not follow: the sessions of
one configuration differ by more (4.35 against 4.81 ms at the vista, 128
reduced) than the configurations do, and 256 was not slower than 128. On
this card at this scene the texture resolution is a memory setting, not a
frame time one; a handheld with shared memory has not been measured. The
512 pack was built but not measured on the GPU: other clients held the
card for the two and a half hours it was waited for.

Frames at a low sun, centre crops of the fixture's walls:
[stone](../perf/texture-size-2026-10-05/stone_wall.png) and
[stone brick](../perf/texture-size-2026-10-05/stonebrick_wall.png), each the
128 pack, the 256 pack reduced to 128, and the 256 pack, left to right.
The reduced 256 reads as the 256 one, a little softer. The 128 pack in
them is the build before its occlusion fix (`tools/pbr_author/README.md`,
"The baked occlusion"), with its joints near black; that frame is why the
fix was made, and the fixed pack has not been seen on the GPU. The
zombie frame of that run showed open sky (the platform's western map
block lost its near mesh, as in the occlusion review), so no mob close
up was taken at any size.

## Evidence and next implementation work

The [feature screening](../perf/render-features-2026-09-27/report.md),
[scene controls](../perf/feature-controls-2026-09-27/report.md) and
[streaming report](../perf/streaming-2026-09-27/report.md) describe the exact
configurations recorded there. Those results do not benchmark the revised
presets in this document. In particular, cloud sample reductions are a new
control, not an established percentage saving.

The first three implementation steps are now present: cloud alternatives,
independent lamp shadows and graded grass. Remaining work is visual review
across weather and motion, tuning the preset values, and calibration on the
actual target hardware. A full-block lamp visibility prototype is available
behind `lamp_occlusion`; it remains off in the presets while its visual
limits and performance are evaluated. See the
[tier cycle](../perf/tier-cycle-2026-09-27/report.md).

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
[validation and screenshots](../perf/quality-options-2026-09-27/report.md)
for the cloud, lamp and grass changes.
