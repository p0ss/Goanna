# Overseer camera

Implemented on 6 October 2026 with DorfCraft's `overseer` mod. The server
specification and verification record are in DorfCraft's
`docs/overseer.md`. This is the first orthographic planning slice, including
level changes. The initial flat-cell renderer has been replaced with real
world geometry and live entities; verification for each revision is below.

## Authority

A server HUD element named `dorfcraft:overseer` grants one private channel.
`GoannaSession::setOverseerChannel` checks that exact HUD name and text,
under the HUD mutex, before joining. Incoming traffic is accepted only
from the server (empty sender) and queued under the server-options mutex.
Relayed player messages never supply geometry. The session thread never
touches Godot objects.

`project/overseer.gd` sends an explicit ready message after joining. It
opens the camera from the server's hello, requests bounded rectangles,
reassembles bounded chunks and submits planning requests. Server removal
of the HUD grant, bye, Escape and connection timeout all close the view.

## Drawing and input

The view owns a separate `SubViewport` and `World3D`, with an orthographic
camera and an opaque dark grey background. The normal camera's visibility
mask is saved and set to zero. The ordinary UI and gameplay input are
suspended; body simulation and the server connection continue.

`GoannaClient::overseer_mesh` runs Luanti's normal mapblock mesher on an
observation-only voxel buffer. Nodeboxes, facedir, connected nodes, mesh
nodes and liquids use their ordinary geometry and world materials,
including texture-pack maps and tile animation. Cached hidden mapblocks,
carve state and light fields are never copied into this buffer. Lava flow
and shoreline shading also sample only the observation buffer. Genuine
triangles are clipped to the selected level and supplied rectangle.
The server supplies up to eight lower slices along known open columns,
stopping at unexplored ground. One support cell below the first solid
surface retains openings in stairs and slabs. Separate server-supplied
known wall cells close the exposed sides of shafts, including beneath
solid capped columns. They never reopen those columns for live actors.
Crossed plantlike sprites
become horizontal cards with the same texture, tint and world material,
limited to one cell; mesh plants keep their original geometry.

Changed mapblocks are rebuilt one per frame. Unchanged meshes survive the
one-second observation refresh. Live worker dig/build events update those
observations, so completed work appears without reopening the camera.

`EntityRenderer` routes its existing scene nodes into the isolated world.
The same skeletons, attachments, movement and animation tracks keep running.
Only actors in currently visible air or thin plants are visible. Actors
below the selected level also require a continuous currently visible open
column above them;
attachments inherit the body's permission. Unknown columns and the area
outside the supplied rectangle have opaque dark grey caps, preventing actor
and nametag overhangs from leaking across the boundary. Empty/stale layers
hide actors too. Exit and scene teardown return them to the ordinary world.

The sun and moon follow the ordinary scene, with conservative ambient
lighting. World particles, weather, local node lights and progressive carve
damage are not yet transferred. The normal server simulation never pauses.
The view uses entities already supplied by the ordinary server stream,
without requesting extra remote actors.

Planning includes two-high excavation, single-level detail digs, tree
felling, ripe-bush harvesting, walls, replacement floors, upright stairs,
beds and doors. The stock picker filters by tool. A facing selector sets
bed length, door orientation and stair ascent; bed previews include both
cells. Workers fetch real items and perform the work through labour.
Inspection and coloured order edges remain; terrain is no longer drawn as
flat textured squares.

Page Up/Down or Shift-wheel changes levels. Wheel zooms. WASD or a middle
button drag pans. Tools use two corners; beds, doors and tree felling use
the same cell twice. Dig includes headroom, while Detail dig stays on one
level. Floors replace the block below and show their order on the standing
level. Inspect includes blocked-order reasons. A level or requested rectangle
change clears the prior geometry immediately; replies must match its
sequence and have a newer revision. Missing, empty, out-of-claim and stale
layers stay dark grey. Closing restores the original camera mask, UI visibility
and pointer capture.

Remembered columns are slightly desaturated (30 percent) and darkened
(16 percent) by `shaders/overseer_memory.gdshader`. Order outlines share this
column treatment. Blue-white transparent sheets accumulate at each open
level between the selected layer and a known lower surface, at 4.5 percent
opacity per sheet. Immediate ground has no depth haze. Unknown bottoms
stay black; the eight-level view limit is grey. Haze tint follows daylight,
so it dims at night. Seven sheets retain about 72 percent of the underlying
contrast. A narrow fixed inner edge marks known drops of two or more
levels; it is a depth cue, independent of cast sunlight shadows.

Exposure and colour grading follow the ordinary scene while the view stays
open. The isolated scene has its own ambient fill and receives no hidden
terrain light field. Sun and moon directions and energies also follow the
ordinary scene; changing the time changes their actual cast shadows.

## Tests

These use Godot 4.5.1 with its headless dummy renderer, and do not take GPU
time:

```sh
/path/to/godot --headless --path project --script res://tests/overseer.gd
```

For live tests, start a **scratch** Luanti 5.17.0 Mineclonia world on port
30561, with `labour`, `rooms` and `overseer` enabled, singlenode mapgen,
`mcl_singlenode_mapgen = false`, `overseer_selftest = true` and
`overseer_test_keep = true`. The scripts use the fixture's `overseertest`
account. Run them sequentially:

```sh
/path/to/godot --headless --path project --script res://tests/overseer_live.gd
/path/to/godot --headless --path project \
  --script res://tests/overseer_fallback.gd
/path/to/godot --headless --path project \
  --script res://tests/overseer_recovery.gd
/path/to/godot --headless --path project \
  --script res://tests/overseer_world.gd
/path/to/godot --headless --path project \
  --script res://tests/overseer_lava.gd
/path/to/godot --headless --path project \
  --script res://tests/overseer_loop.gd
```

The structural suite checks isolated worlds, explicit bounds, unknown
floors, stale replies, level changes and restoration. The live suites
check the private handshake, real layer messages, order requests, the
vanilla fallback without joining the channel, disconnect recovery,
server-side freezing, damage exit and a worker completing a tunnel planned
into unknown rock.

## World geometry verification, 6 October 2026

Godot 4.5.1 dummy renderer, local rebuilt Goanna, Luanti 5.17.0 Flatpak and
Mineclonia release 38561:

- 20 structural camera assertions passed, including active scene teardown.
- 17 live assertions in `project/tests/overseer_world.gd` passed: real cube,
  slab and rotated stair meshes, world shaders, concealed ore exclusion,
  native layer delivery, construction, mining, moving/animated actors,
  entity hiding at an unserved level and restoration on exit.
- The same camera stayed open while a worker fetched stock, built two
  stone-brick blocks, and mined onward to x=8. The server sent updated
  observations and the view queued the changed world meshes.
- Nine vanilla fallback and reconnect assertions passed.
- Two lava regression assertions confirmed the ordinary cache contained
  concealed lava and that identical supplied observations produced
  identical flow and shoreline attributes over different cached terrain.

Run the live world suite against the same opt-in scratch server described
above. It calls `/overseer_world` to prepare shaped terrain and a stocked
container. Do not use that test fixture in a play world.

A CPU-only render-service pass used verified llvmpipe, High settings and
960 by 540 frames. Real terrain shapes, textures and the worker model
were visible. The ordinary camera mask remained zero and the mesh queue
drained. A 5 by 5 pixel patch at the concealed ore was exactly black.
Three server assertions also rejected construction without manage
permission, on unknown ground and with an invalid material. The service
reported no shader errors. The frame and audit are under
`/tmp/dorfcraft-overseer/live-world/frames/detail/` and
`/tmp/dorfcraft-overseer/live-world/detail-audit.json`. The subsequent lava
isolation change is covered by the headless regression, not this frame.
Software frames do not establish GPU performance.

The GPU was occupied during the initial world-geometry revision. A later
GPU check used natural terrain, as recorded below. The full 64 by 64,
eight-level performance run remains outstanding.

## Earlier flat-cell GPU verification, 6 October 2026

These measurements and frames describe the superseded tile prototype.
They are not acceptance results for the world-geometry renderer.

The authorised render-service pass used its shared GPU lock, with
`gpu-free` clear beforehand: RTX 3090, Godot 4.5.1, Luanti 5.17.0,
Mineclonia release 38561, 1280 by 720, verified High settings. The native
library hash recorded by the service was `e6e4aa25a9ae8fa7`. Medium failed
its startup profile check because view range read back as 12 instead of 8;
these results do not claim Medium performance acceptance.

Frames covered levels -1, 0 and 2, panning to the claim edge, level -40
outside the claim, and zooming beyond the supplied 63 by 63 rectangle.
Six audited cases kept the ordinary camera's mask at zero and the
viewport's own world enabled. Transitions cleared the previous geometry
and rejected an injected previous-layer reply. The service reported no
shader errors. A final frame showed the ordinary world after exit; the
camera mask, UI visibility and pointer capture matched their saved values.

The ordinary map cache held both concealed diamond and a lava cave.
Their observation cells remained unknown, and 5 by 5 pixel patches at
both projected positions were exactly black. Patches beyond the claim
and supplied rectangle were also black. The out-of-claim level had no
terrain geometry and its entire map below the controls was black.

Live render-time measurements of the isolated viewport, after discarding
120 initial samples, were:

| Case | Samples | Median GPU ms | p95 GPU ms |
| --- | ---: | ---: | ---: |
| Floor, level -1 | 1,346 | 0.101 | 0.383 |
| Upper, level 2 | 1,064 | 0.103 | 0.392 |
| Concealed cave, level 0 | 1,108 | 0.102 | 0.385 |

This is a small fixture and measures only the overseer viewport, excluding
main-viewport composition, UI, CPU observations and network latency. It is
not the full 64 by 64, eight-level Medium performance acceptance run.
Frames, service settings sidecars, observation audits and the measurement
summary are under `/tmp/dorfcraft-overseer/frames/`.

That prototype had patchy knowledge coverage across open floors from the
server's sparse spherical sight rays. The current server also sweeps every
standing-level cell in a disc, nearest first; coverage grows over time.
Stock-client visual checks and the larger performance run are outstanding.

Continue to use `tools/goanna-render` for GPU frames and timing, following
`docs/agent-interfaces.md` and obtaining the maintainer's permission for
shared GPU time.

## Natural terrain GPU verification, 6 October 2026

A fresh Mineclonia v7 world, seed 1100, replaced the earlier stone-floor
fixture. Its generated grassland, slopes, flowers and trees were left
intact; the fixture added one stockpile chest and two workers. The render
service used `--floor ''`, checked `gpu-free` and held the shared lock for
one RTX 3090 client. Godot 4.5.1, Luanti 5.17.0, Mineclonia release 38561,
verified High settings and 1280 by 720 frames were used.

Natural vegetation exposed two bugs. Observation rays treated grass and
flowers as opaque, leaving their ground black, and the entity mask hid
workers in known plant cells. Thin, non-walkable, sunlight-propagating
plants now expose their ground and pass sight rays. Their known cells
also admit actors. Solid terrain, walkable leaves, water, glass and
unknown cells retain conservative concealment. Forty server assertions
and eight live assertions in `tests/overseer_foliage.gd` passed.

Workers moved and built five stone-brick blocks from stock during an open
127-second camera session; geometry and order overlays updated live.
Soil excavation was accepted but labour refused it with `too_hard`, from
its fixed stone-pick calculation. Successful soil excavation is not
claimed. A chest's separate entity model is also still missing from the
slice, although it appears in the ordinary view.

The final audit had 64 observed plant cells with no missing ground. A
cached air-over-grass column at Luanti (15, 12, -12) remained unknown in
the layer and its projected 5 by 5 pixel patch was black. The slice kept
its own world and the ordinary camera mask was zero. Exit restored the
mask and UI. There were no reported shader errors. The service was stopped
and released the shared lock after verification.

The isolated viewport measured 2.54 ms median GPU time and 6.48 ms p95 over
1,313 samples, excluding the first 120 recorded samples. This is not total
frame time or the full 64 by 64, eight-level performance acceptance run.

Frames, settings and audits are under `/tmp/dorfcraft-overseer/natural/`:
`frames/landscape/default/landscape.png` is the ordinary view;
`frames/corrected/default/` has the construction before/after pair; and
`frames/completed/default/overseer.png` uses the final vegetation fixes.
`summary.json` records the final concealment and timing checks.

## Memory, depth and plant checks, 6 October 2026

The rebuilt native library and Godot 4.5.1 passed 24 headless camera
assertions and 14 live actor/mesh assertions against Luanti 5.17.0 with
Mineclonia release 38561. The latter cover hiding actors in remembered
cells, showing actors down visible shafts, an intervening solid wall,
real lower-slice geometry and horizontal plantlike cards. DorfCraft's
server passed 49 assertions for observation and order boundaries.

The larger payload revealed that Luanti omits base64 padding. The client
now restores it before calling Godot's decoder, with an unpadded chunk
regression. The GPU check used the shared render service and its lock;
frames and audits are in `/tmp/dorfcraft-overseer/fog/`. Server CPU units
still occasionally exceed labour's hard budget; the large eight-level
performance target remains unverified.

The final RTX 3090 service capture used verified High settings at 1280 by
720. Real cobble floors at depths one, one, two, three, five and eight
showed accumulated blue-white haze, alongside overhead-facing grass and
flowers. Unavailable space sampled RGB (67, 74, 81), distinct from the
unexplored (0, 0, 0). The final capture had no new shader or snapshot
reassembly errors. Nine vanilla fallback/reconnect checks also passed.
The service was stopped and `gpu-free` confirmed no clients or driver
errors. DorfCraft's overseer document records the remaining CPU limitation.

## Discovery and shaft shadow verification, 6 October 2026

Godot 4.5.1, rebuilt Goanna, Luanti 5.17.0 Flatpak and Mineclonia release
38561: 30 camera assertions and 15 live actor/mesh assertions passed. The
server passed 58 assertions, including long-range discovery, concealment
behind a distant wall, movement during a survey and known shaft walls.
DorfCraft's default sight range is now 192 nodes. Discovery is incremental;
this does not establish large-fortress performance. Some layer and sight
work units still exceeded labour's 4 ms hard budget in the GPU scene.

The RTX 3090 render service held the shared lock for the High, 1280 by 720
comparison. Known shaft walls cast shadows across the actual cobble floors.
At time fractions 0.35 and 0.65 the floor shadows moved from the right side
to the left. Both captures used the same open view and sun energy 1. The
sun directions were (0.721, 0.693, 0) and (-0.721, 0.693, 0). No lighting
code adjustment was needed for this movement; the added tests guard the
sun and moon direction updates. The captures reported no shader errors.

The preceding noon, sunset and midnight comparison only established colour
and exposure changes: the noon sun and midnight moon were both overhead,
and both direct lights had zero energy at the selected sunset time.
Those images were insufficient evidence of shadow movement. The fixed
inner edge and depth haze are not cast shadows. Sky-fill emission reduces
contrast but did not prevent the morning/afternoon shadows from appearing.

Frames and light directions are in `/tmp/dorfcraft-overseer/shadow-pass/`;
the earlier depth, exposure and actor checks are in
`/tmp/dorfcraft-overseer/depth-pass/`. See DorfCraft's `docs/overseer.md`
for coverage measurements and the remaining CPU budget limitation.

## Mountainside core loop verification, 6 October 2026

Godot 4.5.1 dummy rendering, Luanti 5.17.0 Flatpak and Mineclonia release
38561: 32 camera checks, 83 server checks and 12 live core-loop checks
passed. `project/tests/overseer_loop.gd` uses actual native planning
requests and a real worker while the view stays open. The worker dug a
two-high tunnel and a side bedroom, felled a tree, harvested a berry bush,
built a wall, replaced the floor below, and installed stairs, a bed and a
door. The room system then recognised a usable bedroom.

The camera tests include material filtering and facing controls. Server
checks include headroom bounds, floor cancellation, protected furniture
footprints, all bed facings, door opening, automatic stair corners,
renewable bush harvesting, drops and wide trunks. The final stair-corner
and wide-trunk changes were exercised in the server action suite.

Construction uses stocked finished items; the test did not craft them.
Furniture adapters currently cover Mineclonia beds and doors, and the
harvest adapter covers ripe sweet-berry bushes. Layer assembly still
exceeded the server's 4 ms hard work-unit budget in the small live scene.
No GPU client was started for this pass. Logs are under
`/tmp/dorfcraft-overseer/core-loop/`.


## Core planning UX, 6 October 2026

`project/overseer_ui.gd` supplies the labelled tool families, contextual
panel, navigation and Plans view. The renderer remains in `overseer.gd`.
Two corners now create a draft; Submit plan explicitly sends it. Existing
live tests were updated to exercise that extra step. Drafts stay anchored
when changing levels, retain their parameters after refusal, and retry
with an identical request ID. Leaving still discards local draft state.

The server supplies capabilities and action metadata. This uses DorfCraft's
existing broad rights; the planned multiplayer role API and drafting-table
mechanics are not built. Ledger and production management remain outside
this interface. The vanilla formspec has the same draft and Plans flow.

Godot 4.5.1, Luanti 5.17.0 and Mineclonia release 38561: 32 camera checks,
21 UX checks, 10 live fallback checks and 12 fresh-world core-loop checks
passed. The server passed 99 assertions. Normal and 200 percent text were
captured in a headless GPU client under the shared lock, including a
960 by 640 window. Logs and frames are in `/tmp/overseer-ux/`.

Keyboard targeting and initial controller/touch paths exist. Actual device
usability, remapping and screen-reader output remain unverified. Large
text scrolls instead of shrinking controls. The optional minimap, saved
projects and workstation planning contexts remain future work. Existing
layer-generation budget overruns are unchanged.

## Local modpack activation, 7 October 2026

A new DorfCraft world failed because the local launcher treated a selected
modpack directory as one mod. It enabled the similarly named founding mod
without `labour` or `calendar`. `local_server.gd` now expands nested packs
into declared leaf mod names, including legacy `modpack.txt` packs. World
options restore the menu's pack selection when all its members are enabled.

`tests/local_server_modpacks.gd` passed five checks under Godot 4.5.1's dummy
renderer: nested members, declared names, restoring selections and removing
members when deselected. The installed DorfCraft package resolved to 35
members and loaded on Luanti 5.17.0 with Mineclonia 38561 in a scratch world.
No GPU or client rendering was used for this launcher test. The existing
DorfCraft playtest and the new-world activation failure are distinct paths;
this fix does not claim to diagnose every reported loading or input issue.

## Primary-button item use, 7 October 2026

The current native interaction path ignored `ItemDefinition.usable` and
sent digging or punching packets for items with `on_use`. It now sends
`INTERACT_USE` on the primary-button press, including when pointing at air.
Holding the button does not repeat the callback. Switching from digging to
such an item cancels the dig and waits for a fresh press before using it.

`tools/test/test-item-use.py --dorfcraft /path/to/DorfCraft` runs a disposable
Mineclonia world through the installed Luanti Flatpak and Godot's dummy
renderer. Its fixture wraps the real callbacks to count packet delivery;
`project/tests/item_use.gd` drives `step_interact`, rather than opening the
mode through a chat command. Godot 4.5.1, Luanti 5.17.0 and Mineclonia 38561
passed 21 checks: designation corners, the room form, the chisel's material
validation, opening an Overseer session with an air click, restoring
interaction on exit, held-button and tool-switch behaviour, and ordinary
pickaxe mining. This is an input/protocol test, not a new rendered-camera
or completed-engraving test. No GPU client was started.

The rebuilt native library requires restarting Goanna. This establishes a
missing primary-button path in the current client; it does not establish
which input or client build was used in the earlier successful playtest.

## Terrain replacement and dwarf pose checks, 7 October 2026

A whole `BLOCKDATA` replacement refreshed only its own mesh. The assumption
that content edits always arrive as individual node packets was false:
server-side voxel writes can replace a block without those packets. A
changed replacement now invalidates all six loaded face neighbours, just
as the first arrival does. Identical resends still skip mesh invalidation.

`tools/test/test-block-updates.py` runs a Mineclonia fixture which removes a
sealed dark room above a mapblock boundary through VoxelManip. Under Godot
4.5.1's dummy renderer, Luanti 5.17.0 and Mineclonia 38561, the old client
kept zero floor vertices after the cut; the rebuilt client produced 64.
The retained test also checks that the room became air and the floor node
stayed stone. Both the scratch reproduction and the saved runner passed
with the fix. This establishes one missing-face path, not every possible
cause of the maintainer's screenshot. Logs: `/tmp/overseer-tree-head/` and
`/tmp/goanna-block-updates-j0klg4j4/`.

A separate dummy-client probe kept exactly two dwarf skeletons through
three cycles of sleeping, waking, appearance changes and entity replacement
(12 checks). It did not reproduce the reported apparent duplicate bodies.
DorfCraft corrected an independently verified server head-bone offset;
its `docs/dwarf-body.md` records that fix and the server tests, including a
failure in the broader combat suite. Neither test used the GPU or the
maintainer's running world.
