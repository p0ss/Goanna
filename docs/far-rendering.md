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
areas, out to the far rendering distance. Each finished area is summarised
for every client within range without being asked, because a client that
asked while it was still ungenerated was told there was nothing and does not
ask twice. The client needs no change for this: an unsolicited summary is
taken exactly like an answered one. The local server Goanna launches turns it
on (`project/local_server.gd`); a public operator decides for themselves.

It stays inside the boundary: the server generates its own world on its own
schedule, as it would for a player walking there, and the client never
generates or asks for anything a vanilla client could not.

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

So `GoannaClient` reports `far_extent`, the ninetieth percentile ring of
what is actually drawn, recomputed on each far rescan, and the haze closes
there, floored at the live range and capped by the grant. A percentile
rather than a maximum, so one straggler across a gap does not report a
horizon that is not there. Where there is nothing to show there is haze
rather than an edge, and the view opens as terrain arrives, which reads as
weather clearing rather than as a world being built.

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
