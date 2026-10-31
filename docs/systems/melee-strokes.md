# Melee strokes

A server can send a melee stroke as a few numbers instead of a pose every
tick, and Goanna poses the body itself. Each body's glTF declares a stroke
plan; the server's stroke state rides on the object as a bone override;
Goanna evaluates a whole-body pose from the two, every frame, on top of
the game's own animation. A vanilla client sees only the game's animation
(DorfCraft plays the nearest of eight baked stroke clips) and ignores the
rest. Goanna gives no gameplay advantage here: hits are decided by the
server, and the state is sent to every client alike.

`src/goanna_strokes.h` is the evaluator; `ModelCache::buildStrokes` and
`ModelAnimator::poseStroke` (`src/goanna_models.cpp`) connect it.

## What the model declares

The glTF's root `extras` carries `strokes`:

- `state`: the name of the bone override that carries the stroke state.
  No mesh has a bone of that name, so Luanti's client applies nothing.
- `family`: the media name of the stroke family file. Luanti serves no
  `.json` media, so the family is a glTF with no scene and the family in
  its root `extras.stroke_family`. One file serves every body.
- `plan`: the body as the evaluator needs it: units per node, each bone's
  name, parent, translation and bind position (parents first), and the
  boxes the blade and elbows keep clear of.

A family is a set of authored whole-body strokes, one per drag angle,
stored relative to the body: the grip as a fraction of arm reach from the
shoulder in the chest's frame, and blade, trunk and hand rotations. The
evaluator blends the two strokes either side of an angle and fits them to
whatever body it is given: two-bone or FABRIK arm chains (a tentacle arm
holds the sword too), an elbow swivel chosen as a soft minimum of limb
intrusion, the grip pulled in rather than the hand leaving the hilt, the
blade pushed out of the body's boxes, and the legs planted. It is a port
of DorfCraft's `tools/kindred_creatures/animation/melee_reference/
strokes/evaluate.lua`, which the server runs for its hit tests.

## The state

The state bone's override: position = (drag angle in degrees, stroke time
in seconds when sent, target height); scale = (action serial, phase, 1).
Phase 0 is no stroke, 1 preparing (the angle is where the drag is heading)
and 2 committed (the server's frozen angle). Luanti resends every override
an object holds whenever any one changes, so Goanna restarts its own
stroke clock only when the serial, phase or angle actually change, not on
every resend. The shown angle eases towards the told one at 900 degrees a
second, as the server's does. Past the family's length the game's clip
shows again.

The evaluated pose is applied exactly as an absolute Luanti bone override
with the same numbers would be, after the server's own overrides and
before Goanna's knees, elbows and jiggle bones.

## Feet on the ground

A model with a stroke plan also fits its feet to the ground, whether it
is striking, walking (the game's walking loop) or standing. Each step,
before posing, the animator looks at where each foot was shown last step
and asks the map for the highest walkable collision box under it, within
0.6 of a node of the ground under the model's root (`GroundFrame`, built
by the entity renderer from the map's collision boxes). Each foot's lift
is that difference, eased over about 60 ms. On the global matrices, after
everything else has posed the body, the whole body is lowered by the
lower foot's drop, then each leg (a joint named `leg...` on `body`, its
single child the knee, the knee's the ankle) is bent with a two-bone
solve so the ankle rises by its own lift, the knee staying on the side it
was bent to, and the foot keeping the angle the animation gave it. A
longer chain (a tentacle) rides its further segments on the ankle. The
local player is fitted only while touching the ground; others whenever
there is ground under them.

## Distance

`src/goanna_stroke_detail.h` keeps a crowd cheap. Each sync the entity
renderer puts every body with a stroke plan in one of three tiers, by its
distance from the camera, measured a node above its root, and whether that
point is in the camera's frustum:

| Tier | Where | Stroke | Feet |
| --- | --- | --- | --- |
| Full | on screen within 16 nodes | evaluated every step | ground asked every step |
| Reduced | 16 to 48 nodes, or off screen within 48 | evaluated 15 times a second, interpolated | ground asked 15 times a second |
| Clip | beyond 48 nodes | not evaluated: the game's clip shows | not asked: feet ease back to the clip's |

A body keeps its tier until it is 2 nodes past the boundary, so one
standing on it does not flicker. Your own body is always Full. The
distances and rate are constants in `goanna_stroke_detail.h`, as the jiggle
bones' `JIGGLE_DISTANCE` is; they are not settings.

In Reduced, the stroke is evaluated one interval (1/15 s) ahead of its
clock and the pose shown is interpolated between the last two
evaluations, positions linearly and rotations by slerp, so it does not
step. The feet keep easing every step towards the ground last found.
Going into Clip the stroke pose fades out over the game's animation in a
quarter of a second (smoothstep), and fades back in coming out of it; the
feet ease to no lift over about the same time. Between Full and Reduced
nothing fades: the first Reduced pose is the full evaluation at that
moment.

`status` reports `stroke_bodies_full`, `stroke_bodies_reduced` and
`stroke_bodies_clip` for the last sync, and `stroke_evaluations`, the
evaluator calls since start, beside `stroke_poses`, the poses shown.

## Checks

`goanna_strokes_test` compares the port with the Lua on 144 evaluations of
two bodies (two-bone arms and four-bone tentacle arms), at in-between
angles and at times before commit, in contact and late. The worst
differences are 5e-6 nodes and 5e-4 degrees, the fixtures' own printing
precision. An evaluation takes about 30 microseconds for two-bone arms
and 90 for tentacle arms on the development machine.

`goanna_stroke_detail_test` checks the tiers and their hysteresis, the
fade's length and step, and the Reduced tier against a full evaluation
every step through whole strokes at ten angles, on the same fixtures. Run
31 October 2026 (RelWithDebInfo flags, AMD Ryzen 7 7800X3D, other builds
running on the machine), Reduced's 99th percentile error over every bone
and step is 0.011 nodes and 6.5 degrees for two-bone arms, 0.013 nodes
and 6.8 degrees for tentacle arms, at 13.5 evaluations a second. The worst
single errors are larger (0.13 nodes, 103 degrees) and sit where the full
evaluation itself turns a bone a long way in one step: see "Not done yet".

The same test times a crowd stroking without pause, half two-bone and half
tentacle arms, spread evenly from 2 to 80 nodes away with every fifth off
screen, over 240 steps at 60 a second, best of three runs. Evaluation
only, on one thread; the ground queries are counted, not timed:

| Bodies | Every body full | With tiers (Full/Reduced/Clip) |
| --- | --- | --- |
| 10 | 503 us a step, 10 evaluations | 2/4/4: 154 us, 2.9 evaluations |
| 30 | 1496 us a step, 30 evaluations | 5/13/12: 442 us, 7.9 evaluations |
| 60 | 3008 us a step, 60 evaluations | 10/27/23: 858 us, 16 evaluations |

Bodies asking for the ground fall the same way: 60 a step before, 16.8
with tiers for 60 bodies. How much a crowd saves depends on where it
stands; ten combatants all within 16 nodes and on screen save nothing.

Live, 31 October 2026: DorfCraft's opt-in melee trial on a private
Luanti 5.17.0 server with Mineclonia, a Goanna client (Godot 4.5.1,
software rendering) from this code. The client built evaluators for the
three trial bodies it was shown and evaluated 241 stroke poses over
twelve strokes, and all the server's checks passed (six hits). In a low
resolution recording seen from behind, the body strokes with the sword in
hand and no visibly broken pose; that is all the recording shows.

Feet, 31 October 2026, the same setup with a strip of stone half slabs
under one foot (the player standing on the boundary of two node
columns): 717 steps had a foot fitted, the most any foot moved was 0.5
nodes, the slab's height, and all the server's checks passed. In a low
resolution recording from behind, one foot stands on the slab and the
other leg reaches down past its edge to the floor.

## Not done yet

- No check that the pose Goanna shows matches the server's contact pose
  frame for frame; only the evaluator itself is compared.
- The gait is the game's clip: feet are lifted and lowered to the ground
  but not re-planted, so they slide when the clip's pace and the body's
  speed differ, and a stroke made while walking slides the planted feet.
- Only the ground directly under each foot is consulted; a foot over an
  edge takes whichever surface its centre is over.
- `status` reports `stroke_models`, `stroke_poses`, `stroke_evaluations`,
  the bodies in each distance tier, `feet_fitted_frames` and
  `feet_fitted_most`; there is no per-entity inspection.
- The distance tiers have been measured only offline, on the evaluator
  with the fixtures. No live run with a crowd has been made, the animator's
  own cost (tracks, foot solve, skinning) is not in the numbers, and the
  fade at 48 nodes has not been looked at on screen.
- The evaluator itself is not smooth everywhere: on the two-bone fixture
  body the weapon arm (`arm_right`, its lower arm and hand, and the sword)
  turns a bone more than 30 degrees in one 60th of a second 18 times over
  ten strokes, at most 130 degrees, and the tentacle body 23 times, at
  most 87 degrees, so a near body's arm can snap. In Reduced the
  interpolation spreads such a snap over a fifteenth of a second instead.
- Reduced interpolates with the drag angle as it was at each evaluation,
  so while the angle is still easing (preparing) the pose lags it by up to
  a fifteenth of a second.
