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
 multi tier LOD          (particles, weather, destruction,
   occupancy chain        connected textures, entity animation)
   far field occlusion
   vertex layout fixed
   (all four done 2026-08-21; atmosphere still open)
   |
   v
 local store (Voxy shaped: full blocks, derived chain) ... done 2026-08-21
   |
   v                         v
 true far rendering      Iris rungs 2 to 4, screen space chain
 (drawing from the store works; atmosphere and water at distance open)
                             |
                             v
                         Iris rungs 5 to 7, gbuffers translator
                         (needs the LOD vertex layout above)
```

The root used to be written as a decision about who owns lighting. It is
settled, in `pbr-plan.md` step 3: Godot lights, and Luanti's baked light
travels alongside as a vertex attribute because three later things read it.
What remains is a task, not a question, and it is the first thing on the
path.

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

## Chokepoints

Four things unblock disproportionately, and two of them are already done.

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

**The vertex light path.** `g_goanna_no_light` is still set. One switch with
three consequences that look unrelated until you trace them: it is why
turning on Luanti's smooth lighting changed nothing measurable, it is why an
Iris pack would render its torches and caves wrong (nearly every pack reads
`lmcoord`, not only the ones that light inline), and it is the attribute the
baked occlusion term rides in. It is small, and three later items wait on it.

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
   step 4, the audit, is open. It contains: the vertex light path revived and `g_goanna_no_light`
   removed, Luanti's block and sky light riding as an attribute; the near
   field of baked occlusion, traced per vertex against the block's
   neighbourhood and replacing the corner term; the per node classifier with
   its two columns; the exposure rework. Multiplicative: everything in item
   3 looks better or worse depending on it, and weather, fog and wet
   darkening in particular are exposure dependent, so doing them first means
   doing them twice.
3. **Free presentation work.** Particles, weather, block destruction as
   matter, connected textures, entity animation. No dependencies, no
   authorisation, and the data already arrives. Independent of item 4 and can
   run beside it. Check the `connectedfaces` drawtype upstream first, per
   `capabilities.md`.
4. **Far rendering rungs 2 to 4**: shading parity, multi tier LOD with the
   occupancy chain and the residency rule, the far field occlusion baked
   into the tiers, atmosphere. Rungs 2 and 3 landed 2026-08-21
   (`far-rendering.md`, "What landed"), so the LOD vertex layout item 7 has
   to target is fixed; rung 4, atmosphere, is open. None of it needs a store
   or authorisation, and it makes the range the server already sends look
   like a landscape rather than a contour map, with the holes where the
   server sent nothing now plainly visible as the thing item 5 fixes.
5. **The local store**, Voxy shaped: full blocks as received, the derived
   chain alongside, a reader for the `far_rendering` grant, the far field
   occlusion reaching beyond the live range. Landed 2026-08-21
   (`far-rendering.md`, "What landed at rung 5"): the first frame that drew
   terrain the server was not sending. What remains of far rendering is
   rung 4, atmosphere, and rung 6, water at distance.
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
