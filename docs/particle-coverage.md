# Particle coverage

What a Luanti particle spawner can ask for, and what Goanna actually draws.
Written down because "particles work" is true and useless: they have worked
since the packets were first read, while most of the format went to the
floor. The three columns that matter are whether a field is read off the
wire, whether it reaches the renderer, and whether anything is done with it.

The reference is `ParticleSpawnerParameters` in `luanti/src/particles.h` and
`Client::handleCommand_AddParticleSpawner`. Goanna's parser follows that
order exactly so the two can be diffed when the format next changes.

## Spawner fields

| Field | Read | Drawn | Note |
|---|---|---|---|
| `amount`, `time` | yes | yes | |
| `pos` | yes | yes | box emission shape |
| `vel` | yes | approximated | Godot takes a direction and a spread, not a velocity box, so the mid velocity becomes the direction and its span becomes the spread. A box wider in one axis than another loses that difference. |
| `acc` | yes | approximated | mid acceleration becomes gravity |
| `exptime` | yes | yes | `exp_max` is the lifetime |
| `size` | yes | yes | scale range |
| `collisiondetection` | yes | yes | rigid collision |
| `collision_removal` | yes | yes | hide on contact |
| `object_collision` | yes | no | Godot particles collide with the world, not with entities |
| `vertical` | yes | no | billboards always face the camera |
| `texture` | yes | yes | |
| `texpool` | yes | partly | Godot draws one pass with one material, so the first entry is used. A pool of one, the ordinary case, is exact. |
| `animation` | yes | yes | vertical strips and 2D sheets both, see below |
| `glow` | yes | no | deliberate, see below |
| `node`, `node_tile` | yes | no | a particle taking its texture from a node's tile still needs a content id to tile texture lookup |
| `drag` | yes | approximated | per axis in Luanti, damping along the velocity in Godot, so a drag that differs per axis loses its direction |
| `jitter` | yes | approximated | a random acceleration each step in Luanti, which Godot has no equivalent for. It becomes extra spread and initial velocity, which looks close for short lived particles and diverges for long lived ones. |
| `bounce` | yes | yes | collision bounce |
| `radius` | yes | no | |
| attractors | yes | no | `GPUParticlesAttractor3D` exists and would fit; not wired up |
| `blendmode` | yes | mostly | alpha, add and sub map directly. clip becomes alpha scissor. **screen has no Godot equivalent and borrows add**, which is brighter than it should be where the two differ. |
| per texture `alpha` and `scale` tweens | yes | no | |
| tweened start and end values generally | yes | no | only the start range is used, so a spawner that tweens renders as its opening state |

## Two that are deliberate

**Glow is read and not drawn.** Particles are drawn unshaded, so they are at
full texture brightness everywhere: smoke in an unlit cave is as bright as
smoke at noon. Glow sets a *minimum* light level, which only means something
once particles take light from the world at all. That is the lighting rework
in `pbr-plan.md`, not this file, and adding a light level here would have to
be undone by it. It is carried so the day that lands it is one line.

Worth knowing that this was already wrong in a smaller way: single particles
parsed `glow` and spawners did not, so a spawner's fire and torch sparks lost
the one property saying they are self lit, while the same particle spawned
singly kept it.

**Tweens are read and not drawn.** A tweened parameter is a start range and
an end range, and Godot's particle process material takes one range. Doing
this properly means a custom process shader, which is worth doing once and
not worth doing badly first.

## Why the whole packet is read even where nothing uses it

The format is positional. A field left unread does not just cost you that
field, it makes every field after it unreachable, which is how the parser
came to stop at the attached object id: that was the end of the packet in
5.5, and everything 5.6 added sat in the buffer unseen for as long as the
prefix looked like it worked.

So the rule here is to read to the end of what the protocol version defines,
carry it across the thread boundary, and let the renderer ignore what it
cannot yet use. Reading is cheap and being unable to read is expensive.

Short packets are tolerated rather than rejected. What was read before the
end stands and the rest keeps its default, which is how a client that expects
more than a server sends has to behave.

## Animation

A 2D sheet gives its frame counts directly. A vertical strip gives the
*aspect ratio of one frame* instead, so the frame count only falls out once
the texture's own pixel size is known, which the session does not have. The
ratio is carried whole rather than divided, because dividing it in the
session rounds it away.

Godot counts animation speed in whole runs over a particle's lifetime, where
Luanti gives seconds per frame, so the conversion needs the frame count and
the lifetime together.

## Not covered here

Single particles (`TOCLIENT_SPAWN_PARTICLE`) are parsed with Luanti's own
`ParticleParameters::deSerialize`, so they read the full format for free.
They drop the same fields at the drawing end for the same reasons.
