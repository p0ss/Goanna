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

`project/game/overseer.gd` sends an explicit ready message after joining,
asking the server to send neighbouring levels ahead (`prefetch`). It
opens the camera from the server's hello, requests bounded rectangles,
reassembles bounded chunks and submits planning requests.

It keeps up to eight layers the server sent for the current rectangle, by
level, each with its meshes in a hidden node. Stepping to a kept level
shows it at once while the fresh layer is requested. Until that arrives
every cell is demoted to remembered, so no live actor shows from the kept
copy. A new rectangle, an empty or stale layer, or closing the view drops
them all. A layer for another level is kept only if it answers the current
request's sequence. Server removal
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

Changed mapblocks are rebuilt within about 4 ms a frame, at least one
each frame. Unchanged meshes survive the one-second observation refresh. Live worker dig/build events update those
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

The footer's Rooms and Miasma toggles draw the layer's overlays as
translucent sheets just under the order marks. Rooms are grey until the
server says every cell is known, then tinted by tier (bare, furnished,
decorated, adorned). Miasma cuts each remembered scent sphere at the
viewed level and shades only known cells, in four bands by distance.
Inspect adds the room's tier, points and read day, and the strongest
miasma source. Overlay lists are capped at 256 entries; malformed entries
are skipped, and Luanti's `null` for an empty list reads as none.

The Heat and Wetness toggles draw the seasons' climate field on the
viewed level (`climate` in the layer's overlays, DorfCraft's
`docs/overseer.md`), one sheet per 4 node cell the fortress has seen,
under the other sheets. Heat runs from deep blue at the coldest band
through a faint middle, where a fortress is comfortable, to red; wetness
from parched tan through the same faint middle to deep blue. The middle
is faint so the extremes read. Inspect adds the cell's band names, such
as "Climate: cool, damp". The same field drives the terrain's dry, damp,
moss and frost look (`docs/systems/climate.md`), so the overlay is the
way to see why a place looks as it does.

The Traffic toggle shades known cells by how often workers stand there
and marks workers on the viewed level with their recent trails. Forbidden
areas (red), locked doors (dark red), militia stations with their rings
and watch posts (blue) and protected areas (pale blue) are planner
designations, always drawn on known cells only. Protected areas retain the
pale blue designation and show server-reported guard access: partial access
adds amber diagonal hatching; unreachable adds red crosshatching. Inspect
names the state and the server's reason. Missing or unrecognised states
read as unknown, without a failure hatch or a claim of coverage. Hatches
stay inside known cells, including at unexplored edges. The Devices and
Defence tool families come from the server's tool list like the others.

Officers' pages arrive in the hello and as `page` messages. The newest
unseen danger page is a red line in the header that locates it and marks
it seen; the Plans button counts unseen pages. Plans lists pages first,
with Act and Drop, both answered by the server.

Plans proposed for this player (by the director, through the manager)
are listed as Proposed with Confirm and Drop, and their cells are
outlined in purple until confirmed.

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

On 13 October 2026, the structural suite passed 79 checks on Godot 4.5.1,
including guard-state parsing, overlapping areas, known-cell clipping and
Inspect reasons. An isolated software render-service fixture on llvmpipe
confirmed the amber diagonal and red crosshatch shaders and their unknown
cell boundary. That synthetic frame tests rendering, not guard pathfinding
or a live protected-area response.

On 14 October 2026, the planner UX suite passed 41 checks and the structural
suite passed 79 checks on Godot 4.5.1. Synthetic software render-service
frames at 1920 by 1080 and 960 by 640 checked the outlined player marker,
zone property controls, People observation text and scrolling layout.
These frames are UI fixtures, not evidence of live fortress observations.

### CPU checks

`tests/overseer_cache.gd` checks exact terrain and visibility cache keys,
including changed cells, remembered states, lower walls, node orientation,
level, rectangle, zoom, empty replies and a fresh session. The keys retain
deep copies and use exact equality; visibility does not depend on a hash
collision being unlikely. Unchanged replies preserve pending mesh work.
Overlapping zone rectangles merge their row spans before allocating cells,
and Inspect tests point membership instead of rasterising whole areas.

`tests/overseer_cpu.gd` is a synthetic dummy-renderer benchmark, excluding
the native mesher. On 14 October 2026 with Godot 4.5.1, a 63 by 63 layer
with eight lower slices took 55 to 57 ms to redraw before the cache. Its
first draw still took 56 ms; unchanged redraws took 0.33 to 0.36 ms. Thirty
two overlapping protected areas took 251 to 261 ms before row merging and
10 to 11 ms afterwards. Inspect fell from 115 ms to about 0.1 ms. The 16
cache checks, 79 structural checks and 41 UX checks passed.

A fresh Luanti 5.17.0 / Mineclonia release 38561 server and real Goanna
client with the dummy renderer passed 36 settlement checks and 12 restart
checks. Temporary timing instrumentation measured 7 to 26 ms opening the
UI, 0.4 to 0.7 ms handling hello, 17 to 19 ms handling the first layer and
up to 52 ms for a native mesh batch. First-layer arrival took 1.1 to 1.5
seconds; a short follow-up received a 27 by 27 layer with eight lower
slices without chunk messages. These runs did not reproduce a multi-second
client freeze and do not measure GPU shader compilation or natural-terrain
opening costs. No production timing logger or message-drain change was
introduced. Evidence is under `/tmp/dorfcraft-overseer-cpu-live/` and
`/tmp/dorfcraft-overseer-first-layer-wire/`.

## Planning interface

`project/game/overseer_ui.gd` supplies the labelled tool families, contextual
panel, navigation and Plans view. The renderer remains in `overseer.gd`.
Zones sits near the top of the left rail. Server tool groups become one
button each, with Crop, Storage type or Room type as a dropdown property;
the original tool IDs still carry the order. Build shows the full workshop
catalogue, including unavailable stations and their server-supplied
requirements. Missing materials prevent submission.

People and Supplies request a separate `overview` report on entry or
Refresh. People lists assignment, observed activity and observation age;
Supplies shows the embark manifest with the server's provenance note. It
is not a live stock count. Null or absent lists retain the explanatory
note. These pages do not infer worker positions or inventory totals.

The player has an outlined cyan and white marker labelled You. Find you
returns to the player's position and level; navigation shows when that
level is above or below the current slice.

Two corners now create a draft; Submit plan explicitly sends it. Existing
live tests were updated to exercise that extra step. Drafts stay anchored
when changing levels, retain their parameters after refusal, and retry
with an identical request ID. Leaving still discards local draft state.

### Noun-first selection

In Select, clicking a cell (or Enter on the keyboard cursor) selects it,
and Shift extends the selection to a box. Each selection sends one
`affordances` request with the box; the server, not this view, decides
what the selection is and which verbs apply (DorfCraft `docs/overseer.md`,
"Affordances on the server"). A verb strip opens beside the selection with
the server's answer: up to six verbs on number keys 1 to 6, the rest under
More. Tool groups (crop, room type, storage type) fold into one verb, and
the zone property control then picks the member. A verb the planner cannot
use now stays in the strip, marked unavailable, and pressing it shows the
server's reason. Only verbs naming a tool from the hello, or Progress, are
drawn; an answer to an older selection is ignored.

Choosing a verb sets the existing tool and fills both draft corners from
the selection. Nothing is sent until Submit plan, which sends the ordinary
`order` message. Progress opens Plans at the selected plan. Back clears the
selection before leaving the tool, and changing level drops it. The strip
buttons are ordinary focusable controls, reached with Tab or the right
shoulder button, and the strip is rebuilt only when its content changes so
a layer refresh does not take focus away. Each verb, tool and tool group
also draws the icon the server names (`icon`, `group_icon`) from
`project/ui/overseer_icons/`, so an icon means one thing everywhere: a bare
glyph acts on what is there, a dashed frame marks a zone and builds
nothing, a plus means workers add something from stock. A name this client
has no icon for, or a malformed one, draws the text label alone.

`tests/overseer_verbs.gd` (structural, 26 checks) covers the request, stale
answers, unknown tools, number keys, grouped verbs, unavailable verbs,
Progress, mixed and empty answers, refusals, Back, level change, More and
the icons.
`tests/overseer_verbs_live.gd` fells two trees on the scratch overseer
server: one by mouse (click the trunk, click Fell, click Submit plan) and
one by keyboard only (arrows, Enter, 1, Tab to Submit plan, Enter), each
through `Viewport.push_input` in a 1280 by 720 headless window. Its
keyboard part starts by giving the map focus directly rather than
tabbing to it.

On 24 October 2026, with Godot 4.5.1 headless, Luanti 5.17.0 and
Mineclonia release 38561, the live test passed all 12 checks: the server
offered Fell for each observed trunk, accepted both plans, and a worker
felled each tree. The server's own self-test passed 377 checks in the same
run. The structural suites passed: verbs 23, overseer 79, UX 41 and cache
16. Before this run Goanna could not open the view at all, because the
server's package consolidation had renamed the HUD grant and channel; the
server now uses `dorfcraft:overseer` and `dorfcraft:o:` again.

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


On 27 October 2026, the full four-package DorfCraft snapshot `f74a5269`
produced a 68,608-byte opening reply. Its chunked `hello` was discarded
because the receiver accepted only chunked `layer` replies. The receiver
now accepts both. The headless contract suite passes 83 checks, including
an opening reply larger than one packet. A scratch Luanti 5.17.0,
Mineclonia 39603 and Godot 4.5.1 session received the opening reply and a
terrain snapshot, then restored speed, jump and gravity to one on leaving.
This checks the protocol and server restoration, not Wayland pointer capture
or rendered acceptance. Pointer capture now happens after the isolated
viewport is removed during exit.
