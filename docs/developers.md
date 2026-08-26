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
