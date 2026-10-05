# Local multiplayer architecture

Splitscreen is experimental. Tests cover player ownership, input, menus,
shader parsing and real server connections. A rendered benchmark exercised
one, two, four and six players on an RTX 3090 with Godot 4.5.1 and a Luanti
5.17.0 Mineclonia server. Four players averaged 80 FPS in an inward-facing
circle and 34 FPS while streaming separate areas at 1080p on Low; six
averaged 51 and 22 FPS. These are specific workloads, not hardware guarantees.
See the [benchmark report](perf/local-multiplayer-2026-09-27/report.md).
A real-controller play session and broader visual review remain outstanding.

## Starting it

Choose **Local players** in the main menu, add the players, assign controls
and save. Then use **Start Game** or **Join Game** as usual. Player 1 uses
the name and password from the launch screen. Other players have separate
names and, when needed, server passwords. Names and control assignments are
remembered; passwords are held only in memory.

One player can own the keyboard and mouse. Each other player owns a
controller. An unassigned player displays a prompt to press Start on an
unused controller. Unplugging a controller releases held actions and returns
that slot to the prompt. Reconnecting does not assume the controller keeps
the same device ID.

Two players can split horizontally or vertically. More players use a grid.
The slot collection and layout have no four-player limit. A final incomplete
row leaves unused cells. Very small player rectangles still need a visual
and usability review, particularly for server forms.

Local play starts on its own Low graphics profile. The local setup screen
can select Medium, High or Ultra. Other settings come from the shared main
menu settings; in-game settings changes are deferred to that menu during
splitscreen. A single-player launch retains the existing game scene.

For a developer launch against an existing server, `GOANNA_LOCAL_PLAY=4`
creates four slots: the launch name with keyboard/mouse, then names suffixed
`_2`, `_3`, `_4` with available controllers or a join prompt. The variable
also accepts a JSON array of dictionaries with `name`, `device` and optional
`password`. Device `-1` means keyboard/mouse and `-2` means unassigned.
Use the normal headless launcher when testing rendered clients.

## Ownership

`project/local_launch.gd` transfers the roster and the locally launched
server from the menu. `project/local_play.gd` owns that server, the window
input routing, layout and the collection of `player_slot.gd` instances.
Each slot owns:

- A `SubViewport` and a distinct `World3D`.
- A game scene, native `GoannaClient` and Luanti session.
- Its camera, environment, terrain, entities and sound sources.
- A gamepad state machine, UI focus, cursor and inventory/formspec UI.

Every player authenticates as an ordinary client. The server remains the
authority for player state, inventory actions and world changes. Sessions
do not merge received map data or entities. A player can leave without
disconnecting the others. The shell stops its owned server after its final
player leaves or the application closes. Remote servers are never stopped.

Screen peeking can help local players coordinate, much like separate
machines in the same room. This does not give their connections extra
server authority. Each player occupies an ordinary server slot and remains
subject to the server's account, team and spectator rules. Shared terrain
work must require matching data already received by each connection; it
must not merge discovery, entities, inventories or permissions. A spectator
view remains whatever that player's server permissions allow.

`owned_process.gd` tracks the launched PID and, on Linux, its process start
identity. Shutdown visits only that process's descendants and checks their
identities before stopping them. It does not match process command names or
world paths. Flatpak and Windows launcher shutdown still need platform
testing with this ownership path.

## Input and UI

The menu keeps the original Gamepad autoload. The shell disables that
autoload while playing and forwards events to the assigned viewport.
Player gamepads keep event-derived action state rather than polling
Godot's application-wide action state. Each slot remembers its UI focus and
restores it before delivering input, since Godot transfers focus between
subviewports in one window. Inactive slots draw their remembered menu focus.
The built-in D-pad mappings are also extended beyond controller 0. Virtual
mouse and key events use `Viewport.push_input`, so one player's cursor cannot
click another player's form.

Keyboard state belongs to its assigned slot. Only the shell changes the
window's mouse capture mode. A game scene records its own play/menu state,
independent of the window mode. Opening an inventory or pause menu stops
that player's controls while the other players keep playing. It does not
pause the Luanti server.

`player_context.gd` resolves game and particle helpers within the caller's
viewport. Code that previously selected the first game in a SceneTree group
now finds the game owning that UI or effect.

## Rendering and native state

Godot shader globals are shared across worlds. `GoannaClient` therefore has
an optional `RenderScope`, enabled before a slot creates any material. It
registers distinct global names for that client and loads cached shader
variants using those names. Includes are expanded through Godot resources,
then complete identifiers are replaced. Original shader files stay shared
on disk. Standalone games and material studies retain the original globals.

Sky, underwater state, weather, wakes, ice transmission, light reach and
node animation publish through the owning client. Terrain, entity, grass
and presentation shaders use its variants. Leaving a slot releases its
shader bindings without removing another player's bindings. Ice visibility
queries also filter by the source camera's world.

Mining prediction and crack history belong to their client/session. Each
session owns the stored damage its server has sent; mesh workers snapshot
that store. The upstream mesher's live carve pointer is thread-local and
bound only while the owning client's synchronous meshes are processed.
No Luanti submodule or transplanted source changes were required.

Persistent terrain stores are separated by player identity below the
existing world/server paths, avoiding simultaneous writers and the sharing
of one player's received terrain with another. Texture packs and global
graphics choices remain common to the application.

## Resource policy and remaining work

The shell divides a small mesh-worker allowance and the existing terrain
poll budget between active slots. There is at least one worker per player.
These are scheduling allowances, not hard frame-time limits: completing
one mesh can exceed a time slice. Each connection retains its own received
map and visibility decisions. Experimental process caches now reuse:

- Prepared near-block geometry when the server, definitions, media, texture
  layout,
  palette, meshing settings and all 27 block inputs match. Unknown neighbours
  have a separate identity. Active cracks and persisted carves bypass reuse.
- Immutable LOD hierarchies built from matching received node data or a
  matching serialised block read from that player's own store. Prepared visual
  definitions are part of the identity. Concurrent
  requests for the same hierarchy use one builder.
- Identical near-region GPU meshes without procedural grass, plus glow
  meshes. Each view binds its own materials on its mesh instance. Grass
  changes rebuild that view's region rather than mutating a shared mesh.

Single-view play bypasses the near CPU and GPU caches. GPU reuse is keyed
from the worker snapshot's compact input identities; publication does not
hash the completed vertex buffers on the main thread.

The estimated cache budgets are 128 MiB for near geometry, 128 MiB for GPU
mesh source arrays and 64 MiB for LOD hierarchies. These are eviction
allowances, not whole-process RAM limits: published resources and work in
flight can outlive an entry. Network receipt, map decoding, view selection,
far-region mesh assembly and draw calls remain per player. Near geometry
reuses completed results; simultaneous first misses can still duplicate
work. Immutable texture sharing and a common residency budget remain open.

`GOANNA_NO_SHARED_TERRAIN=1` bypasses the caches for a fresh-process control.
The local benchmark exposes this as `--no-shared-terrain`. Render statistics
report per-view `shared_near_hits`, `shared_near_builds` and
`shared_upload_hits`; `shared_lod_hits_process` is process-wide and must not
be summed across players. A hit count is evidence of reuse, not a frame-time
saving. Validation and timings are recorded in the
[tier cycle](perf/tier-cycle-2026-09-27/report.md).

Every player's viewport listens to its own world. Sound gain is reduced as
players are added. Duplicate world sounds and music are not yet deduplicated;
the audio mix needs listening tests. There is no separate headphone output
per player. Asset downloads and development control endpoints currently
belong to the first slot; the control channel does not yet select players.

## Validation

On 2026-09-27, Godot 4.5.1 with its dummy headless renderer connected four
and then six players to an unmodified Luanti 5.17.0 server running devtest
with a small test fixture mod. Each player received a distinct inventory.
An ordinary
inventory action changed only its owner's inventory, and the remaining
connections stayed ready when one player left. This was a protocol and
lifetime check, not a rendered playtest.

The native `check` target passes, including independent carve stores. These
Godot scripts require no GPU:

```sh
godot --headless --path project --script res://tests/local_play.gd
XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/local_play_scene.gd
godot --headless --path project --script res://tests/local_play_menu.gd
godot --headless --path project --script res://tests/owned_process.gd
```

Use disposable `XDG_DATA_HOME` and `XDG_CONFIG_HOME` directories for the
scene and menu checks, which exercise settings persistence. The routing
check exercises four players and layouts through nine players. The scene
check uses four real game scenes with networking disabled.

The server test creates disposable data under `/tmp`, binds only loopback,
starts Godot with `--headless`, and stops its own server in a `finally` block:

```sh
python3 tools/test-local-play.py --godot /path/to/godot \
  --server /path/to/luanti --players 4
```

Rendered circle and separate-area streaming views have been inspected and
benchmarked. Simultaneous underwater/surface views, different weather, real
controller focus and cursors, inventories at small sizes and audio mixing
remain untested on the GPU.

## Benchmark harness

`tools/bench-local-play.py` runs 1, 2, 4 and 6 players, then repeats the
single-player control. It uses one Godot process at a time, through the
headless gamescope launcher, with a fixed 1920 by 1080 total resolution and
the Low profile by default (`--profile` selects another tier). The first
case uses the ordinary single-player
scene. The others use the local shell and its shared worker allowance.

Supply the existing Mineclonia test world and game paths:

```sh
tools/goanna-headless gpu-free
python3 tools/bench-local-play.py \
  --world /path/to/test_world --game /path/to/mineclonia \
  --output /tmp/local-benchmark
```

The output directory must not already exist. The harness takes a read-only
SQLite backup of the source databases, then gives each trial its own world
copy, loopback server and client data directory. It leaves the source world
untouched. Every launched client and server is stopped on completion or
failure. Run the availability check and harness with host GPU visibility;
the restricted sandbox can hide both devices and other clients.

Each trial records three 45-second workloads: players on an eight-node-radius
circle looking towards its centre, separate areas 192 nodes from the centre,
then flight at eight nodes per second in different directions. Camera
positions use Godot coordinates, with the centre at `(-72, 64, 378)`.
The fixture grants ordinary teleport and fly
privileges. Initial positioning uses the server's teleport command and
checks its response; moving only the camera across a large distance can
leave the server streaming the old position. Fixed-height routes can cross
terrain, so inspect the saved composition screenshots and terrain counters
before accepting a result.

`project/local_bench.gd` extends the existing recorder. Frame periods cover
the entire application. Render CPU/GPU counters are summed across player
viewports and the root composition, with frame setup counted once. These
sums are diagnostic work totals, not independently measured GPU elapsed
time. Per-player terrain counters, viewport sizes, application video-memory
estimates, process RSS and whole-GPU memory/utilisation samples accompany
the frame CSVs. Whole-GPU samples include the desktop.

`--phases` selects workloads. `--feature-sweep` measures individual rendering
switches with restored controls in stationary scenes; effective settings and
feature state are recorded per player. See
[render feature switches](render-feature-switches.md) for the command and
limitations. Streaming comparisons require separate fresh trials.

Unsettled trials are flagged, and rendered trials with no terrain meshes
are rejected. Raw data is saved rather than automatically declared a valid
comparison. Check screenshots, errors, queue convergence and the repeated
control before drawing conclusions. Asset updates are disabled and the
profile starts without a texture pack; this is not a measurement of an
installed PBR pack.

`--dummy --players 4 --seconds 3 --settle-timeout 20` checks orchestration
without GPU rendering. Its frame times are not graphics performance. A
dummy-renderer smoke run exposed a mesh-worker shutdown race while local
slots changed their worker allocation. The stop predicate now changes under
the condition-variable mutex; the native regression check repeatedly starts
and stops idle pools.

On 2026-09-27 the four-player dummy-renderer smoke check completed against
Luanti 5.17.0 and the installed Mineclonia game using a disposable copy of
`test_world`. Both stationary workloads reached the queue-settling check;
each player had terrain meshes and a 960 by 540 viewport. The movement
workload completed without script errors. Native checks passed after the
worker fix. After the GPU became available, the rendered sweep completed
with all player counts and a repeated single-player control. The report
above preserves measurements and captures. Its stationary median-frame-time
control drift was below 3%; concurrent streaming and client RAM remain the
main performance concerns on the tested desktop.

`--check-worker-reset` changes player 1's worker allocation while a regional
batch is in flight, then requires every view to drain before and after
restoring the allocation. It runs after timing. The settling check includes
near-region dirty/building counts: an empty worker queue alone cannot prove
that cancelled work has been resubmitted. `--wall-check --scene occlusion
--phases together` checks closed, open and restored geometry and lamp
visibility after recording, retaining each view's shared mesh and material
identities.

Cloud sampling sweeps hold the sky's cloud offset at the fixture's
`sky_cloud_offset`, so different sample counts see the same moving-cloud
position. This is a development recorder override, recorded in scene
evidence; ordinary gameplay clouds keep their server-driven movement.
