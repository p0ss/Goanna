# Agent interfaces

Goanna has two agent-facing interfaces with different authority. They may
share implementation utilities, but they are not two permission levels of one
public protocol.

## 1. Game development interface

The existing control channel and `tools/goanna-mcp` are the game development
interface. It is a local, privileged test instrument. It may inspect renderer
state, move the camera, teleport a test player, change settings, capture frames,
reload shaders and execute GDScript. See `docs/agents/control-channel.md`.

The first versioned surface is `goanna-dev/0.1`. Its structured `inspect`
operation covers capabilities, the Godot scene tree, render state, active PBR
materials, sky, entities, inventory and world nodes. This keeps routine agent
work discoverable while the existing arbitrary `run` operation remains
available for exceptional development investigations.

This interface is unsuitable for gameplay agents. Loopback binding is useful
protection against remote access, but it does not turn `eval`, `run` or
arbitrary method calls into safe player capabilities.

Its UI commands (`ui_tree`, `ui_click`, `ui_hover`, `ui_type`, `ui_scroll`,
`key`) belong to it too. They push input events inside the client and read
the open form, which is test tooling, and they send the server nothing a
player's own clicks would not send. They are not a player agent action
vocabulary.

### Rules for test clients

`AGENTS.md` states these rules in brief; this section is their detail.

Agents testing Goanna have taken over the owner's desktop while the owner
was using it: clients opened in front of their work, took the focus and
grabbed the mouse, once in the middle of a video call, and an agent tried to
move a client's pointer with xdotool. Agents have also, four times, left
the NVIDIA driver needing a reboot. So:

#### Two kinds of headless

"Headless" means two different things here, and the difference decides
whether a client touches the GPU:

- **Godot's `--headless`** is Godot's own dummy display and renderer.
  Nothing is drawn and nothing touches the GPU, so there is no frame to
  save, but the scene tree, the control channel and its UI commands all
  work. Use it for forms, state and anything that needs no picture.
- **Headless gamescope** is gamescope's headless backend: a compositor
  with its own nested X display and no output. The client inside it
  renders for real, on the GPU (or on lavapipe with `--software`), and no
  window reaches the desktop. `tools/goanna-headless`, the MCP server and
  the render service all run clients this way.

The rest of this document says which one it means.

#### The desktop

- Test clients run in headless gamescope through `tools/goanna-headless`
  or the MCP server (`goanna_session action=start`), or under Godot's
  `--headless`. A window on the desktop only when the owner has asked to
  watch one.
- Never inject input into the owner's display (`DISPLAY=:0`,
  `WAYLAND_DISPLAY=wayland-0`, or whatever the desktop's are) with xdotool,
  ydotool or anything else. Drive clients from inside, with the control
  channel's UI commands. The vanilla client is not driven at all; it is
  framed from the server side and photographed through gamescope.

#### Benchmarks on the desktop

Frame rate, 1% lows, hitch counts and a CPU or GPU bound verdict depend on
the real present path: the desktop compositor, the display's refresh and
the driver's presentation queue. Headless gamescope has none of them, and
under it the GPU idles at low clocks between presents. So a benchmark that
reports absolute frame pacing, `tools/bench/goanna-bench.py`, opens a real
window, and that is the one exception to the rule above:

- Desktop benchmark runs are run by the owner, or by an agent only when the
  owner has said the machine is free.
- They take the GPU lock themselves for the whole run, waiting for it
  (`--lock-wait`, by default until it is free), and make the same checks as
  `tools/goanna-headless` before the first client: no other game client or
  compute job on the GPU and no recent driver errors. `GOANNA_GPU_LOCK`
  names another lock file, and a lock the caller already holds is used.
  `--dry-run` takes the lock and makes the checks without starting a client.
- Agents may run headless A/B comparisons (`tools/bench/bench-local-play.py`,
  `tools/bench/far-baseline.py` against a headless client, the render
  service's `timing`). They are valid only as relative results: one case
  against another in the same run, never against a desktop number.
- Every benchmark report records its mode, desktop or headless.
  `goanna-bench.py` reads it from the client and prints it under the
  report's title; `bench-local-play.py` records `mode` and `relative_only`
  with every result; `far-baseline.py` records them in its manifest.
- A headless A/B result that will be acted on is confirmed with a desktop
  run before it is treated as settled.

#### Processes

- Stop processes only by the PIDs you started, or through the launcher,
  which checks each PID against its recorded start time. Never by name:
  `pkill goanna`, `pkill -f luanti` and `killall gamescope` hit other
  agents' clients and the owner's own game. A `pkill -f` pattern also
  matches the command line of the shell running it, and has killed the
  agent's own shell.
- Give every client its own control port and server port. The launcher
  refuses a control port that is taken; do not work around it.
- Leave nothing running: stop every client, server and gamescope you
  started before finishing. A client left running after its server had
  gone once held 3.4 GB and half the GPU for 20 hours.

#### The GPU

- Use the tools; they take the lock. Every rendered frame and every GPU
  timing goes through the render service (`tools/goanna-render`, below).
  Any other GPU client, a fixture or a client of your own, goes through
  `tools/goanna-headless`. Both take the one GPU lock,
  `/tmp/claude-1000/goanna-gpu.lock` (`GOANNA_GPU_LOCK` overrides it), and
  both check the card before they start, so following them is the rule;
  there is nothing extra to remember. `tools/goanna-headless gpu-lock`
  says whether the lock is free and who holds it.
- One game client on the GPU at a time. A headless gamescope started beside
  another GPU client has wedged the driver: 2026-09-19 with two headless
  sessions, 2026-09-25 with one beside a windowed Godot another agent had
  open.
- `tools/goanna-headless gpu-free` exits 1 and names the client while a
  Godot, gamescope, Luanti or compute job (the owner trains models on the
  same card) is on the GPU, or while the NVIDIA driver has logged errors in
  the last 30 minutes. When it says busy, do not render at all: wait, or
  use `--software`. The launcher makes the same check and refuses; do not
  set `GOANNA_SHARED_GPU=1` to get past it.
- Never build a gamescope command line by hand. Offline fixtures (the
  material ramp, the plant ramp, probes) run through `tools/goanna-headless
  fixture SCENE --env KEY=VALUE ...`, which makes the same checks, keeps
  gamescope itself on lavapipe and waits for the scene to quit. On
  2026-10-02 a hand built one set `VK_ICD_FILENAMES` to lavapipe and was
  run beside the owner's game in the belief that it kept off the card.
  Those variables steer only the child: gamescope chose the NVIDIA device
  itself, and the driver needed a reboot.
- When the owner wants the card back, stop your GPU work at once, check
  with `nvidia-smi` that nothing of yours is left, and only then say it is
  free.

#### When the driver has failed

A wedged driver keeps running the processes that already have a device
and refuses every new one, so the desktop looks fine while every new
client dies. Its signatures, all seen on this project's development
machine:

- Kernel log `Xid 51` then `Xid 154` (a function level reset requested),
  then `NV_ERR_RESET_REQUIRED`.
- Kernel log `NVRM ... NV_ERR_NO_MEMORY`, then every new Vulkan device
  failing with `NV_ERR_STATE_IN_USE` (2026-09-27, with nothing else on the
  GPU). It did not recover on its own.
- The same refusal after a system update put a new NVIDIA userspace under
  the still running older kernel module.

In each, Godot fails `vkCreateDevice` (`VK_ERROR_INITIALIZATION_FAILED`)
and may crash with a segfault at startup. What to do:

- When a GPU start fails, read `journalctl -k | grep -i -E 'xid|nvrm'`
  before anything else. Retrying, freeing VRAM and cleaning up processes
  do not help, and a client started into it crashes at once.
- Treat any of these as needing a reboot, and tell the owner. Do not
  reboot or restart anything yourself.
- Until then, use `--software` or Godot's `--headless`; `gpu-free` reports
  busy for 30 minutes after a driver error in any case.

The launcher and the MCP server are described in
`docs/agents/control-channel.md`, under "Starting it" and "Driving it from an
agent".

### The render service

Use the render service for every rendered frame and every GPU timing. Do
not start a GPU client of your own.

Before it, every agent wanting a frame imported a checkout, made a fixture
world, started a server and a client, took a few frames and stopped, and
held the one GPU lock for 30 to 60 minutes to do it, most of that setup.
`tools/goanna-render` does the setup once and keeps it:

- `goanna-render serve` takes the GPU lock (see "The GPU" above) and
  holds it for the service's whole life, so nothing else renders
  beside it. Under the lock it requires the card clear: nothing
  `goanna-headless gpu-free` names, no NVIDIA driver errors in the last 30
  minutes, and no compute user in `nvidia-smi` that is not a desktop
  program. It then starts one Luanti server (Mineclonia unless `--game`
  says otherwise) on a fixture world it rebuilds every time it starts, and
  one Goanna client in headless gamescope on the GPU, through the launcher
  with `--cpu-compositor`.
- `goanna-render shoot JOB.json` queues a job and blocks until it is done,
  printing the result. Jobs from any number of shells queue and run one at
  a time, oldest first. With no service running, `shoot` starts one with
  the defaults (`--no-start` refuses instead).
- `goanna-render status` says what it is doing, what is queued, which
  build and profile the client holds and why it last restarted;
  `goanna-render stop` stops it.

It gives the card back on its own. Between jobs, and between the variants
and poses of a job, it polls the same checks. When the owner's own Godot, a python
compute job or a driver fault appears, it stops its client and server,
releases the lock, puts any interrupted job back at the front of the queue,
and waits until the card has been clear for a minute before taking the
lock again. It stops cleanly on SIGTERM, and after 20 minutes with no job
(`--idle-minutes`), because a client left running costs the owner.

`--software` runs the whole service on lavapipe, without the lock, for
testing the service itself. Its frames are useless for judging a look.

#### The world

The fixture is a singlenode world with Mineclonia's own Lua level
generator turned off (`mcl_singlenode_mapgen = false`, which otherwise
builds floating terrain over the stage), a 49 by 49 stone floor at the
stage, Luanti (1000, 31, 1000), and `tools/render-fixture.lua` and a fresh
copy of `goanna_server_mod` as worldmods. The server runs with
`time_speed = 0`, Mineclonia's weather cycle off, mob spawning off and
movement anticheat off (poses move the player thousands of nodes a second
as far as anticheat can tell, and it then reset the player and streamed
blocks around the wrong place). The far field is not granted on the
fixture, which has nothing past the stage (`--far` grants it): on the first
GPU run it kept every pose waiting out the settle timeout. `--world-from
NAME` copies an existing world instead, for a scene with real terrain
(`frame: world` in the job), and grants the far field.

The player starts, and waits between jobs, 1200 nodes from the stage, so
a job's nodes reach the client in blocks sent fresh rather than as edits
to blocks it already holds. Every teleport puts the camera at the target
first: the client's `tp` streams blocks with the camera still where it was
and tiers them against it, and on the first GPU run the stage arrived with
0 to 5 blocks meshed and stayed that way, so the frames were sky. An
arrival now also requires at least one block meshed.

`GOANNA_RENDER_STATE=DIR` gives a service its own queue and record, for a
second service on another world or game. The two still share the one GPU
lock, so one waits while the other renders; jobs go to whichever service
the shell's `GOANNA_RENDER_STATE` names. Each world has its own server
files under `~/.var/app/org.luanti.luanti/goanna-render/<world>/`. A
service that is yielded when its own sources change starts again in place
with the new ones (the queue is on disk), because one left yielded for
hours kept yielding to lavapipe clients after `gpu-free` was fixed.

#### A job

Coordinates are Luanti's, relative to the stage (its floor is at y -1),
unless `"frame": "world"` makes them absolute. The service negates z for
Goanna itself. A pose takes `look_at` (a point) or `yaw` and `pitch` in
degrees, yaw 0 looking along +z and 90 along -x, pitch positive looking
up; `pos` is the eye.

```json
{
  "label": "zombie, maps on and off",
  "out": "/abs/path/to/output",
  "tier": "high",
  "size": [1280, 720],
  "pack": "/abs/path/to/pbr_packs/mineclonia/textures",
  "build": "/abs/path/to/a/worktree",
  "env": {"GOANNA_DEBUG_LOD": "1"},
  "profile": {"mat_micro_shadow": 1},
  "time": 0.5,
  "weather": "clear",
  "nodes": [{"box": [[-2, 0, 5], [2, 2, 5]], "node": "mcl_core:stonebrick"},
            {"pos": [0, 0, 7], "node": "mcl_portals:portal", "param2": 0, "swap": true}],
  "lua": ["local p = P(0, 0, 9); set(p, 'mcl_pottery_sherds:pot'); ..."],
  "statues": [{"entity": "mobs_mc:zombie", "pos": [0, -0.5, 3], "yaw": 180},
              {"entity": "goanna_render_fixture:figure", "pos": [2, -0.5, 3],
               "props": {"textures": ["character.png", "mcl_armor_chestplate_iron.png",
                                      "blank.png"]},
               "attach": [{"entity": "mcl_wieldview:wieldview", "bone": "Wield_Item",
                           "props": {"wield_item": "mcl_tools:pick_iron",
                                     "is_visible": true}}]}],
  "verify": [{"pos": [0, -1, 0], "node": "mcl_core:stone"}],
  "poses": [{"name": "face", "pos": [0, 1.6, 0.8], "look_at": [0, 1.4, 3], "fov": 60}],
  "variants": [{"name": "maps_on", "maps": true},
               {"name": "maps_off", "maps": false},
               {"name": "dusk", "time": 0.74}],
  "crops": [{"name": "head", "rect": [540, 160, 200, 200]}],
  "timing": {"rounds": 6, "burst": 600, "poses": ["face"]}
}
```

Everything but `out` and `poses` may be left out. `build` defaults to
main's checkout (`project/bin` there, and its GDScript as it stands);
`pack` to that checkout's `pbr_packs/<game>/textures`; `tier` to `high`;
`size` to 1280 by 720; `time` to 0.5 and `weather` to clear. Each variant
overrides any of `build`, `pack`, `tier`, `size`, `env`, `maps`, `profile`
(merged), `time` and `weather`, and every variant is shot at every pose.
`frames: false` skips frames for a timing only job.

A node entry may give `param2`, and `swap: true` places it with
`swap_node`, so no constructor or destructor runs: a Nether portal set
with `set_node` is destroyed by Mineclonia's own callbacks. `/rs_reset`
puts every node back with `swap_node` and clears its meta. `lua` is a list
of Lua chunks (a string, or a list of lines) run on the server after the
boxes are placed, for node meta, a decorated pot's faces or a callback;
their scope adds `S` (the stage), `P(x, y, z)` (stage relative to
absolute), `set`, `swap` and `save` (each remembering the old node for the
reset), `track(obj)` (an object the reset removes) and `statue(d)` (a held
statue as below, for properties computed on the server, such as worn
armour from the game's own items; list it under `lua_statues` with its
`entity` and `pos` so the arrival checks it). A statue may give
`props` (object properties set after the entity activates), `animation`
(`[from, to, speed]`), `attach` (entities attached to a bone, each with
its own `props`) and `burn` (set on fire for good; its `on_step` is
shadowed, so the burn never runs down). `goanna_render_fixture:figure` is
a statue with the player's own model and texture slots (skin, armour, a
third the game leaves blank), on Mineclonia only. An entity's position is
the bottom of its collision box, so a statue standing on the floor is at y
-0.5.

What costs what:

- `profile` (any key the settings panel has, `mat_*` included), `time`,
  `weather` and a pose's `fov` are applied live and put back after the
  variant, except `texture_size`, which the client reads only when it
  joins: an override of it is written into the profile at launch.
- `build`, `pack`, `tier`, `size`, `env`, `maps` and `texture_size` are
  fixed at launch, so a change restarts the client: 32 to 41 s on lavapipe
  (92 s the first time, compiling shaders), 20 to 27 s on the RTX 3090,
  plus a one off import of a worktree that has
  never been opened (`godot --headless --import`, no GPU, minutes). A
  rebuilt `project/bin` is seen by its hash and restarts the client too.
  Variants that share a launch run together, so maps on and off is one
  restart, not one per pose. The result lists every restart and its
  seconds under `client_restarts`.

Each frame is `OUT/<variant>/<pose>.png`, with the client's own sidecar
(`<pose>.json`, which lists deviations) and the service's
(`<pose>.settings.json`): the build (checkout, HEAD, branch, a dirty flag
and the files, and the hash, size and time of the library), the Godot,
Goanna, server and game versions, the adapter, the tier and every value
the client held at the shot read back from it, the overrides asked for,
the pack, maps, environment, time, weather, both coordinate frames of the
pose, the node and statue checks (with the blocks meshed at arrival),
whether the pose settled and how long it waited, the material counts with
normal and specular arrays bound, and the entity materials built with and
without a normal map, and any shader compile errors in the client log so
far (Godot compiles a shader when its material is first drawn; an error
fails the job, with the frames still written). The material counts cover
only the client's per texture material map, which node arrays do not use,
so on a node scene they read 0 whether the maps are bound or not; the
entity counts are the ones to trust. Crops are `<pose>.<name>.png`. `timing` writes
`OUT/timing/timing.json` (median and p95 of per draw GPU time per variant
and pose, with the range over rounds) and every round's draws as CSV.
`OUT/result.json` repeats what `shoot` printed, with the wall time.

#### The traps it handles, so a job does not have to

- **Stale profile.** A scratch profile first saved on lavapipe stayed on
  Low with parallax off and invalidated three GPU reviews. Every launch
  writes a fresh profile into a fresh `XDG_DATA_HOME`, with
  `GOANNA_NO_HW_DEFAULTS=1`, then reads every value of the tier back from
  the client and refuses to shoot if one differs (`far_distance` follows
  the server's grant and is only recorded). It also refuses an adapter
  that is not the card.
- **Maps off.** `maps: false` launches with `GOANNA_NO_PBR=1` and
  `GOANNA_AUTO_BUMP=0` and `auto_bump=0` in the profile, so no relief is
  inferred either, and `GOANNA_DEBUG_ENTITY_PBR=1` always. A maps off frame
  whose client log has any entity material built with `normal=true` fails
  the job; the sidecar says `maps_off_verified`.
- **Empty `luanti/` submodule.** A build whose checkout has no
  `luanti/textures/base/pack/blank.png` is refused: players would draw
  yellow.
- **z negated.** Jobs are in Luanti coordinates; the service converts for
  `tp`, `pose`, `look` and `node_name_at`.
- **Presented frame timing.** Under headless gamescope the GPU idles at
  low clocks between presents, so timing is back to back `force_draw`
  bursts after 30 warm draws, variants rotated per round, as in
  `docs/perf/low-tier-occlusion-2026-10-05/run.py`.
- **Weather.** Mineclonia's cycle is off, and each variant sets its
  weather for a million seconds and puts clear back.
- **Missing meshes after teleports.** A job teleports once, to `anchor` or
  its first pose, and then moves only the camera. Before any frame every
  corner of every box, every `verify` entry and every statue is looked up
  in the client; if one does not match within 30 s it leaves for the
  parking place and comes back, up to three times, and fails the job
  rather than photograph a hole.
- **Statues.** `/rs_statue` holds the entity in place with its `on_step`
  shadowed (no walking, burning or despawning) and spawns it again
  whenever its block is active and it is gone, so placing one while the
  player is away works.
- **A held player name.** A stopped client can leave its player on the
  server until it times out, and the next client under the name is
  refused; the service waits for the server to log the player leaving.
- **Clients left running.** SIGTERM, `stop`, the idle timeout and a yield
  all stop the client through the launcher and the server by the PIDs
  the service started.

#### What has been run

On 2026-10-06, only with `--software` (lavapipe, 640 by 360), because the
card was never clear of other agents' clients while this was written:
Luanti 5.17.0 server, Mineclonia (release 38561), Godot 4.5.1, main's
build at 00c39896 with two dirty files. The service came up in 75 s (server
19 s, client 41 s). Three jobs were sent from two shells at once and ran
one at a time in order: a stone wall at noon and dusk (209 s, no
restart), a zombie statue with maps on and off (259 s, one 37 s restart;
the maps off sidecar had `pbr_disabled` true, no normal or specular arrays
bound, `auto_bump` 0 and no entity material with a normal map), and a
timing job of two parallax variants (442 s, one 32 s restart back to maps
on; lavapipe's numbers are meaningless as timings). With `--fake-gpu-user`
listing a live dummy `python3` process, the service yielded 5 s after the
job in hand finished, stopped its client and server, released the lock,
and came back 25 s after the process ended. Started without
`--software` beside another agent's client, it took the lock, found the
client, released the lock and waited without starting anything.

On 2026-10-06 on the GPU (RTX 3090, NVIDIA driver, Godot 4.5.1, the same
server and game, main's build at dec70408 and then 019bc7d1, each with two
dirty files, profile High read back at every launch, adapter "NVIDIA
GeForce RTX 3090", `mat_parallax` 1): the first runs drew sky, as above,
and the fixes in this section came from them. After them the service came
up in 20 to 21 s of client launch, and the same three jobs ran: the wall
in 71 s with no restart, the zombie in 101 s with one 23 s restart (maps
off verified, no entity material with a normal map), and the timing job in
233 s with one 23 s restart. Per draw GPU time on the wall at 1280 by 720
was 1.85 ms median with parallax on (1.85 to 1.85 over six rounds of 600)
and 1.66 ms with it off.

Not yet run: a yield in the middle of a job, which puts the job back at
the front of the queue; `--world-from`; a `build` other than main's.

## 2. Player agent interface

The player agent interface represents an ordinary participant in a world. The
server remains authoritative and every action is subject to the same reach,
collision, inventory, privilege, protection and rate limits as a human
player. It has no arbitrary-code or arbitrary-client-method escape hatch.

The protocol reserves two useful scopes:

- **Actor:** an embodied individual. It receives local perception and submits
  ordinary movement, interaction, inventory and communication actions.
- **Director:** a settlement or faction decision-maker. It receives only the
  symbolic information that subject legitimately knows and submits priorities
  or goals which the game decomposes into work. It cannot place nodes, create
  goods or directly command unrelated actors.

`band` or `crew` may later become an intermediate scope. It is deliberately
not required by the first protocol.

These are authority scopes, not personalities. Identity, prose character
descriptions, long-term memory, planning and model selection belong to the
agent host. Goanna transports observations and legal actions; it does not
implement an agent mind.

## Protocol shape to preserve

Every request and observation carries:

- a protocol version;
- a session and subject identifier;
- a monotonically increasing observation sequence;
- the world/game tick when the state was sampled;
- the authority scope and advertised capabilities;
- the observation sequence on which an action was based;
- a structured result: accepted, completed, interrupted, refused or stale.

Capabilities are negotiated rather than inferred from a game name. A Kythen
server may advertise settlement direction while another Luanti game exposes
only embodied player actions.

### Actor observations

The initial observation is intentionally modest:

- player position, orientation and physical state;
- pointed target and a bounded set of visible or otherwise sensed nodes;
- nearby visible entities;
- inventory and wielded item;
- chat and gameplay events since the preceding sequence;
- optional RGB/depth frame references.

Spatial memory distinguishes `current`, `stale` and `unknown`. Previously seen
terrain may remain in the agent host's persistent map, but the interface does
not reveal unseen server map data. This follows the useful lesson from
PERSIST: world, camera, action and rendered observation are synchronized
state, rather than an unstructured history of screenshots.

### Actor actions

The first action vocabulary is:

- look and set movement controls;
- dig, place, use and attack through normal player input;
- select, move and use inventory items;
- send chat;
- wait for ticks, an event or action completion.

Navigation, crafting and other convenience skills may be added later, but
must resolve through these legal actions. There is no teleport, hidden-node
query, direct inventory mutation or server-command shortcut.

### Director observations and actions

Director messages are reserved in v1 even if no game advertises them yet.
They use stable subject IDs and symbolic snapshots/deltas rather than a camera
frame. Likely observation domains are population, stock, work, known places,
relations and reports. Likely actions are priorities, allocations, offers,
postures and requests.

The vocabulary belongs to the game. For Kythen it should align with the A8
tier boundary: an actor may submit T0 actions, a settlement director T2
intentions, and a faction director T3 intentions. Higher-tier requests enter
Kythen's normal decomposition and failure propagation; the interface never
implements an alternative simulation path.

## Roadmap

### R0: Freeze the boundary

- Name the current channel the game development interface.
- Publish this authority and non-goal document.
- Reserve version, sequence, subject, scope, capability and result fields.
- Add tests that developer-only verbs can never appear in a player schema.

Deliverable: protocol examples and schema tests, no autonomous agent.

### R1: Read-only actor

- Add a separate endpoint and wrapper.
- Negotiate capabilities.
- Return synchronized body, camera, inventory, visible-world and event state.
- Record deterministic observation trajectories for debugging.

Deliverable: an external program can observe one connected player but cannot
act.

An experimental first pass is available with `GOANNA_PLAYER_AGENT=1`, using
loopback port 30850 (or set the variable to another port). `tools/goanna-player`
provides `hello` and `observe`, while `tools/goanna-player-mcp` exposes the
same operations to an agent host. It is independent of `GOANNA_CONTROL`;
enabling it does not enable the privileged developer API. R2 below extends
the same endpoint with actions.

### R2: Embodied actor actions

- Add movement, look, interaction, inventory, chat and wait.
- Attach actions to observation sequences and reject stale targets.
- Exercise reach, protection and rate-limit parity against human input.

Deliverable: a scripted policy can play through ordinary mechanics. Planning,
memory and autonomous goal selection remain external.

Status: a first version is in `project/player_agent_channel.gd`, protocol
`goanna-player/0.5`, described below under "The player agent protocol". What
has been seen to work, and what has not, is listed at the end of it.

### R3: Game extension seam

- Let a server/game advertise additional observation and action schemas over
  a mod channel.
- Keep generic actor primitives usable without a game extension.
- Prototype Kythen stable subject IDs and read-only settlement reports.

Deliverable: Goanna can carry game-specific agency without knowing Kythen's
simulation types.

### R4: Director pilot

- Map a small Kythen T2 subset to the extension seam.
- Route accepted intentions through Kythen's existing behaviour hierarchy.
- Verify embodied and unwatched resolution have the same economic result.

Deliverable: one settlement priority loop. No general autonomous settlement,
faction diplomacy, culture generation or multi-agent society.

## The player agent protocol

`goanna-player/0.5`, served by `project/player_agent_channel.gd`. It shares
no code path with the control channel: no dispatcher, no `eval`, no method
call by name. `project/tests/player_agent_boundary.gd` fails if the channel,
`tools/goanna-player` or `tools/goanna-player-mcp` gains any of the control
channel's verbs (`eval`, `run`, `call`, `tp`, `pose`, `inspect`, `time`,
`weather`, `set`, `shot`, `reload_shader` and the rest), or if the channel's
source gains a dynamic call, a pose write or a second shell call.

### Starting it and the token

Start the client with `GOANNA_PLAYER_AGENT=1` (port 30850) or
`GOANNA_PLAYER_AGENT=<port>`. It listens on 127.0.0.1 only. At launch it
writes a fresh random token to `user://player_agent_<port>.token`, created
with mode 0600 before the token goes in, and deletes the file on exit. Every
request must carry that token, so another program on the computer cannot
drive the player without being able to read the user's files.

`tools/goanna_player.py` finds the file where Godot puts `user://` for
Goanna (`$XDG_DATA_HOME/godot/app_userdata/Goanna` on Linux, falling back to
`~/.local/share`). `GOANNA_PLAYER_AGENT_TOKEN_FILE` or `--token-file`
points it elsewhere, `GOANNA_PLAYER_AGENT_TOKEN` gives the token directly,
and `GOANNA_PLAYER_AGENT_PORT` and `GOANNA_PLAYER_AGENT_HOST` say where the
channel is.

### Requests

One JSON object per line:

```json
{"id": 7, "token": "...", "cmd": "dig", "args": {"based_on": 41}}
```

The reply is `{"id": 7, "ok": true, "result": {...}}`. `ok` is false only
for a malformed request, a wrong token or an unknown command. A refused or
stale action is a result, not an error.

### Observations

`observe` returns the protocol, session, subject, scope (`actor`), a
`sequence` that increases with every observation, the frame `tick`, and:

- `body`: feet position, health, breath, grounded, in liquid, climbing,
  velocity, wielded slot and item, hotbar size;
- `camera`: eye position, pitch, yaw, look direction, field of view. Pitch
  is positive looking up; yaw 0 looks along -z and 90 along -x;
- `pointed`: what the crosshair is on, within the wielded item's reach,
  exactly as the client's own selection box shows it, with its `infotext`
  when it has one, the text shown in the corner while it is pointed at;
- `nearby_entities`: objects within 32 nodes that are inside the camera's
  view and have a clear line from the eye to their body or head, with no
  walkable node in the way, each with the `nametag` drawn over it. The
  client is told about objects behind walls and behind the player; those
  are left out;
- `inventory`: the player's own lists, with stripped item descriptions;
- `window`: the open window, and for a form the slots on screen with their
  contents, the stack on the cursor, whether it may be closed, its named
  elements (below) and its `labels`, the text on it that belongs to no
  element;
- `hud`: what the server has put on the screen, as Goanna draws it. Text
  elements with their `text` and `spans`; images with the texture string
  they show; status bars with `value` and `max`; inventory strips; and
  waypoints, only while they are in front of the camera, with their `name`,
  where on the `screen` they are (0 to 1 across and down), the `distance`
  as drawn and the `look` (pitch and yaw) that would centre one. A
  waypoint's exact coordinates are not drawn and are not given. Bars the
  server has hidden, empty text, a compass and a minimap (which Goanna does
  not draw) are left out; the hotbar is in `body` and `inventory`;
- `events`: chat lines, action results and sounds since `since_event`. A
  sound event is every sound the client plays, whatever the player's volume
  or mute: its `sound` name, `gain`, `loop`, its `source` (`server`, or what
  the client made it for: `place`, `use`, `damage`, or `footstep` for
  another player's or a mob's), and for a sound in the world its `distance`
  in whole nodes and the `look` (pitch and yaw) that would face it, or
  `local` for one heard as if from inside the head. Its exact place is not
  given, since a person hears a direction and roughly how far. The player's
  own footsteps, jumps, digging hits and form clicks are left out: they say
  nothing the observation does not, and would crowd out the rest;
- `visible_nodes`, only when asked for (`{"columns", "rows", "range"}`, up
  to 24 by 16 rays and 32 nodes): the first node each ray through the screen
  meets, which is the surface the player sees there. Rays stop at unloaded
  nodes and look through the medium the eye is in (water under water);
- `frame`, only when asked for (`{"width", "format"}`, up to 1280 pixels
  wide, `jpeg` or `png`): a picture of the screen as the player sees it,
  world, HUD and open form together, base64 in `data`. A client started
  with Godot's `--headless` has no picture and says so.
  `tools/goanna-player-mcp` hands it to the host as an image, and
  `tools/goanna-player observe --frame PATH` saves it.

Text a game colours, with `core.colorize` or hypertext styles, comes as
`text` and `spans`, each span a run of one look: its `text`, its `color`
as `#rrggbb`, and in hypertext `bold`, `italic`, `underline` and the
`action` it belongs to. The colour is the one the game asked for; a game
that tells the player something by colour (Kythen marks the words a player
knows that way) tells the agent too. `labels` on a form are objects of
this kind. Chat comes without colour, because Goanna's chat shows none.

A form's `elements` are the named ones on screen. Each has its `name` and
formspec `type`, and as fits the type: `text` (a caption, a field's text, a
hypertext's text as read), `disabled`, `editable`, `checked`, `items` and
`selected` (a dropdown or text list, counted from 1), `tabs` and `selected`,
`rows` (a table's, each with the `row` number it sends and its `cells`),
`value`, `min` and `max` (a scrollbar), `actions` (a hypertext's links,
each with the `action` it sends and the `text` it shows) and `tooltip`.
Elements hidden or scrolled out of a scroll container are left out, as they
are from the player's view; scroll to reach them. A password field reports
its length and never its text.

Positions use Godot's axes: Luanti's x, y and -z, in nodes. Light and fog
are not considered, so an object or surface in darkness, or far off under
water, is still reported; this is the known way an observation can say
more than a person would make out.

### Actions

Every action except `release` must carry `based_on`, the sequence of the
observation it was decided on. The last 64 observations are kept.

| Action | Arguments | What it does |
| --- | --- | --- |
| `look` | `pitch`, `yaw`, `turn_pitch`, `turn_yaw` | Sets the view, pitch clamped to 89 degrees either way. |
| `move` | `controls` (forward, backward, left, right, jump, sneak, aux1), `duration_ms` | Holds the controls for up to 30 s, or until `release` when `duration_ms` is left out. |
| `release` | `control`: all, buttons or one control | Lets go. Ending a move lets go of every control it held. |
| `dig` | `max_ms` | Holds dig on the pointed node until it breaks, then lets go. |
| `place` | | One right click on the pointed node. |
| `use` | | One right click on whatever is pointed at, or on nothing to use the wielded item. |
| `attack` | `duration_ms` | Holds dig on the pointed entity. |
| `hotbar` | `slot`, from 1 | Selects a hotbar slot. |
| `drop` | `single` | Luanti's drop key on the wielded stack. |
| `inventory_open` | | Opens the player's inventory form. |
| `inventory_close` | | Closes the open form, as Escape does. |
| `inventory_click` | `location`, `list`, `index`, `button`, `shift` | Clicks a slot of the open form. |
| `form_button` | `name` | Presses a button, image button or item image button. |
| `form_field` | `name`, `text`, `enter` | Replaces a field's or textarea's text, as typing does. It goes with the next event that sends fields; `enter` (fields only) presses Enter, which sends at once. |
| `form_select` | `name`, `index` or `text`, `double` | Chooses a dropdown or text list entry, a table row (by its row number or a cell's text) or a tab. `double` is a double click. |
| `form_check` | `name`, `checked` | Ticks or clears a checkbox. |
| `form_scroll` | `name`, `value` or `by` | Moves a scrollbar, which also scrolls its scroll container. |
| `form_action` | `name`, `action` or `text` | Follows an action link of a hypertext element. |
| `respawn` | | Presses Respawn on the death screen. |
| `chat` | `text` | Sends one line of chat. |

`wait` (`ticks`, `ms`, `event` with `since_event`, or `action`, each with
`timeout_ms`) and `action_status` (`action`) are queries and need no
`based_on`.

The movement controls join main.gd's key state, and dig and place join the
mouse buttons, ahead of `step_player` and `step_interact`. So the action
goes through the same code as a person's input: the same reach, dig times,
punch interval, window gate (nothing moves while a form is open), and the
server's own privilege, protection, anticheat and rate checks. Inventory
clicks go to the open form's slot handlers, the ones a mouse click reaches,
and only for slots the form shows. Picking a stack up and putting it down
are two clicks, as with a mouse.

The `form_` actions work an element through its own signal, the one a click,
a keypress or a wheel turn on it emits, so `ui/formspec.gd` sends what
Luanti sends for the same event: a button its name and caption with the
fields, a checkbox only its own state, a dropdown its text or index, a list
or table `CHG:` or `DCL:` with the row, a tab its number, a scrollbar
`CHG:` with its value, a link `action:` and its name. Only elements on
screen can be worked; a disabled button or a read only field is refused, a
type the action does not fit is refused, and an element that changed since
`based_on`, or a different form, is `stale`. A form action's `effects` give
the `fields_sent`, the window and form afterwards and the element as it now
is. A `button_url` or a link with a url still offers the address in a
dialogue, as for a person; the agent cannot answer it and it does no harm left
open.

These are refused outright: chat beginning with `/` (a server command),
more than 20 actions a second, more than 5 chat lines in 10 seconds, body
actions while a window or chat is open, while dead or with the free camera
on, `respawn` when the death screen is not up, and anything while the player
is not in a world. Goanna's own menus (pause, settings) are not driven.

### Results

| Status | Meaning |
| --- | --- |
| `accepted` | Under way. A held move, or anything sent with `wait: false`. |
| `completed` | It happened. `effects` says what was seen to change. |
| `interrupted` | It started and stopped early: the crosshair left the target, a window opened, the time limit passed, or a release. |
| `refused` | It cannot be done, or the server undid it (a dig whose node came back). |
| `stale` | The target is not what `based_on` observed: the pointed node, entity or slot changed, or the observation is too old. Observe again. |

A dig is predicted by the client and undone by a server that refuses it, so
its result waits 1.5 s after the break. A node that comes back is
`refused`. `place` and `use` report what changed (a placed node, an opened
form, inventory counts) and give a reason when nothing visibly did.

### Seen working

On 2026-10-01, Goanna from this branch against a Luanti 5.17.0 server
running Mineclonia on the same machine, Godot 4.5.1, in headless gamescope
with software rendering (`tools/goanna-headless start --software`), driven by
`tools/goanna-player` and small scripts over `tools/goanna_player.py`:

- `hello`, `observe` with and without the token (refused without);
- `look`, then `dig` of the pointed dirt: `completed`, the inventory gained
  the drop;
- `hotbar`, then `place`: `completed`, the node appeared and the inventory
  count fell;
- `dig` by a player without `interact`: the server logged the refusal and
  put the node back, and the result was `refused`;
- `dig` with a node on screen but beyond reach: `refused`, nothing pointed;
- `dig` based on an observation from before the view turned: `stale`;
- `move` for a time and held until `release`, swimming included;
- `inventory_open`, two `inventory_click`s moving a stack, a stale click,
  `inventory_close`, and `look` refused while the form was open;
- `chat`, its line coming back as a chat event, and `/grant` refused;
- `drop` of one item, the inventory count falling;
- `attack` with a node under the crosshair: `refused`;
- the MCP wrapper listing its tools, answering `hello`, refusing a `/tp`
  chat line, and not knowing `goanna_player_eval`; developer verbs sent
  straight to the socket answered as unavailable.

On 2026-10-02, the same set up against a Luanti 5.17.0 server running Kythen
0.1.0-b1 in a fresh world (mapgen v7, no baked terrain), Godot 4.5.1, in
headless gamescope with software rendering:

- `use` with the spawn kit's journal wielded opened `kythen:interface_journal`;
  `observe` reported its four buttons and its text as labels;
- `form_button` through journal, dictionary, journal again and
  `kythen:dashboard`, each sending the button's name and caption, and the
  dashboard's History view swapping the text shown;
- `form_button` on a name the open form did not show: `refused`;
- the dashboard's `button_exit` Close sending `quit` and closing the window;
- `inventory_open` and `inventory_close` again, with no elements reported on
  Kythen's plain inventory.

Fields, checkboxes, dropdowns, text lists, tables, tabs, scrollbars,
hypertext links and `respawn` were checked only offline, by
`project/tests/player_agent_forms.gd`, which builds a real form with
`ui/formspec.gd` and works it through the channel with no server. A fresh
Kythen world has no village, so none of its forms with those elements could
be reached. Kythen's map did not open at all: it waits for an image sent
with `dynamic_add_media`, and Goanna's session did not then handle
`TOCLIENT_MEDIA_PUSH`, so the image never arrived and the server never
showed the form. A person playing Goanna met that too.

On 2026-10-04, against a Luanti 5.17.0 server running Kythen 0.1.0-b1 in a
fresh world, with Goanna started with Godot 4.5.1's own `--headless` (no
renderer, so nothing on the GPU), `goanna-player/0.4`:

- `hud` reported Kythen's ground overlay: its two text lines, the second
  in the overlay's own colour, and the two filled images of its bar;
- `use` with the map wielded opened `kythen:mapview`, which needs the
  pushed map image fetched and acknowledged: Goanna now handles
  `TOCLIENT_MEDIA_PUSH`, asks for the file, loads it and sends
  `TOSERVER_HAVE_MEDIA`;
- `form_button` on the map's Zoom to my region, a second pushed image and
  the region view;
- the map's Close button sent `close` and left the map open: Kythen's
  handler returns without closing the form, which a person meets too.
  `inventory_close` closed it.

Later the same day, the same server with Goanna rendering on the CPU
(`tools/goanna-headless start --software`): `observe` with `frame` returned
pictures of the world with the HUD over it, and of the open map form, as
JPEG and PNG.

That picture showed the map as a flat placeholder. The client had joined
under a name that had opened the map before, in an earlier connection, and
Kythen keeps a per player note of the last map file sent
(`engine/interface/map.lua`) that it never clears when a player leaves.
On the next open it skipped `dynamic_add_media` for a file the new
connection did not have, as it would for a vanilla client, which keeps no
ephemeral media across connections either. Under a fresh name the file was
pushed, fetched and loaded at its real 128 by 128, and the form showed it.

On 2026-10-05, the same set up against a Luanti 5.17.0 server running
Minetest Game in a fresh world with damage on, two Goanna clients started
with Godot's own `--headless` (no renderer), `goanna-player/0.5`:

- the client spawned in the air and fell: `player_falling_damage` (a sound
  Minetest Game does not ship, so not heard), `player_damage` and a
  landing step were played, and the damage sound came to the agent as a
  `local` `damage` event;
- `place` of dirt played `default_place_node` and the agent heard it;
  placing into the node the player stood in played the dirt's place-failed
  sound, which Minetest Game leaves empty;
- `dig` of that dirt played two `default_dig_crumbly` hits at the node and
  the dirt's dug sound;
- the second client walked away along -x: the first heard its footsteps
  every 1.5 nodes, from 2 to 8 nodes off, at a yaw of 78 to 88 degrees and
  below eye level.

That run also found that Goanna sends a placement upstream's client refuses
to send, one that would put a walkable node where the player stands; the
server placed it. Its sound is right, the placement is not, and it is not
yet fixed.

Not seen live: HUD speech from a villager, waypoints, infotext and nametags
(a fresh world has no village and no creature came near). They are covered
offline by `project/tests/player_agent_forms.gd`.

Not verified: `attack` landing on a mob. Every mob the test scripts aimed
at moved out of reach first (the spawn was beside a lake, and the
software rendered client ran at about five frames a second). Protection
was not exercised either: the test world had no protection mod, so only a
missing privilege was. `respawn` has not been seen against a server.

## Explicit non-goals

This roadmap does not build an agentic civilization. It does not provide an
LLM runtime, personality system, memory database, autonomous planner,
relationship simulator, culture authoring agent, multi-agent coordinator or
offline population service. Those may consume the interface later; none is a
dependency of R0 through R3.

The developer interface remains the place for renderer and simulation
diagnostics. The player interface remains a narrow, auditable bridge between
an external policy and actions the game already permits.

## References

- Microsoft Research, Project VEGA, for persistent autonomous characters,
  player influence and collaboration as a possible consumer model:
  <https://www.microsoft.com/en-us/research/project/project-vega/>
- Garcin et al., *Beyond Pixel Histories: World Models with Persistent 3D
  State*, for synchronized world-frame, camera, action and rendered
  observations: <https://arxiv.org/html/2603.03482v2>
- Kythen `docs/a8-behaviour.md`, for its T0–T3 authority and decomposition
  boundaries. Kythen remains a separate game and Goanna does not depend on it.
