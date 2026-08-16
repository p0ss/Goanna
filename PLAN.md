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

## Spikes

- **E0a, the look. Done 2026-08-15, ~1 h.** A worldmod on a copy of a
  Mineclonia world drove the flatpak server headless, dumped a 96×64×96
  region + tile defs to JSON; a Python exporter produced OBJ/MTL with real
  textures; Godot 4.5.1 rendered flat / full / golden modes. Result: the
  payoff is real: dappled canopy light, sky-lit shadow sides, contact
  shadow, colour bounce, atmospheric depth, on untouched Mineclonia
  geometry. The exporter and Godot scene for it live outside this
  repository; the resulting images are in `docs/e0a_*.png`.
- **E0b, the pipe (the founding estimate). Stages 1 and 2 done 2026-08-15,
  about three hours from empty repo.** What exists: `luanti_core`, a static
  library of ~50 Luanti source files (network layer, settings/log/porting,
  serialization, node/item definitions, MapBlock/Map, inventory/metadata,
  the SRP auth stack, vendored mini-gmp/sha256/jsoncpp) compiled with
  server-build semantics (no Irrlicht render/GUI/scene types, header-only
  math kept), linked into the GDExtension with `--no-undefined`; one shim
  file for two functions that live in a server-only translation unit.
  `GoannaSession` speaks the real handshake (INIT → HELLO → SRP/FIRST_SRP →
  AUTH_ACCEPT → INIT2 → NODEDEF/ITEMDEF/ANNOUNCE_MEDIA → CLIENT_READY →
  BLOCKDATA with GOTBLOCKS acks and periodic PLAYERPOS) on its own thread.
  Against a devtest server: connected, registered, authenticated and pulled
  ~340 mapblocks within a second; the server logs an ordinary "joins game".
  A naive culled-cube mesher turns blocks into one `MeshInstance3D` each,
  vertex-coloured by node type; a fly camera feeds its pose back so the
  server streams around it. Rendered with SDFGI/SSAO/shadows/fog: see
  `docs/e0b_first_light.png`.
  **Stage 3 (2026-08-16): media and movement.** Media announce → request →
  receive with zstd, CLIENT_READY held until all files arrive (443 files in
  ~1 s on devtest); a material cache turns received PNGs into
  nearest-filtered PBR materials with alpha scissor/blend from the node's
  alpha mode and first-frame handling for animated tiles; the mesher groups
  faces by tile into surfaces with correct UV orientation and node-colour
  tint (`docs/e0b_textured.png`). Movement: `collision.cpp` and
  `localplayer.cpp` transplanted nearly verbatim (Environment* → Map*,
  Client → IGameDef + privilege flags, CAO/event hooks removed, legacy
  old_move dropped) plus the local-player part of
  `ClientEnvironment::step` (sub-stepping, gravity, liquid resistance) as
  `GoannaSession::stepPlayer`; the session owns a real Luanti `Map`
  (`GoannaMap`) and a `LocalPlayer`, MOVEMENT and PRIVILEGES packets are
  applied, MOVE_PLAYER teleports. Result: falls, lands, walks at the
  server's speed, jumps, steps up blocks. Luanti's own physics, inside
  Godot (`docs/e0b_walking.png`). Auth verified: register with password, SRP
  re-login, wrong password denied by the server.
  **Stage 4 (2026-08-16): Luanti's mesher, node updates, sky.**
  `content_mapblock`, `mapblock_mesh`, `node_visuals` and `imagesource`
  transplanted with `tile`, `mesh` and the collector compiled verbatim, so
  every drawtype and the texture modifier language come from upstream;
  `MapBlockMesh` buffers are converted to Godot surfaces per tile.
  Mineclonia renders (`docs/e0b_mineclonia_ground.png`). `ADDNODE` and
  `REMOVENODE` re-mesh the affected blocks (verified with a worldmod that
  toggles a pillar). The sky packets and `TIME_OF_DAY` drive Godot's sun,
  sky colours, fog and grading along Luanti's own sun path
  (`docs/e0b_time_of_day.png`).
  **Stage 5 (2026-08-16, afternoon): materials, lights, interaction,
  entities, menu.** Shader variants by Luanti material type (water, waving
  leaves and plants, glass), emissive materials and a pool of shadow-casting
  point lights for `light_source` nodes (`docs/e0b_torches_night.png`); a
  transplant fix so transparent buffers reach Godot at all (water had never
  rendered); digging and placing through Luanti's own raycast and
  `TOSERVER_INTERACT`, confirmed in the devtest server log; `GenericCAO`
  state transplanted with sprite, cube and placeholder visuals and nametags
  (`docs/e0b_entities.png`); chat, HP, HUD, inventory and formspec strings
  parsed and exposed to GDScript (`docs/protocol-coverage.md`); a
  connection menu; licence headers and the transplant inventory brought
  into order. Three sessions worked the tree at once this afternoon, which
  is where the discipline in `CONTRIBUTING.md` and `docs/transplanting.md`
  earned its keep. Remaining for E0b proper: node light, entity meshes and
  animation, formspec rendering, `RenderingServer` instances instead of
  nodes.
  Findings so far: the tangle in `src/client` is avoidable. The pieces
  below `Client` separate cleanly, so the transplant is "build Goanna's
  client on Luanti's real network/world layer", not "trim `Client`";
  threading is unproblematic (session thread + Godot main thread with two
  mutexes). The sizing above holds or is pessimistic.

## Verified on (as of 2026-08-16)

Godot 4.5.1 release binary; Luanti 5.16.1 via flatpak with a Mineclonia
`test_world` and a devtest server; a Luanti source clone (5.17-dev) used for
the sizing measurements above; cmake 4.4 + ninja; gcc 16 on an immutable
host; NVIDIA RTX 3090, Vulkan.

What Goanna vendors and what it expects from the host is worth stating
precisely, because it is the first thing a packager asks. Vendored, compiled
from the `luanti/` submodule and linked statically: mini-gmp, sha256 and
jsoncpp, from `luanti/lib/`. Expected on the host: zlib (found with
`find_package`, linked dynamically) and Zstandard (found with
`find_library`, linked statically where a static library is available).
There is no `FetchContent`. The built extension is therefore not fully
self-contained: `ldd` shows `libz.so.1` among its dependencies. See
`THIRD-PARTY.md` for the full accounting.

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
