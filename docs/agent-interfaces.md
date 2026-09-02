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

### R0 — Freeze the boundary

- Name the current channel the game development interface.
- Publish this authority and non-goal document.
- Reserve version, sequence, subject, scope, capability and result fields.
- Add tests that developer-only verbs can never appear in a player schema.

Deliverable: protocol examples and schema tests, no autonomous agent.

### R1 — Read-only actor

- Add a separate endpoint and wrapper.
- Negotiate capabilities.
- Return synchronized body, camera, inventory, visible-world and event state.
- Record deterministic observation trajectories for debugging.

Deliverable: an external program can observe one connected player but cannot
act.

An experimental first pass is available with `GOANNA_PLAYER_AGENT=1`, using
loopback port 30850 (or set the variable to another port). `tools/goanna-player`
provides `hello` and `observe`, while `tools/goanna-player-mcp` exposes the
same read-only operations to an agent host. It is independent of
`GOANNA_CONTROL`; enabling it does not enable the privileged developer API.

### R2 — Embodied actor actions

- Add movement, look, interaction, inventory, chat and wait.
- Attach actions to observation sequences and reject stale targets.
- Exercise reach, protection and rate-limit parity against human input.

Deliverable: a scripted policy can play through ordinary mechanics. Planning,
memory and autonomous goal selection remain external.

### R3 — Game extension seam

- Let a server/game advertise additional observation and action schemas over
  a mod channel.
- Keep generic actor primitives usable without a game extension.
- Prototype Kythen stable subject IDs and read-only settlement reports.

Deliverable: Goanna can carry game-specific agency without knowing Kythen's
simulation types.

### R4 — Director pilot

- Map a small Kythen T2 subset to the extension seam.
- Route accepted intentions through Kythen's existing behaviour hierarchy.
- Verify embodied and unwatched resolution have the same economic result.

Deliverable: one settlement priority loop. No general autonomous settlement,
faction diplomacy, culture generation or multi-agent society.

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
