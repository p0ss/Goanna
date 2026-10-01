# Knees, elbows and strokes

Block-limbed player models bend at the knee and elbow, and bodies in the
water swim and tread water. `src/goanna_limbs.h` has the geometry and the
poses; `ModelAnimator` (`src/goanna_models.cpp`) drives them;
`EntityRenderer` (`src/goanna_entities.cpp`) decides what each body is doing
in the water; `project/ui/wake.gd` turns strokes into ripples and splashes.

## The model

Minetest Game's `character.b3d` has each arm and leg as one box; Mineclonia's
`mcl_armor_character.b3d` as two or three nested boxes (skin, sleeve or
trousers, armour), each rigidly on its limb's joint and with no vertices
between its ends, so a limb can only swing at the shoulder or hip.

When such a model is converted for Godot (`buildGodotModel`), `findLimbs`
finds `Arm_Left`, `Arm_Right`, `Leg_Left` and `Leg_Right` by name (both games
use them) and `splitLimbs` cuts each limb's triangles at mid height:

- Each box is cut at its own middle, which on a 12 pixel limb is the 6
  pixel line, so the skin stays pixel exact. Mineclonia's armour boxes are
  inflated unevenly round the limb, so one height for all of them landed
  off the pixel line on the outer ones.
- A box that crosses the knee by less than about half a pixel (Mineclonia's
  boots, whose top edge is a twentieth of a pixel over it) is not cut: it
  goes whole to the side it is on.
- A box that covers only part of the limb is cut at the knee, not at its
  own middle.
- New vertices on the cut take position, normal and texture coordinate
  interpolated along the edge they cut, shared by the triangles either side.

The half below the cut goes to a Godot bone of Goanna's own and the cut
itself to a second one; Luanti's joints, keyframes and bone overrides are
untouched. The lower bone's pose is the limb's skin times a turn about the
cut (`bendTransform`), and the seam bone's is half that turn, so a bent
joint closes as a mitre: the cut lies on the plane halving the angle, with
no gap outside, nothing through inside, and the joint as thick as at rest.
Weighting the seam half to each side, the usual blend, pinched it to 71 per
cent of its width at a right angle.

Joints under a limb and below its cut (Mineclonia's `Wield_Item` and
`Hand_Right`) follow the bend (`ModelAnimator::bentGlobal`), so a held item
stays in the hand; so do rigidly attached parts.

A model without the names, or whose limbs are not upright boxes at rest,
is drawn as before.

## Walking and running

The game still plays its own animation and decides the gait. Each step the
animator measures each limb's swing forward of hanging straight, relative
to the body, and how fast it is changing, and bends from that
(`walkBend`): a knee bends as its leg swings forward, most at the fastest
of the swing (the foot lifting to come through), up to 75 degrees, with 4
degrees of give otherwise; an elbow bends as its arm comes forward and
hangs 8 degrees bent at rest. An arm the game is aiming (a bone override on
it) or Goanna's first-person swing is moving keeps a nearly straight elbow.
Bends ease over about 60 ms. On the test character's 40 degree walk the
knees run 4 to 31 degrees and the elbows 8 to 30. Seen from the eye (the local
player's body in first person) the elbows keep only a quarter of their
walking bend, up to 7 degrees: the arms swing in front of the lens, and the
full bend lifted the hand and whatever it held into the view at every step.

## Moving

Each sync the renderer tells the animator how the body is moving
(`BodyMotion`): its height, speed across, speed up, acceleration and turning
rate, and whether it is on the ground. The local player from its own
physics; others from how their positions change, eased, with the map saying
whether there is ground under them. On top of the game's animation:

- **Landing.** Touching down after falling at more than 1.5 nodes a second
  crouches the body, hips forward and knees bent, deeper the harder the
  landing (`landDepth`, the full crouch from 11 nodes a second: 50 degrees
  at the hip, 85 at the knee), coming in over about 40 ms and gone in half a
  second. The arms come forward for balance. The whole body is lowered by
  exactly what the bent legs lose in height (`legShortening`), so the feet
  stay on the ground: in the test a hard landing bends the knees 62 degrees
  and lowers the body 0.81 units while the feet stay within 0.09 of where
  they stood. A step down off one node is a small one, 21 degrees. The
  movement bends go on top of the eased walk bend, not through it, and the
  game's swing is measured without them: eased, the knee bent behind the
  drop and the feet sank; measured with them, the crouch's own hip flex
  bent the knee again.
- **Falling.** Falling faster than 5 nodes a second for a fifth of a second
  puts the arms out to the sides and loosens the legs, flailing more the
  longer the fall. Landing ends it at once.
- **Stepping up.** A quick rise of a quarter to a whole node while staying
  on the ground lifts the leg further forward, hip and knee, for about a
  third of a second.
- **Climbing.** On a ladder or vine (the local player's `is_climbing`, or a
  climbable node at the body's middle), out of the water: hand over hand,
  each arm reaching overhead in turn, the knee opposite coming up for the
  next rung, one reach of each hand for every 0.9 nodes climbed, and still
  while the body holds on in place.
- **Leaning.** On the ground and out of the water, the whole body pivots at
  the feet: forward into a start and back into a stop (1.6 degrees for each
  node a second squared, to 9), forward when running, and banked into a turn
  by how hard it is turning at its speed (to 12). Not seen from the eye,
  where it would only move the body under the camera.

## In the water

`EntityRenderer` gives each body with limbs a water pose each sync:

- **Swimming** while it is in water, alive, and the game has its body lying
  down (Mineclonia's swim pose: its `Body` up axis nearer level than
  upright), provided it is off the bottom or moving. A drowned player lies
  on the bottom in the die animation, and was seen doing the crawl there.
- **Treading water** while it is in water, upright, with nothing under its
  feet, and holding its place.
- **The breaststroke** while it is upright in water with nothing under its
  feet and moving faster than 0.6 nodes a second: how Mineclonia has a
  player go through deep water when not sprinting. Mineclonia's swim pose
  (frames 368 to 434 lay the body flat) comes only with sprinting.
- The local player from its own physics (`in_liquid`, `touching_ground`,
  health), others from the map at their chest and under their feet.
- A pose holds 0.8 seconds past the last moment it applied: holding jump in
  water bobs a body at the surface, out of the water at the top of each bob,
  and live the pose dropped out every bob.

While swimming or treading, Goanna drives the shoulders and hips as well,
which the game's poses hold nearly still, blending over the game's own
rotation as the pose eases in over a quarter of a second (`strokeAngles`):

- **The crawl.** Each arm turns backward all the way round: from the hip
  over the back, elbow high and bent, to reach past the head, then pulls
  under the chest nearly straight. The arms are half a stroke apart. The
  legs flutter from the hip three beats a stroke, opposite, knees giving on
  the down beat. The stroke rate rises with speed.
- **Treading water.** Arms out and forward, sculling in and out together with
  the elbows bent; the egg-beater with the legs, thighs forward and apart,
  each knee circling, half a cycle apart.
- **The breaststroke.** Both arms together reach forward, sweep out and back
  with the elbows bending, and come in to reach again; half a stroke later
  the legs draw the knees up and out and kick back straight.

Which way a turn about a limb joint's own axes swings its end is found by
trying one on the rest pose (`probeLimbSigns`): Mineclonia's right arm's
pitch control carries a scale flip, and the same local turn swings one arm
forward and the other back.

## Into the water

`entity_list` carries each body's hands and feet in the world and its water
pose. `EntityRenderer` also records, each step, every hand or foot of a body
in water that goes into or out of it, with its speed
(`GoannaClient.take_stroke_events`). `wake.gd`, for bodies on the ripple
patch: a hand going in kicks the patch and throws a small crown, coming out
flicks a few drops, a foot breaking the surface does the same softer, all
by the limb's speed. (Hands sculling just under the surface also kicked the
patch at every sample for a while; in step ten times a second, the kicks
set up a standing wave against a nearby shore, and they were taken out:
treading water makes its rings by the body's own rise and fall.)

## Tests

`goanna_limbs_test` (native, in the `check` target) builds a character in
code the shape of Minetest Game's, with a walk, and checks: the four limbs
found and cut at mid height; no triangle joining the halves, both halves
and the seam on their bones, the seam on a pixel line; a knee bending the
foot back and an elbow the hand forward, about the joint, the seam keeping
the joint's thickness; walking bends in range; the crawl's arms going round
backward over the back, half a stroke apart, both the same way; treading
spreading the arms and bending the knees; a held item staying with the
hand; and the strokes easing away out of the water. Where Mineclonia's and
Minetest Game's own models are installed (the Luanti flatpak's games
folder) they are loaded and checked too. `project/tests/ripples.gd` checks
the strokes reaching the water.

Checked live once, headless on software rendering against a scratch
Mineclonia world: the local body's hands and feet were where they should be
standing; teleported into water three deep and holding jump, it trod water
steadily through the bobbing, the patch rippled and splashes were thrown,
and nothing was logged. Not yet looked at on a GPU.
