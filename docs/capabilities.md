# What Godot unlocks, what needs server authorisation, and in what order

Goanna renders an ordinary Luanti server through a general purpose game
engine. That engine can do a great deal Luanti's own client cannot, and the
useful question is not "what could we build" but "which of it needs the
server's authorisation, and what has to come first".

Nothing on this page is forbidden. With a server's authorisation even the
movement model can change. The question is never whether a thing is allowed,
it is which side of the line it sits on: things a client may simply do, and
things a server has to authorise first. That makes it an engineering question
with a concrete answer, does this need an option in `goanna_server_mod`,
rather than a matter of judgement to be relitigated per feature.

This file is the divergent list and the convergent one. `docs/far-rendering.md`
and `docs/iris-compat.md` are the two items already worked through in depth;
everything here is either smaller than those or not started.

## The test that sorts it

`README.md` states the boundary publicly: Goanna shows you nothing the server
did not send, and anything that would give a Goanna player an advantage over
anyone else is out of scope. `CONTRIBUTING.md` says the same. Read *of its own
accord* into it. Applied item by item, that reduces
to one question, and the question decides which bucket a thing is in rather
than whether it may exist:

> **Could a player make a better decision because of this, that a vanilla
> player could not?**

If no, it is presentation. It needs nothing from anybody and can be built
whenever someone feels like it. If yes, it needs authorisation: it becomes an
option in `goanna_server_mod/`, off by default, and a server operator turns it
on. Both answers are buildable. Only the second has a prerequisite.

The question is sharper than "is it visual". Several things that look purely
cosmetic answer yes, and at least one thing that sounds like a gameplay change
answers no. Sorting them is the whole point of doing this before building.

A second test catches a different failure:

> **Does it change collision, movement or timing?**

If yes it must agree with the server exactly, or the client desynchronises and
the server corrects the player, which is worse than not having the feature.
This is why local physics is safe for debris and unsafe for deformation.

## What the engine actually has

Checked against the godot-cpp bindings for 4.5 rather than assumed.

| | available | notes |
|---|---|---|
| VR | yes | `OpenXRInterface`, `XRInterface` |
| Ragdolls | yes | `PhysicalBone3D`, `PhysicalBoneSimulator3D` |
| Inverse kinematics | yes | `SkeletonIK3D`, `SkeletonModifier3D` |
| Cloth, hair | partly | `SoftBody3D`; no dedicated cloth or hair solver |
| Particles | yes | `GPUParticles3D`, with attractors and world collision |
| Environmental audio | yes | `AudioEffectReverb`, `AudioEffectFilter`, `AudioStreamPlayer3D`, `AudioListener3D` |
| Debris, rubble | yes | `RigidBody3D`, `MultiMeshInstance3D` for the cheap bulk case |
| Damage overlays | yes | `Decal` |
| Volumetrics | yes | `FogVolume` |
| Camera | yes | `CameraAttributesPhysical`, exposure and depth of field |
| Animation blending | yes | `AnimationTree` |
| Occlusion culling | yes | `OccluderInstance3D` |
| **Tessellation** | **no** | Godot 4 has no tessellation shader stage at all |

Tessellation is worth stating plainly because it is on every wish list and is
simply not there. Displacement has to be faked in the vertex shader on
geometry that already exists, or by meshing more finely, which is the same
trade Goanna already makes for bevelling.

## No authorisation needed: presentation

Nothing to ask, nobody to ask. These change what a player sees and hears
about information they already have.

- **Particles**: fire, smoke, portal shimmer, splashes, dust, footfall.
  `SPAWN_PARTICLE` and the spawner packets already arrive and already drive
  Godot particles; the gap is coverage and art, not protocol.
- **Weather** beyond the rain and snow already working: accumulation on
  surfaces, wind direction agreeing with the sky, wet surface darkening.
- **Baked ambient occlusion.** A hemisphere trace against the voxel
  occupancy the client already holds, per vertex, near field at mesh time and
  far field from the same coarse chain the far tiers use. Every occluder it
  reads was sent by the server, so it grants nothing. `docs/far-rendering.md`
  has the design.
- **Connected textures.** The mesher already has the neighbouring mapblocks
  in `MeshMakeData`'s vmanip, which is the hard part. Purely a look.

  Look at `sorucoder/ltc` first, which has a `connectedfaces` branch adding a
  **`connectedfaces` drawtype**, LGPL-2.1+ like Luanti itself, at
  <https://code.sorucoder.net/sorucoder/ltc/src/branch/connectedfaces>. The
  idea is a better shape than inference: the server *declares* that a node
  connects, so nothing has to guess.

  It is a fork rather than a Luanti pull request, so treat it as a convention
  to adopt rather than something to wait on. Support the drawtype where a
  server declares it, and let a server mod name the connecting nodes over
  `goanna:v1` where one does not. Neither needs an engine change from anyone.

  Inferring it anyway, for nodes the server has not declared, stays inside the
  boundary because it grants nothing. But it would make the same world look
  different in Goanna than in a vanilla client, which is a fidelity question
  worth deciding deliberately rather than by default. Supporting the declared
  drawtype has no such tension.
- **Block destruction as matter rather than a texture swap**: shattering,
  fragments, pebbles, a `Decal` for residual damage. Visual only, and see the
  collision caveat below.
- **Skeletal animation, IK, ragdolls**: an entity's death flop, feet planted
  on slopes, head tracking. The server sends position and animation state
  already; this is interpretation of it.
- **Camera**: exposure, depth of field, shake, sway, better third person.
- **Cloth and hair** on entities, within `SoftBody3D`'s limits.
- **VR**. A display and input mode, not an advantage: a vanilla player can
  already choose their field of view and look wherever they like.

## Needs server authorisation

These answer yes to the sorting question, so each becomes an option in
`goanna_server_mod/`. Not blocked, gated: the mod is the mechanism that makes
them available rather than an obstacle to them.

A second question then decides the shape, and it is worth asking before
building rather than after:

> **Does the server have to do anything, or only permit it?**

If only permit, a setting is enough: the mod relays every `goanna_*` setting
without knowing what any of them mean, so a permission costs an edit to
`minetest.conf` and nothing else. Far rendering is this shape. If the server
has to act, relaxing a check, sending data it otherwise would not, keeping
state, then it needs a submod, because behaviour means code. Source style
movement is this shape: it needs `anticheat_flags` relaxed or the server
rejects the movement and the option silently does nothing.

Getting this wrong in the permissive direction is the expensive mistake. A
capability that needed server behaviour but shipped as a flag looks enabled
and does nothing, which is harder to diagnose than a feature that is plainly
off. See `goanna_server_mod/README.md`.

### A submod must replace what it relaxes

The rule that falls out of source style movement, and it applies to anything
that asks a server to lower a guard.

Luanti's `anticheat_flags` has three bits, `digging`, `interaction` and
`movement` (`luanti/src/server.h`). There is no finer grain. Authorising
Source movement therefore means clearing `movement`, which does not disable
movement checking for Goanna clients doing the sanctioned thing, it disables
movement checking **for every client**. Slow flying, teleporting and the rest
of the exploits in luanti-org/luanti#3822, open since 2016, all become
available to anyone, whatever client they run.

That is not a specific grant implemented by a general switch, it is a general
hole with a specific excuse. So:

> **A submod that relaxes a protection must reimplement it, not merely remove
> it.**

The source movement submod owes the server a movement validator that
understands the model it is authorising: one that permits bunny hopping's
acceleration curve and air strafing while still rejecting teleports, flight
and speeds the model cannot produce. Anything less trades a client feature for
the server's integrity, which no server operator should be asked to do and
most would not notice they had done.

This makes source movement a far heavier item than it first appeared, and much
heavier than far rendering, which asks the server for nothing but consent.

`docs/validation.md` works this through: what a replacement validator has to
do, why the split between action cheats and information cheats decides which
capabilities need one at all, and the upstream proposal, which is broader than
Goanna and stands on its own.

- **Far rendering.** Sees terrain the server did not send this session.
  `docs/far-rendering.md`.
- **Source style movement.** Moves in ways the server did not sanction, and
  the server rejects it as speed hacking unless it also relaxes
  `anticheat_flags`.
- **Environmental audio, and this is the surprising one.** Reverb and
  occlusion done properly are not decoration: a correctly occluded footstep
  tells you there is something behind that wall, and reverb tells you the
  size of a cave you have not entered. That is information a vanilla player
  does not have. The tasteful version, attenuating what you can already hear,
  needs no authorisation; the accurate version does. Draw that line explicitly
  rather than letting it drift, because accuracy will always look like the
  better engineering.

## Needs collision to stay honest

Not a permission question, a correctness one. The second test above.

- **Deformation that changes shape must not change collision.** A cracked
  block still occupies its node as far as the server is concerned. Deform the
  visual, never the collider.
- **Debris is safe** because it is not gameplay: it collides with the world
  for looks, and nothing depends on where it lands.
- **Displacement mapping** has the same rule. A bumpy surface the player
  walks through is worse than a flat one they walk on.

## Order

Roughly by what unblocks what, rather than by appeal. `docs/roadmap.md` is
the single place the order is kept and argued; this list is the same order
seen from the capabilities side, and where the two differ the roadmap wins.

1. **Finish the free presentation items that already have their data.**
   Particles and weather have packets arriving now. Connected textures have
   the neighbour data now. Block destruction has the texture and the node
   type now. None of these are blocked on anything, and they are the visible
   half of what makes a client feel modern.
2. **Lighting and materials**, because they are multiplicative. Every item
   above looks better or worse depending on them, and `docs/pbr-plan.md` is
   still where the biggest single visual gain sits.
3. **Entity animation, IK, ragdolls.** Larger than the first group and
   independent of it.
4. **Audio**, with the line drawn first. Cheap to do badly, and the accurate
   version needs an option in the mod, so decide which half is being built
   before building it.
5. **Far rendering**, which now has its authorisation model but not its
   store.
6. **Iris packs**, which subsume a great deal of the shading work and should
   not be started before the material path settles, or it will be built twice.
7. **VR**, last of the large items, not because it is hard but because it
   multiplies the cost of everything not yet settled: every UI, every camera
   behaviour and every performance problem is worse in a headset.

## What needs whom

Three kinds of dependency, and only one of them is expensive. Sorting a
proposal into the right one before starting is worth more than any amount of
enthusiasm for it.

**Goanna's own, needing nobody.** Everything client side, and anything the
server can do from a Lua mod. This is almost all of it. A capability that
needs the server to send data it does not otherwise send does **not** need a
protocol change: a submod sends it over the `goanna:v1` mod channel. That is a
public, sanctioned Luanti mechanism, vanilla clients are unaffected because
they never join the channel, and no engine code is involved. Earlier drafts of
this file sent that category upstream, which was wrong.

**A convention or a rule, proposable at low cost.** A texture naming
convention for material data, as argued in `docs/materials.md`. A set of
server side rules. These are written once and maintained by whoever adopts
them; proposing one costs a conversation, not a commitment.

**Engine C++ work, which is not on the table.** Not because it would be
unwelcome, but because owning code in Luanti's renderer means maintaining it
across releases indefinitely, and that is a standing cost this project has
deliberately not taken on. `luanti/` is a pinned submodule and
`docs/transplanting.md` exists to keep even the copied surface minimal, for
the same reason.

Worth stating plainly, because it was not obvious until the categories were
separated: **nothing in the current design falls in the third group.** Far
rendering is client side with a grant. Iris is entirely client side. Source
movement needs a Lua validator and a config flag. Connected textures are
either someone else's drawtype or a client side inference. The one engine
change that would help, a hook for a mod to supply its own movement model, is
an improvement to something that already works rather than a prerequisite for
it.

If a future proposal does land in the third group, that is the signal to
redesign it rather than to start writing C++ against Irrlicht.
