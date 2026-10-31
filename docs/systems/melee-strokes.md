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

A model with a stroke plan whose legs can be planned plans its steps
(next section). Any other model with a stroke plan (a tentacle lower
body, say) only fits its feet to the ground, whether it is striking,
walking (the game's walking loop) or standing. Each step,
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

## Planned steps

A body walking on the game's clip slides its feet whenever the clip's pace
and the body's speed differ, and a stroke made while walking slides the
planted feet. A model with a stroke plan whose every leg is a two-bone
chain (a joint named `leg...` on `body`, its knee, its ankle and at most a
toe) instead plans where each foot stands (`src/goanna_steps.h`,
`ModelAnimator::ownPelvis`, `planSteps` and `applySteps`). The planner is
plain C++ with no Godot types, so `goanna_steps_test` drives it offline.
The server is not involved: hits use only the blade, so the legs are
presentation, and a stock client still plays the clip.

### Who owns what

The legs own the pelvis (the maintainer's ruling, 31 October 2026). The
planner sets the pelvis's place, its height for stepping up and down, and
its base turn; the look and the stroke own everything from the chest up.
Each step the animator puts the pelvis back to its bind under the root
and keeps what the clip or the stroke gave it only as requests: its turn,
bounded to 15 degrees, and its drop below the bind, passed to the planner
as a crouch, honoured up to 0.2 leg lengths. The chest (the pelvis's
child named `chest`, else every child that is not a leg) is turned back
by whatever the pelvis was refused, so the chest, arms and blade keep the
pose's turn; the chest's place follows the planner's pelvis.

### Rest places and when a foot steps

Each leg has a rest place: where its sole would stand if the body stood
still as it is now. Standing or walking it is the leg's bind ankle under
the root; while a stroke is shown it is where the stroke's leg pose puts
the ankle, so the feet take the stroke's stance by stepping into it. The
planner tracks each rest place's velocity (the body's motion and its
turning together, eased over 80 ms), so a foot does not need the body's
facing or a turn rate to know where it is going.

A planted foot stays fixed in the world. It wants to step when:

- it is behind its rest place, along that place's motion, by more than
  half the stride threshold, or strays from it by more than the whole
  threshold in any direction;
- it points more than 0.9 radians away from the body's facing (turning
  on the spot);
- the body has been still for 0.15 s and the foot is more than 0.06 nodes
  (or 6% of the leg) from rest, or turned more than 0.35 radians: one
  settling step at a time, so a body that stops squares its feet;
- it is forced: out of the leg's reach, or the ground under it is gone.

### Gait from speed

For a leg L long whose rest place moves at speed v, with k = sqrt(L/0.8):

- the stride (how far a foot travels in one cycle) is L (0.6 + 0.6 v/k),
  between 0.3 L and 2.2 L;
- the swing takes 0.4 of the stride's time, between 0.14 k and 0.36 k
  seconds;
- the threshold is the stride less what the body covers during the
  swing, at most 0.7 L: a foot lands half the threshold ahead of its rest
  place and lifts half behind, never more than 0.35 L either way, so the
  hip still reaches it; past that a faster body steps more often, not
  further;
- the swing is shortened, to no less than 50 ms, so a stance lasts as long
  as the other groups' swings.

### Alternation and any number of legs

Legs are put in gait groups: each side ordered front to back, alternating
along a side and across. That gives a biped's two legs, a quadruped's
diagonal pairs (a trot) and a hexapod's tripods. Legs of one group step
together; a group may lift only when no other group is in the air and
every other group has been down for its share of the cycle (the cycle
over the number of groups, less a swing, 40 to 250 ms). That share is
what makes a biped alternate evenly rather than limp: after a start from
standing the second foot waits until half a cycle has passed. The
waiting foot with the greatest need goes first. A foot that must step
but waits on a swinging one hurries that swing, up to four times as fast,
never landing in under two frames.

### Swing and landing

A lifted foot aims where its rest place will be when it lands, plus half
the threshold ahead along the rest place's motion; it re-aims every frame
until 70% of the swing, so a turn or a change of pace mid-step still
lands right. Its path is a smoothstep across, rising early onto a higher
foothold and falling late to a lower one, with a lift of 0.15 L plus a
tenth of the step's length (0.04 to 0.3 nodes), raised further over
anything higher on the way. The foot turns from its old heading to the
body's heading at landing (the turn rate carried on).

A foothold is the highest walkable surface under the aimed point, from
0.6 nodes above the root to 0.8 below (the same map query as the
fitting), and must be reachable: within 0.97 L of the hip across, and no
further below the hip than the leg reaches with the body lowered its
most. If it is not, the planner tries the point a quarter at a time
nearer the hip, then nearer the body's centre (a hip can be over an edge
the body is not), and counts the landing as rejected. If nothing serves,
the foot hangs under its hip at the root's height and counts as
unreachable, and it steps as soon as there is a foothold.

### The body's height

The body is never drawn above where the server has it. It is lowered,
eased over 80 ms, to stand on the lowest planted (or landing) foot plus
any crouch the pose asked for, and at once as far as any planted foot
needs to stay within 0.97 of its leg's reach. It is never lowered more
than 0.6 L below standing on its lowest planted foot. So when the root
jumps up a slab the body stays where it was until the trailing foot
follows, and while walking it dips a little as each foot is furthest
from its hip. The pelvis also turns half way towards where the feet
point, at most 0.5 radians, so a body turning on the spot twists at the
hips before its feet catch up; the chest is turned back by the same.

### Posing the legs

On the global matrices, after everything else has posed the body: the
whole body is lowered by the planner's drop and the pelvis twisted. Each
leg is put back to its bind under the pelvis (the clip's leg motion is
dropped), then solved with the same two-bone solve as the fitting to the
planned ankle (the sole plus the bind ankle's height), the knee bent
forward, between the body's facing and the foot's. The foot is set flat,
turned to the planner's heading for it.

### Bodies it cannot plan for

A body with no `body` joint or no `leg...` chains gets nothing; one with
a leg longer than two bones and a toe (a tentacle lower body) keeps the
fitting of the section above, which slides. A leg with no foothold hangs.
A body in the air (the local player not touching the ground) hangs its
feet under the hips and plants them afresh on landing; a jump of more
than two nodes in a frame (a teleport) plants them afresh at rest.

### The evaluator contract

Today the stroke family authors the pelvis: each sample's `pelvis`
rotation and `drop` (DorfCraft's `evaluate.lua`, layer
`pelvis = {q = s.pelvis, p = rest + drop * hip}`; Goanna's port in
`src/goanna_strokes.cpp` does the same), and the evaluator plants the legs
itself at a fixed stance (`leg_left` {-0.1, 0, -0.2}, `leg_right`
{0.1, 0, 0.2} hip heights). Goanna now treats those as requests, as
above, without changing the evaluator. The change proposed for both
sides, to be made by the coordinating session:

- `pelvis` (rotation) becomes a request, `pelvis_turn`, bounded by the
  consumer (Goanna takes 15 degrees; the family asks up to 52).
- `drop` becomes a request, `crouch`: its y only, in hip heights, bounded
  by the consumer (Goanna takes 0.2 leg lengths). Its x and z go: the
  pelvis's place is the legs'.
- The chest and everything above it are evaluated against the pelvis
  the legs give, not the authored one, so the server's blade contact is
  computed against the same chest the client draws.
- The fixed leg stance becomes a stance request (each foot's place,
  in hip heights from its bind), and the legs leave the evaluator's
  output: the planner steps the feet there.

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

Feet, 31 October 2026, the same setup with a strip of stone half slabs
under one foot (the player standing on the boundary of two node
columns): 717 steps had a foot fitted, the most any foot moved was 0.5
nodes, the slab's height, and all the server's checks passed. In a low
resolution recording from behind, one foot stands on the slab and the
other leg reaches down past its edge to the floor.

Planned steps, offline: `goanna_steps_test` drives the planner over
DorfCraft's `strokes/stance_fixture.lua` terrain and path (a floor and a
half slab across the path; stand, walk over the slab, turn a quarter
left and back, stroke at the slab's edge, strafe, back away, stand), with
1.5 s more standing at the end. The root steps up and down the slab at
once, as that fixture's physics does. The stroke's stance and crouch come
from the 45 degree stroke of `tools/test/strokes/family.json`. Bodies:
the fixture's reference biped (leg 0.81 nodes), a small stocky biped
(leg 0.47, made up for the test) and a trotting quadruped (legs 0.55,
made up), each at the fixture's pace (1.4 nodes a second walking) and at
4.2 (about Mineclonia's walk), at 60 and 20 frames a second. Run on
31 October 2026:

| Body | Pace | fps | Steps | Settling | Forced | Rejected | Unreachable | Frames out of reach | Worst, nodes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| reference biped | 1.4 | 60 | 19 | 3 | 0 | 4 | 0 | 0 | 0 |
| reference biped | 1.4 | 20 | 20 | 3 | 8 | 5 | 0 | 0 | 0 |
| reference biped | 4.2 | 60 | 18 | 3 | 12 | 5 | 0 | 0 | 0 |
| reference biped | 4.2 | 20 | 18 | 3 | 10 | 3 | 0 | 3 | 0.189 |
| small stocky biped | 1.4 | 60 | 28 | 3 | 11 | 5 | 0 | 2 | 0.029 |
| small stocky biped | 1.4 | 20 | 29 | 2 | 19 | 5 | 0 | 0 | 0 |
| small stocky biped | 4.2 | 60 | 27 | 2 | 21 | 7 | 0 | 6 | 0.093 |
| small stocky biped | 4.2 | 20 | 24 | 2 | 17 | 3 | 0 | 7 | 0.162 |
| quadruped | 1.4 | 60 | 62 | 5 | 12 | 20 | 0 | 36 | 0.141 |
| quadruped | 1.4 | 20 | 67 | 3 | 33 | 21 | 0 | 23 | 0.177 |
| quadruped | 4.2 | 60 | 60 | 2 | 35 | 19 | 0 | 27 | 0.255 |
| quadruped | 4.2 | 20 | 53 | 3 | 29 | 14 | 0 | 8 | 0.294 |

In every run a planted foot never moved (slide 0 by construction), every
planted foot stood on the terrain under it, every landing found a
foothold, some foot was always planted, no foot stepped once the body had
stood settled for a second, and the pelvis twisted at most 23 degrees.
"Out of reach" is a planted foot further from its hip than the leg is
long with the body lowered as far as it may go: the leg falls short and
the foot shows as sliding by that much. The test fails if a biped at 60
fps is out of reach by more than 0.03 nodes at the fixture's pace or 0.1
at 4.2; the 20 fps and quadruped runs are reported only. The misses are:
the first steps from standing straight into 4.2 nodes a second (the
script's velocity jumps at once), the small stocky body backing off the
slab's edge, frames too coarse at 20 fps for a swing as short as the pace
needs, and the quadruped straddling the slab's edge, where its hind feet
are refused the floor half a node down and crowd under the body. The
stroke family asks the pelvis for a drop of 0.069 to 0.134 hip heights
(the 45 degree stroke) and a turn of up to 52 degrees (any stroke).

Planned steps, live, 31 October 2026: DorfCraft's melee trial job (its
probe from `strokes/submit_trial.py`, the slab strip under one foot) on a
private Luanti 5.17.0 server with Mineclonia, a Goanna client from this
code (Godot 4.5.1, software rendering, llvmpipe), with walking added to
the script: forward and back 1.5 s each, left and right 1 s each, forward
0.8 s twice between strokes and back 1.2 s at the end, around twelve
strokes. The job passed, so the server's checks passed. The client built
evaluators for three bodies, evaluated 202 stroke poses and landed 58
planned steps (22 of them in the walking before the first stroke), with
no landing short of a foothold; the furthest a planted foot was out of
reach was 0.081 nodes. No recording was made: nothing here shows that the
knees bend the right way, that the feet point the right way or that the
gait looks right, only that the planner ran on the trial bodies without
losing a foothold.

## Not done yet

- Planned steps are checked offline only for the planner; the posing
  (pelvis ownership, the leg solve, the knee's side, the foot's turn) has
  no offline check, and the live run above made no recording, so how
  it looks is unseen.
- Quadrupeds and hexapods are grouped and planned by the same code but
  only the made-up quadruped in the offline test has run; no body in the
  game has four planned legs yet, and on a slab's edge it is out of reach
  for whole stretches. Tentacle lower bodies are not planned (they keep
  the fitting, which slides).
- A planted foot is flat and keeps no heel or toe roll; a swinging foot
  does not pitch. Feet do not follow a slope.
- A foot over an edge takes the surface its centre is over; the foot's
  length is not checked against the edge.
- The stroke's pelvis turn and crouch are taken as bounded requests on
  Goanna's side only; the server's evaluator still uses the authored
  pelvis for its blade contact, so the drawn chest can differ from the
  server's by the refused part (see "The evaluator contract").
- Steps are planned from where the renderer draws the body, which for
  other players is the interpolated position; a lagging or jumpy position
  shows as hurried steps.

- No check that the pose Goanna shows matches the server's contact pose
  frame for frame; only the evaluator itself is compared.
- Bodies that are not planned (a tentacle lower body) keep the game's
  clip with their feet only fitted to the ground, so they slide.
- Only the ground directly under each foot is consulted; a foot over an
  edge takes whichever surface its centre is over.
- `status` reports `stroke_models`, `stroke_poses`,
  `feet_fitted_frames`, `feet_fitted_most`, `steps_planned`,
  `steps_unreachable` and `steps_stretch_most`; there is no per-entity
  inspection.
- Every family and plan is evaluated in full each frame for every body in
  view; there is no distance cut-off yet.
