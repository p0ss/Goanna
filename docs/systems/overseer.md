# Overseer camera

Implemented on 6 October 2026 with DorfCraft's `overseer` mod. The server
specification and verification record are in DorfCraft's
`docs/overseer.md`. This is the first orthographic planning slice,
including level changes. The initial flat-cell renderer has been replaced with
real world geometry and live entities. The verification of each revision is in
the [overseer log](../history/overseer-log.md).

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

## Planning interface

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
