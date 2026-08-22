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
tools/test-shaderpack.sh
```

The script finds Godot the same way `tools/test-formspec.sh` does (`godot`
or `godot4` on `PATH`, or `GODOT_BIN=/path/to/godot`), launches Goanna with
`GOANNA_SHADERPACK` pointing at the proof pack and `GOANNA_SHOT` set, waits
for the screenshot `a.png` that `main.gd` saves about eight seconds in, then
checks the log and the image. `GOANNA_HOST` and `GOANNA_PORT` choose the
server (default `127.0.0.1:30000`); `GOANNA_NAME` and `GOANNA_PASS` choose
the player (default `shaderproof`, no password). `GOANNA_TOD` and
`GOANNA_VIEW` pass through. On failure it prints the log path and keeps the
run directory; `GOANNA_SHADERPACK_TEST_DIR` names that directory, and a
directory named this way is kept on success too.

The image check is `tools/shaderpack_check.py`, which can also be run on its
own against any PNG:

```sh
tools/shaderpack_check.py --json /path/to/a.png
```

It prints one `PASS` or `FAIL` line per check and exits non zero if any
fails. The checks are: the bottom band is magenta, the right third has near
zero chroma, the middle third does not, the noise square has a high
standard deviation, and the frame is not one flat colour. `--json` dumps the
raw measurements. A frame taken without the pack fails three of the five.

## What it needs

- A graphical display. The screenshot is read back from the real viewport,
  so Godot's headless driver cannot produce one.
- A Luanti server answering on the chosen host and port, with a player name
  it will accept. If nothing answers, or the server denies the name, the
  script says so and fails rather than judging a frame of empty sky.
- A built `project/bin/` extension, as for any Goanna run.

Last run: 2026-08-21, Godot 4.5.1, Mineclonia on a local Luanti 5.16 server,
pass.

## What it does not prove

- Only the screen space chain is exercised: `composite` and `final`. There
  are no `gbuffers_*` programs in the proof pack, so nothing about terrain,
  entity or sky shading under a pack is tested.
- Only the proof pack is run. Real packs use far more of the Iris surface
  (more passes, `shadow`, custom uniforms, `#ifdef` option menus, buffer
  formats and flips) and a pass here says nothing about them. See
  `docs/iris-compat.md` for the supported surface.
- The depth and pulse squares are drawn but not measured. Depth at screen
  centre depends on what the player happens to be looking at, and the pulse
  depends on when the shot lands, so neither gives a stable number.
- The thresholds are loose on purpose. The test answers "did the chain draw
  at all", not "did it draw the right values".
