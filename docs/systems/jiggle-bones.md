# Jiggle bones

A model can mark bones that Goanna moves itself, as cloth or hair: a skirt
lags and sways behind a walking body and settles under gravity, a cloak
streams back, a plait swings when the head turns. It is purely cosmetic. It
changes how the client draws a model from what it already draws (the
entity's own pose and its parent's), sends nothing to the server and shows
the player nothing a vanilla client would not. A vanilla client ignores the
marks and draws the bones in their pose.

This page is the contract a game authors against; DorfCraft's drapes and
hair are the first users. The code is `src/goanna_jiggle.h` and
`src/goanna_jiggle.cpp`, driven from `ModelAnimator::step`
(`src/goanna_models.cpp`) and `EntityRenderer::sync`
(`src/goanna_entities.cpp`); the test is `src/goanna_jiggle_test.cpp`.

## Marking a bone

A bone is a glTF node with this in its `extras`:

```json
{"jiggle": {"stiffness": 0.5, "damping": 0.35, "gravity": 1,
            "limit_degrees": 70, "chain": "drape_cloak"}}
```

Only glTF models (`.gltf`, and the JSON chunk of a `.glb`) carry marks.
Luanti's glTF loader drops node extras, so Goanna reads the file's JSON
again and matches the marks to joints by node name, which must be unique
within the model. A field left out takes the default below.

| Field | Range | Default | Meaning |
| --- | --- | --- | --- |
| `stiffness` | 0 to 1 | 0.5 | Natural frequency ω = 2 + 18 × stiffness, radians a second: 2 at 0, 11 at 0.5, 20 at 1. |
| `damping` | 0 to 1 | 0.35 | The damping ratio ζ: 0 swings for ever, 1 is critically damped, no overshoot. |
| `gravity` | any | 1 | A multiplier of world gravity, 9.81 nodes a second squared. 0 for none. |
| `limit_degrees` | 0 to 180 | 70 | The half angle of a cone round the target direction that the bone never leaves. |
| `chain` | string | the node's name | Bones that link parent to child, in order. A bone whose child is in the same chain takes that child as its tip. |

How fast a bone answers is ω; how long it rings is about 4 / (ζ ω)
seconds. DorfCraft's drapes (0.5 / 0.35 / 1 / 70) have ω 11 and ring for
about a second; its plaits (0.6 / 0.4 / 1 / 35) have ω 12.8 and ring for
about 0.8 s.

## What it does

Each marked bone springs toward its target pose: the pose the animation
gives it this frame when a clip plays, and its rest pose when none does
(with the game's bone overrides and Goanna's own posing on top, as for any
bone). In practice DorfCraft's drapes play no clips, so they are their
rest pose plus the physics.

The bone's tip is simulated in world space as a point mass:

- **The spring** pulls the tip toward where the target pose puts it, at ω,
  damped by ζ against the target's own motion. So a body walking at a
  steady speed does not drag its skirt behind it; only a change of motion
  swings it.
- **Inertia.** The target moves with everything above the bone: the
  entity's root, its parent's bones, and for an attached drape or hair the
  parent entity's bone it hangs on. The tip has to be pulled after it, so a
  body accelerating sideways swings its skirt the other way, and one that
  stops swings it on.
- **Gravity** pulls the tip down at `gravity` × 9.81. A bone hanging
  straight down does not move for it; one held out sideways sags until the
  spring balances it (DorfCraft's skirt, laid horizontal: 16 degrees).
- **Length.** The tip stays at the bone's length from its pivot.
- **The cone.** The tip never goes more than `limit_degrees` from the
  target direction.
- **Collisions** push the tip out of the wearer's capsules (below).

The result is written back as the bone's rotation, the shortest turn from
the target direction to the simulated one, keeping the bone's length and
its place on its parent. Everything below it follows, so a chain's next
bone hangs from the simulated tip, and a model attached to a jiggle bone
moves with it.

The solver steps at a fixed 60 Hz, at most five steps a frame (a longer
frame drops the rest rather than catching up), and each step sees the
model's transform part of the way from last frame's to this one's. State is
per entity and per bone. It starts again from the target pose when the
model's root moves more than 2 nodes in a frame (a teleport), when the
simulation is turned off, and when the model is rebuilt.

### Tips

The tip of a bone with a child joint is that child: the one in the same
chain if there is one, else the first. A bone with no child (a skirt
panel, the last link of a chain) gets its tip from the vertices it
carries, at rest: it points from the joint toward their centroid, weighted
by skin weight, and reaches as far along that line as the furthest of
them. A leaf bone that carries no vertices gets a tip a quarter of a mesh
unit straight down. A bone whose rest pose does not hang straight down
settles a little off it under gravity, which is the physics, not an error.

### Colliders

The bones of the wearer can carry:

```json
{"jiggle_collider": {"radius": 0.25, "tip": "neck"}}
```

a capsule from the bone's joint to the named child joint's, `radius` in
the model's own mesh units (the same units as its node translations). A
capsule with no `tip` is a sphere at the joint.

A model that marks no `jiggle_collider` at all falls back to capsules on
the bones named `chest`, `body`, `leg_left`, `leg_right`, `leg_left_lower`
and `leg_right_lower` (every DorfCraft hominid frame has them), each made
from the bone's mesh extent: the box round the vertices it carries most of
(skin weight at least a half), in the bone's own frame at rest. The capsule
runs along the box's longest side through its middle, its radius is the
larger of the box's other two half sides, and its rounded ends sit inside
the box's ends. On a box model that touches the middle of each long face
and leaves the corners a little outside, so a tip can graze a corner but
not pass through a face. On DorfCraft's `aurochs_person_male_carved_adult`
the chest capsule runs across the chest with radius 0.253 and the thigh's
stands upright with radius 0.159.

A drape or hair is a separate entity attached to the wearer's bone
(drapes on `chest`, hair on `head`, beards on `jaw`). Its tips are kept out
of its parent's capsules, in world space as the parent's pose leaves them
this frame. A model's own capsules are not used against its own jiggle
bones, and there is no collision with the world or between jiggle bones.

### Cost and settings

Only models within 32 nodes of the camera are simulated; beyond that the
bones take their target pose. The settings panel's **Swaying cloth and
hair** (`mat_jiggle`, a toggle under Graphics, Materials) turns it off,
and the Lowest graphics profile has it off; every other profile has it on.
Its CPU cost has not been measured.

`call entity_animation args=[<id>]` on the
[control channel](../agents/control-channel.md) includes a `jiggle`
section for a model with jiggle bones: whether it is being simulated, the
steps the last frame took, and for each bone where its tip was drawn,
where its pose puts it and the angle between them.

## Parent and child animation state

DorfCraft found that on the stock Luanti 5.17 client a skinned drape
attached to a body's chest bone that plays a named clip turns the body.
Goanna shares no skeleton or animation state between a parent and a
child. Each entity has its own `ModelAnimator` with its own blend state,
tracks and bone overrides; `animateTracks`, `calculateGlobalMatrices` and
`calculateSkinMatrices` read the shared `SkinnedMesh` and write only the
animator's own arrays; and a child is placed from the parent's joint with
`boneAttachmentTransform`, which reads the parent's pose and changes
nothing of it. The test steps a body and a tabard playing `walk` side by
side and checks the body's chest does not move.

## Tested

`goanna_jiggle_test` loads every DorfCraft drape and hair model and checks
the marks and values, a skirt and a cloak swinging against an
acceleration and settling within 1.5 s of stopping, a plait doing the
same, gravity on a horizontal bone, the cone under 40 g, a capsule pushing
a tip out, the fallback colliders, teleports, the switch, the substep cap,
and that the pose written is the one simulated.

Seen live on 2026-10-27: a disposable Mineclonia world with DorfCraft's
`mods/` on a flatpak Luanti 5.17.0 server, and Goanna on Godot 4.5.1 under
`tools/goanna-headless start --software` (lavapipe, 640 by 360). A sapiens
in a surcoat and cloak stood, then was moved 1.5 nodes either side of its
place on a 3 s period, then stopped dead mid stroke. `entity_animation`
read the surcoat's skirt panels at 0.2 to 1.5 degrees off their pose
standing, up to 8 degrees while moving, and back to the standing figure
within about 0.6 s of stopping; the cloak's hem reached 45 degrees while
moving. Lavapipe drew few enough frames that every frame took the five
step cap, so the simulation ran slower than real time there; a GPU frame
rate has not been tried.
