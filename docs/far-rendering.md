# Plan for long distance rendering

The target is two things at once, and they are usually traded against each
other: a vista that runs to the horizon, and surfaces near the camera that
carry real material detail. Distant Horizons and Voxy do the first for
Minecraft, LabPBR packs and a shader loader do the second, and the reason
they are discussed together is that neither survives the other's absence. A
vista of flat untextured cells is a contour map. Beautiful materials inside a
200 node bubble are a diorama.

This file is the order of work for doing both in Goanna, against unmodified
Luanti servers. It also holds the plan for baked ambient occlusion, because
that turns out to share its data structure with the far terrain and is
cheaper built with it than beside it.

Loading Iris shader packs is a separate plan, in `docs/iris-compat.md`. It
shares this file's licence reasoning, depends on the same block mapping, and
has one hard dependency on this file, set out under "Under a shader pack"
below.

## What we take from Distant Horizons, Voxy and Iris, and what we do not

None can be ported, and the reason is not licence.

Goanna's built binary is already LGPL-3.0-or-later. Goanna's and Luanti's
own terms are both "or later", and mini-gmp is LGPL-3.0-or-later, so the
combination lands there whatever we do. `THIRD-PARTY.md` works this through.
Iris at LGPL-3.0 would combine with that without changing anything.

Distant Horizons is different, and worth stating precisely because it is a
real decision rather than a technicality. It is GPL-3.0, not LGPL. Goanna is
a GDExtension, which is to say a library that someone else's Godot project
links. LGPL is what lets them do that without their own project becoming
copyleft. Linking GPL-3.0 code in would extend GPL-3.0 to the whole combined
work, including games built on Goanna. That is permitted and it is
distributable, and it is a choice about what downstream users may do, so it
is not one to make as a side effect of wanting a feature.

None of which matters much, because there is no code to lift. All three are
Java. Iris drives Minecraft's OpenGL renderer through an OptiFine derived
GLSL pipeline; Distant Horizons and Voxy are coupled to Minecraft's chunk
format, their own storage and their own renderers. Goanna is C++ in a Godot
GDExtension against Godot's Vulkan renderer, with `.gdshader` files. Nothing
survives the trip except the design, and designs are not licensed.

So: independent implementation, and no reading of any of the three codebases
in order to reproduce it. Everything said about them below comes from their
public descriptions and from using them, not from their source.

### Which of the two LOD mods is the model

Voxy, not Distant Horizons, and the difference is worth naming because this
file used to be framed around Distant Horizons.

Distant Horizons stores a column based summary of the world and, to fill
gaps, runs world generation on the client to invent terrain it has never
been sent. Voxy keeps a local database of every section it has received at
full resolution, derives a chain of coarser levels from that, and draws only
what it has seen. It does not generate.

Goanna's boundary rule rejects generation outright (below), so the plan was
already Voxy shaped in principle. Two more Voxy choices are worth adopting
deliberately:

- **The store holds what was received, at full resolution.** Coarser levels
  are derived from it. The store format then does not bake in a tier set, the
  same data serves the near field of ambient occlusion, and staleness can be
  marked against what was actually seen rather than against a summary.
- **A coarse level is drawn only where the finer one is not resident.** That
  single rule is how tier boundaries and the live edge are handled, and it is
  structural where skirts are a patch.

What is not adopted is Voxy's GPU driven renderer: meshing in compute,
indirect multidraw, a separate pass composited by depth. Godot's scene
renderer offers a GDExtension no indirect multidraw, and drawing far terrain
through `RenderingDevice` outside the scene puts it outside the one depth
buffer, the one shader family and the one lighting environment that the rest
of this file depends on. CPU meshing with merged quads into per region
meshes is the right trade here, and it is what rung 3 already is.

## The three problems, which are separable

Treating this as one feature is what makes it look impossible. It is three,
and two of them are useful on their own.

### 1. Data beyond the server's view range

This is the hard one and it is the one the LOD mods actually solve.

Luanti sends mapblocks within a range the client asks for.
`goanna_session.cpp` clamps `wanted_range` to 1 to 255 mapblocks, and the
server caps it again with `max_block_send_distance`, commonly 12 mapblocks,
which is 192 nodes. Asking for more does not get more. A 4000 node vista is
250 mapblocks per axis. No amount of protocol politeness reaches it, and
reaching for it impolitely is out of bounds.

So distant terrain can only come from mapblocks we already received. Today
none are kept: there is no persistence anywhere in `src/`, and blocks unload
with Luanti's own map.

**The store.** A local store holding every mapblock ever received, keyed by
server address and world, at full resolution. Luanti already serialises a
mapblock compactly, the payload arrives from the server compressed, and the
store can keep that payload as it came, so "write on receipt" is close to
free and involves no new format. On ingest, and lazily on read, a chain of
coarser levels is derived: occupancy and representative content per cell at
cell 2, 4, 8 and 16. That chain is what the far tiers draw from and what
the ambient occlusion below traces against, and it is small, roughly a
seventh again on top of the full block.

Size is Voxy sized, not summary sized. A serialised mapblock is typically a
few hundred bytes to a few kilobytes, so a large explored world runs to
hundreds of megabytes, which users of the Minecraft mods accept and which is
the honest cost of keeping what was seen. Cap it per world, oldest out.

An earlier draft proposed keeping only a cell 4 summary. It was smaller and
it fixed the tier set on day one: nothing finer than cell 4 could ever be
drawn from it, and the near field of ambient occlusion could not use it at
all. Full resolution with derived levels costs more disk and buys both.

**The boundary question is settled: the server decides.** `README.md` and
`CONTRIBUTING.md` both state that Goanna must never give a player
information or reach a vanilla player lacks. Reasoning about whether a store
technically passes that test was the wrong approach, because it has Goanna
granting itself the permission. Far rendering is off unless the server
allows it. Then the reach is given, not taken, and a server operator who
does not want it keeps the client at whatever `max_block_send_distance` they
set.

Goanna's own local server turns it on, because there is no fairness question
in a single player world on your own machine, running a server this client
launched. That also makes the whole rung buildable and testable now, against
local worlds, without touching the multiplayer case at all.

The mechanism exists. The protocol has no field for this, so it rides the
`goanna:v1` mod channel: `joinGoannaChannel` and `onModChannelMsg` in
`src/goanna_session.cpp` join, say hello, and parse the `key=value` reply
from `goanna_server_mod` into the session's server options. What does not
exist yet is a consumer: nothing in `src/` reads a `far_rendering` key, so
the grant is received and ignored. That reader is part of rung 5. A server
without the mod says nothing and gets the default, which is off.

Staleness remains, and it is not a fairness problem but an honesty one: the
far view shows what you were sent, whenever you were sent it. A mountain you
mined out still stands until you go back and look. Mark it rather than
pretend otherwise. Because the store holds the full block, a stale region
can be compared against the live block when it arrives and replaced or
faded, rather than guessed at.

Distant Horizons also generates terrain it has never seen, to fill gaps.
Goanna should not. That invents world which does not exist on the server,
and it is exactly the divergence the boundary rule is about.

### 2. Geometry cheap enough to draw

Built, 2026-08-21, inside the range the server sends; see "What landed at
rungs 2 and 3" below for what was observed. The shape of it:

- **The chain.** `src/goanna_lod.h` derives, per mapblock, levels at cell
  2, 4, 8 and 16: which cells are filled, which block light, what is seen
  from each of the six sides, and how lit the air in them is. It is built
  lazily from the block, dropped when the block changes, and is the only
  thing the tier mesher reads. Inside the live range and beyond it the tier
  data has one shape, which is what the store at rung 5 will persist.
- **Tiers.** `lodTierFor` (`goanna_client.cpp`) chooses a tier per block
  from horizontal distance, doubling the threshold per tier, with
  hysteresis so a player standing on a boundary does not rebuild the same
  blocks every step. Tier 1 is `lod_cell` nodes (4 by default), each tier
  doubles it, up to a whole block.
- **Merging.** Blocks at a tier belong to a region of that tier, four to
  sixteen blocks on a side so a region is about 32 cells an axis whatever
  the cell size, and the region is one mesh: coplanar faces with the same
  tile, tint, light and occlusion are merged greedily into quads, one
  surface per array texture. A region is rebuilt when a member block or a
  block next to one changes, coalesced so streaming into it costs one
  rebuild a quarter second rather than one per block, inside a per frame
  time budget.
- **Residency, which replaces seams.** A block is drawn by exactly one tier,
  and a region's mesh culls its faces against every neighbour's occupancy
  at that region's cell size, whatever tier the neighbour is drawn at. A
  live mapblock arriving, or changing tier, leaves its region and the
  region is rebuilt without it. No skirts have been needed so far at the
  join between the live mesh and the first coarse tier; the cells there are
  small and the live mesh hides the join, as it always did.
- **Vertex format.** The region mesh carries exactly what the near mesh
  carries, per `docs/mesh-attributes.md`: tile UV and array layer, tint,
  Luanti's block and sky light, the occlusion term and the block semantic
  ID, and it runs the same node array shader against the same arrays.
- **Depth precision.** Not yet measured: nothing has been drawn further
  than the server sends, which is a few hundred nodes. Godot 4.3 and later
  use reversed Z, which takes most of the far plane problem away. Measure
  at 4000 nodes at rung 5 before reaching for anything clever.

### 3. Shading that is continuous from your feet to the horizon

This is where the current LOD path is furthest from the target, and it is
the cheapest thing on this page to fix.

Far cells today get a `StandardMaterial3D` with albedo from vertex colour,
roughness 1, metallic 0 (`goanna_client.cpp`). That is a flat matte colour
per cell. It cannot produce a distant vista that reads as landscape: no
specular on water, no glint on snow, no difference between stone and grass
beyond hue. `lodColour` is hand-rolling an average texture colour to feed
it, which is what a mip level already is.

The fix is not a far specific look. It is the same shader. A distant
hillside should run the same `nodes_array.gdshader` family against the same
`Texture2DArray`, so sun, sky, fog and tonemap apply identically and there
is no distance at which the world visibly changes rendering. What varies by
tier is only how much is sampled:

- **Albedo**, always, from the array with a mip bias. A distant tile then
  averages itself, correctly, instead of through `lodColour`.
- **`_s`**, always. Smoothness, F0 and emission are what make water, ice,
  snow and lit windows read at distance, and it is one sample.
- **`_n`**, only in the near tiers. At sub-pixel texel size a normal map is
  noise, and it is the expensive one.

This depends on `docs/pbr-plan.md` step 2, the per node material class.
While 80 per cent of nodes carry a flat fallback `_s`, giving the far tiers
the array shader changes almost nothing visible. The order in
`docs/roadmap.md` has materials land first for this reason.

Atmosphere is the other half of it, and is what actually sells a vista. The
horizon in a Distant Horizons screenshot is haze reaching sky colour, not a
draw distance edge. `main.gd` already wires `fog_aerial_perspective` (0.12),
`fog_sky_affect` and a `fog_density` derived from view range. Those numbers
were chosen for a 200 node world and will be wrong by an order of magnitude
at 4000. They want re-deriving against a scattering curve, measured on
`lighting_chart.tscn` with a distance case added, not adjusted by eye.

## Baked ambient occlusion, and why it lives here

Godot's SSAO is on and it is never going to look like baked occlusion. It
sees only what is on screen, so an overhang just out of frame stops darkening
the ground under it as you turn; its radius is a couple of nodes; it swims
as the camera moves. Luanti's own corner term, the one `content_mapblock.cpp`
computes under smooth lighting from the three neighbours of each vertex, is
stable and cheap, and it is also not the same thing: it knows about the
adjacent node and nothing further, so a pit is as dark at the top as at the
bottom and a cave mouth is as bright as open ground.

Real occlusion is an integral over the hemisphere above a point of how much
of it is blocked, out to some radius. In a textured mesh world that needs
a lightmap bake and changes to the world invalidate it, which is why it is
thought of as hard for destructible terrain. In a voxel world it is not
hard, because the occluders are the voxels and the voxels are already in a
grid: the integral is a handful of cone traces through an occupancy
pyramid, and the pyramid is exactly the chain of coarser levels the store
derives in section 1. That is the tie. One data structure, built once,
serves the far tiers and the occlusion.

### The term, in two ranges

Split by radius, because the two halves have different costs, different
invalidation and different sources.

**Near field, radius up to 8 nodes.** Traced against full resolution
occupancy, which the mesher already has: `MeshMakeData`'s vmanip holds the
block and its 26 neighbours. Computed per vertex at mesh time, where the
corner term is computed today, as a hemisphere of a dozen or so cones with a
few steps each. It replaces the corner term rather than adding to it.
Invalidated exactly when the corner term is, by re-meshing the blocks a
changed node touches, which Luanti's lighting update already triggers for
the same neighbourhood. Cost is bounded: tens of lookups per vertex, on the
mesh thread, and it is the part of the bake that is visible up close.

**Far field, radius 8 to about 64 nodes.** Traced against the coarse levels,
cell 4 and up, which is where the store's derived chain comes in. This is
the term that makes a valley floor darker than a ridge, a cave mouth darker
than open ground, and the foot of a cliff read as a foot. It is low
frequency by construction, so it tolerates staleness: one node changing
moves it by almost nothing, and it can be recomputed lazily, a region at a
time, rather than on every edit. It is also the term the far tiers
themselves carry, baked into the per region meshes at build time from the
same chain, so the vista has depth without a screen space pass reaching it.

Both are view independent and both are stable, which is what baked means
here. Neither needs a lightmap, a UV unwrap or an offline step.

### Where it rides

As a per vertex attribute alongside Luanti's block and sky light, in the
channel that `encode_light` in `src/transplant/client/mapblock_mesh.cpp`
writes today and `g_goanna_no_light` currently forces to white. Reviving
that path is already on the critical path in `docs/roadmap.md` for the
`lmcoord` reason in `docs/iris-compat.md`; occlusion is the third value in
the same attribute. The node array shader multiplies it into the ambient
term only, never into direct sun, which is what distinguishes occlusion from
shadow.

SSAO stays on for contact detail at sub node scale, with its radius pulled
in, and SSIL is judged separately; `lighting_chart.tscn` already records
what each contributes and it is the instrument for setting the balance.

### Boundaries and costs

It gives nothing away. Every occluder it reads is a node the server already
sent this client, so it is presentation, not a capability, and needs no
grant. The far field beyond the server's range reads the store, which is
already gated by the far rendering grant and is the same data either way.

It has to stay off collision, like every visual on the list in
`docs/capabilities.md`. It is shading.

Under a shader pack, most packs compute their own occlusion in `composite`
and a few read the vanilla corner term through vertex colour. The term is
exposed to a translated `gbuffers_terrain` as Goanna's extension, not as
something Iris defines, and defaults to multiplying into albedo only when no
pack is loaded. A pack that wants it reads it; a pack that does not is not
double darkened.

### Where it goes in the order

The near field needs only the vertex light path revived, so it belongs with
the lighting and materials work, before the far rendering rungs. The far
field needs the occupancy chain, which is built for rung 3 and persisted at
rung 5, so it lands with rung 3 inside the live range and reaches beyond it
at rung 5. `docs/roadmap.md` has both placed.

## Under a shader pack

`docs/iris-compat.md` translates `gbuffers_terrain` into the node array
shader. If the LOD tiers run that same shader against the same vertex
layout, the translation covers the vista for free. If they do not, a pack
shades the near bubble and leaves the horizon as Godot drew it, which is the
familiar broken look of an LOD mod under a pack that has no programs for it.
Iris had to add separate Distant Horizons programs and a second depth
texture to solve exactly this, because DH draws in its own pass with its own
vertex format.

Goanna avoids both by design, provided rungs 2 and 3 land before the
translator: one shader family, one vertex layout carrying light, occlusion
and block ID, one scene, one depth buffer. That is the dependency
`docs/roadmap.md` records as "far rungs 2 and 3 before Iris rung 5", and it
is the strongest reason not to reorder those two.

## Order of work

Each rung is separately useful, and each is visible on its own, which is how
this avoids becoming a six month branch that never lands.

1. **Client side LabPBR pack loading.** Done, 2026-08-19. It turned out to be
   two bugs rather than a missing feature: `set_texture_path` had exposed
   Luanti's own `texture_path` override all along, but
   `GoannaTextureSource::isKnownSourceImage` had diverged from upstream to ask
   ImageSource to generate the image, which never fails (a missing file yields
   a 1x1 random dummy), and `insertMediaImage` passed `prefer_local = false`,
   which stopped a pack overriding server art. Against a stock Mineclonia
   server with no worldmod, `GOANNA_PACK` now takes companion coverage from
   0/256 to 179/256.
2. **Far shading parity.** Done, 2026-08-21. The coarse tiers run the node
   array shader against the same `Texture2DArray` and its `_n` and `_s`
   companions, on the vertex layout in `docs/mesh-attributes.md`, so there
   is no distance at which the renderer changes. What it buys is bounded by
   `pbr-plan.md` step 2 exactly as predicted: with most nodes on a flat
   fallback `_s`, a far hillside is textured rather than flat coloured, and
   no more than that yet.
3. **Multi-tier LOD geometry**, still inside the server's view range. Done,
   2026-08-21: the derived chain, tiers by distance, greedy merging into per
   region meshes, the residency rule, and the far field occlusion term baked
   into the region meshes from the same tracer as the near field, over a
   field at the tier's cell size. Proven against a local Mineclonia server
   on Godot 4.5.1 without touching persistence; details below.
4. **Atmosphere at long range.** Done, 2026-08-21. Fog density and aerial
   perspective are tied to how far the tiers actually draw, not to the live
   view range: when the server grants far rendering the draw distance is the
   grant (up to `far_distance`), otherwise the view range, and the density
   puts about a sixth extinction at that edge so the horizon fades to sky
   and the mid distance stays clear. Aerial perspective and sky affect rise
   with the distance, so a 512 node horizon reads as haze rather than a hard
   edge. `_apply_sky` in `project/main.gd`.
5. **The store**, gated on the server allowing it, on by default only for
   the local server Goanna launches itself. Full blocks as received, the
   derived chain alongside, a reader for the `far_rendering` grant, and the
   far field occlusion reaching beyond the live range. Only at this rung does
   the view exceed what the server sends, and only at this rung does
   staleness exist. Done, 2026-08-21; see "What landed at rung 5" below.
6. **Water at distance, without a pack.** Done, 2026-08-21. A liquid cell
   in the coarse chain records the height of its surface, and the region
   mesher draws the liquid faces at that height (so a sea lies at sea level,
   not at the top of its cell) on the same water shader as the near mesh,
   keyed by the liquid's own tile. The sea reads as sea at the horizon with
   its waves, specular and fresnel. Reflections proper are a shader pack's
   job (`docs/iris-compat.md`, `gbuffers_water` and the pack's own SSR) and
   are not duplicated here.

7. **Places you have never been.** The store answers "everywhere I have
   walked"; this answers "everywhere the server already has". The server mod
   summarises terrain it has generated, coarsely, on request and at the
   operator's pace, and those summaries become chains like any other. Done,
   2026-08-21; see "What landed at rung 7" below.

Rungs 1 to 7 all landed by 2026-08-21. Rungs 1 to 4 and 6 need no decision
from anyone; rungs 5 and 7 do, and it is the local server that gives it here.

## What landed at rung 5, 2026-08-21

`src/goanna_store.{h,cpp}` is the store. One directory per server under the
root `main.gd` passes in (`user://goanna_store/<host>_<port>`), one file per
16 by 16 by 16 blocks (`r.<x>.<y>.<z>.gbs`): a 64 KB index of offset,
length, time stamp and serialisation version per slot, then the payloads
appended. A block is written as the server serialised it, on the session
thread, as it arrives; a rewrite leaves dead bytes that are folded when they
outweigh the live ones; a cap (512 MB, `GOANNA_STORE_CAP_MB`) evicts whole
region files oldest first. There is no new format for a block, only for the
file around it, and the format is plain enough to read with a hex editor.

The session (`saveBlockToStore`, `loadStoredBlock`, `storedRegionMask`)
writes on receipt, marks blocks edited by `ADDNODE` and `REMOVENODE`, and
writes those back when they are pruned or the session stops, so the store
holds the world as last seen rather than as first sent. `farRenderingGrant`
reads the `far_rendering` and `far_rendering_distance` options the server
mod announced; without them the store still writes (it is the player's own
record of what they were sent, like a screenshot folder, and costs a capped
directory) and nothing reads it.

The client (`lodUpdateFar`, `lodChain`) is the consumer. Every two seconds
or when the player crosses a block, it asks the store which blocks exist
within the lesser of the grant and `far_distance` (512 nodes by default,
`GOANNA_FAR_DISTANCE`), skips the ones the server is sending, assigns the
rest to tiers exactly as received blocks are assigned, and lets go of those
that pass out of range. The region mesher does not know the difference:
`lodChain` builds a block's chain from the live block if there is one and
from the store if not, and frees the stored block as soon as the chain
exists. A live block arriving for a stored one takes over on the next poll.
The far field occlusion reaches beyond the live range the same way, because
the tracer reads chains.

Staleness is marked, not hidden. A chain built from the store sets
`CUSTOM0.a` on its faces to 96 rather than 255 (docs/mesh-attributes.md),
and the node shaders pull such surfaces toward grey by `stale_strength`
(0.6 by default, a material strength channel like the rest), so remembered
terrain reads as remembered.

Measured against the test Mineclonia server, which grants 512 nodes: a 25
second visit to the spawn wrote 331 blocks (688 KB); a second run that went
400 nodes away and looked back found 306 of them in the store, drew them as
tier 3 from the store while the server sent the new surroundings live, with
no errors, and the frame shows the spawn jungle as grey green cells beyond
the live edge. That is the first frame of this client that drew terrain the
server was not sending.

Goanna's own local server grants it: `project/local_server.gd` writes
`goanna_far_rendering = true` and a distance of 1024 into the conf it
launches with, and copies `goanna_server_mod` into the world's `worldmods`
so the grant reaches the client over the channel.

Not done: a settings entry for the far distance and the stale strength (both
are environment variables and bound methods today); the store's contents
are not pruned against a world reset, only aged out by the cap; and the scan
over stored regions is linear in the region count, which is fine at 512
nodes (125 regions) and would want an index at 4000.

## What landed at rung 7, 2026-08-21

The store can only ever show you where you have been, and that is a real
limit on the idea: the first thing anyone tries is looking at a horizon they
have not walked to, and seeing nothing there. Distant Horizons answers that
by generating the terrain locally, which this project rejects outright, and
Voxy does not answer it at all, being client side. The answer that fits the
boundary rule is the server: it already holds the terrain, so let it give
what it chooses to give.

`goanna_server_mod` answers `farsum?` requests. It reads already generated
map through a VoxelManip, never generating any, and replies with 21 bytes
per mapblock, protocol version 2 since 2026-08-22: occludes, lit, liquid, a
4 by 4 grid of surface heights over the block's footprint (one byte each, 0
to 16), the commonest top and side node (as an index into a name list in the
same message), and the light levels. Version 1 sent one height for the whole
block, so a slope summarised as a stepped box; see
`goanna_server_mod/README.md` and the protocol comment above
`GoannaClient::lodTakeSummaries` for what changed and why an old mod and a
new client refuse each other's messages rather than misreading them. An 8 by
8 by 8 block area is about 14 KB on the wire against roughly a megabyte at
full resolution. Requests beyond `goanna_far_rendering_distance` of the
asking player are refused, and the work is paced by
`goanna_far_summary_blocks_per_step` (32 mapblocks a step), so an area costs
a second or two of wall clock and a small slice of each step; the larger
record does not change that bound, since it is still one VoxelManip read per
block.

The client (`lodRequestSummaries`, `lodTakeSummaries` in
`src/goanna_client.cpp`) asks for the nearest area that is not entirely live
and not entirely known already, four in flight, never twice, skipping
anything already fully covered by the live range or the store. A reply
becomes a chain per mapblock at whichever tier's cell is the finest this
client can use at 4 nodes or coarser (cell 4 at the default `lod_cell`),
marked `stored` so it renders with the same staleness treatment, and the
region mesher draws it through the same path as everything else: tiers,
merging, water, occlusion, the fade, and now a real slope instead of a flat
top. No new rendering code at all, which is what the chain was built for.

Measured against a Mineclonia server holding terrain a previous player had
explored: a fresh client with an empty store, a 96 node live range and the
512 node grant drew 1087 blocks of terrain it had never visited, at 139 fps,
with the worst poll at 7.6 ms. Areas the server has not generated come back
as holes and stay holes.

Two limits are worth knowing. A mod channel has no unicast, so replies are
broadcast and filtered by the requester name they carry; the mod README says
what that means for an operator. And a summary carries no data finer than 4
node cells, so distant terrain from this path is coarser than the same
ground would be from the store, which keeps the full block; walking there
replaces it with the real thing.

### Pregeneration, 2026-08-22

A third limit turned up the first time a world was launched from the client:
a summary can only describe terrain that exists, and a server generates only
within the range its client asks for (`max_block_generate_distance` is capped
by the client's wanted range in `clientiface.cpp`, and Goanna asks for 12
blocks). So a fresh world has a 192 node horizon whatever the grant says,
and the player who just created it, the one most likely to look, sees
nothing at all past the live edge.

`goanna_far_pregenerate` is the server's answer, off by default because it
spends mapgen time and map memory on terrain no one has visited. When on,
the mod generates outward from each connected player, one 128 node area at a
time, nearest first, with `goanna_far_pregenerate_interval` seconds between
areas, out to the far rendering distance. An area is emerged a slice at a
time rather than all at once, for the reason the next section gives. Each
finished area is summarised for every client within range without being
asked, because a client that asked while it was still ungenerated was told
there was nothing and does not ask twice. The client needs no change for
this: an unsolicited summary is taken exactly like an answered one. The
local server Goanna launches turns it on (`project/local_server.gd`); a
public operator decides for themselves.

It stays inside the boundary: the server generates its own world on its own
schedule, as it would for a player walking there, and the client never
generates or asks for anything a vanilla client could not.

### Pregeneration yields to the player, 2026-08-22

Pregeneration shipped in the morning and the near field, the blocks around
the player, got worse the same day. The near field is what the client is
for, so this is the more serious half of what pregeneration was added to
fix, and it was traded away without anyone measuring it.

**Why it happened.** An area is 8 by 8 by 8 mapblocks and the mod called
`core.emerge_area` on the whole of it. Lua's emerge sets
`BLOCK_EMERGE_FORCE_QUEUE` (`luanti/src/script/lua_api/l_env.cpp`), which
`EmergeManager::pushBlockEmergeData` reads as "skip every queue limit", so
none of `emergequeue_limit_total`, `_diskonly` or `_generate` applied. Each
emerge thread's queue is a plain `std::queue`, and a player's own block
request goes through `RemoteClient::GetNextBlocks` into the same queue. So
512 mapblocks of terrain nobody had asked for sat in front of the blocks the
player was waiting for, every `goanna_far_pregenerate_interval` seconds.
Logged from inside the mod, one such batch was 0.0 to 3.1 seconds of mapgen
on mineclonia, and the server's `get_server_max_lag` rose from 0.11 to 0.34
while a batch and its summary ran.

Two smaller wastes turned up in the same read. The area search ranked
candidates by horizontal distance only, and the three vertical layers it
searches are all at the same horizontal distance, so the tie always went to
whichever the loop reached first: the layer below the player. Every column
was generated deep stone first and surface last. And a client's own
`farsum?` was appended to the same queue as the summaries pregeneration
offers unasked, up to eight of them, each 512 blocks of `VoxelManip`; worse,
the queue limit that refuses a request counted those offers, so
pregeneration could make the server silently refuse a player's own ask, and
`lodRequestSummaries` does not ask twice.

**What changed**, all in `goanna_server_mod/init.lua`:

- An area is emerged `goanna_far_pregenerate_slice` mapblocks on a side at a
  time, 4 by default, and the next slice starts from the previous one's
  completion callback rather than on a clock. The queue holds 64 blocks
  where it held 512.
- `goanna_far_pregenerate_interval` now paces areas rather than protecting
  the queue, so its default drops from 3 seconds to 1. The slices within an
  area run back to back.
- The area search ranks the player's own vertical layer ahead of the two
  beside it.
- `goanna_far_pregenerate_lag` stops pregeneration when
  `core.get_server_max_lag()` is above it. The default is 0.5 s, five times
  the server step, and the retry is 0.5 s rather than the full interval:
  that number is a running maximum which halves every minute
  (`Server::AsyncRunStep`), not an average, so a threshold near the step
  length reads as "behind" long after one slow step. At 0.2 the mod's own
  summary pass tripped it and pregeneration ran at a third of its rate on a
  server that was fine.
- A client's own `farsum?` is queued ahead of every offered summary, and
  only asked requests count towards the limit that refuses one.

**The numbers.** Godot 4.5.1, mineclonia 0.90 on Luanti 5.16.1, the local
server `project/local_server.gd` starts, on a shared and loaded machine (one
minute load average 1.8 to 5.6 across the runs, three other agents working).
Each run is a brand new world on a fixed map seed, joined through the menu,
28 seconds to settle, then a teleport to (3000, 90, 3000), which no run has
visited, with the camera placed and aimed identically. The far tiers were
drawn throughout, at the client's default `lod_distance`, which matters
because turning them off would also have stopped the summary requests:
`lodRequestSummaries` is called at the end of `lodUpdateFar`, and that
returns early when `m_lod_distance <= 0`. Three or four runs per condition,
interleaved so the load is comparable.

| Condition | +400 blocks after the jump | far blocks at 45 s |
| --- | --- | --- |
| `goanna_far_pregenerate` off | 3.2, 5.3, 3.6 s | 0, 0, 0 |
| on, before | 4.9, 5.7, 5.3 s | 3548, 3551, 3551 |
| on, after | 4.4, 4.4, 3.7, 3.6 s | 3937, 4126, 4127, 4128 |

Far region meshes at the same moment, which is what the far blocks turn
into: 0 with pregeneration off, 69 in all three before runs, 96 then 100,
100, 100 after.

Pregeneration off is the closest thing to the vanilla comparison the user
made: the same server with the mod's pregeneration loop taken out. It cost
1.3 seconds on a 4 second near field fill before, and costs nothing now,
while the horizon fills faster than it did rather than slower. The 45 second
far block count is the client's `render_stats().far_remote`, blocks known
only from summaries.

The variance is real and the machine was busy: the off condition's own three
runs span 3.2 to 5.3 seconds. Read the run means, 4.0 off, 5.3 before, 4.0
after, rather than any single pair. The far block counts are much steadier
because they are paced by the mod rather than by the machine.

**What this does not fix.** `docs/launch-target.md` task 8 still stands: the
client asks for four area layers either side of it and most of what comes
back is sky or interior stone. Ranking the vertical only changes the order,
not the volume. The mod also still offers a summary for an area only when
its own pregeneration made it, so on a real server, where players walking
about generate most of the map, terrain that comes into existence any other
way is never offered to anyone. `core.register_on_generated` is the obvious
answer and is not implemented here; it would want the same discipline as
above, one area at a time, only outside the live send range, and behind the
same lag guard.

### The launch target's four defects, closed 2026-08-22

`docs/launch-target.md` task 2 named four things wrong with the picture
rather than the mechanism, found from screenshots rather than from the
numbers above, and closed them in the order the task set: each one's result
is what the next was judged against.

**2a, the seam.** `lodRequestSummaries` skipped an area whenever its centre,
not its farthest corner, was inside the live range, and skipped it again
whenever any one sampled cell was already known, so a ring straddling the
live edge, or one the player had crossed a corner of, was never asked about.
Both are now farthest-corner and fully-known tests, and the vertical window
widened from one area either side of the player to four, capped rather than
matched to the horizontal radius so a large grant does not turn into a scan
of mostly sky and stone. No mod change was needed for "the ring around spawn
generated by ordinary play": the loosened ask already reaches it, because
`goanna_server_mod` answers `farsum?` for anything generated regardless of
how it got that way.

**2b, the surface.** The record grew from 6 bytes (one height for the whole
block) to 21 (a 4 by 4 grid of them), protocol version 2, and
`lodTakeSummaries` builds the chain at whichever tier's cell is the finest
this client can use at 4 nodes or coarser, rather than always at cell 16, so
the region mesher's existing per-cell height logic (`meshLodRegion`, "Cells
are not cubes" below) draws a slope from a summary exactly as it already did
from a stored block. `goanna_server_mod/README.md` and the protocol comment
above `block_summary` and `lodTakeSummaries` carry the wire format and the
cost per area (14 KB now, was 3 KB).

**2c, the shading.** A merged region quad's UV still repeats once per node,
which is right at the near end of a tier but aliases into a shimmer once the
quad is only a few hundred pixels on screen and no anisotropic filtering is
in the sampler. Past a distance in nodes (64 to 256 by default,
`lod_flatten_near`/`lod_flatten_far` in `nodes_array_common.gdshaderinc` and
`water.gdshader`) the sampled colour blends toward the tile's own average,
the same `getTextureAverageColor` value the no-array fallback material
already used, carried per array layer in a `lod_avg_colour` uniform set only
on LOD materials (`GoannaClient::materialFor`) so the near mesh's shader,
which is the same compiled resource, never engages it. Water at a tier stops
waving (there is nothing at 16 node cells for a per node ripple to be) and
gets the same colour blend. `tools/shotcheck.py --far-band` measures the
result: Laplacian energy in a horizon shot's far band, low for a flat
blended surface, high for an aliased one.

**2d, the horizon.** `m_far_distance` now defaults to whatever the server's
far rendering grant turns out to be (`GoannaClient::lodUpdateFar`), rather
than to a fixed 512 regardless of a larger grant, and an explicit choice
(the settings panel's new "Far draw distance", or `GOANNA_FAR_DISTANCE`)
turns the auto-tracking off. `cam.far` and the fog density, already tied to
the draw distance since rung 4 above, follow the same number and so now
reach as far as the grant does rather than stalling at the old default's
edge. A second new settings entry, "Remembered terrain tint", exposes
`stale_strength` through the existing generic `mat_*` mechanism, no new
plumbing needed. A HUD line reads "Generating distant terrain (N cells so
far)" while `render_stats().far_remote` is still changing, fading a few
seconds after it stops, so a fresh world's first minute or two does not read
as broken. And the purple cells: found by reading `lodTakeSummaries`
alongside `NodeDefManager::get(name)`, which defaults to `CONTENT_UNKNOWN`
when a name will not resolve; the summary path defaulted to `CONTENT_AIR`
instead, so a name this client could not resolve became an invisible hole
rather than Luanti's own magenta and black `unknown_node.png`. Now it
defaults to `CONTENT_UNKNOWN` like the rest of the codebase does, so an
unresolved name is honestly ugly instead of silently absent.

Cost, measured on this machine (Luanti 5.16.1 flatpak, Godot 4.5.1) against
a fresh local Mineclonia world at the default 1024 node grant, through
`tools/test-launch-target.sh`: two minutes after joining, `far_remote` was
6656 blocks across 159 regions and 359 surfaces, 847 draw calls total, the
worst `poll_blocks` call 0.43 ms, and 137 blocks still at full detail near
the player. `docs/requirements.md`'s draw call budget is not threatened by
this; 1024 nodes is the number recorded as affordable on this machine at the
default settings, and it is also, not coincidentally, the number
`project/local_server.gd` has granted since before this task.

### Why distant patches never filled in, 2026-08-22

Reported as terrain that is "only ever partially created": sitting still for
minutes, the shattered plates and the gaps in the distant land never close.
They were not slow. They were permanent, and the cause was on this side.

A summary describes terrain the server has already generated and reports
the rest as ungenerated, which the client drops rather than inventing. That
is right. What was wrong is that the client asked for each area exactly
once. `lodRequestSummaries` recorded every area it had asked about and never
asked again, so an area that was half generated at the moment it was asked
kept that half for the whole session. The only thing that ever corrected one
was the mod pushing an unsolicited summary for an area its own pregeneration
had just finished, which covers the areas it generates and nothing else.

Worse, the blocks that did arrive hid the rest. The request loop skips an
area once its sampled cells are all known, which is the right shortcut for
an area the store already covers. A partly generated area has chains for the
part that exists, so it could pass that test on the strength of the very
blocks that proved it incomplete, and be skipped for ever.

So an ask is now remembered with what came back rather than merely that it
happened: `GoannaClient::FarAsk` holds when the area was last asked and
whether every record in the reply was generated. A complete area is finished
with and never asked again. An incomplete one is asked again once
`kFarRetryMs` (20 seconds) has passed, and the known looking sample no
longer skips it, because an incomplete answer beats a sample that looks
known.

Twenty seconds is chosen so that a server generating steadily is not asked
the same question every second, and a player standing still watches gaps
close rather than waiting out the session. It costs one request per stale
area per twenty seconds, against a queue that already holds at most four in
flight.

Not measured live. The machine was running four agents, five servers and
their clients at the time, and a client launched to watch the retry was
killed out from under the measurement, so what is written here is the
mechanism and the reasoning rather than an observed before and after. The
observation to take is simple and worth taking before this is trusted: stand
still with `GOANNA_DEBUG_LOD=1` and watch whether an area that first reported
few blocks is asked again and reports more.

### Background, overlay, foreground, 2026-08-22

The four defects above were closed and a fresh world still read as broken.
What was left was not a defect in any panel but the absences between and
beyond them: the world was seen ending. A panel that has not arrived is a
hole showing sky through the ground, and the outermost panels stop at a
line, in clear air, with nothing past them.

Correct panels do not add up to a cohesive field, because the eye reads the
gaps as well as the geometry. So the far view is three layers rather than
one, and only the middle layer is terrain:

**Background, always complete.** The sky's lower hemisphere holds a broad
band of the horizon's own colour under the horizon line
(`sky.gdshader`'s `ground_curve`, 3.0, set from `main.gd`), and only darkens
toward the ground colour when the camera looks steeply down, where terrain
is always loaded. Nothing is invented by this: it claims no terrain, it is
air. It costs nothing and it is there from the first frame, which is what
the far field cannot be.

**Overlay, as much as we have.** The tiers, drawn over that background and
revealed through the haze as they arrive.

**Foreground.** The live range.

The layer that joins them is the haze, and the thing that was wrong is what
its distances were tied to. Every one of them followed the distance the
server permits us to draw. The far field reaches only as far as the store
and the summaries have filled, which on a new world is very little and grows
for minutes, so the haze was closing hundreds of nodes past the last panel
and the edge stood in clear air. Measured on a fresh profile against the
test server: `far_blocks` 0, terrain stopping at the live edge of 192 nodes,
fog set to close at the 512 node grant.

So `GoannaClient` reports `far_extent`, recomputed on each far rescan, and
the haze closes there, floored at the live range and capped by the grant.
Where there is nothing to show there is haze rather than an edge, and the
view opens as terrain arrives, which reads as weather clearing rather than
as a world being built.

The first version of that measurement was one ring histogram around the
player, taken at the ninetieth percentile so a straggler across a gap could
not report a horizon that was not there. It was not enough, and the way it
failed is worth keeping. The frontier is ragged: the store and the
summaries fill outward at whatever rate the server generates, so for most
of the time a world is filling, the field reaches several times further one
way than another. One radius describes the directions holding the most
blocks, which are exactly the directions that least need hiding, and leaves
the sparse ones ending in clear air. The haze looked right when the field
happened to be even and wrong the rest of the time, which is how it was
reported: it looks great when it works, and it does not work all that
often.

It is now measured per direction: eight sectors, each with its own ring
histogram and its own ninetieth percentile, and the extent is the lower
quartile across the sectors that hold anything, so it says how far you can
see in a poor direction rather than a good one. Sectors holding nothing are
skipped, since the live range floor already covers them. Measured at the
same spot on the same world, the old figure was 512 nodes and the new one
240, which is the size of the raggedness rather than a change of policy.

The curve was opened up with it, since the same complaint was that there
was too little haze: `fog_clear_fraction` 0.5 to 0.3 and `fog_curve` 3.0 to
1.6, so the haze begins nearer and builds steadily instead of holding off
and then closing hard over the last fifth.

The fog is a depth curve rather than exponential. An exponential cannot be
both clear in the foreground and closed at the edge: the density that hides
the far edge puts most of its extinction on the mid ground and lays a veil
over everything, which is what the first attempt did. Depth fog takes a
begin, an end and a curve, so it is clear to half the extent, closes over
the last part and is complete at the edge (`fog_clear_fraction` 0.5 and
`fog_curve` 3.0 in `main.gd`, swept with `GOANNA_FOG_CLEAR` and
`GOANNA_FOG_CURVE`). Under water the fog stays exponential, because that
murk is a property of the water and starts at the eye.

Measured on the pregenerated world at a 1024 node grant: 4898 far blocks,
`far_extent` 512, haze from 256 to 512, and the far edge dissolving with no
boundary visible in the frame.

What this does not fix, and does not pretend to: the panels are still
blocky, they still take minutes to fill, and their side faces still read
darker than their tops at a low sun. The background makes those less
visible rather than untrue. `docs/launch-target.md` R1 and R3 hold the rest.

### Unknown is not air, 2026-08-22

Screenshots of a world mid pregeneration showed free standing vertical
slabs of terrain out in the far field, and one pitch black mass standing
above the horizon with holes in it. Both are the same fault, and it is a
one line reading of a flag the mesher already had.

`LodLevel::kKnown` marks a cell that contains at least one node which is
not `CONTENT_IGNORE`, so it separates "air" from "never seen". It was set
faithfully everywhere, by `buildLodChain` and by the summary reader, and
then never read. `meshLodRegion` asked only whether the neighbouring cell
was filled, and a cell we know nothing about answers no, exactly as air
does. So every filled cell along the frontier of what the store and the
summaries had filled grew a side face, and the frontier is a plane: a wall.
Where the cells behind that wall were underground, their light is zero and
their faces are the interior of the ground, so the wall was black.

A side face is now drawn only against a neighbour we know to be empty.
Nothing is drawn at the frontier instead, which is the honest answer and
the same rule as never inventing terrain: we do not know that surface is
there. The haze closes at that frontier anyway, so what is left is air
rather than a hole.

Top and bottom faces keep the old rule deliberately. The block above a
surface is often one we have never been sent, and applying this there
would take the ground's own top face away, which would make the far field
invisible from above rather than merely walled.

That held for the rest of the day and then stopped holding. Once a summary
marked its own air as air, a cell could carry its own top face without asking
the cell above, and the exception's only remaining effect was a lid over every
solid column at a mapgen chunk boundary. See "Lids, layers and the vertical
walk" below for the narrower rule that replaced it.

The trade this makes, stated plainly: a block missing from the middle of
otherwise known terrain now shows a gap where it used to show a wall. A
gap in the haze is the better of the two, and the walls were never true,
but neither is right and the answer to both is the vertical extent work in
`docs/launch-target.md` task 8, which stops asking for the areas that
produce them.

Measured against the pregenerated world at a 1024 node grant, 3034 far
blocks and `far_extent` 800: no free standing slabs and no black masses in
frame, and the far field still draws from above.

### One light, from your feet to the horizon, 2026-08-22

This is the open half of R1 in `docs/launch-target.md`, and the reading it
opened with was wrong, so the record starts with what the instrument said
rather than with the fix.

**There is no baked hour, and there never was.** The task was framed on
`goanna_lod.cpp` taking a face's light from a cell's stored `day` and
`night`, so a far tier would carry whatever the light was when that data was
made. It does not. `LIGHTBANK_DAY` is Luanti's sunlight propagation, a
visibility term that says how much of the sky reaches a node, and it does not
move with the clock; the vanilla client blends it against the night bank by
the day/night ratio at draw time, and Goanna does the same job in the shader
with `goanna_sky_fill` and the sky radiance, which `main.gd`'s `_apply_sky`
sets from the time of day. Both meshers store exactly that same value, the
near one per vertex in `goanna_light.cpp`, the far one per cell in
`goanna_lod.cpp`, and the shader is the same shader. Measured, on one running
client through the control channel: the `CUSTOM0` bytes read straight off the
live meshes were identical at time 0.5, 0.25 and 0.0, to the sampled vertex,
while the frame changed from noon to midnight. So there was nothing to fix in
the mesher's idea of time, and any fix that had moved the stored value would
have been moving the wrong number.

**What the same instrument did find is two populations where the world has
one surface.** Reading `CUSTOM0.g` off every mesh under the client and
splitting it by whether the material has `lod_flatten` set, which is what
separates a far tier from the near mesh, on a fresh Mineclonia world at a
1024 node grant with about 9000 far blocks resident:

| | near mesh | far tiers |
| --- | --- | --- |
| share of sampled vertices at 255 | 96.4 per cent | 42.6 per cent |
| share at 238 | 0.2 per cent | 40.9 per cent |
| mean | 247.8 | 229.5 |

238 is `quant16(decode_light(14))`. `GoannaClient::lodTakeSummaries` clamped
the wire's raw light level to `LIGHT_MAX`, 14, before decoding it, and an
open sky column on the wire carries `LIGHT_SUN`, 15. So two fifths of the far
field was reading 234 of 255 sky visibility where the same open ground reads
255 the moment it comes inside the live range, and that 7 per cent went
straight into the sky fill and the sky ambient. `LIGHT_MAX` is the cap for a
light source, not for sunlight, and `decode_light` clamps to `LIGHT_SUN`
itself, so the clamp is gone.

**The louder fault was the same defect seen from the geometry side.** A
summary block wrote a cell only where its heightfield said something was
there, and left every cell above the surface at the default flags, which is
`kKnown` clear: never seen. "Unknown is not air" above then culled every side
face against them, so a summarised hillside drew one cell of skirt at a step
of any height and nothing under it. The far field came out as floating tops
with daylight through them, which no amount of shading was going to rescue.
A generated block's air is air, and `lodTakeSummaries` now says so, marking
those cells known, and lit with the block's light where the record reports
any. It also puts a summary top face's light back on the same footing as the
live mesher's, taking it from the air in front of the face rather than
falling through to the block's own average.

That costs what the missing faces were saving. On the same world and pose,
`lod_quads` per far block went from 2.9 to 4.6, a 59 per cent increase, and
the far mesher's own moving average, `lod_ms`, from 0.68 to 0.85 ms per poll.
That is the price of the cliffs and it is not optional: they are the terrain.

Judged in the frame from 180 nodes up looking down at a ridge 260 nodes out,
at midnight so the sky fill is doing the work: before, the ridge is a spray
of separate tops with night sky visible between and under them, and it reads
as confetti rather than as a hill. After, it is one landscape with cliff
faces, and the near ground at the bottom of the frame runs into it with no
step at the join.

**One change was made, measured and taken out again.** The mesher's fallback
for a face it has no light for is `day = 255`, full sky exposure, and the
obvious reading is that it should be 0 for a face buried in solid ground, the
way `BlockLightField::sample` answers for the near mesh when every neighbour
is solid. Answering 0 whenever the cell in front is known and unlit put 53
per cent of far vertices at sky light 0, against 4 per cent before it, and
painted black patches across the far field in the very next frame captured.
The reason is that the
far mesher never draws a buried face: a top face needs an unfilled cell in
front of it, a side face needs a shorter one, so the case that branch was
written for does not arise, and what it caught instead was air cells with no
light record. `docs/mesh-attributes.md`'s neutral of 255, "a missing
attribute should look unremarkable", is right and stays.

**Measured after, same world, same viewpoint, same three times**: far
vertices at 255 went from 42.6 per cent to 74.2 per cent and the 238
population fell from 40.9 per cent to 3.2 per cent, which is the level 14
light that is really there under a tree edge rather than a clamp. Far mean
sky visibility 229.5 to 232.9 against a near mesh whose own mode is 255 in
both runs. `shotcheck.py --launch-target` continuity across the live/far
boundary, at time 0.5, 0.25 and 0.0, before and after:

| time | luminance diff before | after | chroma before | after |
| --- | --- | --- | --- | --- |
| 0.5 | 0.68 | 0.58 | 0.10 | 0.03 |
| 0.25 | 0.22 | 1.30 | 0.28 | 0.29 |
| 0.0 | 3.69 | 0.61 | 1.15 | 0.28 |

Midnight is where it shows, and that is the expected shape: the sky fill is
most of the light at night, it is scaled by exactly this channel, and the sun
swamps a 7 per cent difference at noon. The 0.25 row moving the wrong way by
one luminance unit is noise; R4 measured the same-tier floor at 0.35 to 4.93
luminance, so every number in that table except the 3.69 is inside it. Every
one of the six runs passed the harness thresholds, before and after: the
check was never failing, which is why the vertex bytes rather than the frames
are what found this.

`tools/test-launch-target.sh` itself, unmodified, on a fresh profile and a
fresh world: passes. Two earlier attempts failed, both on the close shot's
`normal map response` (detail 3.72 and 3.24 against a floor of 5.0), and
neither is this change: the harness poses that shot 1.2 nodes above the
ground looking 31 degrees down at a point two nodes ahead, so when the
settled camera stays exactly where it was put, a single node face fills the
whole frame and there is no detail in it to measure. The passing runs are the
ones where the spawn put something further away in front of the camera, or
where the camera drifted during the settle. That is a fragility in the pose
rather than in what it is looking at, and it is worth a fixed distance from
the surface rather than a fixed distance from the player.

**Measured and deliberately left alone.** Each of the far tiers' own shading
terms was swept on a running client by setting its uniform on every material
with `lod_flatten`, camera not moved between shots, and read as the change in
mean luminance of the far band. Two shots of the same settings a minute apart
drift by 0.90 at midnight and 0.15 at noon while the world streams, so that
is the floor these sit against:

| term set to 0 on the far tiers | far band at midnight | at noon |
| --- | --- | --- |
| `block_light_emission` | +0.04 | -0.03 |
| `sky_light_strength` | +0.25 | +0.10 |
| `vertex_ao_strength` | +1.07 | +1.40 |
| `sky_fill_strength` | -5.94 | -3.55 |

`block_light_emission` is 1.0 on LOD materials and 0 on the near mesh, which
makes it a per tier term by construction: a far tier adds Luanti's block
light as unshaded emission, being past the reach of the node light pool the
near mesh uses instead. On this world it does not reach the frame at all, at
either time, and it is recorded here rather than changed. `sky_fill` is the
loudest term in the far band and it is not per tier: it is the same
`goanna_sky_fill` the near mesh takes, which is exactly why the sky light
channel it is scaled by had to be right.

The one that is still open and is worth a number: the far tiers' own traced
occlusion is much heavier than the near field's, `CUSTOM0.b` mean 113 against
205 on the same world and frame. The far tracer runs at `6 * cell` nodes of
radius, up to 64, against a field where a cell is filled if half a layer of
it is, so a hillside occludes a great deal more of the hemisphere than the
same hillside does node by node. Occlusion multiplies ambient only, so the
frame cost is the one to one and a half luminance units in the table above,
which is the largest remaining per tier term in this channel and still a
small one. It wants calibrating on `lighting_chart.tscn` against the near
tracer rather than adjusting by eye, which is what `docs/pbr-plan.md` step 3
says about all of these.

Two notes for whoever measures here next. The harness's horizon pose puts the
camera 150 nodes above the player looking out at a shallow angle, which at a
sea level spawn lands most of the far field in the thickest part of the haze:
the frames are nearly all fog and the continuity bands read fog against fog.
A steeper look down is what shows the far tiers. And the first person body
(`GoannaClient::m_show_body`, on by default) draws the player's own model,
which in fly mode sits at the camera and can fill a third of the frame at the
harness pose; `EntityRenderer` sets its visibility every frame, so hiding the
node does not hold and `client.set_show_body(false)` is what works.
### Stipple and close tiling, closed 2026-08-22

Two more defects, both found in screenshots of a world mid pregeneration
rather than in the numbers: the arrival dither reading as a permanent
stipple, and a far tier panel tiling into a regular pattern close to the
camera.

**Stipple.** `GoannaClient::startFade` opens every fresh region's mesh
through the interleaved gradient noise dither in the node shaders over a
third of a second (`advanceFades`), which reads well for one region
appearing at a time. While a world pregenerates, hundreds of regions arrive
at once, so a large fraction of the far field was mid fade at any instant
and the whole distance read as a dotted, flickering texture rather than as
terrain, which is what the user described as two different textures
alternating.

A region well inside the haze is already mostly hidden by fog, so
dithering it in over a third of a second buys nothing visible.
`lodBuildRegion` now skips the fade for a fresh region whose horizontal
distance from the camera is past three tenths of `far_extent`, the same
fraction `main.gd`'s `fog_clear_fraction` uses to begin closing the haze
(mirrored here rather than plumbed through, since only the shape of the
cutoff matters, and `far_extent` is already the per direction lower
quartile rather than one radius, so this follows the same ragged frontier
the haze itself follows). A region past that line pops under the haze
instead of fading; close to the camera, where a pop would read as a wall
of terrain, the fade still runs exactly as before. This was chosen over a
shorter fade or a randomised dither because it removes the wasted case
outright rather than shrinking it: a region nobody can really see fading
in is not worth spending a third of a second dithering, whatever the
dither looks like or how long it runs.

Measured on a fresh, actively pregenerating local Mineclonia world (a
scratch `XDG_DATA_HOME` profile, Luanti 5.16.1 flatpak, Godot 4.5.1), with
a temporary counter added for the measurement and removed afterward: over
a fifteen second window from a fresh connection, the unmodified code
started a fade on every one of 68 newly created regions; with the fix, 46
of 85 started a fade, the remaining 39 popping under haze instead. The
existing pop metric (`tools/shotcheck.py --launch-target`, run through
`tools/test-launch-target.sh`) still reads 0.0 across eleven frame pairs
on this machine, unchanged from before this landed. That is expected
rather than evidence either way: the metric watches one fixed camera cone
(`docs/launch-target.md` R4's own finding), this fix specifically removes
fades outside whatever cone happens to be in frame at the time, and it
must not regress the metric, which it does not. The fade count comparison
above is what actually exercises the change.

**Close tiling.** A far tier quad is one greedy merged face from
`meshLodRegion`, and its UV repeats the tile once per node
(`src/goanna_lod.cpp`'s `uv` switch). `lod_flatten` blends the sampled
colour toward the tile's average between `lod_flatten_near` and
`lod_flatten_far` nodes of camera distance, which handles a quad seen from
far away. It did nothing for a panel drawn close to the camera, which
happens wherever the server has not streamed a block but the store or a
summary has: the panel is still a single wide merged quad, so the tile
visibly repeats at point blank range, and screenshots showed a wall of
regular rectangles a few nodes from the eye.

The merge loop in `meshLodRegion` already knows how wide each quad it
builds is, in the same node units the UV switch repeats the tile in (`w`
and `h`, cell units, times `cell`). `LodRegionMesh` now carries the widest
span seen while building a region, `max_span`, and
`GoannaClient::lodBuildRegion` hands it to that region's `MeshInstance3D`
as a new instance uniform, `lod_repeat`. The node shaders' flatten now
fires on either how far away a fragment is or how wide the quad it sits on
actually is: `smoothstep(lod_flatten_near, lod_flatten_far,
length(VERTEX))` for distance, `smoothstep(lod_repeat_near,
lod_repeat_far, lod_repeat)` for size, combined with `max`. The size test
gets its own thresholds, 16 to 64 nodes rather than the distance test's 64
to 256, because a merge only a few tens of nodes across already reads as
a repeat once it fills much of a close view, well inside where the
distance test would ever fire on its own; a small quad still only
flattens at range, as before.

Flattening the colour was not enough on its own. Auto bump
(`docs/pbr-plan.md`) infers a normal map from the diffuse texture at 0.35
strength by default, on every material, with no resource pack needed, and
a strongly patterned diffuse tile infers a matching relief: a fully
flattened albedo still shaded like the tile pattern under the sun, bumps
and all, because the normal map sample was untouched by any of this. The
same `flatten` value now also blends the sampled relief and the pack's
baked occlusion toward neutral (`normal_strength * (1.0 - flatten)`,
`ao_strength * (1.0 - flatten)`), so a flattened panel reads as flat under
lighting as well as in colour, in both node array shaders.

Measured on a merged far tier quad, camera posed away from the player so
the panel stayed LOD rather than streaming live, close and at an oblique
angle (a stress case chosen to show the defect, not the ordinary horizon
shot 2c above was judged against): with no size based flattening at all,
`tools/shotcheck.py --far-band` on the shot read 29.65 to 30.92 across
three separate readings, comfortably above the 9.0 the harness wants; with
the size test engaged, sharing the distance thresholds and touching
colour only, it read 22.53 in the same session against the same
underlying mesh, a genuine drop that proves the mechanism. The
independent, tighter thresholds and the normal map fade above are a
further refinement of the same mechanism, reasoned through rather than
measured against that exact figure: this machine's clients crashed or
hung repeatedly partway through the follow up runs needed to confirm it
(silent, no crash log, the same shape of fault `docs/launch-target.md`'s
R4 section already records on this machine under concurrent load), and
the one merged quad this session could reach repeatably turned out to sit
on a terraced, banded rock formation whose own stepped geometry, not its
texture, dominates `--far-band`'s reading there; a flat panel was needed
to isolate tiling from geometry and this session did not hold one still
long enough for a second controlled reading before the client went again.
What did land cleanly: the mechanism proof above, and
`test-launch-target.sh`'s own horizon shot, at the ordinary range 2c was
judged against, still reads 0.67 on `--far-band`, unchanged and well under
9.0, so the far range case this extends is not regressed by any of it.

### Lids, layers and the vertical walk, 2026-08-22

Three complaints from one afternoon's screenshots: panels floating in the sky
over savanna, a large magenta mass over desert, and distant panels still not
joined to each other. Two of them share a cause, and the third was never the
far field at all.

**The magenta was not this.** The summary reader defaults an unresolved name
to `CONTENT_UNKNOWN` on purpose, so a name this client cannot resolve draws as
`unknown_node.png` rather than as an invisible hole, and that made it the
obvious suspect. It is not the culprit. `lodTakeSummaries` now counts the
names in each reply it cannot resolve and reports them under
`GOANNA_DEBUG_LOD`; over roughly two hundred replies on a Mineclonia world,
including an unexplored area at (3000, 90, 3000) reached by teleport, the
count was zero in every reply. No magenta appeared in any far field frame
taken here. The mass in those screenshots sits at the camera and is the first
person body model, not a summary. The counter stays, because it is the
instrument that settles the question in one line next time.

**Panels in the sky are lids, and a mapgen chunk is where they form.** The
region mesher drew a top or bottom face wherever the cell beyond was not
filled, and treated a cell it knows nothing about as not filled. That was
deliberate ("Unknown is not air", above): the block above a surface is often
one nobody has sent, and culling there would take the ground's own top face
away and leave the far field invisible from above.

The cost of that exception is a lid. A column of solid rock that reaches the
top of its block, with the block above unknown, grows a top face across the
whole column, and the greedy mesher merges those into one region sized quad.
Luanti generates in chunks five blocks tall while a summary area is eight, so
a generated chunk under an ungenerated one is the ordinary case, not a corner
case: the result is a flat plate at the chunk boundary, hanging in clear air
with no terrain under it, exactly the shape reported.

The exception is now narrowed rather than removed, and what makes that safe is
a change made earlier the same day: a generated summary block marks the air
above its surface as air, so an ordinary hillside carries its own top face
inside its own cells. A cell whose content stops part way up is known from
that cell alone and keeps its top face whatever is above it. Only a cell
filled right to its ceiling leans on the cell above, and a bottom face always
leans on the cell below, because the chain fills a cell from its floor. Those
two are now culled against an unknown neighbour like the sides. The far field
still draws from above, which is what the exception existed to protect.

**Nine vertical layers, of which at most two hold anything.**
`lodRequestSummaries` asked for a fixed window of area layers, four either
side of the player, each 128 nodes tall and 512 blocks in it. Of the nine, one
or two hold the surface. The rest are sky the server has not generated, which
never comes back complete and so is asked again at every retry for the whole
session, and solid rock, which does come back complete and answers with 512
buried blocks nobody can ever see.

Measured on the client's own request log, standing on a pregenerating
Mineclonia server at a 1024 node grant: of 91 areas asked in the first 150
seconds, **three** were in the layer the player was standing in. The other 88
were sky between 256 and 768 nodes up, or rock between 256 and 512 nodes down,
and the same handful were asked over and over as their retries came due. A
longer run of the same build put 3 of 237 in the player's layer, so the ratio
gets worse the longer you stand there, not better. That is why the horizontal
frontier stood still while a player watched, and it is most of "still not
contiguous": the summaries were not slow, the requests were going somewhere
else.

The window is now a bound on a walk rather than a window. The layer the player
is in is always eligible. A layer above becomes eligible only once the layer
below it has answered that terrain reaches its top face, and a layer below
only once the layer above it has answered that its floor is not solid
everywhere. Both flags fall out of the heights already in the reply, and a
layer that is all rock along its floor is neither, so the walk stops at the
ground rather than tunnelling to bedrock. The vertical offset also joins the
distance the request loop sorts on, as a tie break, because the loop order was
choosing for us and it chose the deepest layer of each column first.

A block the server has not generated is not known to be solid, so it does not
close the walk downward. Without that guard a player flying above a column the
server had never made would get an ungenerated answer for their own layer and
never ask about the ground under it. Upward asks for evidence instead, terrain
reaching the top face, because nothing is the usual answer up there and taking
it as a reason to climb is the scan this replaces.

After, same server, same grant, same 150 seconds, same 91 areas asked: 71 were
the player's own layer, 7 the one below, 13 above. From 3 per cent useful to 78
per cent.

**One tier at every distance.** `lodTakeSummaries` built one chain level, the
4 node one, and assigned every summarised block to the tier that uses it, at
any distance. A region reads its own tier's cell size out of a block's chain,
and a chain holding one level answers "nothing known" at every other, so a
coarse region beside summarised terrain culled its whole boundary against it
and the two never joined. Every level from 4 nodes up is now built from the
same 4 by 4 heights, and a summarised block takes the tier its distance calls
for, the same as a stored one.

Both builds run against the same world from the same fresh connection, 150
seconds in, same camera at (3000, 130, 3000), same time of day override, same
`show_body 0`, Mineclonia on Luanti 5.16.1, Godot 4.5.1, a 1024 node grant
with pregeneration on:

| | Before | After |
| --- | --- | --- |
| Far blocks | 23176 | 34845 |
| Far blocks at tier 1, 2, 3 | 23185, 0, 0 | 2007, 9395, 23452 |
| Far regions | 451 | 187 |
| Draw calls | 731 | 381 |
| Cell faces before merging | 191049 | 84454 |
| Primitives | 203509 | 154895 |
| `far_extent` | 832 | 944 |

Half again as much far terrain, reaching further, in a quarter of the cell
faces and half the draw calls. The blocks that went were buried and the ones
that came are surface, and drawing them at the tier their distance calls for
is where the rest of the saving is.

Looking north at a shallow angle, the before frame is one island of terrain
around the player with a single panel hanging in clear air off to the left and
nothing else out of the fog; the after frame is a continuous landscape to the
horizon. Looking down from 260 nodes, the before frame has a void across the
whole centre with two fragments floating in it, and two disconnected patches at
the bottom corners; the after frame has terrain across the lower half with no
void.

What this does not fix. Small fragments still hang over the far field, a few
cells each, where a treetop or a snow drift sits in a block whose neighbours
have not arrived; they close as the field fills rather than staying. The
vertical walk needs one round trip per layer, so a player who flies a long way
straight up waits a layer at a time for the ground to reappear. And a
partially generated area is still asked again every twenty seconds for as long
as it is in range, which is right when a server is generating and pure cost
when it has stopped.

## Cells are not cubes

A coarse cell used to draw as a full cube, so at cell 16 a hill snapped to
16 node steps and the vista read as a stack of boxes. Every cell in the chain
records the height its content reaches, and the region mesher now uses it:
a top face sits at that height, and a side face spans from the height the
neighbour reaches to the height this cell reaches, which is nothing where
the neighbour is as tall, a step where it is shorter, and the whole cell
where it is empty. Terrain at any tier follows its own surface with one node
of vertical resolution while keeping the horizontal cell size.

A partial height side face cannot merge with one in the row above (each sits
at its own height inside its own cell), so the face key carries its row and
only full height faces merge freely, which is the common case underground
and inside hills.

## How terrain arrives, and what it cost to make that smooth

The first build of the tiers arrived in walls: a region mesh appeared whole,
and the frame stalled while it was made. Two things caused that, both
measured with the worst `poll_blocks` call per second that `render_stats`
now reports as `poll_max_ms` (the `GOANNA_PERF` line prints it).

A region build used to build every block chain it touched, in the same
poll. A tier 3 region reads its 16 by 16 by 16 member blocks and a margin
of four more each side for the occlusion radius, nearly fourteen thousand
blocks at 0.3 ms each live or 0.5 ms from the store: seconds in one frame
when a far area first came into range. Chains are now built from a queue,
a few per poll inside a time budget; a region builds with the chains that
exist, asks for the ones it lacks, and is dirtied again only when one of
those is actually built. Blocks with no source at all, neither live nor
stored, are remembered as missing so a region touching one does not rebuild
every quarter second for nothing, which the first draft of the queue did:
`dirty` never reached zero.

The near mesh had the same shape of problem without any store: `poll_blocks`
took up to 24 blocks a call, at about 5 ms each meshed and uploaded, so the
arrival of a new area was a 120 ms frame. It now stops at 6 ms
(`GOANNA_POLL_MS` to change it) and requeues the rest for the next frame,
and the region work takes what is left of that budget.

Regions were also halved for the near tiers: a region is now its cell size
in blocks (4 blocks at cell 4, 16 at cell 16), so tier 1 arrives in 64 node
pieces and a coarse tier still covers a lot of ground per draw call.

And a mesh that has just appeared fades in rather than popping: the node
shaders carry a per instance `fade` that a fresh MeshInstance opens from 0
to 1 over a third of a second, through an interleaved gradient noise dither
(opaque geometry cannot blend). `GoannaClient::startFade` and `advanceFades`.
A rebuild of an existing mesh does not fade, or a dug node would flicker its
whole block.

Measured against the test server with the store holding the spawn area and
the camera 400 nodes away: the worst poll per second is 7 to 10 ms while an
area streams, 0 to 1.4 ms at rest, and 126 ms once when the first materials
and texture arrays are built; the one large figure left is content
preparation itself (node visuals, the classifier, the first array textures)
at 1.2 to 1.9 s, which happens before anything is drawn. Region meshing
itself is still on the main thread at 0.3 to 1.3 ms a region, inside the
budget; moving it to a worker is the next step if a finer budget is wanted.

## What landed at rungs 2 and 3, 2026-08-21

`src/goanna_lod.{h,cpp}` holds the chain and the region mesher, free of
Godot and of the session so the store can feed it later and so it can be
tested offline. `GoannaClient` (`lodAssign`, `lodBuildRegion`, `lodRebuild`
in `src/goanna_client.cpp`) keeps the membership, the dirty set and the
region meshes, and converts the output to surfaces. The single tier,
single block mesher it replaces (`meshBlockLod`) is gone.

Measured against a local Mineclonia server, Luanti 5.16.1, Godot 4.5.1,
from one fixed viewpoint 55 nodes above a jungle, view range 12: full detail
drew 234 blocks in 3,454 draw calls at 287 fps; with tiers starting two
blocks out, 15 blocks stayed at full detail and 220 were drawn at tiers 1 to
3 in 10 region meshes, 31 surfaces, 306 draw calls, 377 fps. A region build
costs about 1 to 2 ms at any tier. The two frames are from two runs of the
same player at the same view, so the streamed set differs slightly; the
draw call ratio is the result, the frame rate is indicative.

Three things were wrong on the first run, and each is worth keeping:

- **Every cell was drawn inside out.** The old mesher's quads were wound
  counter clockwise, which Godot culls as back faces, so what rendered was
  the underside of every cell seen through its missing top. Flat colour and
  fog had hidden it for as long as that mesher existed; the array shader
  showed it at once as a world of slate grey undersides lit only by sky.
  Painting the light channels as emission (`debug_nodelight`) is what told
  the two apart: the channels were right, the geometry was not.
- **A cell with anything in it drew as a full cube.** At cell 16 a single
  leaf made a cliff, and a jungle canopy became a wall of cubes. A cell now
  draws when half a layer's worth of nodes fills it, which keeps a floor, a
  canopy and a two by two trunk and drops a post and a stray branch, and it
  blocks light when a full layer does. Both thresholds are named constants
  in `buildLodChain` waiting to be calibrated on the chart, as this file
  already asked.
- **Leaves did not count.** Luanti classes leaves and glass as
  `solidness` 0 with `visual_solidness` 1, and the first chain used
  `solidness` alone, as the old mesher and the near field occlusion do. A
  forest at range is its canopy, and without it the jungle meshed as the
  log tops the trunks had been standing on. What draws is now solid, or
  cube shaped, or liquid; what blocks light is still solid alone.

And one limit, which is the reason rung 5 exists and was worth seeing
plainly: the server sends only the blocks it has generated, within the view
cone the client reports, so from a height the far tiers show holes where no
block was ever sent, and a view turned away from the reported look direction
shows nothing at all. The tiers draw what was received. Making the vista
continuous is the store's job, not the mesher's.

Not done here: the fill and occlusion thresholds have not been calibrated
against a brute force count; the far field occlusion is visibly weak on the
jungle floor and the reason is not yet separated between the thresholds, the
radius and the terrain; animated tiles (water, lava) have no array texture
and fall back to a flat average colour per face, which is what rung 6 is for.

## Where this is most likely to fail

- **Rung 5 is the only route to a real vista.** Everything below it is
  cosmetic improvement inside a range the server chose. Measured on a local
  Mineclonia world: the server default `max_block_send_distance` of 12
  mapblocks is 192 nodes, and raising it to 32 gives 512. The LOD mods draw
  thousands. Raising the send distance costs the server linearly and runs
  out long before it reaches that, which is exactly why the store exists and
  why nothing short of it produces the target image.
- **Staleness has no good answer**, only honest ones. Fading distant terrain,
  or tinting it, or dropping it when contradicted. Holding the full block
  makes "contradicted" checkable; it does not make it pretty.
- **The store is the engineering, not the rendering.** 250 mapblocks per axis
  of blocks and their derived chains, written on a session thread, read on
  approach, evicted on a cap.
- **Draw call budget.** The existing LOD path wins by merging to one
  material. Several tiers must not quietly undo that. Measure against
  `docs/requirements.md`'s table every rung.
- **The far field occlusion can over darken.** Cone tracing against coarse
  occupancy reads a half filled cell as half solid, which is right on
  average and wrong on any given face. Calibrate it on `lighting_chart.tscn`
  against a brute force ray count before trusting the look, and clamp it
  where the near field already has the answer.

## Instruments

Per this repository's habit of building the instrument before trusting the
result:

- `lighting_chart.tscn` wants a distance case, so fog and aerial perspective
  are read off numbers rather than impressions, and an occlusion case: a pit,
  an overhang and a cave mouth, with the brute force hemisphere integral
  printed beside what the cone trace produced.
- `tools/shotcheck.py` for viewpoint repeatability, which matters more here
  than anywhere else, because a vista shot before terrain streams in is a
  photograph of fog.
- A per tier readout, so rung 3 cannot regress rung 2 silently: `render_stats`
  reports blocks per tier, region meshes, quads before and after merging,
  surfaces and the build time, and `GOANNA_PERF=1` prints them each second.
  `GOANNA_DEBUG_LOD=1` prints every region build with its surfaces, which is
  what says whether a tier landed on the array shader or the flat fallback.
