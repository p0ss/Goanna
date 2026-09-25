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

## Log since v0.8.0-alpha (2026-09-16)

The v0.8.0-alpha tag is `3f476b4`, 2026-09-16 22:39 +1000. The Kythen
authoring run below straddles that date: its first commit landed seven
minutes after the tag, so the whole run sits in this section.

- Kythen authored, 2026-09-16 to 17. The playbook's first run on a second
  game: 228 stems across the eight cultures in fifteen agent batches,
  each reviewed on the close-up ramp under sun and lamp; two reworks. The
  standalone pack sits beside the bake at `baked/authored-kythen/textures`
  and in the launcher's texture pack list; a 1.1.0 terrain bundle is the
  production path. Findings in `docs/material-calibration.md`.

- The sun no longer shines into caves, 2026-09-18. Reported in play from a
  Mineclonia lava cave at (-216, -48, 161): sunlit floor patches with
  shadows cast the wrong way, and edges that flickered as they moved. The
  sun's only occluder was the shadow map, and the server never sends the
  ground above a cave (occlusion culling; 211 blocks were resident), so
  nothing stood between the cave and the sky. The node, foliage and entity
  shaders now carry their own `light()` (`direct_light.gdshaderinc`, Godot
  4.5.1's `light_compute` reproduced) that scales every directional light
  by Luanti's sunlight, read as day bank minus night bank the way
  `encode_light` does, since the day bank also holds torch and lava light.
  Measured on a copy of that world, Luanti 5.16.1, Godot 4.5.1: the cave
  frame with the sun on now matches the sun switched off to within the
  noise floor (0.80 against 0.75 mean difference). On a copy of test_world
  at the beach the replacement matches Godot's own lighting on land to
  within the noise floor in 16 pixel tiles (0.55 against 0.44 to 0.53, +0.2
  of 255 brighter). The flicker was the sun and moon lights being turned
  every frame, which draws every shadow caster again against a rotated
  texel grid; they now move in 0.2 degree steps (`light_step_deg`). With
  shader animation frozen and the clock driven one 60 fps frame at a time,
  pixels reversing brightness on consecutive frames fell from 60,848 to
  24,924 over 90 frames against 19,751 with the clock stopped, and land
  away from the water reached that floor. Not yet done: water, glass, ice
  and lava are not gated, and water still reflects the sky underground; an
  entity with no `node_light`, which is every non-mesh visual, is lit as
  if under open sky; and the sky fill still takes the raw day bank, so a
  lamp lit cave takes a daylight fill that varies with the time of day.

- Start Game finds Luanti where it is packaged, 2026-09-18. Reported from a
  Pop!_OS machine with Luanti installed: Goanna said no game was installed.
  The lookup found a server program and then looked for games only in
  `~/.minetest/games`, plus one hard coded system Flatpak path. In an Ubuntu
  24.04 container (Pop!_OS uses Ubuntu's archive), `minetest-server` is
  Minetest 5.6.1 at `/usr/games/minetestserver` and its games are in
  `/usr/share/games/minetest/games`, so that layout gave exactly that
  message. The lookup now keeps every install it finds (packages, user and
  system Flatpak, Snap, AppImages, the Windows zip and self-extracting
  build, source checkouts) and finds each one's share and user directories
  by Luanti's own rules in `porting.cpp` and `subgames.cpp`. A new Luanti
  screen in the menu lists them, remembers the player's choice, locates one
  by hand, installs the Flathub build on Linux or the pinned, hash-checked
  official 5.16.1 zip on Windows, and opens Luanti's own client for
  installing a game. Verified: in that container, with Godot 4.5.1, the scan
  found the package and its two games and `start_config` brought the server
  up with the Goanna server mod loaded (the mod warns that 5.6 has no
  `register_on_mapblocks_changed`). On this machine the system Flatpak,
  Luanti 5.17.0, is found with its eight games in 16 ms. The real 5.16.1
  Windows zip unpacks on Linux and is recognised as a portable install.
  `res://tests/local_server_discovery.gd` covers the layouts. Not verified:
  anything on Windows itself, the Flathub install end to end, joining a 5.6
  server with Goanna, and the Pop!_OS machine the report came from.

- Lava has its own material, 2026-09-17 to 18. Any real liquid with a
  light level of 6 or more now draws with `lava.gdshader` and its source
  tile's artwork, flowing and falling blocks included. Near lava is
  subdivided to eight segments per node and carries a velocity field taken
  from neighbouring liquid levels, continuous across mapblock borders, so
  the art moves with the flow. Dark texels rise up to 0.14 nodes as crust
  and the glow is the inverse of the same mask, so raised crust and bright
  melt move together; the crust settles flat at the edge of a flow. The
  mask's range is measured from the selected tile's own luminance, since
  Mineclonia's darker tile rendered nearly black against a range tuned to
  Minetest Game. Exposed lava lamps sit above the surface, 3.5 nodes apart,
  at 2.5 times an ordinary lamp's energy for their light level and with no
  specular. Distant lava keeps the artwork and glow without the
  subdivision. Verified with Godot 4.5.1 on an
  RTX 3090 by fixtures (zero changed pixels across a split surface, glow and
  height coupled at two times) and captures from disposable Minetest Game
  and Mineclonia caves; `docs/lava-material.md` has the numbers. The
  stylised lava in `asset_bundles/` is Tarox's CC0 "Stylized lava" from the
  Material Maker library. Not yet done: the cost of a large lava lake near
  the player is not measured, a pack's separate flowing artwork is replaced
  by the source artwork, and the full animation strip is not played.

- Ice keeps its shader globals across a change of world, 2026-09-18 to 19.
  The ice renderer added its four global uniforms when a world started and
  removed them when it ended, while the shader and its materials stay cached
  between worlds, so the next world's ice bound to globals that were no
  longer there. They are declared in `project.godot` now, like the other
  globals, and the renderer only sets and clears their values. The shader
  also stops sampling the transmission background unless it is ready and the
  ice is not solid, since an unbound texture can return NaN and NaN survives
  being multiplied by zero. Verified: `tests/ice_reload.gd` builds the ice
  renderer three times around one retained material, and loads two and three
  match the first with zero changed pixels on Godot 4.5.1. Not yet observed
  leaving and rejoining a world with ice in play.

- Dig damage shared between players, 2026-09-18 to 19. A Goanna client has
  always carved the block it digs on its own screen. With
  `goanna_shared_dig_damage` on, the client also reports the carve when a dig
  ends, the server mod's `damage.lua` stores it in the node's metadata under
  `goanna_carve`, and every Goanna client draws what it finds there. That is
  the one step where a client's account is trusted, so the server checks
  reach, caps the size and rate limits reports, and the setting is off by
  default; a server started from Goanna's own menu turns it on, since the
  operator there is the player. Dig progress is untouched, and the server
  still enforces how long a block takes to break. Three faults from play are
  fixed with it: a block with stored damage started whole again when struck,
  damage vanished after a dozen or so blocks because carves were read only
  when a node changed in view and are now read from each block as it arrives,
  and two carved blocks side by side each closed the gap with a full face for
  the other. `content_mapblock.cpp` is touched, and its header note and
  inventory row are updated. Not done: carved nodes lose their bevel, and
  explosions leave no damage. The maintainer saw carves persist in play on a
  Goanna-launched server before those three fixes. The fixes themselves are
  built and unit tested but not seen in play, and no run with a second client
  is recorded.

- Luanti 5.17.0, 2026-09-19. The `luanti/` submodule moves from 5.16.1 to
  5.17.0 (protocol version 53, formspec version 11) on the `luanti-5.17`
  branch. The transplanted files were carried across by a three-way merge
  against 5.16.1. Every conflict was in code Goanna had already removed,
  except the new waving liquid top face in `content_mapblock.cpp`, which now
  sits beside Goanna's carve and fake liquid rules. `content_cao` was ported
  by hand: 5.17 animates several tracks at once, and Goanna plays only the
  first, addressed by number, while `AO_CMD_STOP_ANIMATION` on it holds the
  first frame. `goanna_models` animates through the per-track API. Direction
  keys are now analogue amounts, `NetworkPacket` hands out a string view,
  `getColor` returns its colour and HUD elements carry a `hideable` flag;
  each is ported. One fault got past the compiler: `Client::getMesh` now
  takes a `bool *is_shared`, Goanna's stand-in still took `bool cache`, and
  the merged `node_visuals.cpp` passed a pointer that converted to true and
  then read an uninitialised flag. The stand-in has the new signature.
  `hypertip[]`, new in formspec version 11, shows as a plain text tooltip;
  the version 11 `halign` and `valign` styles are not applied. Install
  Luanti on Windows now fetches the 5.17.0 zip, whose hash matches the
  digest GitHub publishes and which unpacks and is recognised on Linux.
  Verified: the build, the native tests (rebuilt, see the correction below)
  and the formspec, discovery, ice and lava suites, and against a fresh
  Mineclonia world on the Luanti 5.17.0 Flatpak with Godot 4.5.1: protocol
  53 negotiated, 3856 media received, 23 of 30 entities advancing their
  animation frames (the others were chests, a spawner doll, two glow squid,
  which Mineclonia gives an empty animation table, and an idle creeper),
  about 13 nodes walked in three seconds with no drift after release, digs
  logged by the server, and 120 HUD elements and the creative inventory
  formspec built with nothing skipped. Not verified: any server older than
  5.17.0, Windows itself, and a mod that uses more than one animation track.

- Correction, 2026-09-19: the native test runs recorded earlier today, in
  the commit that sped up the tool swing (fcc9f72) and during the move to
  5.17.0, ran stale binaries. The test targets are EXCLUDE_FROM_ALL, so
  `cmake --build build` never rebuilds them; the binaries dated from 16
  September. Built fresh, `goanna_mining_cycle_test` failed 17 checks, and
  one of them was real: the faster swing started its clock 0.62 of a swing
  in, so the dig completed, and was reported to the server, that much before
  the tool time, earlier than a vanilla client ever reports a dig. The swing
  still starts on its downstroke, but the blows are now spaced so the last
  lands exactly at the tool time, and the clock starts at zero again. The
  other checks encoded the old 0.65 second swing and now follow the
  constants. Built fresh, all nine native tests pass
  (`build/goanna_trees_test` is a leftover binary with no source). Not yet
  seen in play against a server with digging anticheat.

- Animation tracks, 2026-09-19. Entities play every animation track a
  Luanti 5.17 server sends, where the move to 5.17.0 kept only the first:
  several at once, ordered by priority, addressed by number or by a name
  resolved against the mesh, each with its own start frame, speed, loop and
  blend, and a stopped track leaves its joints at rest instead of holding
  its first frame. The transplanted active object keeps GenericCAO's own
  track state and functions. A track name needs the mesh, which only the
  renderer has, so `processMessage` queues the animation commands and the
  renderer applies them, and a new `goanna_animation` poses the joints the
  way `AnimatedMeshSceneNode` does, replacing `ModelAnimator`'s single frame
  loop. Frames carry across a mesh change, and a texture change no longer
  restarts anything. The first-person body plays a game's
  `set_local_animation` ranges from the local controls, as the vanilla
  client does for a visible local player, so on Minetest Game its legs walk
  while W is held although Goanna still reports no movement keys. Mineclonia
  sets none, so nothing changes there. A model[] preview left at its
  default frame loop now plays once and holds its last frame, because
  5.17's `GUIScene` no longer clamps the loop to the model's length; Goanna
  used to loop it. `entity_animation(id)`, through the control channel's
  `call`, reports an entity's tracks and joint poses. Verified with Godot
  4.5.1: `goanna_animation_test`, which feeds the messages of both 5.17 and
  older servers through the transplanted object and checks the joints for
  priority, names and numbers, start frame, per track speed, stop to rest,
  blend, mesh changes and the queue bound, and fails with the priority
  order inverted or the queue bound removed. Against the Luanti 5.17.0
  Flatpak: a fresh devtest world with a throwaway probe mesh, where the
  higher priority of two tracks on one joint owned it, by name and by
  number, stopping every track put the joint back at rest, pausing one
  track left another running, a start frame of 1.5 held, a paused frame
  survived a mesh swap and a mesh without the tracks dropped them; the
  same world with devtest's own multi-track fixture, both named tracks
  playing, one paused while the other ran, frames kept across its model
  swap; a fresh Mineclonia world, where 27 of 54 visible entities advanced
  their first track over two seconds, the rest being items, wield items,
  chests and a spawner doll with no track, a spider's eyes, idle creepers
  and a sheep on one-frame ranges, and five entities that arrived between
  the samples, and where digging played the server's mining range on the
  body; and a fresh Minetest Game world, where the body walked and dug from
  its local animations. Against a Luanti 5.10.0 server (Debian's package,
  in a container, protocol 46) with Minetest Game: the old `set_animation`
  and `set_animation_frame_speed` messages played, paused and resumed the
  first track, an entity never given an animation held frame 0 of the
  (0, 0) animation older servers send at init, and the local walk played.
  A preview built through `model_preview` held its last frame from about
  7.3 seconds while one with an explicit loop kept looping. Not verified:
  Windows; any server between 5.10 and 5.17; the model[] change in a real
  formspec; the blend by eye. Upstream blends from the pose shown the frame
  before, by the fraction of the blend time elapsed, so at 60 fps a four
  second blend reaches its target within about a second; Goanna reproduces
  that rather than a linear blend. Still wrong: an entity the server makes
  invisible does not animate, where the vanilla client animates it anyway.
  `goanna_mining_cycle_test` fails 17 checks, from sources this work did not
  touch.

- Animated node tiles, 2026-09-19. Tiles now play their frames with the
  vanilla client's timing: one clock advanced once a rendered frame with
  `dtime` capped at 2.5 s and wrapping at 60 s, as `Client::step` keeps it,
  and upstream's frame rule from `AnimationInfo::getTexture`, with no per
  node offset, which 5.17.0 no longer has. Cube-like tiles that the node
  array shader draws go into Goanna's own animation arrays, built from the
  frames `node_visuals` already cuts, each tile's frames as consecutive
  layers; the shader adds the frame to the tile's first layer from a per
  layer `layer_anim` table, so nothing changes per frame on the CPU and the
  LabPBR companions follow the frame, cut from a pack's strip when it has
  one. Double sided tiles and those on the glass, ice, leaves and plants
  shaders keep their shared single image material, which gets the frame's
  textures when the frame changes: `MapBlockMesh::animate`'s swap, once per
  material. Water and lava keep their own shaders untouched. The far tiers
  draw animation array tiles from the same arrays instead of a flat colour.
  No transplanted file changed. `GOANNA_NO_NODE_ANIM=1` or
  `set_node_animation_enabled(false)` turns it all off. Verified with Godot
  4.5.1 on an RTX 3090 against the Luanti 5.17.0 Flatpak:
  `tests/node_animation.gd` reads back the frame both array shaders draw at
  eight clock times with 0 failures; on a fresh devtest world
  `testnodes:anim` showed A, B, C and D at 0.5, 1.5, 2.5 and 3.5 s; on a
  fresh Mineclonia world 41 animated tiles were found, 11 went into two
  arrays, a wall of magma, sea lantern, prismarine, sculk, fire, kelp,
  seagrass, torch, lanterns, campfires and portal changed where the frame
  lengths say, all eleven single image materials reported the vanilla frame,
  and the wall drawn from a far tier stayed textured and moving. In one
  client at a fixed pose, animation on against off: 570 against 573 camera
  draw calls, 61 against 64 materials, 13.45 against 13.59 ms median frame
  time; the lava suite is unchanged. `docs/node-animation.md` has the rest.
  Not done: animated inventory, wield and dropped item images, the strips
  of water and lava tiles, a cracked node (it shows its first frame while
  dug), and the look of sea lantern and magma now that they take the array
  shader's material; no pack with per frame companions has been tried live.

- Formspecs drawn as the vanilla client draws them, 2026-09-19. The game's
  formspec prepend was being dropped: two commits recovered from a stale
  session (577796e, a29dfbe) had removed `GoannaClient.formspec_prepend`
  and the calls that passed it on, so every game form was a grey Godot
  panel. It is wired again, with a suite check on the host side. Buttons
  follow `GUIButton::setFromStyle`: `bgcolor` tints the `bgimg`,
  `border=false` drops the pane but keeps the image (the recipe book, the
  creative tabs and every themed button had lost their artwork), padding,
  `bgimg_middle` and `content_offset` place a label that is now a child
  with Luanti's text shadow, image buttons draw their image behind it, and
  `item_image_button` takes `image_button`'s styles and its item's
  description. Style lookup follows `getStyleForElement`, colour names are
  Luanti's CSS table, and the `sound`, `font` and model `bgcolor`
  properties apply. Tooltips are drawn by the form as `drawMenu` draws
  them, in their own or the `listcolors[]` colours with colour escapes
  kept; `hypertip[]` renders its markup at its width and static position.
  Slots draw the item full size with upstream's wear bar and count, and
  borders only when `listcolors[]` names one. Labels keep colour escapes,
  and the area label of version 9 wraps with the version 11 alignment.
  Fields are Luanti's grey and green edit boxes, a four-part `pwdfield[]`
  works, a form without `size[]` is upstream's 580 pixel window, and a
  node's own form resolves `${key}` from its metadata. Old-system buttons,
  fields, dropdowns, tab headers and hypertext sit where upstream places
  them, and the first empty edit box takes the focus. Hypertext gains
  `<global>` alignment, margin and hover colours; textlists and tables get
  GUITable's look; scrollbars Luanti's colours; backgrounds keep their
  order behind everything else; `button_key[]` captures a key. `tooltip`,
  `hypertip` and `model` are now supported in the coverage manifest;
  `button_key`, `hypertext`, `style`, `style_type` and `tablecolumns` stay
  partial, each naming what is missing. Verified: the formspec suite (317
  checks), and side by side with the vanilla client on one Luanti 5.17.0
  Flatpak server at 1600 by 900 with Godot 4.5.1, each form shown to both
  players by a test mod: Mineclonia's survival and creative inventories,
  furnace, chest, crafting table, anvil, enchanting table, villager
  trading, written book and skin editor, VoxeLibre's release
  announcements and creative inventory, and Minetest Game's creative
  inventory, furnace, chest and sign. They now match in layout, colour,
  button artwork, slots and text placement. Still different: Godot's
  default font is wider than Luanti's Arimo, so a line that just fits
  upstream can wrap; node icons that are not cubes; scrollbar arrows; tab
  headers, dropdowns and checkboxes in Godot's look; no clipping to the
  form; slightly taller textlist rows. Not verified: the vanilla client's
  tooltips, which the harness cannot hover; hover colours, `sound`, `font`,
  a model's `bgcolor` and `button_key`, which none of these games use; and
  the Minetest Game sign through a real right click, whose text round trip
  was exercised through an ordinary node metadata fields packet instead.

- Node items without an inventory image are drawn as their item mesh, as the
  vanilla client draws them, 2026-09-19. `item_icon()` used to fold tiles 0,
  3 and 4 into an `[inventorycube`. That read a mesh node's texture atlas as
  cube faces (Mineclonia's chest came out as a see-through box of atlas
  scraps), drew anvils, stairs, slabs, walls, trapdoors and carpets as full
  cubes, showed a furnace's side where vanilla shows its front, and lost
  overlay tiles and tile colours. Now upstream's `ItemVisualsManager` builds
  the item mesh (the transplanted `createItemMesh`, already turned to the
  inventory angle) and `src/goanna_icon_raster.cpp` draws it the way
  `drawItemStack` does: orthographic, two units across the slot;
  `colorizeMeshBuffer`'s light, ambient 0.5 plus a fixed direction; the
  inventory shader's nearest texel times vertex colour, in sRGB as upstream
  does it; its three alpha modes; GL's clockwise front faces and depth test;
  and depth writes for alpha blended materials, which vanilla has in game
  because `CSceneManager::drawAll` turns `AllowZWriteOnTransparent` on and
  nothing turns it off. That is a small software rasteriser rather than a
  SubViewport, chosen because it keeps the maths exactly upstream's, gives a
  finished image with no GPU readback, and runs under `--headless`, where
  the native test can reach it. `item_icon()` queues; the queue is drawn at
  `frame_pre_draw` across threads, before the frame that asked for it is
  drawn. Icons are drawn at the slot size a form lays out when it fits the
  window (54 pixels at 1600 by 900), redrawn in place when that changes, and
  keyed by item, overlay and the stack's base colour: inventory lists now
  carry an `icon_item` string with any colour or image metadata, which list
  slots, the hotbar and the HUD inventory pass on. Plain cubes take the same
  path, on evidence: the folded cube is bigger (it touches the image edges,
  where the mesh spans 85% of the slot), shaded differently and faced
  differently, and in list slots the mesh path matches vanilla pixel for
  pixel. The item
  mesh is built without Goanna's bevel, through a per thread
  `g_goanna_plain_solids` that the transplanted `item_visuals_manager.cpp`
  sets and `content_mapblock.cpp` reads. Hotbar and HUD inventory icons fill
  the image rectangle as `Hud::drawItem` hands it to `drawItemStack`,
  instead of an 8% inset that made them smaller than vanilla's.

- Verified: `goanna_item_icon_test`, new, 26 checks from node definitions
  alone (an OBJ mesh node on an atlas with a transparent quadrant has no
  holes inside its outline, where the folded cube of the same atlas has 476;
  a faced cube shows top, front and +x at the shades worked out by hand from
  upstream's formula; a slab keeps its outline; a stack colour tints; an
  alpha blended cube shows vanilla's draw order layering), each check seen
  to fail with its rule broken; the formspec suite, 317 checks; the style
  check. Then side by side with the vanilla client on one Luanti 5.17.0
  Flatpak server per game, fresh worlds, 1600 by 900, Godot 4.5.1, a test
  mod showing both players one opaque form of up to 48 items in list slots,
  most of them node items without an inventory image, four stacks tinted by
  metadata, `item_image[]` and `item_image_button[]`, plus the creative
  inventory and hotbars. Mean absolute difference per
  cell, 0 to 255, crops aligned to within two pixels, glass compared with
  vanilla running `connected_glass` as Goanna does: in Mineclonia every list
  slot, tinted stack and 1x1 `item_image` is at 0.9 or below, where before
  they were 4.4 to 70.7, and the 0.8 cases are the slot border inside the
  crop; in Minetest Game every node icon slot is at 0.8 or below except
  lava, against 5.0 to 28.6 before. Frames and per cell numbers are in
  `docs/perf/item-icons-2026-09-19/`.

- Cost, Mineclonia's creative inventory (the scrolling form of about 1840 items,
  782 of them node items without an image), first open in a settled world,
  RelWithDebInfo build, 16 core machine with an RTX 3090: 170 to 178 ms to build
  the form before, 80 to 89 ms after; first frame drawn at 200 to 208 ms before,
  121 to 135 ms after. Of that, building 782 icon jobs takes 20 to 23 ms and
  drawing them 10.6 to 13 ms (rasterising 8.1 to 9.0 ms across 16 threads,
  upload 2.5 to 4.0 ms). Two earlier samples each, taken while the world was
  still streaming in, put the old path at 576 and 669 ms and the new one at 85
  and 138 ms; each `item_icon()` call takes the map lock, which the session
  thread holds while it handles blocks, but that cause was not measured.
  Reopening costs 32 to 38 ms either way, since the UI keeps its own icon cache.
  Steady state, the frame hook costs under 1 microsecond a frame when nothing is
  queued, and a cached `item_icon()` call from GDScript about 1 microsecond.
  Minetest Game's paged creative inventory has 8 node icons a page; it opens in
  about 21 ms before and after.

- Still different from vanilla: glass looks framed because Goanna defaults
  `connected_glass` on (vanilla with the same setting draws the same icon);
  animated node tiles show their first frame, so Minetest Game's lava
  differs; a 2x2 `item_image[]` is the slot icon scaled up, where vanilla
  draws the mesh at 108 pixels; the hotbar scales the 54 pixel icon down to
  48 unfiltered, where vanilla draws at 48; flat inventory images ignore a
  stack's colour metadata (the test form's tinted torch and snowball in
  Minetest Game: vanilla tints them, Goanna does not), and by the code its
  overlay too, which would leave Mineclonia's dyed candles undyed, not
  checked in game; the new `icon_item` string would let `item_icon()` fix
  that; the stack on the cursor still passes only its name;
  `inventory_items_animations` is not supported. Not verified: VoxeLibre;
  texture packs larger than 16 pixels, where vanilla may pick a mip level;
  a window resize was checked only through the control channel (the same
  texture went from 54 to 43 pixels and back), not by dragging.

- Dark glass interface style, 2026-09-19. Settings, Appearance, Interface
  style chooses between Dark glass, the default, and Game theme, and
  applies at once in the main menu and in game (an open form is rebuilt
  and keeps what was typed). In dark glass the main menu, pause menu,
  settings, chat and every server form sit on panes that blur and darken
  the world behind them through a soft luminance ceiling, with a rim, a
  slight edge bend and a shadow, and one Godot Theme dresses every
  control. In forms the game's window chrome is replaced and its content
  kept: the prepend's backgrounds become glass panes of the same
  rectangles, its `bgcolor`, every `listcolors` and the prepend's button
  art and text colours are dropped, `image[]` slot frames (behind a slot,
  framing it, the texture framing two slots or more) give way to glass slot
  tiles, and every other image, item, model, box and form background is
  kept; a form that paints its own window, a book, keeps the game theme
  whole. The theme is recognised when a form repeats it under
  `no_prepend[]`, as Mineclonia's creative inventory does. Text colours
  below 4.5:1 against the glass's worst case are lifted towards white, so
  Mineclonia's `#313131` labels read `#bababa`. The hotbar gets clear glass
  that does not read the screen. `docs/interface-style.md` has the rule and
  the numbers. Verified: the formspec suite, now 402 checks (85 new, on what
  glass replaces and keeps, the slot frame rule's edge cases, the repeated
  theme, a book, the same fields sent in both styles, and the contrast
  arithmetic); live on fresh Mineclonia and Minetest Game worlds on the
  Luanti 5.17.0 Flatpak with Godot 4.5.1 at 1600 by 900, Mineclonia's
  survival and creative inventories, chest, furnace and crafting table,
  Minetest Game's inventory, and Goanna's main menu, pause menu and
  settings, each captured in both styles over a bright day, a forest and a
  cave (`docs/perf/ui-glass-2026-09-19/`); measured contrast of text on the
  glass alone over snow, open sky, sand and water, a forest, a cave and a
  night: 9.1:1 or better for interface text, 6.3:1 for quiet text, 5.1:1
  for a lifted label, 4.6:1 for a slot's count; and the GPU cost, 0.07 to
  0.10 ms a frame with a form open (0.36 ms under a heavier load from other
  processes on the same RTX 3090) and nothing measurable with no window
  open. Not verified: VoxeLibre and other games, other GPUs and
  resolutions, dropdowns, tables and hypertext photographed in glass, and
  the in-game settings dropdown clicked by hand. Known to be worse than the
  game theme: dark and mid tone items stand out less on the glass slot tile
  than on Mineclonia's light grey slot (light items stand out more), and
  Mineclonia's creative tabs stay light grey because they are the game's
  own art.

- Dark glass, second round, and form fields as upstream sends them,
  2026-09-19. A review of the entry above (its screenshots were taken from
  the main checkout, not this branch) led to these. Mineclonia's player
  settings back arrow now returns to the inventory: every submission used
  to carry every check box, text list, tab header and table in the form,
  and that form's handler read the check boxes as changes, saved them as
  the player's settings on the server and showed itself again. It was
  broken in both styles and in an export of `5cfd7b9`, before the glass
  existed. Fields now follow `GUIFormSpecMenu::acceptInput`: edit boxes,
  password fields, dropdowns, scrollbars and animated images with every
  event, anything else only with its own event, and a changed dropdown as
  the only dropdown. Scrollbars gained `CGUIScrollBar`'s arrow buttons,
  thumb size, thickness and wheel step, and no thumb when there is nothing
  to scroll; small buttons keep their label centred, as the X revert
  buttons on that form need. Forms older than version 3 are drawn in
  upstream's legacy element order, which puts the brewing stand's items in
  front of its art. Forms, menus, chat, tooltips and the hotbar frame are
  now one pane: the same 12 pixel radius, rim and outline. Plain window
  art that frames a slot, button, model or field (a large output slot, the
  player preview's backing, Mineclonia's creative tabs) becomes a glass
  tile, the lighter of a set of tabs is ringed as selected, tabs outside
  the window get glass behind them, dark line art in slots is drawn light,
  grey boxes become sunken tiles, and slot art with no slot on it (a short
  creative tab, the trade slots before a trade is chosen) becomes an empty
  glass slot. Verified: the formspec suite, 460 checks, including the field
  semantics, an `image_button` with an empty label sending its name, the
  scrollbar parts, the legacy order, window art, tabs and empty slot art;
  the back arrow live on the fixed build in both styles and on the
  `5cfd7b9` export; the vanilla Luanti 5.17.0 client showing the same form,
  with the server replaying through Mineclonia's own handler the fields the
  vanilla client sends for the arrow (back to the inventory) and the ones
  Goanna used to send (the form again), the vanilla client not being
  clicked; and a sweep of every Mineclonia form the test mod could reach
  on a fresh world on the Luanti 5.17.0 Flatpak with Godot 4.5.1 at 1600 by
  900, each captured in both styles with `4d48e0b`: survival inventory,
  crafting guide, help, achievements, player settings, skin editor, chest,
  furnace, blast furnace, smoker, crafting table, enchanting table, anvil,
  loom, stonecutter, smithing table, grindstone, brewing stand, beacon,
  hopper, dispenser, dropper, barrel, shulker box, ender chest, villager
  trading and all 13 creative tabs are glass (the villager's trade slots
  and the rail tab's spare row only after the empty slot change, checked by
  reloading `formspec.gd` into the running client), and the two books keep
  the game's art by the bespoke rule. The comparison sheets, contrast and
  cost were retaken with default graphics
  (`docs/perf/ui-glass-2026-09-19/`): interface text 9.1:1 or better over
  snow, sky, sand and water, a forest, a cave and a night, quiet text
  6.2:1, a lifted label 5.1:1, a slot's count 4.6:1; 0.07 to 0.11 ms more
  a frame with a form, the pause menu or a tooltip up, and nothing
  measurable with no window open. Not done, because the GPU faulted (Xid
  51) at 17:38 and refused every new Vulkan context until a reboot: the
  Minetest Game sweep and inventory recapture, the main menu recapture, and
  the GPU cost on an idle GPU (these numbers are from the one client left
  running, on a GPU a game shared at about 40 percent). Also not done: the
  Mineclonia sign's text form, which the test mod could not open without a
  server restart, and any click on the vanilla client.

- Test clients off the owner's desktop, 2026-09-19. Agents testing Goanna
  had been opening client windows in front of the owner's work, taking the
  focus and grabbing the mouse, once during a video call, and one tried to
  move a client's pointer with xdotool. Three things change. Test mode
  (`GOANNA_CONTROL`, or `GOANNA_NO_POINTER_CAPTURE=1`) never captures the
  OS pointer and asks for no focus: every capture in `main.gd` and
  `game_ui.gd` goes through one function that, in test mode, keeps the
  state inside the client, and only mouse input pushed in by the control
  channel counts as captured. The control channel gains `ui_tree`,
  `ui_click`, `ui_hover`, `ui_type`, `ui_scroll` and `key`, which push
  InputEvents through `Input.parse_input_event` so forms send what a
  player's click sends, with read-only introspection in `formspec.gd`. And
  `tools/goanna-headless` (shared with the MCP server as
  `tools/goanna_headless.py`) runs Goanna from any checkout or worktree, or
  the vanilla Luanti Flatpak, inside gamescope's headless backend, refuses
  a control port already in use, and stops gamescope, which outlives its
  child and ignores SIGTERM, by PID when the client exits or when asked.
  `tools/goanna-mcp` runs any number of these as instances, and every reply
  names the instance and port. The rules are in `docs/agent-interfaces.md`
  and `CLAUDE.md`. Verified against a Luanti 5.17.0 Flatpak server on a
  fresh Mineclonia world with Godot 4.5.1, through the MCP server: two
  Goanna instances at once on control ports 30851 and 30852, a third start
  on 30851 refused; the creative inventory opened with `key`, read with
  `ui_tree`, a tab pressed by element name and another by its tooltip text
  (the server answered each with the rebuilt tab), a slot's tooltip read by
  hovering, a search typed and entered (the server filtered the list), a
  torch stack moved between hotbar slots (the server's inventory showed
  it), and shots taken both from the viewport and through gamescope. A
  pushed left button dug with the form closed while the OS pointer stayed
  free, and a device 0 press and motion, standing in for a real pointer,
  neither dug nor turned the camera. A client told to quit took its
  gamescope and Xwayland down with it. KWin, asked over D-Bus while the
  clients ran and again after, listed no Goanna, Luanti or gamescope
  window, and nothing was typed or clicked on the desktop. All of it
  ran with `--software` (lavapipe and llvmpipe), at about one frame a
  second, because the GPU was unavailable: at 17:38:35 the NVIDIA driver
  logged Xid 51 and Xid 154 and refused every new Vulkan device with
  `NV_ERR_RESET_REQUIRED` until a reboot. That came within a minute of two
  headless gamescope sessions starting, this work's first probe and another
  agent's, after a single headless run at 17:21 had been fine; the cause is
  not known, so two GPU instances at once is an open risk to verify after
  the reboot, not a result. The vanilla client (the same Flatpak, 800 by
  450, software) joined and was photographed in game from its own window on
  the nested X display with ffmpeg's `x11grab`; gamescope's screenshot of it
  showed the loading screens and then only black, so `x11` is the default
  route for it. Not working or not verified: the vanilla client with the
  GPU; framing the vanilla client, which cannot be steered and looks
  wherever the server puts it; picking from a dropdown's list; and dragging
  a stack with the button held, which has no command. Found on the way:
  while a field is being edited, Goanna's first Escape only ends the
  editing (Godot's `LineEdit` takes `ui_cancel`) and a second one closes
  the form; what the vanilla client does there was not checked.

- Freeminer servers, 2026-09-19. Whether Goanna can join them had not been
  checked. `docs/freeminer-plan.md` answers it from Freeminer's current
  master (`5d2c77028`, merged with Luanti 5.17.0) and from a locally built
  server, rather than from the project's old documentation. A default
  Freeminer build speaks Luanti's protocol on its main port and negotiates
  protocol 53 with a Luanti 5.17.0 client; Goanna on the `luanti-5.17` branch
  joined it with devtest and Mineclonia, with no code change, and its own far
  field worked there through `goanna_server_mod`. What Freeminer adds (far
  view over its own msgpack commands, 32-bit positions at protocol 148, wind
  physics) needs a second protocol path or a build against Freeminer's
  GPL-3.0-or-later tree, so the plan recommends documenting the working case
  and nothing more yet, and says what would change that. Found on the way:
  the Freeminer server crashes on fresh worlds with several emerge threads,
  reproduced with the stock Luanti client and no Goanna mod, and clean with
  one thread. No Goanna code changed.

- Sub node damage measured from the node's own shape, 2026-09-19 to 20. The
  v1 model measured a dig as an inset from the cube's six faces, so a blow on
  a thin moss layer or a ramp's slope could land past the shape's real
  surface and remove nothing. Kythen's `mods/kythen/core/radial_form.lua`
  (commit 809475f, branch `form/damage`) replaced that with damage measured
  from the shape's own derived carve centre and present position, a delta and
  crater pair per control, a strike gated by both the struck normal and the
  hit's own direction, a six connected flood fill so a pit cannot leave
  floating fragments, and a crack stage tied to connected volume against the
  shape's own pristine volume. That rule is ported into
  `goanna_radial_form.{h,cpp}` and the v1 displacement model is removed: one
  damage model, not two. A node's own resolved boxes feed the same rule,
  which is what a Kythen mound or a Mineclonia slab or stair arrives as over
  the ordinary protocol, so no node type channel is needed, and solid nodes
  and nodeboxes both draw their carve from the live dig or from a carve the
  server has stored. A stored carve now earns a persistent crack stage on
  every damaged node rather than only the one under this player's tool, in
  two visible states rather than the full five frames, because the
  transplanted material flags have two bits spare. A reported carve is hex
  encoded over the mod channel: Luanti hands such a message to Lua as a C
  string, the codec's header and mask bytes make a zero byte common, and the
  stored carve was being truncated there. A game can claim the
  `goanna_carve` key with `goanna_carve_authority=game`, and the relay then
  does not run at all, so a client's guess cannot overwrite a game's
  validated answer; local dig prediction is untouched. Verified:
  `goanna_radial_form_test`, rewritten against
  `tools/dig-review/reference_v3.json`, a copy of Kythen's own generator
  output, passes 7083 checks matching centroid, present position, delta,
  crater, connected occupancy cell for cell, stage and the encoded wire bytes
  byte for byte, and `check_kythen.py` re-runs that generator against a live
  Kythen checkout to show whether the copy or the port has drifted. The hex
  fault was found in `tools/dig-review`'s own live dig screenshots, where a
  punched cube showed no visible carve under `goanna_shared_dig_damage` and
  carved correctly after the fix. Not verified: which server, game and Godot
  version that was, a game claiming the authority key, and any run with a
  second client.

- Cutting v0.9.0-alpha, 2026-09-20. The release itself turned up five
  defects, three of them in work that had already shipped.

  The asset epoch the catalogue pointed at had never been published.
  `assets-2026.09.1` sat as an untagged draft, so every bundle URL in
  `asset_bundles/catalogue.json` answered 404 and no client could install
  anything. `tools/publish-assets.sh` creates the release with `--draft`
  and prints a reminder to publish it by hand, which is the step that was
  missed on 2026-09-13. Everything is now in `assets-2026.09.2`, published,
  and all five URLs answer 200.

  Mineclonia's maps are a bundle: `org.goanna.mineclonia.pack` 1.0.0, 1021
  pairs, 95 MB, companions only, no albedo. One bundle rather than Kythen's
  three, because that split comes from three bake stages driven by nodedef
  manifests and Mineclonia had no manifest at all until this release. It
  does not make the authored look a default on a remote join: the Join Game
  screen defaults to a choice whose pack path is empty, and a pack cannot
  be handed over after connect, so a player still picks Installed
  Mineclonia PBR. A world hosted in Goanna does serve the maps with no
  setting touched.

  The shipped pack was a stale bake. `CLASS_HEIGHT_DEPTH` and the height
  encoding landed 2026-09-09; 839 of the pack's 846 baked stems were
  written in August and overran an envelope that did not exist then. Nobody
  knew because `tools/check-pbr-quality.py` measured every authored map by
  the bake's convention too, and reported 1016 of 1023 failures, which read
  as noise. The gate now reads a `goanna_pipeline=authored` PNG chunk that
  `tools/pbr_author/lib.py` writes, and measures an authored height field by
  its own rule; baked corpora report identically before and after. The
  re-bake itself was a recompose: every generation from the 2026-08-20
  ComfyUI queue survived on Pockets, so 1021 stems cost minutes rather than
  the seven hours a fresh bake would. Terrain and billboard both report 0
  failed.

  Three smaller faults on the way. `tools/pbr_author/lib.py` never
  neutralised a cut-out's transparent texels where the bake does, so 20
  Mineclonia and 32 Kythen sprites carried authored fields in texels the
  art does not draw. 57 Kythen scripts that delegate to a family module
  never declared `GAME`, so a Mineclonia run built them and installed
  `kythen_` stems into the Mineclonia pack. And `project/shots`, 99 MB of
  gitignored test screenshots, was being swept into `Goanna.pck` by
  `export_filter=all_resources`: the first 0.9.0 package was 150 MB against
  0.8.0's 77 MB.

  The client could not install a bundle at all. `AssetStore.install_archive`
  compared its `_n` and `_s` stem dictionaries with `keys() != keys()`,
  which compares arrays in order, and the sorted ledger puts a stem that is
  a prefix of another stem in a different position in each list
  (`mcl_bamboo_bamboo` before `mcl_bamboo_bamboo_plank` among normals,
  after it among materials). A fresh profile joining a Mineclonia server
  fetched the whole 95 MB archive and threw it away. This had never fired
  because no client had ever downloaded a bundle.

  Verified after the fixes, on a Luanti 5.17.0 Flatpak server, Mineclonia,
  Godot 4.5.1: a fresh profile joined, fetched the archive from the
  published catalogue, checked its hash, installed 1021 pairs and composed
  `profiles/mineclonia/textures`, 2042 files, with nothing in the log. That
  is the first bundle install there has ever been. The Linux package was
  built and connected to the same server, media 5902 of 5902, blocks
  meshed, player on the ground.

  Not done, and worth picking up. Eleven of the 1021 maps ship with a
  quality failure, five of them soil where `lib.pack`'s `keep_mean` clips
  at zero and lifts the mean it was setting, the rest near misses on bands
  the classification review calls defaults rather than judgements;
  `asset_bundles/recipes/mineclonia-pack-1.0.0.json` names them. Kythen's
  authored set still has the cut-out fault and three scripts
  (`kythen_moana_lava_lichen`, `kythen_moana_peat_moss`,
  `kythen_norse_lichen_ground`) hand `pack` an RGB albedo, so those nodes
  draw as solid squares. `lib.metrics` measures over holes, so
  `build_pack.py --check` now prints failures on cut-outs that are reading
  the neutral fill. And `tools/goanna-headless start` failed twice today:
  gamescope and Godot come up, then a zenity dialogue appears inside the
  nested display and the client exits before the control channel opens
  (`~/.cache/goanna-headless/goanna-30870-20260920-170019/output.log`).
  Nothing reached the desktop. The plain `--headless` client is unaffected,
  which is what every measurement here used.

- Correction, 2026-09-20, same evening. The entry above calls the shipped
  pack a stale bake and the re-bake a fix. It was the other way round. The
  maps of August filled the height byte; `pack_deepbump_normal` began
  pre-multiplying that byte by the material's depth on 2026-09-09, and
  `nodes_array.gdshader` applies the same depth again at draw time
  (`h = 1.0 - a`, then `goanna_class_depth(cls) * parallax_depth`), so the
  encoding the gate was enforcing applied it twice. Composing 844 stems to
  it took `mcl_copper_block` from a height span of 255 to 46 and flattened
  the world, which the maintainer saw within the hour of the release:
  "it still doesn't have the authored ones as default". The authored 177
  were untouched throughout, which is exactly why the difference read as
  the authored pack being off.

  The analysis that taught the gate the two encodings had said plainly that
  the bake's pre-attenuation is a second application of the same table and
  left it alone as out of scope. I read that and shipped anyway. The lesson
  is not about the encoding: a gate reporting 0 failed says the art matches
  the rule the gate holds, and when the rule itself is the thing in
  question, that number is worth nothing. The evidence that mattered was
  four lines of shader and a height span, and both were available before
  the bundle went out.

  Fixed: the bake writes the field across the byte, the gate's two height
  rules are gone (they existed only to describe the doubled convention) and
  both pipelines are now measured by one rule, the two tests that asserted
  the old encoding assert the new one, and every baked map is composed
  again. Authored stems are byte identical; 844 baked ones move. The gate
  still reports the same 11 smoothness failures and no height failure on
  either pipeline. (Corrected 2026-09-25: this entry and 3c02257 also said
  `default_stone` went from 89 to 161 back to 0 to 255. That was never true
  of a shipped map. Mineclonia's `default_stone` is authored and is 89 to
  161 by design; the 0 to 255 map was the bake's staging copy, which the
  authored set overrides.)

  Still to do: `org.goanna.mineclonia.pack` 1.0.0, published this evening
  and installed on at least one machine, carries the flattened maps and
  needs a 1.1.0 in a new epoch. And damaged blocks read as low resolution
  because `crack_anylength.png` is 16 by 160 and `draw_crack` scales one
  16 px stage over a 256 px base; an authored crack in the pack would fix
  it, since the pack overrides by filename.

- Release checks, 2026-09-25. One check for each 0.9.0 fault that nothing
  would have caught, described under "Release checks" in
  `docs/building.md` and listed in `docs/launch-target.md`.
  `cmake --build build --target check` builds every native test and then
  runs it; built fresh here, all 11 pass. `tests/asset_bundle_install.gd`
  installs an archive `tools/pbr_bundle.py` built, with prefix stems, into
  an empty store through the updater's own call; it fails against the old
  `keys() != keys()` comparison. `tools/check-pbr-height.py` runs in
  `pbr_bundle.py build` and `verify` and in the quality gate: it passes
  `pbr_packs/mineclonia/textures` and Mineclonia pack 1.1.0 (median span
  255) and fails Mineclonia 1.0.0 (77), Kythen billboard 1.0.0 (41), Kythen
  item 1.0.0 (77), Minetest Game terrain 1.0.0 (141), Kythen terrain 1.1.0
  (205.5) and `pbr_packs/minetest_game/textures` (205). The last two were
  not on the list of known flattened sets; both carry spans of 141, 108 and
  41, which are stone, wood and leaves depths times 255.
  `tools/check-asset-catalogue.py --live` found all five catalogued URLs
  answering 200 at the catalogued size.

  The install test also found that `AssetStore.install_archive` left its
  unpacked `.bundle-*` staging copy in the store whenever it refused an
  archive or was handed a version already installed, which
  `install_bootstrap` does on every launch of a packaged client. The store
  on the development machine held five, 5.7 MB each. It now removes them.

## Log since v0.6.1-alpha (2026-09-02), covering v0.7.0-alpha and v0.8.0-alpha

The 0.5 and 0.6 series were released without a section here. What they
contain is in `docs/release-v0.6.0-alpha.md` and
`docs/release-v0.6.1-alpha.md`; this section does not reconstruct them after
the fact.

v0.7.0-alpha (2026-09-14) and v0.8.0-alpha (2026-09-16) were then tagged
without a section of their own, so what follows is two release cycles under
one heading, ending at the v0.8.0-alpha tag.

- The community PBR bake was lost and rebuilt, 2026-09-09. The staging root
  had been `/tmp`, which is tmpfs on this box, so the reboot of 2026-09-07
  took the extracted sources, every composed map and the log of a run that
  was most of the way through. `tools/pbr_stage_sources.py` now rebuilds the
  sources from `pbr_packs/COMMUNITY_LOCK.json`, refusing any archive whose
  hash does not match the lock the licence audit was written against, and
  the overnight queue works from `~/.local/share/goanna-pbr-audit`.

- The generation had survived on ordinary disk, because ComfyUI keeps every
  image it produces. `pbr_bake.py --reuse-outputs` composes from a previous
  run's saved detail pass and Chord maps and generates only the gaps: 644 of
  947 textures came back that way at about 0.7 s each against 31 s to
  generate, and a reused `br_carpet_0` is byte identical to a fresh bake of
  the same stem at seed 1. The full queue then ran 13:26 to 15:53, against
  the six to seven hours a bare re-bake would have cost.

- The acceptance gate was measuring the fill it had asked for. It averaged
  whole images, including the neutral written into transparent cut-outs, and
  `NEUTRAL_S` alone is smoother than a foliage sprite's reviewed maximum, so
  60 of 72 community billboards failed as too smooth while their material
  texels sat at 0.10 to 0.12 against a 0.15 band. Masking the statistics to
  the texels the source authored, which the colour drift check had always
  done, removed 59 false failures and uncovered 31 real ones: maps whose
  height never reaches its high reference inside the art, satisfied until
  then by the fill's own 255. That second half was a bake defect, since the
  height range was taken over the whole generated image including whatever
  the model invented in the cut-out, and it is now taken over the opaque
  texels.

- Three reviewed judgements, on the evidence the gate produced. Glass,
  stained glass and covellite are dielectric at `terrain-v1.1`: the leaded
  edge and submetallic lustre arguments are true of real materials and not
  of dark pixel art, where a metal read renders near black. A reviewed metal
  or mixed material is allowed to be dark, so flint and steel, the muskets
  and the flashlights now warn instead of failing. Four near transparent
  tint overlays left the community terrain tranche rather than being
  rebaked, which takes it to 205.

- After all of that, recomposed in ten minutes with no GPU: 943 textures
  checked, 0 failed, 229 warned, of which 225 are wrap seam warnings and 6
  are dark art carrying reviewed metalness. Nothing here is a release
  claim. The gate is half the acceptance test and the failures-first review
  sheets under each stage have not been looked at by a person, no bundle has
  been built from these maps, and `README.md` is unchanged.

- Far region skirts wound both Z faces the same way once the mesher's Z
  mirroring is accounted for, so back face culling opened repeated
  horizontal cracks through terraced far hillsides. Fixed and covered by a
  `goanna_lod_test` case. Not yet observed against a server: the test
  asserts the winding, not the picture.

- A correctly audited community source could not pass the licence gate,
  2026-09-13. `lessdirt` declares CC BY-SA per file, which is the case
  `docs/pbr-community-review.md` says needs a per-file mapping, and the
  mapping already existed: `pbr_texturepack_intake.py` records an exact
  licence against every selected file. The gate now resolves any package
  whose summary is not a single accepted licence from those records, and
  fails it if the mapping is missing, if a file carries no exact licence, or
  if any recorded licence is outside the accepted set. A rejected
  package-level licence still fails first, so this is narrower than the check
  it replaces, not wider.

- Enhanced materials are distributed from this repository, 2026-09-13.
  `asset_bundles/catalogue.json` is tracked and served raw from the default
  branch, with absolute URLs into the epoch's release assets, so a shipped
  client sees new bundles by refetching one small file rather than by being
  rebuilt. The release carries archives only and is published as a
  pre-release, so there is no second catalogue to diverge and an asset epoch
  cannot become the repository's latest release. Building no longer writes a
  catalogue, since its default wrote a relative URL that only resolved in the
  arrangement being removed, and `tools/check-asset-catalogue.py` refuses to
  publish a release the catalogue does not name. That last failure had
  already happened: the tracked catalogue listed one bundle while four were
  built. **Not yet observed**: no client has downloaded a bundle from a
  served catalogue. What is checked is local, that an archive installs under
  its recorded hash and is refused under the superseded one.

- Published art no longer names the baking machine, 2026-09-13. Every bundle
  ships an `ATTRIBUTION.md` whose first paragraph gave the absolute path the
  source game was installed at. `pbr_bake.py` now names the game instead, and
  all four bundles were rebuilt with byte-identical texture payloads.

- The default-look work is a checkpoint, not an overhaul, 2026-09-13. Two
  review passes were rejected; `docs/default-look.md` records what landed and
  what is still open, including that the daylight treatment is too slight to
  claim and that the shared lamp/shadow budget can drop visible room lighting
  as the camera moves.

- Material calibration, 2026-09-15. Feedback on Mineclonia in full sun
  said "plastic", and the guess behind it was missing normal and albedo
  maps. Two new offline fixtures measure the renderer instead of guessing:
  `project/material_ramp.tscn` (a roughness and metalness ramp beside the
  pack's core sets, with the sun swept to each column's mirror direction)
  and `project/water_ramp.tscn` (water over sand at five depths beside dry
  sand). Findings in `docs/material-calibration.md`: the pack's terrain
  shows almost no specular in daylight, spreading its roughness maps
  (`tools/pbr_spec_variance.py`, new) moves nothing by more than a count in
  the sun, a dielectric loses the sun glint above smoothness 230, and no
  surface can show a mirror because nothing but the sky is there to
  reflect. What did measure wrong was the water: the bed seen through it
  was lit twice and the deep body was a half strength tile under the full
  sun, so deep water sat at seven tenths of the dry sand's brightness.
  `water.gdshader` now sends the transmitted bed out as emission and lights
  only a dim scatter term; deep water fell to a third to a half of the sand
  from thirty degrees and converges on the reflected sky from twelve.
  Fixture only: no Mineclonia server was up and the tree carried another
  session's C++. The saturation question (ACES plus 1.15 on top, against
  reference frames at half the saturation) is deliberately left for after
  these three.

- Authored PBR pack, 2026-09-15 to 16. The plastic look turned out to be
  structure, not specular: the bake embosses the pixel grid (median texel
  tilt six degrees, occlusion never under 0.81). `tools/pbr_author/` now
  holds a script per stem that builds height and smoothness fields from
  the 16 px art, about a hundred and eighty stems across three fleets of
  Sonnet subagents (surfaces, ores, furniture, doors and cut-outs, four
  colour families, stone variants and glowing blocks), each batch judged
  on the close-up ramp and reworked where the user's eye caught what the
  metrics passed. The node shader gained parallax occlusion with self
  shadow, under a millisecond a frame on a full screen wall, with depth
  per material class. The authored sets are installed into the
  shipped `pbr_packs/mineclonia` (2026-09-16, a0eee77) at the user's
  direction after review in play, and also sit in the launcher's texture
  pack list as `mineclonia_authored`. Two client fixes came out of the
  in-game review: the mesher's binormal handedness, which had every
  normal map upside down along a tile's V axis, and the companion lookup
  for composite tiles, which had the grass block's dirt side flat.
  Mineclonia has no asset bundle in the catalogue yet; the pack reaches a
  player through the texture pack setting or a worldmod. Findings in
  `docs/material-calibration.md`.

## Log since v0.4.1-alpha (2026-08-30)

Verified on a local Mineclonia server on Luanti 5.17.0 with Godot 4.5.1 and
an RTX 3090, unless marked otherwise.

- The far region ladder keeps doubling with the tier (4, 8, 16, 32, 32
  blocks against the old 2, 4, 8, 8, 8): measured at the test_world
  beach facing the open west after a 75 s settle, regions fell 3116 to
  604, far surfaces 11.2k to 3.1k, and camera draw calls 4703 to 1895
  with primitives unchanged, the same picture in fewer submissions.
  Before and after screenshots match, including the pre-existing
  floating stale shelves.

- Overnight performance session, 2026-08-31, with the benchmark session
  measuring and this one code-only. What its data established: flying
  is the failure mode, medians healthy at 4.7 to 6 ms while 1 per cent
  lows sit at 36 to 49 ms and 0.1 per cent at 119 to 263 ms, GPU bound,
  170 to 340 hitches a minute, and standing still has no such tail, so
  the cratering happens while the world arrives, not while it draws.
  The region ladder was confirmed independently (-32 per cent camera
  draws at the village anchor) but moved frame time by nothing there,
  so draw submission is not the binding constraint at that anchor; and
  the per frame HUD stats path measured as free at test_world scale.
  What landed on that evidence and on code reading, in bd91ace through
  baad665: the tier rescan no longer copies all of m_block_tier per
  camera block crossing (a 10 ms and worse hitch every 16 nodes of
  travel at half a million blocks); the horizon bake extraction became
  bounded slices; the summary ask scan's lattice walk is sliced by row;
  the engine render counters refresh five times a second instead of per
  frame; occluder swaps are timed and boundable by distance
  (set_occluder_distance); and far tier meshes left SDFGI, whose
  re-voxelisation on arriving geometry is a prime suspect for the GPU
  bound tail. Still to be measured on one revision: the flying hitch
  census with SDFGI and occluders toggled, the occluder distance sweep,
  and the prolonged session growth question.

- The near batch build moved onto the mesh workers (the structural fix
  the whole attribution night pointed at): the concatenation and the
  occluder triangle filter run as pool jobs on copy-on-write snapshots,
  and the main thread keeps only surface assembly, material binding,
  the mesh swap and the occluder commit, budgeted with the far region
  publishes and guarded by generation stamps. Validated live: terrain
  renders correctly through the worker path, and the worst single
  publish across two teleport streaming floods measured 7.3 ms warm
  against the old path's routine 10 to 29. First-sight material
  creation still spikes a cold publish to about 114 ms; deferring it
  is the named follow-up.

- The torch responsiveness work came back from the stash, repaired:
  the aging sort scores once per element (the old in-comparator now()
  broke strict weak ordering and caused the night's three SIGSEGVs),
  and the lamp slot eviction only trades up. Verified live: a torch
  placed at night lights its ground promptly and takes a pool slot.

- The validation trio that closed the night (V1/V2/V3, one route, one
  instrument, 1.7 per cent noise floor): the arrival-gap rebuild
  debounce is a confirmed win (mesh-cut occluders went 299-304 to 256
  hitches a minute, 1 per cent low 22.6 to 18.0 ms, rebuild commits
  halved). Box occluders with real coverage (the emitter had iterated
  the member list, which structurally excludes the solid blocks boxes
  are made of; fixed by walking the region cube and enqueueing chains
  for buried live blocks) read 199 a minute and 15.2 ms against the
  mesh cut's 256 and 18.0 while genuinely occluding in flight, with a
  clean over-occlusion check, so boxes are now the default
  (GOANNA_OCCLUDER_BOXES=0 restores the mesh cut). The residual cost
  tracks the engine's per-commit occlusion consumption, not triangle
  count, naming distance-gated box commits as the next lever; the
  bigger remaining item is moving the near batch build onto the mesh
  workers, which owns the ~150 a minute floor and every extreme frame.
  The bench route wrap (a teleport, not a lap) still wants a closing
  leg before any future census.

- The dedicated tester's queue, small hours of 2026-08-31, all on one
  clean revision with per-second instrumentation: 91 per cent of flying
  hitches are near batch region builds (10 to 29 ms single builds
  during arrival floods); the occluder swap itself never exceeded 0.8
  ms. The celebrated five minute cycle, quiet minutes, residency decay
  and all, was aliasing: the bench route's wrap teleports 300 nodes
  every 75 seconds and re-streams the same 15.4k blocks per lap, and
  60 second census bins against 75 second laps manufacture a 300
  second beat; per lap figures are flat. A same-client live A/B then
  put the mesh-cut occluder construction inside those batch builds at
  about 45 per cent of the hitch rate (310 to 171 a minute), while the
  box representation emitted almost nothing because tier 0 blocks
  carry no chains, a coverage gap, not a terrain fact. SDFGI owns
  essentially none of the tail (299 against 303 a minute with it off)
  and about 0.2 ms of steady median. Cross-cell noise for this
  instrument bounds at about 4 per cent. Fixes staged on the findings,
  committed unlinked pending the queue's end: rebuild debounce on a
  gap in arrivals rather than age, worst-cost counters with a proper
  reset owner, and chain coverage for near blocks so box occluders can
  actually stand in for the mesh-cut. The route wrap wants a closing
  leg; the near batch belongs on the mesh workers; both are morning
  work.

- The measurement half of that session, later the same night, on clean
  single revisions: no growth over ten minutes of instrumented flight
  (medians, heap and VRAM flat), so the long-session drain does not
  reproduce on test_world. The periodic 657k-triangle occluder mass
  events were identical recommits and the geometry hash in c06a86d
  removed them (peak 88k after, heap normal, and a run spanning both
  day/night ratio transitions showed none, killing that trigger
  theory). With occluders absent entirely the flying hitch rate fell
  336 to 236 a minute and the 1 per cent low 17.1 to 11.7 ms, so
  occluders own about a third of the tail; the first box criterion
  never fired on real terrain (a fully solid 16 node block does not
  exist at the surface) and 13f24fb re-cuts it per 8 node sub-cell.
  Openly unexplained and recorded as such: a five minute cycle of
  residency burst plus a near-quiet minute that survives revision,
  occluder and clock changes, and monotonic residency decay between
  bursts on a fixed loop. An arrivals-versus-hitches correlation was
  tested and is not established. Remaining queue: fixed-yaw cell,
  boxes retest with the distance sweep, and the SDFGI 2x2.

- The knowledge/mesh split is in (2026-08-31, set_far_mesh_distance,
  env GOANNA_FAR_MESH): region meshes stop at the mesh horizon while
  chains, summaries and the horizon bake keep filling to the far
  distance, the fog closes at the drawn edge, and the band beyond is
  panorama alone. At the beach with the mesh horizon at 512 against
  knowledge to 960: regions 604 to 428, camera draws 1895 to 1350, the
  horizon continuous. Off by default until the benchmark session
  measures it; the profiles own the default after that.

- The horizon bake is in (2026-08-31, docs/sky-orchestration.md, "The
  baked horizon"): the terrain the client knows about, marched into a
  cylindrical albedo and distance panorama off the main thread and
  relit by the sky shader every frame from the beam and air
  authorities. Verified at the beach: baked silhouettes hide exactly
  behind the drawn terrain they duplicate, and toggling it shows known
  but unbuilt directions filling in. Coverage is currently bounded by
  the chain radius, so the next step is retaining chains to the full
  grant while meshing only a shorter radius, at which point the
  outermost band costs zero draw calls.

- The tier benchmark's "frustum culling is not running" had two wrong
  explanations before the right one. Culling works: per pass counters at
  the test_world beach drop from 478 camera draws on the vista to 92
  straight down. The first wrong story was the counter (the HUD's TOTAL
  numbers fold every pass together, which is real but was not the cause);
  the second was this session's "the shadow passes are direction
  invariant", contradicted by its own measurements and by the cascades
  being fitted to the camera frustum. The actual cause, found by the
  benchmark session: the benchmark set the camera with cam.look_at()
  from a run snippet, and main._process overwrites the camera basis from
  the player pose every frame, so the camera never turned and every
  direction photographed yaw 0. Only the control channel pose commands
  stick. What survives: render_stats reports per pass counters, the HUD
  leads with the camera pass, far tier regions no longer cast shadows
  (they were 948 shadow draw calls per frame into a 200 node map for 4
  per cent of its primitives), and the re-run attribution says the
  frame is dominated by per draw submission (~1600 camera draws at ~760
  primitives each), not by any post effect. The far ladder's pixel-size
  reduction remains an open question.

- First field session on a Terrain Diffusion world (4096 grant, half a
  million far blocks) reported four faults against the new sky: biome
  borders flipped the whole dome in one frame (indigo to peach in a few
  steps), the valley mist band was pinned at spawn height so climbing to
  that height anywhere wrapped the camera in a veil, the night mist glow
  banded green like an aurora, and a sunset deck's underside stayed black
  over gold-flooded land. All four addressed: server sky and cloud sets
  ease over four seconds, the mist reference tracks terrain (down in
  seconds, up over ninety), the glow dropped to a third with the hue
  capped, and both cloud layers take an underside term from the
  ridge-gated ground beam. The easing and mist tracking are verified by
  code and fixture only; a biome border cannot be reproduced offline, so
  the next session on that world is the test. The same session showed the
  far poll at 65 ms on that world, which is the known far field scale
  cost, not new.

- The dawn is orchestrated from the horizon each layer actually sees
  (docs/sky-orchestration.md): one transmitted-sun beam behind every warm
  term, per layer horizons behind every timing ramp, the ridge probe in
  lodUpdateFar feeding the ground's gate, the dome's lower hemisphere
  drawn as the fog wall, and the valley mist given a diurnal cycle and a
  night glow so dawn pierces a fog that already exists. Composed on the
  offline dawn sweep fixture, then verified 2026-08-30 on the test_world
  Mineclonia server: at the beach at (515, 6, 447) a 42 node hill 133
  nodes east holds the sunrise, the clouds light pink at sun elevation
  -0.13 over a dark land, the astronomical rise at 0.0 brightens only
  the sky, the morning stays sunless in the hill's shadow through 0.20,
  and the sun's energy ramps in over the crest near 0.29 with the first
  warm rake on the terraces. The probe reads 0.288/48/133 there, stable
  across shots, with lod_ms at 0.2. Not yet done: the moon still rises
  astronomically, daytime terrain past the 200 node shadow map is still
  lit unshadowed, and the night mist glow is calibrated on the fixture
  only.

- The screen space light shafts had never drawn anything, from the day the
  code landed until it was first run. The fragment ended `ALBEDO =
  vec3(0.0); EMISSION = col;`, and under `render_mode unshaded` Godot takes
  the fragment colour from ALBEDO alone and never runs the lighting step
  that applies emission, so the additive quad added black on every frame.
  `ALBEDO = col` is the whole fix. The fault survived a first look because
  the `light_shafts` slider also scales `volumetric_fog_density`: sweeping
  the slider moves the froxel fog a great deal and reads as the setting
  working. Measured instead by hiding the quad, at the mesa east of
  (130, 37, 313) at dawn, the pass moved the frame by +0.01 of 255 before
  the fix and +3.11 after, against a frame-to-frame noise floor of 0.09
  taken from two shots with nothing changed. At ten times the shipped
  strength the broken pass was still an order of magnitude under that
  floor. After the fix a dawn sun behind the mesa throws lanes of light
  across the canopy, the fan swings with the camera, and there is nothing
  on the far side. The pass was already paying its cost: the depth march
  ran every frame and only the write was discarded.

- The graphics profiles are Medium, High and Ultra, renamed from Modest,
  Balanced and Rich. Nothing reads the stored profile name, because the
  picker works out the current profile by comparing values, so no config
  migrates and nobody loses a setting.

- The top profile could never be shown. `matches()` compared the profile's
  `far_distance` of -1, the "whatever the server granted" sentinel, against
  the number the client reports, which is the grant it is tracking, so any
  session with a grant at all read as Custom. A negative target now matches
  any value, the rule `below_hardware` already used for the same sentinel.

- The tiers were measured as live sweeps in two scenes, because neither
  alone can judge them: the vista carries the view and detail distances,
  the village after dark carries the lamp shadows, and a setting a scene
  cannot exercise reads as free. Against the client's own defaults, steady
  state at 2560x1371 and GPU bound in every row: by day High is -3 per
  cent on the median and Medium -24; at night High is -10 and Medium -25,
  with Ultra under the noise floor in both. Floors 1.7 and 3.3 per cent.
  The server granted 512 far nodes, so Ultra and High shared a far
  distance and only Medium's 256 was genuinely smaller.

- Ultra and High are close enough on this hardware to question whether
  they are two tiers, and the reason is the machine rather than the
  profiles. Counted at the same vista, settling each tier from the
  coarsest up so the LOD hysteresis cannot carry fine tiers downward,
  Medium draws 2507 calls and 3.65M primitives, High 2619 and 4.24M,
  Ultra 3066 and 6.41M: Ultra draws 76 per cent more geometry than Medium
  for 24 per cent more frame time, because an RTX 3090 is nowhere near
  geometry limited at this scale. The same sweep at 1600x900 gave a wider
  spread than at 2560x1371, so more pixels shrink the gap and this is not
  a fill rate story, and switching every material and lighting quality
  channel off at Medium bought only a further 10 per cent, so the frame is
  not sitting in those either. Where the rest of the frame goes is not yet
  answered. The percentages are a floor for weaker hardware, not an
  estimate of it.

- The plans ask for a resolution and do not get it. Wayland does not let a
  client resize its own window, so `window_set_size` is ignored, the
  harness notes the mismatch and measures the default window anyway. The
  first pair of tier reports were taken at 1600x900 while asking for
  1920x1080. Forcing it needs `--resolution` at window creation, through a
  wrapper on GODOT_BIN.

- The first version of that plan measured its own ordering rather than the
  tiers. Four tests, a process per variant and one shared warm store: the
  store fills as the plan runs, so each variant began from a fuller world
  than the last, the end-of-plan control repeat came back 45.7 per cent
  from the first control on the steady median and 84.6 on the moving one,
  and every tier result sat under that noise. `docs/benchmark.md` carries
  the rule that came out of it. Load and streaming-ceiling numbers for the
  tiers are therefore not claimed: they need a plan that hands every run an
  identical pre-warmed store, which the harness cannot yet do.
- Material Maker materials as a renderer benchmark (2026-09-18): the
  flatpak's own export is broken, so `tools/mm_export.py` runs it headless
  with a replacement start script and exported 56 sets from the site's
  free materials; 27 dress Mineclonia's main blocks as the `mineclonia_mm`
  pack. They render cleanly, and showed that the parallax depth table is
  small and that parallax never cuts a silhouette; a ramp only silhouette
  cut is in the shader behind a uniform, off. `docs/material-calibration.md`
  has the findings.

## Log since v0.4.0-alpha (2026-08-29)

- The depth fog thins with altitude. It is a layer the terrain wears, not
  a property of distance in empty air, but Godot's depth fog knows only
  the camera-distance ramp, so from any height every slant ray crossed it
  and the whole map drowned in one flat horizon colour (reported from a
  Terrain Diffusion world: "the entire ground turns into this horrible
  distance fog"). Godot's own height fog modulates by the fragment's
  height and the ground is always inside the layer, so it cannot help;
  the density, aerial perspective and the fogged share of the sky now
  scale down by how far the camera stands above the terrain, anchored by
  a new ground_height sample beside ground_albedo and held at its last
  answer during high flight. At ground level nothing changes. Verified
  at 280 nodes up over the test world: the map below reads as an aerial
  view with haze at the horizon, against a uniform wash before.

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
