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
knees run 4 to 31 degrees and the elbows 8 to 30.

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
