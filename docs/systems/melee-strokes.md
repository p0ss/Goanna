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

## Checks

`goanna_strokes_test` compares the port with the Lua on 144 evaluations of
two bodies (two-bone arms and four-bone tentacle arms), at in-between
angles and at times before commit, in contact and late. The worst
differences are 5e-6 nodes and 5e-4 degrees, the fixtures' own printing
precision. An evaluation takes about 30 microseconds for two-bone arms
and 90 for tentacle arms on the development machine.

Live, 31 October 2026: DorfCraft's opt-in melee trial on a private
Luanti 5.17.0 server with Mineclonia, a Goanna client (Godot 4.5.1,
software rendering) from this code. The client built evaluators for the
three trial bodies it was shown and evaluated 241 stroke poses over
twelve strokes, and all the server's checks passed (six hits). In a low
resolution recording seen from behind, the body strokes with the sword in
hand and no visibly broken pose; that is all the recording shows.

## Not done yet

- No check that the pose Goanna shows matches the server's contact pose
  frame for frame; only the evaluator itself is compared.
- Legs are planted on flat ground under the body; they are not fitted to
  steps, and a stroke made while walking slides the feet.
- `status` reports `stroke_models` and `stroke_poses`; there is no
  per-entity inspection.
- Every family and plan is evaluated in full each frame for every body in
  view; there is no distance cut-off yet.
