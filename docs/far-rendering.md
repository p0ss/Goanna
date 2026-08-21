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

Partly built. `meshBlockLod` in `goanna_mesher.cpp` already reduces a
mapblock to coarse cells, and `docs/requirements.md` records the result: at
view range 20, 4,858 draw calls and 118 fps became 2,824 and 262 with LOD
beyond six mapblocks.

What is missing:

- **Tiers.** `lodTierFor` (`goanna_client.cpp`) returns 0 or 1 from a single
  distance. Long range wants several, cell 2 through 16, chosen per region
  by distance with hysteresis, so cost falls with distance instead of
  stepping once. The levels come from the same derived chain the store
  keeps, so inside the live range and beyond it the tier data has one
  shape.
- **Merging.** Cells are emitted per cell, one mesh per mapblock. A cliff
  face should be a few quads, not a few thousand, and a region of 8 by 8 by
  8 mapblocks at a coarse tier should be one mesh. Greedy merging of
  coplanar same content faces, on the CPU, into per region meshes per tier.
- **Residency, which replaces seams.** Today seams are ignored on purpose,
  and the comment in `goanna_mesher.cpp` says why: a neighbouring block
  hides the join. With several tiers meeting, that stops being true. The
  rule borrowed from Voxy is that a region at tier N is drawn only where no
  finer tier is resident for it, and the mesh at tier N is built against its
  neighbours' occupancy at tier N, not at whatever tier they happen to be
  drawn at. A live mapblock arriving evicts the coarse cell it falls in.
  Skirts stay as the cheap fallback at the join between the live mesh and
  the first coarse tier, where the two meshers differ.
- **Vertex format.** The LOD mesh must carry what the near mesh carries:
  array layer and UV into the `Texture2DArray`, the per node light and
  ambient occlusion term, and the block semantic ID. Nothing reads the last
  two yet. They are there so that the shader family is one family and so
  that a shader pack, later, treats the vista as terrain. See "Under a
  shader pack".
- **Depth precision.** Godot 4.3 and later use reversed Z, which takes most
  of the far plane problem away. Measure at 4000 nodes before reaching for
  anything clever; the likely remaining issue is the near plane, not the
  far.

None of this needs the store. It can be built and judged inside the range
the server already sends.

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
2. **Far shading parity.** Give the existing coarse tier the array shader
   and `_s`, on a vertex layout that already has room for light, occlusion
   and block ID. No new geometry, no new storage. Immediately visible once
   `pbr-plan.md` step 2 has given most nodes a real `_s`, and it is the
   difference between a contour map and terrain.
3. **Multi-tier LOD geometry**, still inside the server's view range. The
   derived occupancy chain, tiers by distance, greedy merging into per region
   meshes, the residency rule. The far field occlusion term is baked into
   these meshes here. Proves tiers and joins without touching persistence.
4. **Atmosphere at long range.** Re-derive fog and aerial perspective.
5. **The store**, gated on the server allowing it, on by default only for
   the local server Goanna launches itself. Full blocks as received, the
   derived chain alongside, a reader for the `far_rendering` grant, and the
   far field occlusion reaching beyond the live range. Only at this rung does
   the view exceed what the server sends, and only at this rung does
   staleness exist.
6. **Water at distance, without a pack.** Specular and fresnel from `_s` on
   the coarse tiers, so sea reads as sea at the horizon. Reflections proper
   are a shader pack's job (`docs/iris-compat.md`, `gbuffers_water` and
   the pack's own SSR) and are not duplicated here.

Rungs 1 to 4 need no decision from anyone. Rung 5 does.

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
- A per tier draw call and fps readout, so rung 3 cannot regress rung 2
  silently.
