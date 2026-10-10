# Shader pack testing

Goanna can run the screen space part of an Iris or OptiFine shader pack:
the `composite` and `final` programs, their `DRAWBUFFERS`, the `colortexN`
ping pong, `depthtex0`, `noisetex` and the uniform block. This document
describes the repeatable test for that chain. It is a smoke test, not a
conformance suite.

## The proof pack

`project/tests/shaderpacks/proof/` is a deliberately small pack written in
the legacy OptiFine dialect (`#version 120`, `varying`, `gl_FragData`,
`texture2D`, an `#include`, a const directive inside a comment), so the
translator has to do real work. It paints marks that a script can measure
rather than a look that a person has to judge:

- `composite.fsh` writes the scene's luma to `colortex1` and the inverted
  scene to `colortex2`, through `DRAWBUFFERS:12`.
- `final.fsh` shows the graded scene on the left third, `colortex2` on the
  middle third and `colortex1` (pure grey) on the right third.
- A magenta band (1, 0, 1) covers the bottom 4 per cent of the frame.
- Three 48 px squares sit along the top left edge: one pulses red with
  `frameTimeCounter`, one shows `depthtex0` at screen centre as a grey, and
  one shows `noisetex`.

The log line `Goanna Iris: proof ready, 2 of 2 passes compiled` means both
programs translated and compiled; any `ERROR: Goanna Iris:` line means one
did not.

## Running the test

From anywhere, with a Luanti server already listening:

```sh
tools/test/test-shaderpack.sh
```

The script finds Godot the same way `tools/test/test-formspec.sh` does (`godot`
or `godot4` on `PATH`, or `GODOT_BIN=/path/to/godot`), launches Goanna in
headless gamescope through `tools/goanna-headless` with `GOANNA_SHADERPACK`
pointing at the proof pack and `GOANNA_SHOT` set, waits for the client to
save the screenshot `a.png` that `main.gd` takes about eight seconds in and
quit (`goanna-headless wait`, stopping it after 120 s), then checks the log
and the image. The client's exit status does not reach the launcher, so a
crash is read from the log instead. `GOANNA_HOST` and `GOANNA_PORT` choose the
server (default `127.0.0.1:30000`); `GOANNA_NAME` and `GOANNA_PASS` choose
the player (default `shaderproof`, no password). `GOANNA_TOD` and
`GOANNA_VIEW` pass through. On failure it prints the log path and keeps the
run directory; `GOANNA_SHADERPACK_TEST_DIR` names that directory, and a
directory named this way is kept on success too. It holds the client's log
(`goanna.log`, gamescope's output included) and `instance.json`, the
launcher's record of the run.

The image check is `tools/test/shaderpack_check.py`, which can also be run on
its own against any PNG:

```sh
tools/test/shaderpack_check.py --json /path/to/a.png
```

It prints one `PASS` or `FAIL` line per check and exits non zero if any
fails. The checks are: the bottom band is magenta, the right third has near
zero chroma, the middle third does not, the noise square has a high
standard deviation, and the frame is not one flat colour. `--json` dumps the
raw measurements. A frame taken without the pack fails three of the five.

## What it needs

- The GPU, through the launcher. The screenshot is read back from Godot's
  own viewport, which renders for real in headless gamescope, so the pixels
  are the ones a desktop window gives and no window reaches the desktop.
  Godot's `--headless` draws nothing and cannot produce one. The window is
  1600 by 900, the project's own size, which the desktop runs had. The
  launcher takes the shared GPU lock; the script waits up to
  `GOANNA_LOCK_WAIT` seconds (default 1800) for it, and still refuses while
  another game client or compute job is on the GPU.
  `GOANNA_SOFTWARE=1` renders on lavapipe instead, which checks the harness
  but not the look.
- A Luanti server answering on the chosen host and port, with a player name
  it will accept. If nothing answers, or the server denies the name, the
  script says so and fails rather than judging a frame of empty sky.
- A built `project/bin/` extension, as for any Goanna run.

Last run on a desktop window: 2026-08-21, Godot 4.5.1, Mineclonia on a local
Luanti 5.16 server, pass. Through the launcher: 2026-10-10, Godot 4.5.1,
Mineclonia (a fresh world) on a local Luanti 5.17.0 server, with
`GOANNA_SOFTWARE=1` (lavapipe), pass on all five checks at 1600 by 900. It
has not yet been run through the launcher on the GPU: the card was held by
another Godot for the whole session.

## What it does not prove

- Only the screen space chain is exercised: `composite` and `final`. There
  are no `gbuffers_*` programs in the proof pack, so nothing about terrain,
  entity or sky shading under a pack is tested.
- Only the proof pack is run. Real packs use far more of the Iris surface
  (more passes, `shadow`, custom uniforms, `#ifdef` option menus, buffer
  formats and flips) and a pass here says nothing about them. See
  `docs/design/iris-compat.md` for the supported surface.
- The depth and pulse squares are drawn but not measured. Depth at screen
  centre depends on what the player happens to be looking at, and the pulse
  depends on when the shot lands, so neither gives a stable number.
- The thresholds are loose on purpose. The test answers "did the chain draw
  at all", not "did it draw the right values".
