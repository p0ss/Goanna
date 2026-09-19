# Developer guide

This is the entry point for contributors. The repository contains a Godot
project, a small C++ extension, and selected Luanti client code. The Luanti
and godot-cpp directories are submodules.

## Architecture

Goanna keeps Luanti's networking, protocol, world state, movement prediction,
node definitions, inventory and meshing rules. Godot provides the window,
scene tree, renderer, materials, lighting, models, UI and input. The boundary
is deliberately narrow so Luanti releases can be tracked without maintaining
a second game engine.

The client has three important rendering paths:

1. Near terrain: full block meshes assembled into regional batches.
2. Far terrain: persistent block data and derived LOD chains, server summaries,
   occlusion and coarser regional meshes.
3. Presentation: Godot environment, sky, atmosphere, materials, entities,
   particles and optional Iris screen-space effects.

Background meshing consumes immutable snapshots. Render-thread objects are
replaced only after a completed mesh is ready, so a detail transition should
not remove the old surface before its replacement exists.

## Build

```sh
git clone --recurse-submodules --shallow-submodules \
  https://github.com/p0ss/Goanna.git goanna
cd goanna
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build
```

The executable is the Godot project in `project/`; the CMake target builds
the native extension loaded by that project. Full platform dependencies and
flatpak notes are in [building.md](building.md).

## Tests and validation

Start performance work with the [rendering baseline](baseline.md). It defines
the control condition, capture views and acceptance gates used to separate
geometry/streaming regressions from optional visual-system costs.

To measure what a graphics setting costs, or to show a renderer change has
not made things slower, use the [benchmark harness](benchmark.md). It runs a
plan of setting variants through load, steady state and two movement tests,
records every frame rather than one line a second, and reports medians, 1%
lows, stability and what each frame was waiting on, against a noise floor it
measures on the same machine in the same session.

Native tests are built in `build/`:

```sh
./build/goanna_lod_test
./build/goanna_mesh_pool_test
./build/goanna_light_test
```

Godot integration checks can be run headlessly with the project's Godot
binary, for example:

```sh
Godot --headless --path project \
  --script res://tests/local_server_terrain_diffusion.gd
```

Local server discovery (including system game paths outside the desktop
session's `PATH`) can be checked with:

```sh
godot --headless --path project --script res://tests/local_server_discovery.gd
```

The Appearance grade's twilight and night bypass, its curve endpoints and
monotonicity, and its texture cache are checked with:

```sh
godot --headless --path project --script res://tests/look_grade.gd
```

An asset bundle's archive hash, payload hashes and composed profile are
checked by installing one into a scratch root. It names the bundle and the
hash it must match, so it also demonstrates that a superseded hash is
refused:

```sh
GOANNA_TEST_ASSET_BUNDLE=dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip \
GOANNA_TEST_ASSET_SHA256=$(python3 -c "import json;print([b for b in \
  json.load(open('asset_bundles/catalogue.json'))['bundles'] \
  if b['id']=='org.goanna.minetest-game.terrain'][0]['sha256'])") \
godot --headless --path project --script res://tests/asset_store_install.gd
```

The catalogue wiring, that `catalogue_url` is absolute and that every bundle
URL is absolute so nothing has to resolve against the catalogue's own
location, is checked with:

```sh
godot --headless --path project --script res://tests/asset_catalogue.gd
```

The terrain world catalogue that the world picker is built from, including
that every world has a usable hash, size, tile window and bundled preview, is
checked with:

```sh
godot --headless --path project --script res://tests/terrain_catalogue.gd
```

Point it at a downloaded world as well to check the published archive
unpacks to the tile window its catalogue entry claims, which is the step
between a verified download and a world that loads:

```sh
GOANNA_TEST_TERRAIN_ARCHIVE=/path/to/tdl-default-1m-v4.zip \
GOANNA_TEST_TERRAIN_ID=tdl-default-1m-v4 \
godot --headless --path project --script res://tests/terrain_catalogue.gd
```

Use `git diff --check` and the style checker before submitting. Visual
fixtures and deterministic capture conventions are described in
[validation.md](validation.md), [building.md](building.md) and
[shader-pack testing](shaderpack-testing.md).

## Technical references

- [Distant terrain](far-rendering.md): storage, summaries, LODs, occlusion,
  seams and server grants.
- [Materials](materials.md) and [PBR plan](pbr-plan.md): material inputs,
  shader attributes, authored maps and remaining work.
- [Mesh attributes](mesh-attributes.md): the vertex data contract.
- [Control channel](control-channel.md) and [capabilities](capabilities.md):
  optional server-authorised features.
- [Interface style](interface-style.md): the dark glass style, the rule for
  what in a form is chrome and what is content, legibility and cost.
- [Protocol coverage](protocol-coverage.md): transplanted protocol support.
- [Transplanting](transplanting.md): how Luanti source changes are tracked.
- [Iris compatibility](iris-compat.md): shader-pack boundary and status.
- [Launch target](launch-target.md): release acceptance criteria.
- [Roadmap](roadmap.md): current priorities and dependencies.

## Contribution rules

Keep changes at the narrowest layer that can solve them. Preserve upstream
copyright headers in transplanted code, document intentional deviations, and
add a focused test or visual fixture for behaviour that can regress. Avoid
recording dates, private debugging conversations or one-off measurements in
the system description; put reproducible measurements in validation notes.
