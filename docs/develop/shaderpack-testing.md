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

Several packs have since run this way; see
[Shader pack status](shaderpack-status.md).

## The Shader pack setting

Players choose a pack in Settings, Shader packs
(`project/ui/shader_pack_row.gd`, built by both the main menu and the
in-game panel), or on Start Game's Shader packs tab beside Mods
(`build_tab`). Join Game keeps a compact Shaders row (`build_join_picker`).
All list the packs in `user://shaderpacks` and write the same setting.
`project/game/shader_packs.gd` does the rest:

- A pack is a directory holding `shaders/`, or a `.zip` with `shaders/` at
  its top or one directory down (some downloads wrap the pack in a folder).
  A zip is unpacked once into `user://shaderpack_cache/<name>-<mtime>/`,
  under a directory named after the zip, so the loader and its log lines
  name the pack as the player does; a replaced zip unpacks afresh and the
  old copy is removed. Entries that would land outside the cache are
  skipped.
- The choice is saved by name as `shader_pack` in the `settings` section
  of `goanna.cfg`. Each pack's option overrides are saved in a section of
  their own, `shaderpack_options/<name>`, only where they differ from the
  pack's default.
- Options are found as Iris finds them: a value-less `#define` (on) or a
  commented one (off) that some source tests with `#ifdef`, `#ifndef` or
  `defined`, and a `#define NAME value` whose comment lists its allowed
  values in brackets. Where `shaders.properties` has `screen` lines, the
  list follows them, headings and all, and shows only what they show; the
  names come from `shaders/lang/en_US.lang` where the pack has one. The
  conditionals around screen lines are not run, `const` options and
  `<profile>` are not offered, and sliders are shown as lists.
- At each join `main.gd` asks for the chosen pack only when
  `GOANNA_SHADERPACK` is unset, so the render service, this document's
  scripts and any run that sets the variable are unaffected. The pack's
  saved overrides reach both halves of the loader by setting
  `GOANNA_SHADERPACK_OPTIONS` in the process, with any value the variable
  held at start winning name by name.
- `main.gd` prints `shader pack setting: NAME from PATH options ...`, then
  a one line summary of `report()` at load and again once the chain has
  compiled on the GPU, and saves that line in the `shaderpack_status`
  section, which the settings row shows under the picker.

The game scene is built afresh at each join (`menu.gd` and `game_ui.gd`
change to `main.tscn`), so a change applies at the next join; nothing
switches packs in a running world.

To try a pack this way in a headless client, write the pack into
`$XDG_DATA_HOME/godot/app_userdata/Goanna/shaderpacks` and the setting
into `goanna.cfg` beside it before starting it through `tools/goanna-headless`
with `--env XDG_DATA_HOME=...`. Through the render service, write the
profile the service would (`goanna_render.write_profile`) into a directory
of your own, add the two keys, and give the job's variant
`"env": {"XDG_DATA_HOME": "..."}`.

Last run that way: 2026-10-13, Godot 4.5.1 on the RTX 3090 through the
render service, Mineclonia on a local Luanti 5.17.0 server (a copy of a
real world). With `GOANNA_SHADERPACK` unset, the setting named
`Mellow.zip` (Mellow zipped one directory down) with `VIGNETTE_OPACITY`
saved at 1.5: the client unpacked it into the cache, logged
`shader pack setting: Mellow.zip from ... options VIGNETTE_OPACITY=1.5`
and `Goanna Iris: Mellow ready, 9 of 9 passes compiled`, and saved the
line the row shows. The frame had Mellow's grey sky and grade and a heavy
vignette, against Goanna's own look in the variant without the setting.

## What it does not prove

- The proof pack exercises only the screen space chain: `composite` and
  `final`. There
  are no `gbuffers_*` programs in the proof pack, so nothing about terrain,
  entity or sky shading under a pack is tested.
- The proof pack exercises little of the Iris surface. Real pack results
  are recorded separately in the status page; a successful compile alone
  does not establish visual correctness. See `docs/design/iris-compat.md`
  for the supported surface.
- The depth and pulse squares are drawn but not measured. Depth at screen
  centre depends on what the player happens to be looking at, and the pulse
  depends on when the shot lands, so neither gives a stable number.
- The thresholds are loose on purpose. The test answers "did the chain draw
  at all", not "did it draw the right values".

## History and lifetime regressions

`project/tests/shaderpacks/history` adds 0.1 to a preserved floating point
buffer each frame and displays it as red. Run it as a render service
variant with `GOANNA_SHADERPACK` pointing at that directory. After ten
frames the image should be solid red (255, 0, 0), apart from the client
interface. Resetting the ping pong side each frame leaves it dark red.

`tests/iris_teardown.tscn`, through `tools/goanna-headless fixture`, checks
four effect lifetimes, binding the geometry read textures and changing the
viewport's internal scale during each. Its log must say
`iris teardown: ok` without rendering errors. It is an offline GPU fixture,
not a server test.

The history pack was run on 13 October 2026 through the render service,
RTX 3090, Godot 4.5.1, a local Luanti 5.17.0 server and Mineclonia release
38561 (a copy of `r1tod1`). All 230400 pixels at 640 by 360 were (255, 0, 0).
This checks accumulation, not a real pack's temporal antialiasing.

## Eclipse lighting isolation

`tools/test/eclipse-lighting-fixture.py` prepares a stone wall, roofed
recess, lantern and pool for the render service. It copies a supplied
Eclipse pack into a new scratch directory, records source hashes and
generates day and night variants. It never changes the supplied pack or
starts a client itself:

```sh
python3 tools/test/eclipse-lighting-fixture.py /path/to/eclipse \
  --build /path/to/committed/checkout --out /tmp/eclipse-lighting
GOANNA_RENDER_STATE=/tmp/eclipse-lighting-service \
  tools/goanna-render serve --build /path/to/committed/checkout
GOANNA_RENDER_STATE=/tmp/eclipse-lighting-service \
  tools/goanna-render shoot /tmp/eclipse-lighting/job.json --no-start
GOANNA_RENDER_STATE=/tmp/eclipse-lighting-service tools/goanna-render stop
```

The checkout needs a matching compiled extension. Normal GPU checks and
the shared lock apply. `--variants baseline --phases dusk` makes one
additional time-of-day reference, with a different output directory.

All variants turn Eclipse's SSAO and soft shadows off. The baseline keeps
the rest of the pack unchanged. The other variants isolate:

- Inverse light levels: approximately invert Goanna's default Luanti
  brightness curve before supplying light coordinates. This is a probe,
  not a production correction: the inverse of averaged brightness is not
  the average of the original levels. Luanti's daytime bank also contains
  artificial light, so it is not Minecraft's separate skylight channel.
- Old lighting off: set the pack's `oldLighting` property to false. This
  removes directional face shading, not ambient occlusion.
- Neutral vertex colour: replace `gl_Color` with white. This removes tint,
  directional face shading and Goanna's combined corner/traced occlusion.
  A brighter result does not establish that removing all of these is right.
- Geometry only: remove composite/deferred programs and use an identity
  final pass. Lighting and fog inside the geometry programs still run;
  this is not an unlit albedo capture.

The generated Minecraft function builds corresponding geometry around
(1000, 64, 1000), clears its fixture volume and places the camera. Run it
only in a disposable Java world, after loading the surrounding chunks.
The final camera uses spectator mode so it does not fall. Match Eclipse's
version and options, FOV, sun direction, weather and resource pack before
comparing captures.
The two games' textures, light propagation and lamp strengths can differ;
equal clock values alone do not establish equivalent illumination. No
Minecraft client is installed, authenticated or launched by this tool.

The job records server node light levels in `GOANNA_LIGHT_PROBE_LOADED`
log entries. Reject `ignore` samples: they describe unloaded mapblocks,
not darkness. Goanna's eye-brightness uniforms remain fixed at full light
in these experiments, so camera adaptation is not tested.

On 14 October 2026, the five variants were captured at day and night on
the RTX 3090, Godot 4.5.1, local Luanti 5.17.0 and Mineclonia 38561,
using the portable extension from committed `5bdefa52`. A baseline dusk
capture was also made. Every capture reported no shader errors. Fixed
opaque wall and floor samples were identical with and without the screen
chain, locating their darkening in the geometry shading. The inverse
light-level probe changed the lantern recess modestly; removing vertex
colour darkening changed it much more. Dusk already produced warmer
sunlight with the unmodified pack. These are Goanna-side observations,
not a matched Iris comparison or a validated lighting fix. Minecraft
reference captures and performance measurements remain outstanding.

## Custom texture sampling proof

The authored `texture-sampling` pack checks adjacent `.png.mcmeta` sampling
metadata for custom shader images. Four 2x1 black/white textures declare
nearest or linear filtering and clamp or repeat addressing. The final pass
encodes midpoint, left-outside and right-outside samples into RGB. Each of
the four combinations must appear, within one level of quantisation.

```sh
tools/goanna-render minecraft tools/minecraft/texture-sampling.json \
  --only goanna --out /tmp/goanna-texture-sampling
python tools/test/check-iris-texture-sampling.py \
  /tmp/goanna-texture-sampling/calibration-goanna.png
```

Use a fresh output directory. The render service holds the GPU lock and
starts the disposable comparison server. This is a Goanna GPU contract
probe, not a visual comparison against Iris. It passed on 18 October 2026
against the unmodified Minecraft Java 26.2 dedicated server through
BridgeTest protocol 52, no Luanti game, Goanna's Luanti 5.17.0 core,
Godot 4.5.1 and RTX 3090 in headless gamescope. The observed colours were
`(127, 0, 255)`, `(255, 0, 255)`, `(127, 255, 0)` and `(255, 255, 0)`.

Custom images default to nearest filtering and repeat addressing. Valid
boolean `texture.blur` and `texture.clamp` fields select the other modes;
malformed metadata is reported. This covers ordinary custom image files,
not Minecraft's terrain mipmap strategy metadata. Native cloud geometry
still has no `gbuffers_clouds` path, independently of procedural cloud
textures sampling correctly.
