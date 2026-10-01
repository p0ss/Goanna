# Agent interfaces

Goanna has two agent-facing interfaces with different authority. They may
share implementation utilities, but they are not two permission levels of one
public protocol.

## 1. Game development interface

The existing control channel and `tools/goanna-mcp` are the game development
interface. It is a local, privileged test instrument. It may inspect renderer
state, move the camera, teleport a test player, change settings, capture
frames, reload shaders and execute GDScript. See `docs/control-channel.md`.

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

Agents testing Goanna have taken over the owner's desktop while the owner
was using it: clients opened in front of their work, took the focus and
grabbed the mouse, once in the middle of a video call, and an agent tried to
move a client's pointer with xdotool. So:

- Test clients run headless, through `tools/goanna-headless` or the MCP
  server (`goanna_session action=start`, headless by default), inside
  gamescope's headless backend. A window on the desktop only when the owner
  has asked to watch one.
- Never inject input into the owner's display (`DISPLAY=:0`,
  `WAYLAND_DISPLAY=wayland-0`, or whatever the desktop's are) with xdotool,
  ydotool or anything else. Drive clients from inside, with the control
  channel's UI commands. The vanilla client is not driven at all; it is
  framed from the server side and photographed through gamescope.
- Stop processes only by the PIDs you started, or through the launcher,
  which checks each PID against its recorded start time. Never by name:
  `pkill goanna`, `pkill -f luanti` and `killall gamescope` hit other
  agents' clients and the owner's own game.
- Give every client its own control port and server port. The launcher
  refuses a control port that is taken; do not work around it.
- Leave nothing running: stop every client, server and gamescope you
  started before finishing.
- One game client on the GPU at a time. Twice a headless gamescope started
  beside another game client has put the NVIDIA driver into a reset
  required state (Xid 51 then 154) that lasts until the owner reboots:
  2026-09-19 with two headless sessions, and 2026-09-25 with one beside a
  windowed Godot another agent had open. Every Godot fixture, ramp and
  client then fails with `vkCreateDevice` until the reboot. Before any GPU
  render run `tools/goanna-headless gpu-free`, which exits 1 and names the
  client while a Godot, gamescope or Luanti is on the GPU, and wait or use
  `--software`. It also reads the kernel log and reports not free while the
  NVIDIA driver has logged errors in the last 30 minutes: on 2026-09-27 it
  ran out of memory and then refused every new Vulkan device
  (`NV_ERR_STATE_IN_USE`) with nothing else on the GPU, and a client
  started into that crashes at once. Do not retry into it. The launcher makes the same check itself and refuses; do
  not set `GOANNA_SHARED_GPU=1` to get past it.

The launcher and the MCP server are described in `docs/control-channel.md`,
under "Starting it" and "Driving it from an agent".

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
`goanna-player/0.2`, described below under "The player agent protocol". What
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

`goanna-player/0.2`, served by `project/player_agent_channel.gd`. It shares
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
- `camera`: eye position, pitch, yaw, look direction, field of view;
- `pointed`: what the crosshair is on, within the wielded item's reach,
  exactly as the client's own selection box shows it;
- `nearby_entities`: objects within 32 nodes that are inside the camera's
  view and have a clear line from the eye to their body or head, with no
  walkable node in the way. The client is told about objects behind walls
  and behind the player; those are left out;
- `inventory`: the player's own lists, with stripped item descriptions;
- `window`: the open window, and for a form the slots on screen with their
  contents and the stack on the cursor;
- `events`: chat lines and action results since `since_event`;
- `visible_nodes`, only when asked for (`{"columns", "rows", "range"}`, up
  to 24 by 16 rays and 32 nodes): the first node each ray through the screen
  meets, which is the surface the player sees there. Rays stop at unloaded
  nodes and look through the medium the eye is in (water under water).

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

These are refused outright: chat beginning with `/` (a server command),
more than 20 actions a second, more than 5 chat lines in 10 seconds, body
actions while a window or chat is open, while dead or with the free camera
on, and anything while the player is not in a world.

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
running Mineclonia on the same machine, Godot 4.5.1, headless with software
rendering (`tools/goanna-headless start --software`), driven by
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

Not verified: `attack` landing on a mob. Every mob the test scripts aimed
at moved out of reach first (the spawn was beside a lake, and the
software rendered client ran at about five frames a second). Protection
was not exercised either: the test world had no protection mod, so only a
missing privilege was. Not built: clicking form buttons and fields other
than slots, and the death screen's respawn.

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
