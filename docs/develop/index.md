# Developing Goanna

This section is for people who build, change or test Goanna. The
repository holds a Godot project in `project/`, a C++ GDExtension in
`src/`, Luanti client code carried across from the `luanti/` submodule,
and the optional server mod in `goanna_server_mod/`. The `luanti/`,
`godot-cpp/` and `whisper.cpp/` directories are submodules.

## Start here

- [Building and running](building.md): dependencies, the build, running
  against a server, the environment variables and release checks.
- [Contributing](https://github.com/p0ss/Goanna/blob/main/CONTRIBUTING.md):
  the relationship to Luanti, licensing, code style, commits and how work
  lands. Read it before your first change.
- [Text style](style.md): Australian English, no em dashes, and the check
  that enforces it.
- [Transplanting Luanti code](transplanting.md): how Luanti's code is
  carried, and the inventory of copied files.
- [Architecture](architecture.md): how the pieces fit. Not written yet.

## Testing and measuring

- [Testing](testing.md): native tests, headless Godot checks and the
  container checks.
- [Launch target](launch-target.md): the acceptance checklist for a fresh
  install and a release.
- [Formspec conformance](formspec-conformance.md) and
  [shader pack testing](shaderpack-testing.md).
- [Benchmarking graphics settings](benchmark.md) and the
  [rendering baseline](baseline.md).

## Materials and assets

- [PBR authoring playbook](pbr-authoring-playbook.md): how the authored
  material maps are made.
- [Community PBR review](pbr-community-review.md): the licence gate and
  acceptance for community packs.
- [Asset bundles](asset-bundles.md): how material maps are versioned,
  published and installed.

How the running client works is described subsystem by subsystem under
[systems](../systems/index.md), and plans under [design](../design/index.md).
Coding agents start from
[`AGENTS.md`](https://github.com/p0ss/Goanna/blob/main/AGENTS.md) and the
[agents](../agents/index.md) section.

## Architecture in brief

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

## Contribution rules

Keep changes at the narrowest layer that can solve them. Preserve upstream
copyright headers in transplanted code, document intentional deviations, and
add a focused test or visual fixture for behaviour that can regress. Avoid
recording dates, private debugging conversations or one-off measurements in
the system description; put reproducible measurements in validation notes.
