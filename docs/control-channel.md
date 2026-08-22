# The control channel

A loopback socket into a running client, so it can be driven and questioned
while it runs instead of being relaunched for every question. It is a
development aid, not a feature, and it is off unless you switch it on.

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

```sh
GOANNA_CONTROL=1 GOANNA_HOST=127.0.0.1 GOANNA_NAME=dev \
    /path/to/godot --path project
```

`GOANNA_CONTROL=1` listens on 127.0.0.1:30800. Any other number is used as
the port. It binds to the loopback address only, so nothing off this machine
can reach it, and with the channel open the client does not grab the mouse,
because a control session is usually unattended. Escape still toggles it.

Then, from anywhere on the same machine:

```sh
tools/goanna-control status
tools/goanna-control tp 10 65 -20
tools/goanna-control time 0.5
tools/goanna-control set light_sun 2.0
tools/goanna-control shot /tmp/a.png
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
| `tp x y z` | Teleport through the server, then wait for the blocks to arrive. |
| `pose x y z pitch= yaw=` | Place the camera. No server move, so use it for viewpoints, not for travel. |
| `look x y z` | Aim the camera at a point. |
| `fly on` | Fly camera, or walk with collision. |
| `time <0..1>` | Override the time of day. Below 0 hands the clock back to the server. `server=true` also runs `/time`, which moves it for everyone. |
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

It speaks MCP over stdin and stdout as newline delimited JSON-RPC, with
nothing outside the standard library, so there is nothing to install.

Everything it exposes is reachable from a shell with `tools/goanna-control`,
because the channel is the interface and this is a wrapper over it. What the
wrapper adds is the session: starting the client, rebuilding and relaunching
it after a C++ change, and handing back a shot that `shotcheck.py` has
already looked at.

There are eight tools rather than one per command, because a tool schema
costs context whether or not it is used:

| Tool | What it covers |
| --- | --- |
| `goanna_session` | start, stop, restart, and `build=true` to run cmake first. The only way to see a C++ change, and the way to confirm a reading on a clean client. |
| `goanna_status` | Where the client is and what it is holding, with the deviations list. |
| `goanna_view` | `teleport` through the server, or `position`, `look_at`, `pitch`, `yaw`, `fly`. |
| `goanna_world` | Time, weather, spawn, give, chat. Reports what the server said and whether it refused. |
| `goanna_settings` | Get, set or list everything in the settings panel. |
| `goanna_shot` | Settle, capture, sidecar, and the shotcheck reading. |
| `goanna_run` | A GDScript snippet in the client. The one that does not run out. |
| `goanna_command` | Any channel command by name: `reload_shader`, `wait`, `help`. |

The client it starts inherits this server's environment, so a host that
trims that environment leaves Godot without a display and the launch fails.
The failure says so rather than reporting an exit code, and the fix is to
pass `DISPLAY`, `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in the tool's `env`
argument, or to start the client yourself and let the tools attach to it.

## Limits

`shot` needs a real display. Godot's headless driver has only a dummy
renderer, so there is no viewport texture to save, the same restriction
`tools/test-formspec.sh` works around.

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
