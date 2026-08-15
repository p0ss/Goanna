# Goanna — a Godot client for Luanti worlds

Goanna transplants Luanti's own client logic into Godot 4 as a GDExtension.
It connects to ordinary Luanti servers over the ordinary protocol and renders
what a vanilla client renders — with Godot's Forward+ pipeline: PBR
materials, SDFGI, SSAO/SSIL, volumetric fog, real shadows, colour grading.
It is a visuals-first client. It is deliberately **not** a low-spec client:
Forward+ only, Vulkan required, no fallback renderer.

Goanna started as the visual-ambition lane of a larger game project (see
`POSSMOD-LUANTI-PLAN.md` in the investigation folder) and became its own
project the moment its first images made clear the wider Luanti community
would plausibly use it regardless of that game.

## Settled decisions

- **Transplant, don't rewrite, and don't fork the engine.** Goanna carries
  Luanti's client *logic* — networking, world/mapblock handling, movement
  prediction, node meshing rules, formspec parsing — and replaces only what
  Irrlicht used to provide: rendering, GUI widgets, mesh/model loading,
  input, window. Parity with vanilla movement and formspecs comes for free
  because it is the same code.
- **GDExtension against the release Godot binary.** No engine source, no
  engine rebuild; `RenderingServer`, threads and everything needed are
  reachable from an extension. Module-vs-extension for the long run is
  decided later (`godot_voxel` ships as both).
- **Forward+ only.** Vulkan; PBR; SDFGI. Visual quality is the product; if
  a machine cannot run it, it runs the vanilla client, which is always the
  reference. Not a 3090-only client either — a mid-range discrete GPU is the
  target — but no Mobile/Compatibility renderer path.
- **Vanilla servers, vanilla games, honest protocol.** Goanna is a client
  for the existing ecosystem. It does not modify servers, ship a game, or
  give players anything the protocol does not give a vanilla client.
- **Licence:** LGPL-2.1-or-later for the transplanted client code (as
  Luanti's is); godot-cpp is MIT. Own name; does not trade on the Luanti
  mark. Transparent about what it is (a renderer/UI transplant of the
  official client logic) and what it is not — "alt client" in this
  community has meant cheat clients.

## Why this is feasible — measured on a 5.17-dev checkout

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
  `content_mapblock`, `meshgen/` — pure geometry generation; swap
  `S3DVertex` for Godot arrays), the texture-modifier DSL
  (`texturesource`/`imagesource` over `IImage` → Godot `Image`), particles,
  HUD, camera, minimap, sky and cloud logic, input mapping, sound.
- *Genuine rewrite (~35%)*: the GUI widget layer — formspec *rendering*
  (parser and layout come along), chat console, hypertext, tables, touch
  controls — onto Godot `Control`s; entity visuals (`content_cao`: meshes,
  skeletal animation, attachments, nametags onto
  `Skeleton3D`/`MeshInstance3D`); rendering glue (`RenderingServer`, one
  instance per mapblock — the `godot_voxel` pattern — never one big mesh).
- *Delete (~25%)*: dynamic shadows, the post pipeline, the GLSL shaders,
  GUI scaling filters, drivers — all replaced by Godot's.

## Compatibility ladder (the roadmap, in effect)

1. **A plain game and devtest** — mapblocks, movement, basic nodes.
2. **minetest_game** — the classic baseline.
3. **Mineclonia / VoxeLibre** — B3D models, the full formspec corner-case
   zoo, particles, attachments. This is the "community-usable" bar and the
   games people actually play.
4. **SSCSM** — when upstream lands server-sent client-side modding, mirror
   it.

## Spikes

- **E0a — the look. Done 2026-08-15, ~1 h.** A worldmod on a copy of a
  Mineclonia world drove the flatpak server headless, dumped a 96×64×96
  region + tile defs to JSON; a Python exporter produced OBJ/MTL with real
  textures; Godot 4.5.1 rendered flat / full / golden modes. Result: the
  payoff is real — dappled canopy light, sky-lit shadow sides, contact
  shadow, colour bounce, atmospheric depth, on untouched Mineclonia
  geometry. Reproducible from `~/Documents/Code/Godot/luanti_e0a/`.
- **E0b — the pipe (the founding estimate). Stages 1–2 done 2026-08-15,
  about three hours from empty repo.** What exists: `luanti_core`, a static
  library of ~50 Luanti source files (network layer, settings/log/porting,
  serialization, node/item definitions, MapBlock/Map, inventory/metadata,
  the SRP auth stack, vendored mini-gmp/sha256/jsoncpp) compiled with
  server-build semantics — no Irrlicht render/GUI/scene types, header-only
  math kept — linked into the GDExtension with `--no-undefined`; one shim
  file for two functions that live in a server-only translation unit.
  `GoannaSession` speaks the real handshake (INIT → HELLO → SRP/FIRST_SRP →
  AUTH_ACCEPT → INIT2 → NODEDEF/ITEMDEF/ANNOUNCE_MEDIA → CLIENT_READY →
  BLOCKDATA with GOTBLOCKS acks and periodic PLAYERPOS) on its own thread.
  Against a devtest server: connected, registered, authenticated and pulled
  ~340 mapblocks within a second; the server logs an ordinary "joins game".
  A naive culled-cube mesher turns blocks into one `MeshInstance3D` each,
  vertex-coloured by node type; a fly camera feeds its pose back so the
  server streams around it. Rendered with SDFGI/SSAO/shadows/fog: see
  `docs/e0b_first_light.png`. Remaining for E0b proper: media fetch (real
  textures), port `content_mapblock` (all drawtypes), `LocalPlayer` physics
  (walking, not flying), `RenderingServer` instances instead of nodes.
  Findings so far: the tangle in `src/client` is avoidable — the pieces
  below `Client` separate cleanly, so the transplant is "build Goanna's
  client on Luanti's real network/world layer", not "trim `Client`";
  threading is unproblematic (session thread + Godot main thread with two
  mutexes). The sizing above holds or is pessimistic.

## Environment (as of 2026-08-15)

Godot 4.5.1 release binary at `~/Documents/Code/Godot/`; Luanti 5.16.1 via
flatpak with a Mineclonia `test_world` (flatpak has no home access — world
copies live in `~/.var/app/org.luanti.luanti/.minetest/worlds/`); Luanti
source clone (5.17-dev) at `~/Documents/Code/investigation/luanti/`;
cmake + ninja via linuxbrew; gcc/g++ on the immutable host; NVIDIA RTX
3090. Luanti's build dependencies (zlib, zstd, jsoncpp, …) are not on the
host — Goanna vendors what it needs via CMake `FetchContent`/submodules and
links statically so the extension is self-contained.

## Repository layout

```
goanna/
  PLAN.md               this file
  README.md
  LICENSE               LGPL-2.1-or-later
  CMakeLists.txt        builds the extension (godot-cpp + luanti sources + deps)
  src/                  Goanna's own C++ (extension entry, Godot-side glue)
  luanti/               git submodule: luanti-org/luanti, pinned to a release tag
  godot-cpp/            git submodule: godotengine/godot-cpp, 4.5 branch
  project/              Godot project: project.godot, scenes, GDScript, the .gdextension
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
