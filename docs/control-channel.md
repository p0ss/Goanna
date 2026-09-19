# The game development control channel

A loopback socket into a running client, so it can be driven and questioned
while it runs instead of being relaunched for every question. It is a
development aid, not a feature, and it is off unless you switch it on.

This is Goanna's privileged **game development interface**. It is intentionally
separate from the constrained player agent interface described in
`docs/agent-interfaces.md`. Commands such as `eval`, `run`, teleport and
arbitrary method calls must never be exposed through the player interface.

## Why

Before this, every question cost a process launch. You set one of the
hundred odd `GOANNA_*` variables listed in `docs/building.md`, connected,
waited a fixed number of seconds, saved a PNG and quit. Three things follow
from that and all three are bad.

The loop is slow. A shader tweak, a lighting value or a material strength is
seconds of thought and half a minute of relaunch, so few get tried.

The timing is a guess. `tools/shotcheck.py` opens by listing four
conclusions drawn from frames captured before the world had arrived: an
inverted normal map, a jungle canopy measured as snow, an autojump verified
against a swimming character, and rain checked against a clear sky. A wait
on a wall clock cannot tell you the blocks are there. A wait on the block
count can.

The answer is a picture. Reading a number off a screenshot is guesswork
where a query would be exact, and `client.node_name_at()` and its ninety odd
siblings were already there, with no way to reach them from outside.

## Starting it

Test clients run headless, where the person at the machine never sees them:

```sh
tools/goanna-headless start --control-port 30851 --server 127.0.0.1:30000 \
    --name dev --size 1280x720
```

That runs Goanna from the checkout the tool is in (`--project` picks another
checkout or a worktree) inside gamescope's headless backend: a compositor
with its own nested X display and no output at all. The client renders on
the GPU as usual, but no window reaches the desktop, nothing takes the focus
and nothing grabs the mouse. The command returns once the control channel
answers, with an instance id (`goanna-30851`), the PIDs and the log. It
refuses a control port that is already in use; leave `--control-port` out
and a free one from 30801 up is chosen, leaving 30800, which every tool
talks to when not told a port, to clients started by hand.
`tools/goanna-headless list` shows every instance on the machine, `stop
goanna-30851` stops one, and `shot goanna-30851 /tmp/a.png` saves the
virtual display as gamescope composites it. The MCP server below does all
of this as tools. The rules that go with it are in
`docs/agent-interfaces.md`.

`--software` renders on lavapipe and llvmpipe and never opens a GPU context.
Goanna then draws about one frame a second at 1280 by 720, which is enough
for forms and state and too slow for anything visual. It exists because the
GPU on the machine this was written on went into a state where it refused
every new context (see Limits).

The launcher sets the variables itself. Starting Godot by hand still works:

```sh
GOANNA_CONTROL=1 GOANNA_HOST=127.0.0.1 GOANNA_NAME=dev \
    /path/to/godot --path project
```

`GOANNA_CONTROL=1` listens on 127.0.0.1:30800. Any other number is used as
the port. It binds to the loopback address only, so nothing off this machine
can reach it. With the channel open the client is in test mode: it never
captures the OS pointer and asks for no focus, because a control session is
usually unattended, and a client on the desktop that grabbed the mouse took
it away from the owner in the middle of a video call. Capture is kept inside
the client instead, so Escape and the forms behave as they do for a player,
and only mouse input pushed in through the channel counts as captured: a real
pointer crossing the window does not turn the camera. The camera is driven
with `pose` and `look`. `GOANNA_NO_POINTER_CAPTURE=1` gives test mode without
the channel. A player's launch has neither and captures as always.

Then, from anywhere on the same machine:

```sh
tools/goanna-control status
tools/goanna-control tp 10 65 -20
tools/goanna-control time 0.5
tools/goanna-control set light_sun 2.0
tools/goanna-control shot /tmp/a.png
tools/goanna-control inspect target=materials
tools/goanna-control inspect target=materials texture=default_stone.png
tools/goanna-control inspect target=scene depth=2 limit=100
```

The port is not inferred at either end, and on a machine running more than
one client that is a hazard rather than a nuisance. `tools/goanna-control`
talks to 30800 unless you pass `--port`, and does not read `GOANNA_CONTROL`,
so a client started on another port is not found and a client that happens
to be on 30800 is. The client side has the mirror of it: whoever binds 30800
first holds it for everybody, so a second client launched without
`GOANNA_CONTROL` set silently has no channel of its own while the tool
cheerfully drives the first one.

This has already happened twice in one evening, in both directions, between
two people who each thought they were driving their own client: a settings
change and a teleport went into someone else's session each time. Give every
session its own port, set `GOANNA_CONTROL` explicitly when you launch, pass
`--port` on every call, and check `label` or `status` before you believe a
reply came from the client you meant.

The wire format is one JSON object per line over TCP,
`{"id": 1, "cmd": "tp", "args": {"x": 10, "y": 65, "z": -20}}`, and one
reply object per line, so anything that can open a socket can drive it.
`tools/goanna-control` is a convenience, not the interface. A line that does
not start with a brace is read as `cmd key=value key=value`, which makes the
channel usable from `nc` when something is wrong with the tooling.

One command runs at a time. Several of them wait on frames, and two
overlapping camera moves would each photograph the other's pose.

## Commands

`help` returns the current list. As of this writing:

| Command | What it does |
| --- | --- |
| `ping` | Liveness, and how long the client has been up. |
| `label <text>` | What this session is testing. Shown on screen; see below. |
| `status` | Session state, camera pose, block, entity and media counts. |
| `inspect target=<kind>` | Structured scene, render, material, sky, entity, inventory or node data. |
| `tp x y z` | Teleport through the server, then wait for the blocks to arrive. |
| `pose x y z pitch= yaw=` | Place the camera. No server move, so use it for viewpoints, not for travel. |
| `look x y z` | Aim the camera at a point. |
| `fly on` | Fly camera, or walk with collision. |
| `time <0..1>` | Override the time of day, for this client only. Below 0 hands the clock back to the server. `server=true` also runs `/time`, which moves it for everyone, and is what you want whenever the sky itself matters: see below. |
| `weather <kind>` | The game's own weather command. `fake=true` injects a local spawner instead. |
| `spawn <name> [x y z]` | `/spawnentity` through the server. |
| `give <item> count=` | `/giveme` through the server. |
| `chat <text>` | Send a chat line and return what the server said back. |
| `set <key> <value>` | Any settings panel key, applied live through the same code the panel uses. |
| `get <key>`, `settings` | One value, or every value with the value it had at startup. |
| `deviations` | What has been moved since startup. See below. |
| `shot <path>` | Settle, capture a PNG, write a JSON sidecar beside it. |
| `wait settle=` / `frames=` / `ms=` / `expr=` | Wait on a condition. |
| `reload_shader <res://path>` | Recompile a `.gdshader` from disk, in place, without a relaunch. |
| `call <method> args=[...]` | Any `GoannaClient` method. Three numbers become a `Vector3`. |
| `eval <expr>` | One GDScript expression, evaluated against `main`. |
| `run src=<snippet>` | A GDScript snippet, for anything with a loop or a wait in it. |
| `quit` | Disconnect and close the client. |
| `ui_tree` | The open form or menu: elements, slots, labels, rectangles and state. See below. |
| `ui_click`, `ui_hover`, `ui_scroll` | Click, rest the pointer on, or scroll a target, with events pushed inside the client. |
| `ui_type name= text=` | Click into a field and type, optionally clearing it first and pressing Enter after. |
| `key <name or action>` | Press, release or tap a key or a game action: `inventory`, `menu`, `hotbar3`, `dig`. |

### Two clocks, and the one that will bite you

`time` moves this client's clock and nothing else. The server keeps its own,
and a game computes its sky from the server's: Mineclonia's night sky
colours, its weather and its day night ratio all come from there. So a
client side override moves the sun and leaves the sky it is meant to be
setting behind, and the two disagree silently.

Two sessions lost measurements to this in one evening. One noticed only
because the frames came back too dark to use. Frames that are subtly wrong
rather than obviously wrong are the case that will cost someone a day, and
nothing in the reply says which clock you moved.

So: `time` for a quick look at the sun, and `time <t> server=true`, or a
plain `/time` over `chat`, for anything where the sky, the weather or the
ambient light is part of what you are measuring. If a night measurement
comes back brighter or darker than it should, check the server's clock
before you believe the renderer.

`run` is the one that matters most. `eval` handles a single expression, so
anything with a variable, a loop or a wait in it goes here instead. The
snippet becomes the body of a function with `main`, `client`, `cam` and `ui`
in scope, it may `await`, and whatever it returns comes back as JSON:

```sh
tools/goanna-control run src='var p = client.server_player_position()
var y = int(p.y) + 4
while y > int(p.y) - 20:
	var n = client.node_name_at(Vector3(p.x, y, p.z))
	if n != "air" and n != "ignore":
		return {"y": y, "node": n}
	y -= 1
return {"node": "nothing found"}'
```

### Reading an entity's animation

`call entity_animation args=[<id>]` says what an entity's skeleton is doing,
for checking animation against what the server sent. Ids come from
`inspect target=entities`. `tracks` is what plays on the mesh, numbered from
1 as the Lua API numbers them, each with its frame, speed, range, priority,
loop flag and blend progress. `server_tracks` is what the server last set,
which differs from `tracks` while the local player's own animations play.
`joints` gives each joint's local transform as the tracks alone left it,
before bone overrides and Goanna's first-person posing, beside its rest
transform and an `at_rest` flag. Transforms are in the mesh's own terms:
mesh units, and Irrlicht's handedness rather than Godot's. It reads and
changes nothing.

## Using the UI from inside the client

Forms, menus and keys are driven from inside the client, so no OS pointer or
keyboard is involved and nothing on the desktop moves. Each action is a
Godot `InputEvent` handed to `Input.parse_input_event`, the entry an OS event
takes: it updates `Input`'s own state (a held key moves the player), then
goes through the window, the viewport, the GUI and `_unhandled_input` as a
player's would. A formspec button pressed this way sends the server what a
click sends. The code is `project/control_ui.gd`; the formspec is read
through `describe()` in `project/ui/formspec.gd`, which only reads.

```sh
C="tools/goanna-control --port 30851"
$C key key=inventory                  # the I key: opens the inventory
$C ui_tree                            # what is open, and where everything is
$C ui_click text=Tools                # a creative tab, found by its tooltip
$C ui_hover item=mcl_clock:clock      # the tooltip of the slot holding it
$C ui_type name=search text=torch enter=true
$C ui_click 'slot={"list":"main","index":2,"location":"current_player"}'
$C ui_scroll item=mcl_core:stone amount=3
$C key key=Escape
```

`ui_tree` says which window is open (`none`, `inventory`, `form`,
`pause_menu`, `settings_menu`, `death_screen`), and for a form lists every
named element with its formspec type, text, tooltip, rectangle in viewport
pixels and state (focus, pressed, current tab, value), every inventory list
with its visible slots and what they hold (a scrolled out slot is counted,
not listed), the labels, the element with the focus and the tooltip on
screen. A Goanna menu is listed as its buttons and fields.

The actions take a target: `name` (a formspec element, with `tab` for a tab
header, as a caption or a number from 1), `slot` (`list`, `index` and, when
the form has the list twice, `location`), `item` (the first visible slot
holding it), `text` (a caption, a tab, a label or a named element's tooltip,
exact first, then ignoring case, then contained; more than one match is an
error unless `nth` picks one), or `x` and `y`. A target scrolled out of view
is refused rather than clicked through. `ui_click` takes `button`, `double`,
`shift`, `ctrl` and `alt`. `ui_hover` waits for the tooltip and returns it.
`ui_scroll` takes `amount` in wheel notches, negative for up. `ui_type`
clicks the field named, types `text` a key at a time, and takes `clear` and
`enter`. `key` takes a key name (`Escape`, `I`, `E`, `1`, `F5`, `Enter`) or a
game action (`inventory`, `menu`, `chat`, `forward`, `jump`, `sneak`,
`aux1`, `hotbar1` to `hotbar10`, `dig`, `place`), and `action` tap, press or
release, with `hold_ms` between.

Replies say what the pointer landed on (`hit`), which fields the form sent
(`fields_sent`, read from the form's own signal), which slots it acted on,
whether the server answered with a new form (`form_rebuilt`), and what is
open afterwards. That is the check that the server received a press: a
creative tab clicked this way comes back as a rebuilt form listing that
tab's items, and a stack moved into the hotbar shows up in the next
`ui_tree`, because the inventory it reports is the server's.

Mouse events carry the channel's own device id, which is how test mode tells
them from a real pointer. Key events keep device 0, because Godot's built in
actions, such as Enter submitting a field, only match the device they were
defined for. A dropdown opens but its list cannot yet be picked from, and
dragging a stack across slots with the button held has no command.

## The overlay, so a watching human knows what is going on

A window that is not moving looks the same whether the client is wedged, the
server has stopped answering, or the agent driving it is simply thinking.
Telling those apart by watching has cost real time here, so a client with the
control channel open draws a small overlay in the top right corner saying
what it is doing:

```
far tier lighting: midnight comparison
running wait  8.4s
```

The first line is the session's label, set with `label <text>` or with
`GOANNA_TEST_LABEL` at launch. The second is the command in flight and how
long it has been running, or, when nothing is in flight, how long the client
has been idle and which command finished last. A failed command says so and
the overlay turns orange until the next one succeeds.

How to read it: a number that keeps climbing under one command name is a
stall, in the client or in the server it is waiting on. A number that resets
is progress. `idle` climbing means the client is fine and whatever is driving
it has not asked for anything, so look at the agent rather than the client.

It is drawn as part of the HUD, and `shot` hides the HUD while it captures,
so the overlay never appears in a screenshot the tooling takes. That is
deliberate: it is for the person watching the window, and captures stay
clean. To photograph it, grab the viewport directly with `run` instead.

## What it may and may not do

Everything that changes the world goes to the server as an ordinary chat
command, the same text a vanilla client sends, and needs the same
privileges. `tp` is `/teleport`, `give` is `/giveme`, `weather` is the
game's own command. Nothing here reaches past the protocol, and nothing
here asks for anything a vanilla client cannot ask for. That is the boundary
in `CLAUDE.md` and the channel does not move it.

Because a server answers a refused command in chat and nowhere else, the
command verbs return `server_said` with what came back, and set `refused`
when it was a refusal. Without that, a missing privilege reads as success:

```
$ tools/goanna-control weather rain
{"sent": "/weather rain", "refused": true,
 "server_said": ["You don't have permission to run this command
                  (missing privileges: weather_manager)."]}
```

What the channel does change locally is the view: the camera, the time of
day override, and the lighting and material settings the settings panel
already exposes. Those go through `game_ui._apply_setting`, the same path
the panel uses, so there is one implementation rather than two.

Not every game has every command. Mineclonia has no `/spawnentity`, so
`spawn` is refused there and a mob comes from `give mobs_mc:sheep` and
placing the egg. `chat` is the way through for anything a game spells
differently.

## Cold verify, which is not optional

Tuning a value in a live process and then reporting it as working is not the
same as the committed code doing it, and `CLAUDE.md` forbids the second
claim on the strength of the first. A live channel makes that mistake much
easier to make, so the channel is built to make it hard to make quietly.

The value of every setting is recorded before the first command lands.
`deviations` lists what has moved since, along with the time of day override
and any shader hot loaded with `reload_shader`, which is the sharpest case:
the frame came from code on disk, and code on disk is not necessarily code
that is committed. Every `shot` reply carries the same list, and writes it
into a JSON sidecar beside the PNG along with the camera pose, the time of
day and the block count at capture.

So the rule is: a reading taken with deviations listed is a lead, not a
result. Write the value into the source, relaunch with nothing set, take it
again, and report that one. `README.md` and `PLAN.md` only ever get the
second number.

One setting is expected to show up here on a completely untouched profile:
`far_distance` defaults to whatever the server's far rendering grant turns
out to be (`docs/launch-target.md` task 2d), not to the fixed number its C++
field starts at, so the baseline taken on the first command (usually before
a grant has arrived) and the value once the world has streamed in
legitimately differ. That is the code adapting, not a live tweak; check
`render_stats().far_grant` against it before treating it as a lead worth
chasing.

## Driving it from an agent

`tools/goanna-mcp` is an MCP server over the channel, so an agent can drive
the client as tools rather than by composing shell commands. Register it
with:

```sh
claude mcp add goanna /path/to/goanna/tools/goanna-mcp
```

The preferred read tool is `goanna_inspect`. Its `capabilities` target
identifies the interface as `goanna-dev/0.1` and lists the stable observation
targets. These cover the common diagnostic questions directly; `goanna_run`
remains the privileged escape hatch for a one-off investigation.

For a PBR release check, pass a game texture filename to the `materials`
target. `resolved` reports whether the albedo, `_n` and `_s` files were found
through the active Luanti texture source and their dimensions. `built` reports
how many rendered array materials actually have normal and specular arrays
bound. This distinguishes an enabled slider from a pack that is genuinely
loaded and connected to the shader.

It speaks MCP over stdin and stdout as newline delimited JSON-RPC, with
nothing outside the standard library, so there is nothing to install.

Everything it exposes is reachable from a shell with `tools/goanna-control`
and `tools/goanna-headless`, because the channel is the interface and this is
a wrapper over it. What the wrapper adds is the session: starting clients,
rebuilding and relaunching them after a C++ change, and handing back a shot
that `shotcheck.py` has already looked at.

Clients are instances. `goanna_session action=start` launches Goanna from
any checkout or worktree (`project`), headless by default, on the control
port given (refused if taken) or on a free one, and returns an instance id
such as `goanna-30851`. Every other tool takes that id as `instance`, and may
leave it out while the session has exactly one client running. Every reply
starts with the instance and the control port it acted on, because two
sessions once drove each other's clients through a shared port for a whole
evening without noticing. `action=start_vanilla` runs the vanilla client,
`action=list` shows every instance on the machine and which ones this
session started, and `action=stop` stops only this session's own unless
given `force=true`. A client somebody started by hand is reached with
`action=attach control_port=N`, or, as before, by leaving `instance` out
when this session has none and one answers on 30800 (or
`GOANNA_CONTROL_PORT`). `headless=false` opens a window on the desktop, for
the rare case where the owner has asked to watch one.

A typical run, as tool calls:

```
goanna_session  action=start project=<worktree> control_port=30851
                port=30000 name=dev                -> instance goanna-30851
goanna_ui       instance=goanna-30851 action=key key=inventory
goanna_ui       instance=goanna-30851 action=tree
goanna_ui       instance=goanna-30851 action=click text=Tools
goanna_ui       instance=goanna-30851 action=type name=search text=torch enter=true
goanna_shot     instance=goanna-30851 hide_ui=false path=/tmp/inv.png
goanna_session  action=start_vanilla port=30000 name=ref -> instance vanilla-ref-30000
goanna_shot     instance=vanilla-ref-30000 wait_ms=20000 path=/tmp/ref.png
goanna_session  action=stop instance=vanilla-ref-30000
goanna_session  action=stop instance=goanna-30851
```

There are ten tools rather than one per command, because a tool schema costs
context whether or not it is used:

| Tool | What it covers |
| --- | --- |
| `goanna_session` | start, start_vanilla, stop, restart, status, list, attach, and `build=true` to run cmake first. The only way to see a C++ change, and the way to confirm a reading on a clean client. |
| `goanna_status` | Where the client is and what it is holding, with the deviations list. |
| `goanna_inspect` | The structured observations: scene, render, materials, sky, entities, inventory, node. |
| `goanna_view` | `teleport` through the server, or `position`, `look_at`, `pitch`, `yaw`, `fly`. |
| `goanna_world` | Time, weather, spawn, give, chat. Reports what the server said and whether it refused. |
| `goanna_settings` | Get, set or list everything in the settings panel. |
| `goanna_shot` | Settle, capture, sidecar, and the shotcheck reading; `method=gamescope` for the composited virtual display, `method=x11` for the window's own pixels, the default for the vanilla client. |
| `goanna_ui` | tree, click, hover, type, scroll and key, as in the section above. |
| `goanna_run` | A GDScript snippet in the client. The one that does not run out. |
| `goanna_command` | Any channel command by name: `reload_shader`, `wait`, `help`. |

After `tools/goanna-mcp` changes, a running Claude Code session keeps the old
server until it reconnects: `/mcp` and reconnect `goanna`, or restart the
session. Registration does not need repeating, since it names the file.

## Vanilla reference frames

`tools/goanna-headless vanilla --server 127.0.0.1:30000 --name ref` (or
`goanna_session action=start_vanilla`) runs the Luanti Flatpak in headless
gamescope, joined straight to the server with `--go`, with a configuration
file of its own under `~/.var/app/org.luanti.luanti/goanna-headless/`, so
the owner's own client settings are never touched. The sandbox gets no
Wayland socket, so it can only reach gamescope's X display.

A frame is taken with `tools/goanna-headless shot <id> <path>` or
`goanna_shot`, by one of two routes, neither of which involves a window, a
key or the pointer. `x11`, the default for the vanilla client, reads the
client window's own pixels from the instance's nested X display with
ffmpeg's `x11grab`, after finding the window with `xwininfo`; it refuses the
desktop's display. `gamescope`, the default for Goanna, is gamescope's own
screenshot of the virtual display (`gamescopectl screenshot`, sent to that
instance's gamescope socket and nobody else's). Under `--software` the
gamescope route showed the vanilla client's loading screens but returned
pure black once it was in game, while `x11` returned the game; with the GPU
neither route has been tried on the vanilla client yet.

The vanilla client cannot be steered: it has no control channel, and
nothing here types into it. It looks wherever the server puts it, so frame
it from the server side (a spawn point, a teleport by an admin, a test mod),
and allow it time to load before the shot: under `--software` that is
minutes.

## Limits

`shot` needs a real display. Godot's own `--headless` driver has only a
dummy renderer, so there is no viewport texture to save, the same
restriction `tools/test-formspec.sh` works around. Headless gamescope is a
real display as far as Godot is concerned, so under the launcher `shot`
works. The UI commands work under Godot's `--headless` too, which is useful
when there is no GPU at all, though its window is 64 by 64 until a `run`
snippet sets `main.get_window().size`.

On 2026-09-19 the NVIDIA driver on the machine this was written on went into
a reset-required state (Xid 51, then Xid 154 asking for a function level
reset), after which every new Vulkan device failed with `vkCreateDevice`
until a reboot, while processes that already had one carried on. It came
within a minute of two headless gamescope sessions starting, one of them this
work's first probe, after a single headless run earlier had been fine. The
cause is not known. Until it is, treat two GPU instances at once as
something to verify rather than assume, and use `--software` when the GPU is
in that state: `journalctl -k | grep NV_ERR_RESET_REQUIRED` says so.

gamescope does not exit when its child does and ignores SIGTERM. The
launcher's supervisor stops it with `gamescopectl shutdown` on the
instance's own socket and kills its process group only if that fails.

C++ changes still need a rebuild and a relaunch: `project/goanna.gdextension`
sets `reloadable = false`, which is right while the session runs on its own
thread. Shaders, GDScript, settings, materials and the camera are all live.
The channel makes the cold path cheaper rather than unnecessary: rebuild,
relaunch, `tp` to the same absolute position, `time` to the same hour, then
`shot`, and the A/B is honest because both halves were framed by the same
script rather than by memory.

Which matters, because the framing traps are real and repeat. A fresh
`GOANNA_NAME` spawns at a random point, so two names photograph two
different places. The server streams only blocks in the view cone of the
reported look direction, so a view facing away from the pose the client
reported sees nothing. Both are avoidable once the sequence lives in a
script instead of in a shell history.
