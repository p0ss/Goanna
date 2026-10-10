# Goanna: a Godot client for Luanti worlds

Goanna transplants Luanti's own client logic into Godot 4 as a GDExtension.
It connects to ordinary Luanti servers over the ordinary protocol and renders
what a vanilla client renders, using Godot's Forward+ pipeline: PBR
materials, SDFGI, SSAO/SSIL, volumetric fog, real shadows, colour grading.
It is a visuals-first client. It is deliberately **not** a low-spec client:
Forward+ only, Vulkan required, no fallback renderer.

Goanna started as the visual-ambition lane of a larger, separate game
project, and became its own project the moment its first images made clear
the wider Luanti community would plausibly use it regardless of that game.

This is the founding plan, written in August 2026 and kept for the
decisions it settled and the reasons behind them. The current priorities
are in the [roadmap](roadmap.md). The dated record of what was built, and
the spikes that proved the approach, is the
[development log](../history/development-log.md).

## Settled decisions

- **Transplant, don't rewrite, and don't fork the engine.** Goanna carries
  Luanti's client *logic* (networking, world/mapblock handling, movement
  prediction, node meshing rules, formspec parsing) and replaces only what
  Irrlicht used to provide: rendering, GUI widgets, mesh/model loading,
  input, window. Parity with vanilla movement and formspecs comes for free
  because it is the same code.
- **GDExtension against the release Godot binary.** No engine source, no
  engine rebuild; `RenderingServer`, threads and everything needed are
  reachable from an extension. Module-vs-extension for the long run is
  decided later (`godot_voxel` ships as both).
- **Forward+ only.** Vulkan; PBR; SDFGI. Visual quality is the product; if
  a machine cannot run it, it runs the vanilla client, which is always the
  reference. Not a 3090-only client either: a mid-range discrete GPU is the
  target. But there is no Mobile/Compatibility renderer path.
- **Vanilla servers, vanilla games, honest protocol.** Goanna is a client
  for the existing ecosystem. It does not modify servers, ship a game, or
  give players anything the protocol does not give a vanilla client.
- **Licence:** LGPL-2.1-or-later for the transplanted client code (as
  Luanti's is); godot-cpp is MIT. Own name; does not trade on the Luanti
  mark. Transparent about what it is (a renderer/UI transplant of the
  official client logic) and what it is not. In this community, "alt
  client" has meant cheat clients.

## Why this is feasible, measured on a 5.17-dev checkout

Irrlicht is Luanti's in-house platform layer, vendored in `irr/` (~60k
lines) and shrinking ~15% per two years as pieces are replaced in place. But
its coupling to the engine's *core* is almost nil: outside `src/client` and
`src/gui`, the only rendering/GUI/scene symbols in use are `video::SColor`
(a 32-bit colour struct, 132 uses), bone-animation track ids (44 uses) and
five stragglers; the header-only math types (`vector3d`, `aabbox3d`,
`matrix4`, ~4k lines, no renderer dependency) are simply kept. Server,
network, world, persistence, Lua API, mapgen and content definitions are
Irrlicht-free. The scar tissue is exactly `src/client` (~38k lines) and
`src/gui` (~19k), and it is client-only.

Sizing, by what happens to those ~57k lines:

- *Mechanical retarget (~40%)*: mapblock meshing (`mapblock_mesh`,
  `content_mapblock`, `meshgen/`: pure geometry generation; swap
  `S3DVertex` for Godot arrays), the texture-modifier DSL
  (`texturesource`/`imagesource` over `IImage` → Godot `Image`), particles,
  HUD, camera, minimap, sky and cloud logic, input mapping, sound.
- *Genuine rewrite (~35%)*: the GUI widget layer, meaning formspec
  *rendering* (parser and layout come along), chat console, hypertext,
  tables and touch controls, onto Godot `Control`s; entity visuals
  (`content_cao`: meshes, skeletal animation, attachments, nametags onto
  `Skeleton3D`/`MeshInstance3D`); rendering glue, which is `RenderingServer`
  with one instance per mapblock (the `godot_voxel` pattern), never one big
  mesh.
- *Delete (~25%)*: dynamic shadows, the post pipeline, the GLSL shaders,
  GUI scaling filters, drivers: all replaced by Godot's.

## Compatibility ladder (the roadmap, in effect)

1. **A plain game and devtest**: mapblocks, movement, basic nodes.
2. **minetest_game**: the classic baseline.
3. **Mineclonia / VoxeLibre**: B3D models, the full formspec corner-case
   zoo, particles, attachments. This is the "community-usable" bar and the
   games people actually play.
4. **SSCSM**: when upstream lands server-sent client-side modding, mirror
   it.

## Repository layout

```
goanna/
  README.md, AGENTS.md, CONTRIBUTING.md, THIRD-PARTY.md, LICENSE
  CMakeLists.txt        builds the extension (godot-cpp + luanti sources + deps)
  cmake/                the Luanti core library and helpers
  src/                  Goanna's own C++ (extension entry, Godot-side glue)
  src/transplant/       Luanti code copied in, see docs/develop/transplanting.md
  project/              Godot project: project.godot, scenes, GDScript, shaders
  goanna_server_mod/    the optional server mod that grants Goanna capabilities
  pbr_packs/            authored material maps and their attribution
  asset_bundles/        bundle recipes and the asset catalogue
  tools/                run, test, benchmark, release and PBR tools
  docs/                 this site, built by mkdocs.yml
  luanti/               git submodule: luanti-org/luanti, pinned to a release tag
  godot-cpp/            git submodule: godotengine/godot-cpp, 4.5 branch
  whisper.cpp/          git submodule: speech to text for voice typing
```

## Risks

- **Upstream churn.** A divergent client, forever: each Luanti release is a
  merge of network and client-logic changes against the rewritten files.
  Mitigation: keep the rewritten surface minimal and clearly bounded; track
  release-by-release; the vanilla client is always a working fallback.
- **The tangle in `src/client`.** `Client`, `ClientEnvironment`,
  `ClientMap` and `LocalPlayer` reference each other and Irrlicht types.
  E0b exists to find out how cleanly they separate; the answer decides
  whether the transplant is "trim the real client" (hoped) or "reimplement
  the client against the real network layer" (fallback, larger).
- **Scope gravity.** Rung 3 of the ladder is large. Mitigation: ship rung 1
  early and publicly; a client that renders like E0a and runs a plain game
  already attracts the contributors that rung 3 needs.
