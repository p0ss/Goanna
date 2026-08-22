# Dependency chain

What depends on what, across `pbr-plan.md`, `far-rendering.md`,
`iris-compat.md`, `capabilities.md` and `validation.md`. Those files say what
each thing is and why. This one says only what has to come first, and it is
the single place the order is kept; where another file lists an order, it is
this one seen from that file's side.

## The chain

```
  ALREADY LANDED
        |
   block/texture semantics ------> Minecraft packs
   mod channel handshake    ------> any grant a server wants to give
        |

  NEXT CRITICAL PATH

   Iris rung 1 spike, done 2026-08-21 (the pipeline works)
        |
   lighting and materials
     Godot lights, Luanti's light rides along ... done 2026-08-21
     near field baked occlusion .................. done 2026-08-21
     exposure and sky fill, on the chart ......... done 2026-08-21
     per node classifier, both columns ........... done 2026-08-21
        |
   +----+--------------------+
   |                         |
   v                         v
 far shading parity      free presentation work
 multi tier LOD          (particles, weather and block destruction
   occupancy chain        done 2026-08-21; connected textures,
   far field occlusion    node and entity animation still open)
   vertex layout fixed
   (all four done 2026-08-21, and atmosphere with them)
   |
   v
 local store (Voxy shaped: full blocks, derived chain) ... done 2026-08-21
   |
   v                         v
 true far rendering      Iris rungs 2 to 4, screen space chain
 (far rendering rungs 1 to 7 all done 2026-08-21, including terrain the
  server has but the player has not visited)
                             |
                             v
                         Iris rungs 5 to 7, gbuffers translator
                         (needs the LOD vertex layout above)
```

The root used to be written as a decision about who owns lighting. It is
settled, in `pbr-plan.md` step 3: Godot lights, and Luanti's baked light
travels alongside as a vertex attribute because three later things read it.
That task landed on 2026-08-21, so the root of the chain is no longer a
question or a task. What is left of the item it sat in is the audit; see
"Where the front is" below.

## Where the texture map does and does not reach

The block and texture correspondence is landed and it feeds both Minecraft
packs and Iris semantic IDs, but it is not one table read two ways. It is not
intrinsically reversible, and the asymmetry is worth knowing before relying on
it.

**Many Luanti textures to one Minecraft path.** 18 of 496 pack paths, 3.6 per
cent, have more than one Luanti texture pointing at them, covering 46
textures. `block/oak_planks.png` has six, including `default_wood.png` and
three fence variants. Going forward is fine, which is the direction resource
packs need. Inverting it is ambiguous.

**Texture identity is not block identity, and this is the larger gap.** Iris
assigns semantic IDs per *block*, through `block.properties`. Our map is per
*texture*. In Mineclonia 578 of 1084 textures are used by more than one node:
`blank.png` by 157, one mushroom texture by 128, a redstone dust texture by
73. Knowing a node's texture therefore does not tell you which block it is,
and a node has several tiles which may disagree.

So deriving Iris IDs needs the nodedef as well as the map: which node uses
which tiles, plus a rule for what to do when they disagree, and it will be
lossy wherever one texture serves several distinct blocks. That nodedef read
is the same one `pbr-plan.md` step 2 does to assign a material class, so it
is built once with two output columns, and the Iris ID becomes a lookup
rather than a second classifier.

## Where the front is, 2026-08-22

Nearly every numbered item in "Order, and why" is marked done, which makes
that list hard to read as a plan. Four things are actually open. In the
order they should be taken below. `launch-target.md` cuts across them from
the other side: the one experience a fresh install should have, and the
tasks, in order, that get it there.

**The audit, `pbr-plan.md` step 4.** The last of the material path, and the
gate the Iris items wait behind. Per game and per node: the class assigned,
whether authored data exists, and a rendered swatch, generated over every
registered node. It is measurement rather than shading, so it grows nothing
that Iris would subsume, which is why it can be the one part of item 2 left
standing in front of item 6. Done when a row can be pointed at rather than
a screenshot.

**Iris rungs 2 to 4, the screen space chain.** Rung 1 proved the pipeline
on 2026-08-21, and no translator is needed for these three: a pack running
only its composite chain is already most of what a pack looks like. This is
the largest piece of unbuilt work that has nothing blocking it but the
audit.

**What is left of free presentation work.** Connected textures, entity
animation, and node texture animation, which stops on its first frame.
Block destruction landed 2026-08-21 (pieces thrown off a node as it is dug
and when it breaks, matching vanilla's counts). Independent of everything
above and of each other, so this is what to pick up when something above is
waiting on a decision. Connected textures is the one that may not be ours to
build; see the last section.

**Far rendering quality.** No rungs left, only calibration and scale: the
chain thresholds, a worker thread for region meshing, settings entries for
the far distance and the stale strength, and an index over stored regions
before that scan is asked to cover 4000 nodes.

After those, in order: Iris rungs 5 to 7, the gbuffers translator, which
needs both the LOD vertex layout and the light path and now has them; source
movement, behind the validator that is the larger half of it; and VR, which
multiplies the cost of everything still unsettled.

## Chokepoints

Four things unblock disproportionately, and three of them are now done.

**The mod channel.** Every capability needing authorisation was blocked on
having any way for a server to grant one. It now exists
(`joinGoannaChannel`, `onModChannelMsg` in `src/goanna_session.cpp`), is
generic, and needs no change when a capability is added. What each
capability still needs is its own reader of the option it was granted;
`far_rendering` has one since 2026-08-21 (`GoannaSession::farRenderingGrant`).

**The block and texture mapping.** It feeds both a Minecraft resource pack
dressing a Luanti game and, with the nodedef alongside it, the semantic IDs an
Iris pack needs from `block.properties`. Not the same lookup in both
directions; see the section above for where it stops.

**The vertex light path.** Done 2026-08-21, and not the way this entry
predicted. The three consequences were real: it is why turning on Luanti's
smooth lighting changed nothing measurable, why an Iris pack would render
its torches and caves wrong (nearly every pack reads `lmcoord`, not only the
ones that light inline), and where the baked occlusion term had to ride. But
the fix was not to clear `g_goanna_no_light`. That switch stays set on
purpose and permanently, because Luanti's mesher multiplies baked light into
the vertex colour and Godot then lights the result, which applies the light
twice, once as a darkening of the surface and once as light. So the two are
separated instead: `ARRAY_COLOR` keeps the tile tint alone, and Goanna's own
code samples block light, sky light and occlusion from the same nodes Luanti
would have read into `CUSTOM0`, where a shader applies them as light rather
than as albedo (`mesh-attributes.md`, `src/goanna_light.h`). Anything that
still reads "clear the switch" is out of date; the contract is the attribute
table.

**The material path settling.** Not a feature, a gate. Iris subsumes a great
deal of shading work, so building the material path further after starting
Iris means building it twice. `pbr-plan.md` should finish first. The one
exception is Iris rung 1, which is a proof of the pipeline and not shading
work, and whose answer changes how far `pbr-plan.md` step 3 should go.

## Order, and why

1. **Iris rung 1, as a spike.** Done, 2026-08-21: parse a pack, allocate
   the buffers, compile through `shader_compile_spirv_from_source`, run as a
   `CompositorEffect`; a two pass proof pack renders against Mineclonia on
   Godot 4.5.1 (`iris-compat.md`, status section). The answer was yes, so
   bloom, tonemap, volumetrics and reflections come from packs and item 2
   should not grow them in `.gdshader`. The rest of Iris waits for item 2.
2. **Lighting and materials.** `pbr-plan.md` steps 1 to 3, and the gate
   above. Steps 1 to 3 landed 2026-08-21 (the chart, the classifier with
   both columns, and the exposure and sky fill recipe the chart settled);
   step 4, the audit, is open. It contains: the vertex light path revived,
   Luanti's block and sky light riding in `CUSTOM0` rather than in the
   vertex colour, which is why `g_goanna_no_light` stays set; the near
   field of baked occlusion, traced per vertex against the block's
   neighbourhood and replacing the corner term; the per node classifier with
   its two columns; the exposure rework. Multiplicative: everything in item
   3 looks better or worse depending on it, and weather, fog and wet
   darkening in particular are exposure dependent, so doing them first means
   doing them twice.
3. **Free presentation work.** No dependencies, no authorisation, and the
   data already arrives. Independent of item 4 and can run beside it.
   Particles and weather landed 2026-08-21: the spawner packet is read to
   the end of what the protocol version defines and drawn as Godot GPU
   particles, and rain and snow reach a shader pack as `rainStrength`
   (`particle-coverage.md`). Two gaps there are deliberate rather than
   missed. Particle glow is parsed and not drawn: it sets a minimum light
   level, which means nothing while particles are drawn unshaded, so the
   open piece is particles taking light from the world at all, and that
   belongs with the lighting work rather than here. Tweened parameters are
   parsed and not drawn because Godot's process material takes one range,
   and the honest version is a custom process shader, which is worth doing
   once rather than badly first. Block destruction landed the same day:
   pieces thrown off a node as it is dug and when it breaks, with vanilla's
   counts. Still open: connected textures, entity animation, and node
   texture animation, which does not advance past its first frame. Check the `connectedfaces`
   drawtype upstream first, per `capabilities.md`.
4. **Far rendering rungs 2 to 4**: shading parity, multi tier LOD with the
   occupancy chain and the residency rule, the far field occlusion baked
   into the tiers, atmosphere. All landed 2026-08-21 (`far-rendering.md`,
   "What landed"), along with rungs 5 (the store), 6 (water at distance)
   and 7 (server summaries), so every far rendering rung is done: the LOD
   vertex layout item 7 targets is fixed, and the range the server sends
   reads as a landscape. What is left of far rendering is quality and scale,
   not rungs: chain threshold calibration, a worker thread for region
   meshing, settings entries for the far distance and the stale strength
   (environment variables today), and an index over stored regions, the scan
   being linear in the region count, which is fine at 512 nodes and is not
   at 4000.
5. **The local store**, Voxy shaped: full blocks as received, the derived
   chain alongside, a reader for the `far_rendering` grant, the far field
   occlusion reaching beyond the live range. Landed 2026-08-21
   (`far-rendering.md`, "What landed at rung 5"): the first frame that drew
   terrain the server was not sending. Rung 7 followed the same day and is
   the answer to what the store cannot do: the store shows you only where
   you have walked, so `goanna_server_mod` answers `farsum?` with coarse
   summaries of map it has already generated, never generating any, and the
   horizon takes in places the player has never been.
6. **Iris rungs 2 to 4**, the screen space chain. No translator needed, and
   a pack running only its composite chain already looks like a shader pack.
7. **Iris rungs 5 to 7**, the gbuffers translator. Needs the LOD vertex
   layout from item 4 and the light path from item 2, or the vista renders
   as Godot drew it under a pack that shades everything else.
8. **Source movement**, only behind its validator, which is the larger half.
9. **VR**, which multiplies the cost of everything unsettled.

## The one that is gated on someone else

**Connected textures** may not be ours to build. `sorucoder/ltc` has a
`connectedfaces` drawtype in progress. If that lands upstream, supporting the
drawtype is better than inferring connection, and inferring it anyway means
the same world looks different in Goanna than in a vanilla client.

It is on a fork rather than in a Luanti pull request, so waiting for it to be
accepted upstream is not a plan. The realistic route is to adopt the idea:
support the drawtype where a server declares it, and otherwise let a server
mod say which nodes connect over `goanna:v1`, which needs no engine change
from anybody.

**Source movement** is not in this category. It needs `AC_MOVEMENT` cleared
and a Lua validator to replace what that removes, covering every player rather
than only the granted ones. That is real work, and it is self contained: no
upstream change is required for it, only for it to be tidier.
