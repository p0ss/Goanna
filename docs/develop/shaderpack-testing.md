# Shader pack testing

Goanna can run the screen space part of an Iris or OptiFine shader pack:
the `deferred`, `composite` and `final` programs, their `DRAWBUFFERS`, the
`colortexN` ping pong, `depthtex0` and `depthtex1`, `noisetex`, custom
textures, custom uniforms and the uniform block. This document describes
the tests for that chain: an offline compile check that needs neither a
GPU nor a server, the proof pack smoke test, and real packs through the
render service. They are smoke tests, not a conformance suite. What each
real pack does today is in [Shader pack status](shaderpack-status.md).

## The offline compile check

`tools/test/shaderpack_compile.py` loads a pack with Goanna's own loader,
translates its screen space chain exactly as the effect would, and compiles
each stage with `glslangValidator`, the front end Godot's
`shader_compile_spirv_from_source` uses:

```sh
cmake --build build --target goanna_iris_pack_test
tools/test/shaderpack_compile.py /path/to/pack [/path/to/pack ...] \
    [--out DIR] [--option NAME=VALUE ...] [--json]
```

A pack is its root (the directory holding `shaders/`) or `shaders/` itself,
unpacked. `glslangValidator` must be on `PATH` or named by `GLSLANG`; it is
packaged as `glslang` by most distributions and by conda-forge. For each
pack the script prints the passes that compile and the first error of each
that does not, the programs `shaders.properties` disables, any Iris feature
the pack requires (such a pack is refused at load), the names its custom
uniforms read that nothing answers, and for each pass the uniforms it
declares that nothing supplies, which read zero. `--out` keeps the
translated GLSL; error line numbers count from the `#line 1` that starts
the pack's own text. A pass that compiles here can still fail at pipeline
creation on the GPU, so this is the cheap first check, not the run.

The same binary, `build/goanna_iris_pack_test` with no arguments, is the
unit test for the loader: the `#if` evaluator, the conditional pass over
`shaders.properties` and over each program, the custom uniform language,
option defaults and overrides, program toggles and the proof pack. It runs
under `cmake --build build --target check`.

Packs are third party data. Keep each in its own directory outside the
repository, and do not commit one unless its licence allows it; see the
licence column of the [survey](../design/shaderpack-survey.md).

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

## Real packs

The proof pack's script takes `GOANNA_SHADERPACK` as fixed, so a real pack
goes through the render service instead: a job whose variants each set
`env` to `{"GOANNA_SHADERPACK": "/path/to/pack"}`, plus a variant without
it for comparison. Each pack is a client restart. The effect prints
`shader pack NAME {report}` when it loads, and `Goanna Iris: NAME ready, N
of M passes compiled` or `ERROR: Goanna Iris:` lines once the GPU has
compiled it, all in the client log under the service's log directory.
`report()` lists the programs `shaders.properties` disabled, the Iris
features a refused pack required, the custom uniforms' unresolved names,
the `texture.*` files loaded or skipped, and per pass the uniforms that
read zero. `GOANNA_SHADERPACK_OPTIONS=NAME=value,NAME=false` overrides a
pack's option defaults, as an Iris options file would.

None has been run this way yet; see
[Shader pack status](shaderpack-status.md).

## What it does not prove

- Only the screen space chain is exercised: `composite` and `final`. There
  are no `gbuffers_*` programs in the proof pack, so nothing about terrain,
  entity or sky shading under a pack is tested.
- The proof pack exercises little of the Iris surface. Real packs are
  checked offline (above) for loading and compiling only; the GPU run of
  real packs is still to do. See `docs/design/iris-compat.md` for the
  supported surface.
- The depth and pulse squares are drawn but not measured. Depth at screen
  centre depends on what the player happens to be looking at, and the pulse
  depends on when the shot lands, so neither gives a stable number.
- The thresholds are loose on purpose. The test answers "did the chain draw
  at all", not "did it draw the right values".
