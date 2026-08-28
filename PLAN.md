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
  earned its keep. At that point the remaining E0b work was node light,
  entity meshes and animation, formspec rendering, and a cheaper rendering
  path.
  **Stage 6 (2026-08-16 to 17): residency, performance and particles.**
  Mapblock residency is bounded around the player and evictions are reported
  to the server with `DELETEDBLOCKS`; frame-time and renderer telemetry made
  the real cost visible. Luanti's array-texture grouping is now carried into
  Godot `Texture2DArray` resources, and buffers sharing a material are merged.
  Distant blocks can be rebuilt as coarse flat-coloured cells with one shared
  material. At view range 20, the measured Mineclonia scene moved from 4,858
  draw calls and 118 fps to 2,824 draw calls and 262 fps with LOD beyond six
  mapblocks. `SPAWN_PARTICLE`, `ADD_PARTICLESPAWNER` and
  `DELETE_PARTICLESPAWNER` now feed Godot GPU particles; rain and snow exposed
  and fixed player-relative anchoring and size conversion. Particle behaviour
  still needs broader coverage testing, and animated node textures do not yet
  advance beyond their first frame.
  Findings so far: the tangle in `src/client` is avoidable. The pieces
  below `Client` separate cleanly, so the transplant is "build Goanna's
  client on Luanti's real network/world layer", not "trim `Client`";
  threading is unproblematic (session thread + Godot main thread with two
  mutexes). The sizing above holds or is pessimistic.

## Log since v0.3.0-alpha (2026-08-28)

Verified on a local Mineclonia server on Luanti 5.17.0 with Godot 4.5.1
unless marked otherwise; the offline fixture is `project/water_seam.tscn`.

- The near/far water hand-off no longer draws a seam. Both tiers run the
  same water material with the same parameters and every difference is a
  function of view distance inside the shader; the fallback reflection
  samples the frame's own sky pixels by direction, with a drawn sun disc
  and halo (new globals `goanna_sun_dir`, `goanna_sun_glow`) where the sky
  is off screen. See "The near/far water hand-off, 2026-08-28" in
  `docs/far-rendering.md`.
- The far field sat half a node adrift of the near mesh on all three axes,
  a corner-versus-centred node convention mismatch. One transform on the
  published region node corrects it. Verified over open water by day; the
  frozen sheet at far range was not re-verified before a storm closed in.
- Ice and glass reflect the same two-rung sky answer, bent by the pack's
  `_n` companion and gated per texel by the `_s` smoothness, under a hard
  cap (`reflect_strength`), with the water's screen space march for banks
  and trees. Judged live against the icetest sheet through three rounds of
  the author's feedback: the first pass read as a mirror, the balance is
  now roughly nine parts texture to one part sheen.
- The sun holds through the golden hour (a twilight band in `_apply_sky`)
  instead of dying exactly when the sky peaks pink, and the bounce light
  and shader ground fill take their colour from `ground_albedo`, a new
  sampled average of the terrain around the camera, so undersides are
  tinted by what the scene actually stands on. Judged live at dusk; the
  lighting chart does not exercise `_apply_sky`.
- `goanna_server.conf` default privs gained `weather_manager`: Mineclonia
  storms blacken the night sky, and clearing them mid-test needs the priv
  on a freshly created player.
- The first `ground_albedo` cut the frame rate from 90 to under 30: it
  called `getTextureAverageColor` per column twice a second, and that
  composes the full tile image on every call. A per content cache with a
  small per-call warm budget restored 90 at dusk with the sun hold, moon,
  bounce and sampling all active, measured sitting still at the bay.
- The violet hour reaches the land: the sky fill's twilight term borrows
  the cloud deck's own colour ramp and rides the twilight window rather
  than the narrower dawn band, so cliffs and canopies go purple-grey under
  a purple sky instead of dead grey (the player's report). Deep night is
  unchanged; the extension decays with the ramp itself.
- A storm stopped wearing a white wall at the horizon. Three sun-facing
  terms were cloud-blind, because the raymarched deck casts no shadow map:
  the froxel air's sun energy, the depth fog's sun scatter, and the haze
  colour itself, which kept the server's fair weather horizon while the
  deck darkened, so a bright band sat between dark clouds and dark ground
  with a hard join. All three now answer to the same cloud cover the deck
  and the ground shadows use. Verified in live rain: the sun reads as a
  soft glow through overcast and the haze meets the deck as one weather.
- Rain wets the ground: a goanna_wetness global rises over half a minute
  of rain and drains over a few minutes after, and the array shaders
  darken and gloss up-facing, sky-lit surfaces by it, split by the pack's
  LabPBR porosity (soil soaks, stone sheens); anything under a roof stays
  dry via the sky light channel. Verified in live rain at the bay.
- The ice edge stopped standing on the water. At a flush shore the ice's
  sideways boundary face lies wholly at or under the waterline (a source
  renders its surface at the top of its node), and Godot's per mesh
  transparent sort could draw that submerged pane over the nearer water
  surface. The face is now skipped outright on a sideways boundary with a
  source at the same level (content_mapblock.cpp, the second half of the
  water/ice ownership rule); a face over air or part filled flowing water
  is genuinely exposed and stays. Verified at the icetest sheet's edge.

## Log since v0.2.0-alpha (2026-08-25 to 2026-08-26)

Eighteen commits. The theme is that the client stopped doing its heavy work
on the frame, and that several things which looked like rendering faults
turned out to be one number set wrongly.

**A breaking change first.** The far summary protocol goes from version 6 to
version 7. `goanna_server_mod` must be updated with the client: an older mod
logs a version mismatch and answers nothing, so far rendering stops without
saying why on screen. A stale copy in a world's `worldmods` is the usual way
this bites, and it bit the author's own test world for most of a day.

**Measured, on a local Mineclonia server on Luanti 5.16.1 with Godot 4.5.1,
one player name reused so runs stand in the same place.**

- Meshing left the main thread. `goanna_mesh_pool.h` is a worker pool in the
  shape of Luanti's own `mesh_generator_thread.h`, which Goanna had never
  compiled. Far region meshing went first (main thread cost 3.24 to 8.77 ms
  down to 0.24 to 0.25 ms), then near block meshing with its occlusion trace
  (0.36 ms down to 0.00 ms). Hand-off between tiers is atomic: a block keeps
  its far mesh until the near one is ready.
- Region merging stopped pushing indices one at a time across the
  GDExtension boundary. 2.45 ms down to 1.24 ms, mean of three runs.
- Defaults come from the machine. Detail distance was a hardcoded 12 blocks
  chosen before far rendering existed; 12 against 24 is within noise on
  frame time and within five megabytes of video memory, so the default is 20
  and a discrete card with twelve threads asks for 32. The mesh pool takes
  half the machine to a cap of eight rather than four to a cap of four.
  Godot will not report total video memory, so the discriminator is the
  adapter type.
- Distant foliage draws as thick as near foliage. Leaves are alpha tested at
  64 to 82 per cent coverage and the far tiers drew them solid, so a canopy
  was 22 to 56 per cent more leaf at range than up close.
- A far surface keeps its own reflectivity. Roughness and specular converged
  to fixed constants past the flatten distance; they converge to the tile's
  own mean now. Birch leaves are 0.493 and 0.490, where the constants were
  1.000 and 0.200.

**Observed on screen, before and after shots kept.**

- The sky was being painted over by the volumetric fog:
  `volumetric_fog_sky_affect` defaults to 1.0 in Godot and nothing set it, so
  the sky gradient, the sun and the cloud deck were all replaced by flat fog
  colour. The clouds reported as black smog were not black, they were not
  visible at all.
- Clouds were being drawn twice, once on the sky deck and once as a slab in
  the froxel grid. The froxel one is gone: that grid ends at
  `volumetric_fog_length` and spreads a fixed cell count over it, so a cloud
  edge cannot exist in one at any tuning.
- The main menu has the screens a Luanti player expects, and Join Game lists
  the public servers from the same place Luanti's own client takes them.
  Measured against the live endpoint: 437 servers.

**Fixed but not confirmed against the fault it was written for.**

- Media no longer times out 30 seconds after the announce whatever is
  happening; the test is on silence instead. A player reported the client
  dying at media load on several large public servers while a small one
  worked, which is the shape this produces, but their log has not been read.
- Connection state is on screen: a progress bar while media arrives, and the
  server's refusal in words when it refuses. `access denied (code 7)` now
  reads "this server requires a password", which is what Your Land answers a
  join with no password, and what was previously a black screen for four
  minutes.

**Tried and reverted, recorded so it is not tried again.** Dividing
`background_energy_multiplier` by the exposure makes the visible sky sit in
the same units as the lamp-lit ground, and also lights the world: ambient
comes from the sky and SDFGI reads it, so the land was lit like noon at
midnight. The sky against ground mismatch is real and still open; whatever
fixes it must move the sky's appearance without moving its contribution as a
light source.

**Still not working**, unchanged: some dropped items are placeholder boxes,
animated node textures stay on their first frame, parts of particle
behaviour and the batched particle packet are absent, and Windows and macOS
have not been play-tested.

## Log since v0.1.0-alpha (2026-08-17 to 2026-08-25)

The tag `v0.1.0-alpha` was cut on 2026-08-17. What follows is what landed
between then and `v0.2.0-alpha`, separated into what has been observed
running and what has only been built and unit tested. That separation is the
point of this section: the code existing is not the same claim as the code
working, and `README.md` may only move an item on the second.

**Observed running.** Against a local Mineclonia server on Luanti 5.16.1
with Godot 4.5.1, Forward+ on Vulkan, NVIDIA:

- Far rendering end to end, 2026-08-23. A 1024 node grant drawn within 30 s
  of joining, and again across a server restart, from summaries the mod
  keeps for terrain it has generated. `docs/far-rendering.md`.
- An Iris shader pack's screen space chain, 2026-08-21. The proof pack in
  `project/tests/shaderpacks/proof/` renders through `composite` and `final`
  with DRAWBUFFERS routing, ping pong and live uniforms. No real pack has
  been run. `docs/iris-compat.md`.
- Per vertex light, 2026-08-21. Luanti's two light banks carried in
  `CUSTOM0` rather than multiplied into albedo, so caves are dark, a torch
  matters, and the same values are available to a translated pack as
  `lmcoord`. `docs/mesh-attributes.md` is the contract.
- The daylight balance reset on a material chart rather than by eye, with
  the numbers in `docs/pbr-plan.md`.
- Server particle spawners, weather, positional sound, the first person
  body and held item, and the formspec and inventory work behind rung 3.

- The far field at summary protocol version 6, 2026-08-25, measured from
  the packaged `v0.2.0-alpha` build headless against that same server: the
  full 1024 node grant reached (`reach=992/992`) in about 40 s from joining,
  61,947 far blocks, 364 complete areas and 181,436 coarse chains. That is
  the request, summary and chain path proven end to end at the new version.

**Built and unit tested, not yet observed in a session.** These are in
`v0.2.0-alpha` and are the first thing to look at if it misbehaves:

- What the volumetric far field actually looks like. The move from a
  heightfield to a 4 by 4 by 4 voxel mip chain is what should let a distant
  cave mouth, overhang or floating island keep its lower and side faces, and
  `goanna_lod_test` covers the recursive mip and the exposed faces, but the
  measurement above was headless, so nothing has yet judged the picture. The
  summary protocol goes to version 6 with the change, so a 0.1 era copy of
  `goanna_server_mod` will log a version mismatch and send nothing until it
  is updated.
- Concurrent far pregeneration, and the client's own local server trusting
  this single player's movement (`anticheat_flags = digging,interaction`)
  so fast flight stops reading as a streaming limit. This applies only to
  the server Goanna starts for its own player and changes nothing for any
  other server.
- The cloud twilight ramp.

**Still not working**, unchanged from `README.md`: some dropped items are
placeholder boxes, animated node textures stay on their first frame, parts
of particle behaviour and the batched particle packet are absent, and
Windows and macOS have not been play-tested.

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
