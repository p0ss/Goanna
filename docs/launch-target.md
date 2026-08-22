# The launch target

One experience, stated so it can be tested: a player opens the menu, starts
a new local world, and within a few minutes is looking at terrain all the
way to the horizon, at PBR textures up close, under a shader pack whose
effects hold across that whole depth. Nothing set in a settings panel,
nothing set in an environment variable, no file copied by hand.

`docs/roadmap.md` keeps the dependency order for the project as a whole.
This file is narrower: it is the order of work for that one experience,
broken into tasks small enough to hand to a focused agent, each with what
done looks like. When a task lands, record it here with the date and what
was measured, as the other plan files do.

## What a fresh install gets today, 2026-08-22

Read from the code, not assumed. "Fresh" means no `user://goanna.cfg`, so
every value is the code's default.

| Piece | Default | Where it is decided | State |
| --- | --- | --- | --- |
| Server mod installed into the world | yes | `project/local_server.gd`, `_install_server_mod` | on |
| Far rendering granted, 1024 nodes | yes | `local_server.gd`, `far_distance` | on |
| Pregeneration around the player | yes | `local_server.gd` writes `goanna_far_pregenerate = true` | on |
| Send distance 32 blocks | yes | `local_server.gd`, `send_distance` | on |
| Far tiers, store and summaries drawn | yes since 2026-08-22 | `m_lod_distance` in `src/goanna_client.h`, was 0, is 12 | on, measured below |
| Far distance cap, stale strength | the grant, 0.6 | settings entries since 2026-08-22 (task 2d) | on; the stale grey is a per tier signal and R1 takes it to 0 |
| Material classifier and auto bump | always, 0.35 | `GoannaClient` constructor | on |
| Texture map for the classifier's block column | per game since 2026-08-22 | `GOANNA_GAME` from the menu, `project/texture_maps/<game>.csv` | on for Mineclonia only, the one map bundled |
| Baked PBR pack | none | `settings/texture_pack`, a local path | off; the pack is 139 MB, gitignored, Mineclonia only |
| Shader pack | none | `GOANNA_SHADERPACK` only | off; only the proof pack runs, see task 5 |
| Lighting values | `main.gd` constants | `light_*` in `project/main.gd` | on, but not the values the chart settled |

Measured 2026-08-22 on a fresh profile (`XDG_DATA_HOME` pointed at an
empty directory, so no `goanna.cfg` and an empty store), against the local
Mineclonia world a client had launched earlier that day, Luanti 5.16.1 in
the flatpak, Godot 4.5.1: `lod_distance` read 12, `far_grant` 1024, the
bundled texture map was applied from `GOANNA_GAME`, and twenty seconds
after joining 6233 summary blocks were drawn at tier 3 across 31 regions
and 99 surfaces, with 352 live blocks resident.

So the server side of the target is met, and the far field's four
mechanical defects (the seam, one height per block, tiling at range, a cap
short of the grant) were closed the same day under task 2 below. The
harness passed. The frame still did not: a far band lit for a different
hour than the ground at the player's feet, tops a colour the same biome
never has up close, grey where it was remembered, a hard edge where the
generated terrain stops, and cells arriving and leaving in one frame. Set
against a Photon screenshot the difference is not detail at distance, it
is that Photon's distance is shaded by the same rules as its foreground.
That is the rule the rest of this file is now judged by.

## The rule: one light, one air

Every drawn surface, whatever tier it came from and however it was learnt,
is lit by the same sun and sky, takes the same tonemap and exposure, and
sits in the same fog, with no per tier signal in the image. The only thing
distance may change is detail, and detail changes through a fade, never in
one frame. Water is the rule applied to one material: one surface model at
every range, procedural waves with detail that fades by distance, the same
reflection and absorption near and far, no texture tiling at any range.

One light, one air is not enough on its own, because the eye reads the gaps
as well as the geometry, and on a new world most of the far view is gaps:
panels that have not arrived, holes between the ones that have, and an
outermost edge with nothing past it. So the far view is three layers and
only the middle one is terrain. A background of horizon coloured air,
complete from the first frame and claiming no terrain at all; the panels
over it; the live range in front. The haze that joins them closes at the
edge of what is actually drawn rather than at the distance the server
permits, so where there is nothing to show there is air rather than an
edge, and the view opens as terrain arrives. That landed 2026-08-22;
`far-rendering.md`, "Background, overlay, foreground", has the measurements
and what it deliberately does not fix.

Where the code breaks the rule on 2026-08-22, found by reading rather than
by guessing, each a task under it:

**R1, continuity of the far field.** Four things, all in `src/` and the
node shaders. Three landed 2026-08-22 (commit "Stop the far field reading
as a different world"): `stale_strength` now defaults to 0, since pulling
remembered terrain toward grey is a per tier signal painted into the frame,
and summary blocks, which are what the server holds now rather than a
memory, are no longer marked stale at all; and the tier average colour that
2c blends toward, `getTextureAverageColor`'s sRGB byte average handed to a
shader whose `ALBEDO` is linear, is now converted to linear in the node
materials, the water material and the no array fallback, so a far tile is
no longer brighter and paler than the same tile near. The orange far tops
in the fresh world shots were that conversion missing.

The fourth is deferred until R4's pop metric can measure it, because it
reworks the region swap path that task 2 tuned for streaming: a coarse
region's faces are removed the moment a finer replacement is assigned,
while the replacement dithers in from nothing over a third of a second, so
every tier change is a hole for that long. The fix is to hold the old
faces until the new ones have faded in. Do it once R4 gives a number to
move, and confirm on the chart that the same material under the same sky
at 100, 300 and 600 nodes has no step where a shadow distance or an SDFGI
cascade edge would fall. Fable has this one.

Landed 2026-08-22, the light. Full detail and the numbers are in
`far-rendering.md`, "One light, from your feet to the horizon"; the summary,
including what this task expected to find and did not:

The far tiers do not bake a time of day and never did, so the framing this
task opened with was wrong. `LIGHTBANK_DAY` is Luanti's sunlight
propagation, a visibility term that does not move with the clock, and both
meshers store the same thing; the hour comes from `_apply_sky`'s
`goanna_sky_fill` and the sky radiance, through the same shader for near and
far alike. Measured on one running client: the `CUSTOM0` bytes on the live
meshes were identical at time 0.5, 0.25 and 0.0 while the frame went from
noon to midnight.

What was really there, found by reading those bytes rather than the frames,
was two populations of sky light where the world has one surface.
`lodTakeSummaries` clamped the wire's light level to `LIGHT_MAX` (14) before
decoding, and an open sky column carries `LIGHT_SUN` (15), so 40.9 per cent
of far vertices read 234 of 255 where the same ground reads 255 the moment
it comes inside the live range. After: 3.2 per cent, which is the level 14
light that is really there. Alongside it, and louder in the frame, a summary
block left every cell above its surface marked "never seen", so "Unknown is
not air" culled the side faces against them and the far field drew as
floating tops with daylight through them; a generated block's air is now
marked as air, and it draws as landscape.

`tools/shotcheck.py --launch-target` at time 0.5, 0.25 and 0.0, same world,
same viewpoint, before and after, on a fresh Mineclonia world at a 1024 node
grant with 6600 to 10000 far blocks, Luanti 5.16.1 flatpak, Godot 4.5.1: all
six runs passed every threshold, and the live/far boundary luminance
difference at midnight, where the sky fill is most of the light, went from
3.69 to 0.61 and its chroma difference from 1.15 to 0.28. Noon and dawn were
already inside R4's same-tier noise floor and stayed there. The harness was
never failing on this, which is why the vertex bytes were the instrument
that found it. `tools/test-launch-target.sh` itself, unmodified, passes on a
fresh profile and a fresh world; two earlier attempts failed on the close
shot's normal map response, which `far-rendering.md` records as a fragility
in where that shot is posed rather than anything about the far field.

Two per tier terms were measured and left: `block_light_emission` at 1.0 on
LOD materials moves the far band's mean luminance by 0.04 at midnight and
0.03 at noon, which is nothing against the 0.90 two shots of the same
settings drift by while the world streams; and the far tiers' traced
occlusion is much heavier than the near field's (mean 113 against 205) for
one to one and a half luminance units. Both are recorded with their numbers
in `far-rendering.md`; the occlusion one wants calibrating on the chart
against the near tracer.

Landed 2026-08-23, the paint. The light was right and the colour was not.
A node face carries its array texture layer in `UV2.x`, and the node shaders
read it two ways: the texture samplers take it as a coordinate, which GLSL
rounds, while `lod_avg_colour` and `layer_class` indexed a uniform array with
`int(UV2.x)`, which truncates. The same integer reaches the fragment through
interpolation a hair either side of itself, so layer 16 arrived as 15 on
about half the fragments, and one of those hand written indexes is the colour
a far tier flattens toward. A far surface therefore took a neighbouring
tile's average colour on half its pixels and its own on the rest, which is a
different colour and a different sign for every tile and every world: about a
fifth too dark on grass, a warm grey where the near mesh had deep blue on a
frozen sea. The near mesh never flattens, so it never saw it, which is what
made it a per tier signal. It is now `int(round(UV2.x))` in both node
shaders.

Measured on a world built to have nothing else in it, `mg_name = flat` with
`mcl_superflat_classic`, one tile at one height under open sky, one client
with the shader reloaded in place between the two readings: in the band of
rows where the near mesh and the far tiers are the same distance away, at
midnight, the far tiers were 13.48 luminance below the near mesh and are now
1.59 below, which is the haze between them. Every channel is within two of
the near mesh where it was out by eight to fifteen. Read directly, the light
channels were already identical on both sides (48.3, 205.4, 203.8 far
against 45.2, 207.0, 206.3 near), and every other per tier shading term was
swept and eliminated with a number first. `tools/shotcheck.py
--launch-target` at time 0.5, 0.25 and 0.0 on a Mineclonia world with 87000
to 94000 far cells: boundary luminance difference 6.61, 2.39, 1.95 before and
4.47, 0.81, 1.10 after, chroma 1.31, 0.79, 1.24 before and 0.89, 0.67, 0.54
after. All six runs passed every threshold, before and after, and that is not
a fluke of tuning: the defect is a per fragment speckle, and averaging a band
either side of one row is exactly the operation that removes it. Catching
this kind of fault wants variance or a nearest neighbour colour distance
within the far band, not a difference of means across the boundary. Full
detail, the offline fixture that isolated it with no server at all, and what
was measured and left alone, are in `far-rendering.md`, "The far field's
albedo".

Recorded there and not fixed: on Mineclonia, rain or thunder sets the
server's `night_sky` and `night_horizon` to pure black, and both
`goanna_sky_fill` and `radiance_floor` are multiples of that colour, so
through weather at night the world is lit by the moon alone. Reproduced with
`/weather thunder` and `/time 0:00`: mean luminance 1.34 of 255 with 81 per
cent of the frame at pure black. The level of the night share probably has to
come from the server's `day_night_ratio` rather than from the brightness of a
colour the server may set to black, and that is a change to a line calibrated
on the chart, so it wants the chart.
Landed, 2026-08-22, a separate defect in the same fade mechanism, not the
fourth item above: while a world pregenerates, hundreds of regions arrive
and fade at once, so a large fraction of the far field was mid fade at any
instant and the distance read as a dotted, flickering texture rather than
as terrain. `GoannaClient::lodBuildRegion` now skips the fade for a fresh
region past three tenths of `far_extent` from the camera, since it is
already mostly hidden by the haze and popping there is not visible as
popping; close to the camera the fade still runs as before. Full detail
and what was and was not confirmed by measurement are in
`far-rendering.md`, "Stipple and close tiling, closed 2026-08-22". The
fourth item above, holding old faces through a tier swap, is still open.

**R2, water.** `water.gdshader` tiles a 16 pixel texture and refracts.
Replace the surface model: world space procedural waves in a few octaves
with detail fading by distance (Glimmer, MIT, and Daybreak, CC0, are the
sources, credited at the point of use), a normal from them, sun specular
off that normal, Godot's screen space reflection on, absorption underneath,
and the tier water plane as the same material with waves off, so near and
far water are one surface by construction. No texture tiling at any range.
Done when the harness horizon shot's water reads as one surface on the far
band check and the close shot shows a sun highlight, and when the same
parameters drive both. Opus, in a worktree, merged when done.

**R3, atmosphere.** `main.gd` turns volumetric fog on only underwater or
when the server asks. Global volumetric fog at low density with the sun's
light shafts, Godot's glow (already on) and aerial perspective following
the draw distance, tuned on `lighting_chart.tscn` with a far scene in it,
and the haze beginning close enough that a seam two hundred nodes out is
already softened and the generated edge is never seen as an edge. The
volumetric grid is short (`volumetric_fog_length`), so it does the near
shafts and the exponential fog does the far haze, and the two must agree
on colour.

Most of this landed 2026-08-22 from another session working the same
branch, commit 7b37a71 "Put light shafts and haze in the air above water".
The volumetric block was already wired to the server's
`volumetric_light_strength` but at a density of 0.00025 to 0.00085 against
Godot's own default of 0.05, so it could not be seen at any hour; it now
has a density that shows, shaped by sun elevation, weather and the
server's strength, with a volume length of 72 and detail spread 3.0, and
`project.godot` buys the range back with `volume_size` 128 and
`volume_depth` 96. `e.fog_sun_scatter`, which was never set, now warms the
distance fog around a low sun, and it works in `FOG_MODE_DEPTH` so it
composes with the depth curve the haze uses rather than fighting it. There
is a Light shafts setting on the Lighting tab, with `GOANNA_SHAFTS`
alongside it.

What is left of R3 is the part its author was straight about not having:
the haze and the warm backlit look were verified at sunset against shafts
off, and noon is unchanged to the eye, but no discrete beam through a gap
was ever photographed, because every occluder framed was a solid ridge.
The shot that proves or kills it is under a canopy at mid morning. Also
still open: the near volumetric and the far depth haze agreeing on colour
across the whole depth, which is the half that touches the far field and
wants judging with R1's lighting settled.

**R4, the instrument.** `shotcheck.py` grows a continuity check that the
harness fails on: luminance and chroma discontinuity across the live/far
boundary of the horizon shot, and a pop metric, the largest single frame
change in the far band over a few seconds standing still, which a dither
fade keeps small and a pop does not. Sonnet. Before R1 is judged.

Landed 2026-08-22. `shotcheck.py` places the live/far boundary on the
horizon shot from the pose the harness already records: the boresight pitch
and camera height in the shot's own JSON sidecar, the vertical fov and
`view_range` from the settings JSON, and the ground height under the player
that `tools/test-launch-target.sh` finds but did not previously write down,
added there as `ground`. The row a ground plane `view_range * 16` nodes out
crosses the frame follows straight from the camera's perspective projection
(the screen offset from the boresight goes as the tangent of the angle off
it, over the tangent of the half vertical fov), which the geometric
derivation used in preference to the double-shot `lod_distance 0` fallback
because it checked out exactly on a live client: `cam.project_ray_normal` at
the row the formula names lands within a node of the ground distance asked
for, at every row tried from the middle of the frame to the bottom. The same
projection gives the top of the far band, the row where the true horizon
(ground at infinite distance) crosses the frame, above which nothing but sky
can appear at any draw distance. The continuity check reads mean luminance
and a chroma measure (the average of \|R-G\| and \|G-B\|) in a band just
inside the boundary against a band just outside it; the pop check takes a
twelve frame burst at the horizon pose spaced by `wait frames=18`
(about three seconds at 60fps) through the control channel, camera not
moved since the settled horizon shot, and reports the largest fraction of
far-band pixels whose luminance moved by more than a threshold between
consecutive frames. Both are wired into `shotcheck.py --launch-target`
directly rather than a new flag, so `tools/test-launch-target.sh`'s existing
call is unchanged; the harness only gained the burst capture and the
`ground` field in `settings.json`.

Thresholds were set by comparing the boundary reading against the same
metric run on two adjacent bands of the wall shot, which has no tier
boundary in it at all and reads as one continuous surface by construction:
on the two runs below that natural, same-tier noise floor was 0.35 to 4.93
luminance and 0.30 to 1.41 chroma. `--continuity-luminance-max` is 8.0 and
`--continuity-chroma-max` is 3.0, above that floor but well under the tens
of luminance units a reintroduced stale grey pull or a bytes-as-linear
colour would produce. For the pop metric, twenty-two standing-still frame
pairs across both runs read exactly 0.0 changed fraction, a clean floor with
no dithering or temporal noise crossing the per-pixel threshold;
`--pop-change-threshold` stays at 10.0 (0-255) and `--pop-max-fraction` is
0.01, comfortably above that floor while still well under what a coarse
region's faces vanishing over their own screen area in one frame would read.

Run twice on this machine against fresh profiles and fresh worlds, Luanti
5.16.1 flatpak, Godot 4.5.1, both after commit "Stop the far field reading
as a different world" (three of R1's four fixes: the stale grey pull default
to 0, summary blocks no longer markable stale, the tier average colour
converted from sRGB to linear before it reaches `ALBEDO`). Boundary row 802
of 900 both times (192 nodes out, eye height 151.0, matching the harness's
fixed camera offsets). First run, `far_min` 500: far cells 3071, luminance
diff 1.05, chroma diff 0.29, worst pop fraction 0.0 across eleven frame
pairs. Second, `far_min` lowered to 150 to land the burst earlier in the
far field's population: far cells 990, luminance diff 1.08, chroma diff
0.19, worst pop fraction 0.0 across eleven frame pairs. Both pass the
thresholds above, and both diffs sit inside the natural noise floor
measured the same run, which is the expected result now that three of
R1's four causes are fixed rather than the failure this task opened
expecting: the instrument was written and its thresholds chosen before
those three landed, in the same working tree, while this task was in
progress.

The fourth cause, a coarse region's faces removed the moment a finer
replacement is assigned rather than held until it has faded in, is
deliberately still open, and it is exactly what the pop metric exists to
catch. It was not caught in either run above: `far_remote`'s growth (500 or
150 to nearly 3000) happens across the whole far field around the player,
in every direction, while the pop burst watches one fixed camera cone, so
most of that resolving activity was almost certainly outside the frame both
times. Reproducing the old stale grey signal live, by setting `mat_stale`
back to its old default of 0.6 on a running client, no longer moves the
reading either: the fix removed summary blocks from being markable stale at
all, not merely the default strength, so that path is gone rather than
dialled down. Catching the fourth cause in a harness run will need the
burst aimed at a direction with active chain resolution in it, or a longer
burst, either of which is a fair follow up rather than a change to what
shipped here. Separately: distant teleports to force fresh chain activity
into view crashed the client outright on this machine (silent, no log
entry) both times they were tried; that looks unrelated to this task, since
it reproduced with an unmodified client on an old world, and is left as a
finding rather than chased, since `src/` is out of scope here. Sonnet.

That last finding is not a crash in Goanna and not a fault at all. There
was no server left to talk to: several agents were running four or five
clients and their servers at once on this machine that afternoon, and the
user shut servers down to get the machine back. A client whose server has
gone sits exactly as described, so an attempt to reproduce it reproduced
the symptom and none of the cause. Two `luanti.bin` core dumps from that
afternoon reach `SIGABRT` through libstdc++'s terminate handler in a
background thread, which is what a shutdown racing a working thread looks
like as well as what a spontaneous fault would, so they are not evidence
of one either. An earlier version of this paragraph read them as a
pregeneration crash and said so; that was wrong, and it was written before
asking what had actually happened on the machine.

Two things worth keeping from it. The client says nothing useful when its
server disappears: it sits in "connection timed out" with the player at
the origin and no message a player would understand, which is worth fixing
whatever killed the server. And the launched server's stderr goes nowhere
a player could find, because `local_server.gd` starts it with
`OS.create_process`, which captures no output, while Luanti's fatal errors
go to stderr rather than to the `--logfile` it is given, so a real fault
there would be as silent as this one was. Both belong with task 9.

These come ahead of everything in "The tasks, in order" below except task
1, which they use. The translator (tasks 5 and 6) continues as shader pack
compatibility, off by default; the shipped look is Goanna's own.


## The tasks, in order

Each task names where the code is, what instrument says it is done, and
which model tier it suits. A task marked opus has a design decision in it;
one marked sonnet is bounded and measured. Every task ends with
`tools/check-style.sh` clean, the relevant plan file updated, and no claim
in `README.md` moved to "Working" without the run that proves it.

### 1. The acceptance harness

Nothing else here can be called done without this. A script,
`tools/test-launch-target.sh`, that: starts the client against an empty
settings file without touching the player's own (`XDG_DATA_HOME` pointed at
a scratch directory does this on Linux, Godot puts `user://` under it, and
the measurement above was taken that way; a `GOANNA_CFG=<path>` override in
`main.gd` and `ui/game_ui.gd` is the portable fallback, with the
`GOANNA_LOCAL_TEST` guard in `menu.gd` as precedent); starts a new local
world through the menu path, not a hand started server; waits on the
control channel (`docs/control-channel.md`) for `render_stats().far_remote`
to pass a threshold rather than on a wall clock; takes one shot at the
horizon and one at a wall two nodes away; writes both beside a JSON of the
settings in force. `tools/shotcheck.py` gets a `--launch-target` check that
reads them: far cells above a count, a normal map response in the close
shot, a non identity final pass in the frame when a pack is on.

Done when the script passes on this machine from a fresh profile and its
output is the evidence the rest of this file cites. Sonnet. No dependencies.

Landed 2026-08-22. `tools/test-launch-target.sh` drives the control channel
with an embedded Python client rather than shelling out per command, because
the sequence (wait for the far field, find the ground under a spawn point
nobody chose, pose two shots, write settings.json, quit) has too much state
to carry through `tools/goanna-control` calls cleanly. Every run gets a
freshly named world, because a reused one's earlier pregeneration would let
a regression here hide behind old progress.

Run three times on this machine against fresh profiles and fresh worlds,
Luanti 5.16.1 flatpak, Godot 4.5.1, `far_min` at its default of 500: passed
each time, with `render_stats().far_remote` at 616, 2139 and (a fourth,
deliberately impossible run to check the failure path) never, all within
five seconds of joining. `deviations` was empty at both the start and the
end of every passing run, so the profile was cold throughout. The close
shot's local shading detail (10 to 24 depending on what terrain a fresh
spawn produced) passed against `auto_bump` at its default 0.35 in all
three; the shader pack check reported `SKIP` in all three, correctly, since
nothing sets `GOANNA_SHADERPACK` by default today. A run that cannot reach
the control channel, or times out waiting on the far field, exits non-zero
with the run directory and a log tail; verified separately by asking for
more far cells than any world could produce in five seconds.

### 2. The far field, made continuous

The four defects listed above, as four pieces that can go to four agents,
in this order because each one's result is what the next is judged
against.

**2a. Close the seam.** `lodRequestSummaries` in `src/goanna_client.cpp`:
ask for every area out to the cap that is not entirely live, not only
those whose centre is past the live range; ask for an area that is partly
known, and let `lodTakeSummaries` fill only the blocks that are neither
live nor chained, which it already does; widen the vertical window to
what the terrain actually spans. On the mod side, push summaries of areas
generated by ordinary play, not only by pregeneration, or have the client
ask for them, whichever keeps the server's work bounded. Done when a
fresh profile's horizon shot, task 1, has no band of sky between the live
edge and the tiers in any direction. Sonnet; the rule is in one function.

**2b. Summaries with a surface.** The 6 byte record per block has to
become a heightfield: at least a 4 by 4 grid of surface heights per block
(16 cells of 4 nodes, one byte each, plus the contents), so a slope is a
slope and the 128 node fill threshold can go. `goanna_server_mod/init.lua`
writes it, `lodTakeSummaries` reads it into a `BlockLodChain` at the
matching level rather than at cell 16, and the protocol comment in both
places names the new version so an old mod and a new client fail loudly.
Size the record against `goanna_far_summary_blocks_per_step` so the
server's bound holds. Done when the same horizon shot shows slopes, not
stepped boxes, and the mod's README says what a summary costs per area.
Opus for the record design, sonnet to carry it through both sides.

**2c. Shade the far field as a far field.** In `src/goanna_lod.cpp` and
the node and water shaders: UVs that still repeat per node near the
player's end of a tier but blend to the tile's average colour with
distance, using the average the fallback path already has, so no quad
aliases at any range; water at tier scale as a flat tinted plane with the
live water's colour and none of its per node wave, since there is nothing
at 16 node cells for a wave to be. This is the same question task 5's
pack faces from the other side, so the two agents should read each
other's notes: the pack owns atmosphere, the tier shader owns what is
under it. Done when the water in the horizon shot is one surface, judged
by `shotcheck.py` measuring high frequency energy in the far band. Opus.

**2d. Reach the horizon.** Default `m_far_distance` to the grant rather
than 512, push `cam.far` out with it, and tie the fog so the far edge ends
in haze at the cap, with the density following the cap rather than a
constant; settings entries for the far distance cap and the stale
strength, environment variables today (`GOANNA_FAR_DISTANCE`, the `stale`
channel); a line in the HUD while `far_remote` is still rising so the
first minute of a new world does not read as broken; and the cost of all
of it measured on this machine through task 1 at a 1024 node grant, with
the number that is affordable recorded in `far-rendering.md`. Find the
purple cells while there: which content, which path. Done when the
horizon shot ends in sky, not in a cut edge, and the two entries round
trip through the panel. Sonnet. Depends on 2a to 2c only for the shot to
be worth judging.

Landed 2026-08-22, all four. Full detail in `far-rendering.md`'s "The
launch target's four defects, closed 2026-08-22"; the summary:

2a loosened `lodRequestSummaries`'s two skip conditions from centre based
to farthest-corner and fully-known based, and widened the vertical window
from one area either side to four, capped rather than matched to the
horizontal radius. No mod change: the loosened ask already reaches terrain
generated by ordinary play, since `farsum?` answers for anything generated
regardless of how.

2b is a 21 byte record, protocol version 2 (`goanna_server_mod/init.lua`,
`GoannaClient::lodTakeSummaries`, `GoannaSession::requestFarSummary`), a
4 by 4 grid of heights with content and light staying block level. An old
mod and a new client now refuse each other's messages rather than
misreading them: the request and reply patterns simply do not match, and
`lodTakeSummaries` also logs a plain error if a reply from a stale mod
turns up. The 128 node fill threshold is gone; a cell's own height says
whether it has anything in it. The chain builds at whichever tier's cell
is 4 nodes or coarser, not always at cell 16.

2c did not end up touching `src/goanna_lod.cpp`: the average colour a
tile blends toward with distance is looked up per array layer from a
uniform set only on LOD materials (`GoannaClient::materialFor`), which
needed no change to the shared vertex format the near mesh also uses,
`docs/mesh-attributes.md`'s contract for why that mattered. Water at a
tier stops waving and gets the same blend, both a two line change since
`waving` was already a per instance uniform on the shared water shader.
`shotcheck.py --far-band` is the instrument.

Landed further, 2026-08-22: 2c's flatten only ever looked at camera
distance, which missed a panel drawn close to the camera where the server
has not streamed a block but the store or a summary has, since it is
still a single wide merged quad and the tile visibly repeats at point
blank range. `meshLodRegion` now tracks the widest merged quad it built
each region, `GoannaClient::lodBuildRegion` hands that to the region's
mesh as a new instance uniform, and the node shaders' flatten fires on
quad size as well as distance, each against its own thresholds, with the
auto-inferred normal map's relief and occlusion fading the same way the
colour does. Full detail and what was and was not confirmed by measurement
are in `far-rendering.md`, "Stipple and close tiling, closed 2026-08-22".

2d: `m_far_distance` defaults to the grant, an explicit choice (env var or
the new "Far draw distance" setting) turns that off; `cam.far` and the fog
density, already tied to draw distance since rung 4, follow it out
automatically. A second new setting, "Remembered terrain tint", reached
`stale_strength` for free through the existing generic `mat_*` mechanism.
The HUD line reads "Generating distant terrain (N cells so far)" while
`far_remote` changes. The purple cells were `lodTakeSummaries` defaulting
an unresolved summary name to `CONTENT_AIR` where `NodeDefManager::get`
itself defaults to `CONTENT_UNKNOWN`; fixed to match, so an unresolved
name is Luanti's own magenta `unknown_node.png` rather than a silent hole.

Verified together, not only apart: `tools/test-launch-target.sh` passes
clean on this machine from a fresh profile and a fresh world, with
`far_distance` reading 1024 (the local server's grant) with nothing set,
`cam.far` reading 1280, and the horizon shot ending in haze. Two minutes
in, `far_remote` reached 6656 blocks at 847 draw calls; the number is in
`far-rendering.md`.

### 3. The PBR pack, distributed

The look up close is `baked/pack-mineclonia-v2`: 3069 files, 139 MB, baked
by `tools/pbr_bake.py` from Mineclonia's own art and therefore CC BY-SA 4.0
with the attribution `ATTRIBUTION.md` carries (`docs/materials.md`, "Licence
of the source art"). It cannot go in the repository and it is Mineclonia
only.

The decision in this task: where it lives and how it arrives. The
recommended shape is a release asset, one archive per game, fetched by the
client into `user://packs/<game>/` from the menu with a progress bar and a
checksum, and selected automatically when a local world of that game is
started or when a server's game can be recognised from its node names. The
alternative, installing it as a worldmod through `tools/pbr_deploy.py` so
the server serves it, keeps the client vanilla but makes every join a
139 MB media transfer and makes the world's texture set the mod's. Pick the
first unless the design turns up a reason not to, and say why either way.

Pieces: `tools/package-pbr-pack.sh` (archive, checksum, attribution inside);
the menu button and download; the per game selection in `main.gd` beside
the texture map; a visible attribution line in the menu, because a
share-alike licence requires it where the work is distributed. Opus for the
decision and the selection logic, sonnet for the packaging and the download.
Depends on nothing; task 1 measures it.

### 4. Lighting defaults, judged with the pack on

`project/main.gd` starts at sun 1.0, ambient 1.0, bounced light 1.4, corner
shading 4.0, exposure 0.46, sky fill 0.4. The values that have actually been
looked at with the baked pack on are different (sun 0.5, ambient 0.5,
bounced light 0, corner shading 7.75, bounced light grain 7.75). Neither
set was settled by the chart in `project/lighting_chart.tscn` with the pack
on, which is the condition the target runs under.

Run the chart with and without the pack, settle the defaults, and record
the values and the frames in `pbr-plan.md` step 3. If the answer differs
with and without a pack, the defaults follow the pack's presence. Sonnet
with the chart; opus if the two conditions want different exposure
pipelines rather than different numbers. Depends on 3, or on the pack
being present locally, which it is on this machine.

### 5. Base-Shader running, which means the gbuffers translator

Changed on 2026-08-22, after reading both packs rather than their pages.
The earlier plan here was to write a pack of our own, on the grounds that no
third party pack was licensed for us to ship. That was simply wrong:
Base-Shader is CC0-1.0 and Eclipse is CC-BY-4.0, both shippable, Eclipse
with attribution. So the default is a real pack, and the work is the
translator that lets one run.

Base-Shader is fourteen `gbuffers_*` programs and no screen space chain at
all. Loaded into Goanna today it succeeds and draws nothing, because
`compositeChain()` is empty. So this task is rung 5 of `iris-compat.md`:
translate `gbuffers_terrain`, unshaded, into the node array shader path, and
run the same translated shader on the far tiers so the horizon is shaded
like the near bubble rather than left as Godot drew it.

Two findings make this smaller than the rung description assumed. The
lightmap coordinate `lmcoord`, which `iris-compat.md` listed as a known hole
to be reopened, has been carried in `CUSTOM0.rg` since 2026-08-21, so it is
a scale rather than a revival. And Base asks for nothing beyond an atlas
sample, a lightmap sample, a vertex colour and a fog mix: no normals, no
second render target, no vertex displacement, no parallax. The substitution
table and the one genuine mismatch, Goanna's array texture against
Minecraft's flat atlas, are in `iris-compat.md` under "The first target".

New pieces, none of them large:

- A hand written shell `.gdshader` declaring the Iris vertex and uniform
  environment, into which the pack's `main` bodies are placed.
- A generated `lightmap` texture, from the server's sky colour and the torch
  colour, or every translated pack renders fullbright.
- Fixed function fog state as uniforms (`gl_Fog.*`, `fogShape`, `fogMode`),
  fed from the drawn distance `main.gd` already computes at the fog block,
  not from `far`, which is the camera's 1000 and not what Goanna draws.
- `MC_RENDER_STAGE_*` as preprocessor constants.
- `report()` saying "no screen space programs" when a pack has none, so the
  silent no op above cannot happen again.

The fog and tonemap ownership rule is settled and written down in
`iris-compat.md`: a pack with `final` takes the tonemap, a pack with a
translated terrain program takes the fog, neither is inferred from mere pack
presence. Apply it to every pack, not to one.

Also in this task, unchanged from the earlier plan: a `shader_pack` settings
entry, `main.gd` reading it where it reads `GOANNA_SHADERPACK` today, packs
found in a `shaderpacks/` directory beside the executable so a player can
drop one in, and a pause menu toggle.

Done when Base-Shader is the default with no setting touched, task 1's two
shots show its terrain program shading the near mesh and the far tiers
alike, and `tools/shaderpack_check.py` grows a check that says so. Opus, and
the largest task on this page. Depends on nothing here, but it is now on the
critical path where task 6 used to be.

One consequence to decide rather than fix: `unshaded` takes Godot's
lighting, normal maps, roughness, specular, SSAO and SDFGI off every surface
the pack shades. Base recreates vanilla Minecraft's flat look on purpose, so
with Base as the default the baked PBR pack from task 3 and the lighting
defaults from task 4 settle nothing about what a player actually sees. The
sentence at the top of this file promises PBR up close and a pack across the
whole depth, and those two are in tension. Eclipse recovers some of it, and
task 6 is where that is judged.

### 6. Eclipse, which is rungs 6 and 7

Eclipse ships `gbuffers_water` and `shadow`, which Base does not, so it is
what rungs 6 and 7 are measured against, and it has a real composite chain
on top. It is also where the pack side of the look is decided, because it is
the one of the two that is trying to be good looking rather than faithful.

Four things found in its source on 2026-08-22, recorded in `iris-compat.md`
so they are not rediscovered: its `final` is an identity pass, so it cannot
be used to test that a final pass ran; its composites are gated on targets
only the geometry programs write, so it is a whole pack or nothing; it is
`#version 330 compatibility` with located outputs, which the translator does
not yet handle; and it declares a variable named `sample`, reserved since
GLSL 4.20, which the translator has to rename.

`iris-compat.md` rungs 2 and 4 come with it: the `shaders.properties` option
`#define`s and custom uniforms, `depthtex1` and `depthtex2`, and a real
`shadowtex`. Eclipse's options live as `//[25 50 75 100]` comments on its
`#define` lines, which is the OptiFine convention and the thing rung 2 is.

Done when Eclipse renders with no translator edit specific to it, and the
default pack question from task 5 has an answer that was looked at rather
than assumed. Opus. Depends on 5.

### 7. The audit

`pbr-plan.md` step 4: per game and per node, the class assigned, whether
authored data exists, a rendered swatch, generated over every registered
node (`tools/goanna_pbr_gallery.lua` is the start of it). Done when a row
can be pointed at rather than a screenshot. Sonnet. Independent; it is the
gate the Iris translator rungs 5 to 7 wait behind, not this target, so it
comes after 5 and 6 here.

### 8. Far rendering at scale

Cost, after task 2 has settled what is drawn: a worker thread for region
meshing (cross thread rules in `CLAUDE.md` apply, everything through
`GoannaSession`'s mutexes), the chain thresholds calibrated against task
1's measurements, and an index over stored regions before the scan is
asked to cover 4000 nodes. Opus for the thread, sonnet for the rest.
Depends on 2 for the numbers.

Also here, and the reason a new world takes minutes to fill: most of what
is asked for is never seen. Task 2a widened the vertical window to four
area layers either side of the player, so a column of nine 128 node areas
is requested where the terrain in it is one surface and the rest is sky
above and stone below. The sky areas summarise to nothing and the stone
areas to a solid block whose faces are all interior. Both cost the server a
`VoxelManip` read per mapblock and cost us the round trip. The fix is for
the mod to answer the vertical extent of generated terrain per column, and
for `lodRequestSummaries` to ask only within it, which needs a protocol
version like 2b's. Until then the pregeneration rate, not the client, is
what the first minutes are waiting on.

### 9. Launcher polish

The worldmod copy of `goanna_server_mod` goes stale when the checkout moves
on (copy it every start, or compare a version line); the other games need
their texture maps bundled and, when baked, their packs (VoxeLibre, Asuna,
Minetest Game, in that order of players); a player who lands in an old
world made before the privilege change has no fly and no clear reason why.
Sonnet. Independent.

## What this file is not

It is not the roadmap. Connected textures, entity and node animation,
Iris rungs 5 to 7, source movement and VR are all real and all absent here,
because none of them is between a fresh install and the experience at the
top of this page. They stay in `roadmap.md` in their order.
