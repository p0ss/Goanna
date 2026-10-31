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

Each open plan on the viewed level carries its tool's rune once, on the
plan's cell nearest its middle, above the coloured state outlines. The
rune comes from the tool list's `rune`, matched by the order's kind: a
tool id, a tool prefix (`farm` of `farm:wheat`) or a room kind. Done
cells draw none.

The footer's Marks toggle appears when the server answers `{t = "marks"}`
(DorfCraft's world marks): it shows or hides the player's planned work in
the world, which the server draws as shaded outlines with the same rune
for every client. The choice is kept on the server, for vanilla clients
too (`/marks on|off`).

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

Houses are DorfCraft's co-op households (its `docs/tasks/coop-fortress.md`).
A layer may carry `houses`, `{[id] = {surname, head, colour = "#rrggbb",
pattern}}`, and `house = id` on rooms, zones, locks, stations and orders.
A housed entry's known cells get a faint fill of the house's field pattern
in the house colour, under every other sheet and outline, always shown like
the designations. The pattern is drawn by a shader in world node
coordinates, so it runs on across a room, and its edges are smoothed by
screen derivative, so it stays crisp from close zoom to the widest view.
It knows DorfCraft's `R.field_patterns` (diaper, semy, chequy, lozengy,
paly, barry, bendy, fretty, masoned, gyronny); any other id gets a plain
diagonal hatch. Unhoused entries, entries naming a house the layer does not
list, and a house marked `owner = true` look as they did before houses.
The Access toggle draws the `access` overlay, `{pos, state, house}`: a
shared cell is a ring in the house colour, a locked one a thicker ring with
a solid corner, so the two read apart even in one colour; a mark naming no
listed house is off-white. The Houses toggle draws an ownership field: one
sheet over the layer, a texel a cell, so a glance shows the fortress
divided among houses. Each cell keeps its own house's colour; where two
houses meet a dark rule a fifth of a cell wide separates them, so near
colours still read apart (two blues read as one in the first live run),
and towards unheld ground the tint fades over the cell's outer half. A cell is held by its access mark, else the room it lies in,
else a housed plan, zone, lock or station on it; cells with none stay
clear. The owner's house tints too, paler and with diagonal stripes. While
the field is on it replaces the patterned fills rather than sitting over
or under them: both say which house holds a cell, and two tints of one
colour on the same cell only muddy it. Inspect says "Held by House X" and
which source decided it. It is built from the data above; the server
sends no per-cell field. Inspect and Plans add "(House Surname)" after
the room, zone, lock, station, order or author, and Inspect says what a
shared or locked mark allows. An older server sends none of this, and the
view is unchanged.

The Houses section of the rail (with the server's `Houses` rune when its
signposts name one) holds the server's House access tools and the Houses
page, from DorfCraft's `{"t": "houses"}` request, which the server pushes
again on every change. The page lists each house with a swatch of the
fortress pattern in its colour, its head as "Ana of house Stonehand" (the
server's `head_title`), and its workers. The owner gets the open to
settlers toggle and Banish, which first sends the action without
`confirm` and shows the server's confirm text with Confirm and Keep them.
Offices show their holder; one the viewer may fill has a candidate picker
with Appoint and Vacate. The viewer's own workers have a checkbox per
labour, sending the whole list, and a workshop picker. The stream of work
picker stays disabled with the reason while the server offers no streams.
A house the viewer heads, or any house for the owner, has a rename row
for the head's first name and the surname; only changed names are sent.
Every action is one `{"t": "house", "req", "op"}` through the view's
pending request, so a retry reuses its id, and a refusal redraws the page.
Colours come from the server; the client hard-codes none.

The view sends its keep-alive before handling the frame's messages and
again between them, and handles messages within 8 ms a frame, leaving the
rest for the next. On 31 October 2026 the first view of a live session
kept the client silent for 15 s and the server timed it out; this keeps a
backlog from starving the ping. Whether the stall itself is gone has not
been checked live: the synthetic CPU benchmark puts the GDScript side of a
63 by 63 first view under 100 ms, so it may lie in the native mesher.

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

`res://tests/overseer_houses.gd` checks house parsing, fills, access marks
and the house in Inspect and Plans the same way, headless.
`res://tests/overseer_houses_render.tscn` renders every pattern and both
access marks from a synthetic layer with no server, through
`tools/goanna-headless fixture ... --software`; frames go to `$GOANNA_OUT`.

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
Refresh. When the server sends `tables` (DorfCraft's table shape,
`docs/interface-rules.md`), each is drawn by the shared table widget,
`ui/data_table.gd`, covering the map; see "Tables" below. A server that
sends only the older `people` and `supplies` lists keeps the older side
panel text. The client never infers worker positions or stock totals.

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

### Tables

`ui/data_table.gd` is the one table widget for every list a game sends
(`interface-layout.md`, "Tables"). It draws the server's table shape:
a title, a search box filtering every text cell as you type, the
server's filters as dropdowns, a Tree whose headings sort (again to
reverse; the sorted heading shows its direction), right aligned numbers,
the row's rune leading it, and the note below. A locked row is greyed
with its reason as the tooltip. With no rows it shows the server's `why`
and `what`; when a search or filter empties it, "No rows match." and one
Clear search and filters button. Typing on the rows goes to the search
box; Down from the search box returns to the rows; arrows move the row
and Enter activates it. A refresh of the same table keeps the player's
sort, search and chosen row. Two row fields beyond DorfCraft's shape:
`keys` (what a column sorts by) and `detail` (lines for the detail).

The overseer uses it for People, Supplies and the workshop picker. The
table covers the map; the map's navigation box and overlay toggles step
aside (the toggles shown come back as they were, so a task view's scoped
overlays survive), and the context panel shows only for a chosen row:
its other columns, its detail lines, a locked row's reason, and one
accent action, Show on map for a row with a place (back to Select,
centred, with the cursor on it) or Use this workshop. Back clears the
chosen row before leaving. Page Up and Page Down scroll the table
rather than change level, and the right shoulder button focuses the
rows.

Set up workshop opens the picker in place of the old dropdown, ready
workshops first. A greyed workshop cannot be chosen. After choosing,
the context panel names the workshop and its requirements once, with
Change workshop. Unavailable tools and verbs elsewhere are now greyed
rather than labelled "(unavailable)", and a vanished draft material
shows its title, never its id.

`tests/data_table.gd` (21 checks) and `tests/overseer_tables.gd` (34
checks) are structural, under Godot 4.5.1 `--headless`. With them, on 1
November 2026: overseer 83, overseer_ux 45, overseer_verbs 26,
overseer_runes 25, overseer_houses 55, all passing.

`tests/overseer_tables_render.tscn` captures the three screens from a
live server at the window size and at 200 percent text. DorfCraft's
`mods/kindred/settlement/overseer/tests/tables_live/run.py` starts the
server, founds a real fortress (seven founders, 25 kinds of supply) and
runs it through `tools/goanna-headless fixture --software`. Frames and
the checklist answers are in DorfCraft's
`reviews/kindred/settlement/overseer/tables/`. It needs the official
Godot 4.5.1 build (`GODOT_BIN`): the nixpkgs build aborted with
`free(): invalid size` as soon as the scene's client connected.

What does not work: at 200 percent text in a 1280 by 720 window only two
or three columns show at once (the rest scroll sideways); before this
change the footer's status wrapped a letter at a time at 200 percent and
covered the window; the status now stays one line, but the map screens'
footer, still nine toggles in a row, was not captured at 200 percent
since (the View menu is the later fix);
the rail's labels wrap ("Supplie s") at 100 percent. Device input
(controller, touch) was exercised only through synthetic events in the
structural tests.

### Screens, second pass, 1 November 2026

The rest of DorfCraft's "Screens to bring in line" for the overseer
(`interface-layout.md`; DorfCraft `docs/interface-rules.md`), with the
maintainer's rulings of 31 October and 1 November 2026.

- **Header and rail.** Select and Map focus are header tools beside the
  view's name. The rail holds two groups under quiet headings, Plan (Zones,
  Build, Terrain, Gather, Devices, Defence) and Fortress (People, Supplies,
  Houses, Plans), 24 px apart. Labels never wrap: the rail is as wide as
  its longest shown label, up to a quarter of the window, and scrolls
  sideways past that at large text. Its buttons are 40 px high, the
  rule's least, and the rail runs to the window's foot with the footer
  beside it, so both groups fit at 1280 by 720; at 200 percent text it
  scrolls. Hidden sections are absent, and a
  heading goes with its last section; locked ones stay greyed with the
  server's reason, as before.
- **View menu.** The footer has the status, one View menu and Legend. The
  menu lists each overlay as a check item and, once the server answers,
  "Plan marks in the world" (DorfCraft's marks part). The button names
  what is on ("View: Heat", "View (2)"). A task view lists only its
  task's overlays with the first on, and shows no menu when it has none.
  Legend stays its own quiet button: it is help to read, not a setting,
  and inside the menu it would take a second click to find. It now names
  the night watch's small pale blue squares, which no legend explained;
  task views other than Defence leave the militia's stations, rings and
  watch out (`drawn_zone_marks`).
- **Plans.** When the server sends a `table` with its `plans` list, Plans
  covers the map with the table widget, danger and blocked first. The
  chosen row's detail and its actions (row field `actions`: id, label,
  `primary`, help) sit in the context panel; the server's primary action
  takes the one accent, else Show on map does. Choosing a new page marks
  it read; the Progress verb opens Plans with its plan chosen. An older
  server keeps the older list.
- **Houses.** The `houses` message's `table` covers the map: house, head,
  players, workers, colour (column kind `swatch`: the widget leads the
  label with a square of the row's `swatch` colour) and access marks
  shared and locked. The owner's controls, offices and the head's workers
  open from Offices and workers; the access tools from Mark access; each
  has Back to houses, and Back does the same.
- **One task per panel.** While any table covers the map, the map's tool
  list is not shown beneath its detail. The workshop picker shows no
  context panel until a row is chosen, then that workshop and Use this
  workshop only. With a workshop chosen, the panel is that workshop's,
  with Other Build tools in place of the tool list.
- **Grouped tools.** The member picker (Crop, Room type, Storage type)
  now shows for any family's grouped tool, so DorfCraft's Build Shape
  group (Line, Wall, Box and the rest) can be changed from its first
  shape.

`tests/overseer_screens.gd` (structural, 57 checks) covers all of this.
On 1 November 2026, with Godot 4.5.1 headless: overseer 83, overseer_ux
45, overseer_verbs 26, overseer_runes 24 (one fewer: Select left the
rail), overseer_houses 55, overseer_tables 33 (the check that the Build
tools stay beside the picker is replaced by its opposite), data_table 21
and overseer_screens 57, all passing. The table widget's first column now
keeps room for 14 characters.
