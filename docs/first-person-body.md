# The first person body

Goanna draws the local player's own model, so you can look down and see your
torso, your legs and the tool in your hand. The vanilla client does not: it
marks the local player invisible and draws a separate hand and wield item in
a second scene. Drawing the real body is nicer and it is also more fragile,
because the body stands exactly where the camera is and any error in placing
it lands in the middle of the frame rather than somewhere you can ignore.

This is its own document rather than a section of `docs/protocol-coverage.md`
because almost none of it is protocol: it is placement, bone posing and
shadow casting, and the one protocol part (the keypress field) is a single
line. `docs/protocol-coverage.md` should say what Goanna sends and receives,
not how it poses an arm.

The code is `EntityRenderer::buildMeshVisual` and the `is_self` blocks in
`EntityRenderer::sync`, both in `src/goanna_entities.cpp`, with the pose
mathematics in `ModelAnimator::step` in `src/goanna_models.cpp`.

## 2026-08-22, five reported faults, four causes

Observed against a local Mineclonia server (Luanti 5.16.1, world
`goanna_fpbody`, port 30821) with Godot 4.5.1 on Linux, on branch
`first-person-body`. Screenshots were framed by script so the before and
after halves are comparable.

### The body filled the screen, and you were inside it

Reported as a wall of skin at eye height in ordinary screenshots. It is not
the head, and it is not terrain. The cause is that
`GoannaClient::set_player_pose` is handed the camera position and stored it
as the local player's position:

    p->setPosition(luanti * BS);

Every other reader of that value takes it for the feet. The collision box
stands on it, `step_interact` starts the dig ray an eye offset above it, and
the first person body is drawn from it. Setting it to the eye put the body's
feet at eye height, so the legs and waist rose through the lens.

It only shows in fly mode, because that is the only mode that calls
`set_player_pose` every frame; walking goes through `step_player`, which
returns an eye position the camera is set from and leaves the player's feet
alone. That is exactly why every agent hit it: the control channel's `pose`
command turns fly mode on by default, so every scripted screenshot is taken
in the one mode where it breaks.

The fix is to put the feet an eye height below the camera the caller gave
us. Switching fly off no longer jumps the camera up by an eye height either,
and the dig ray in fly mode now starts at the eye rather than 1.6 nodes
above it. What Goanna reports to the server is unchanged, so block streaming
still centres on the camera.

The old workaround, nudging the body 1.2 BS units (0.12 nodes) backwards
along the look yaw to keep the shoulders out of the lens, is gone with it.
It was too small to hide a head and large enough to put your legs and your
shadow twelve centimetres behind your feet.

### The shadow had no head

To keep the head out of the camera, `ModelAnimator` collapses the model's
`Head` joint to a hundredth of its size each step. One skinned mesh cannot
be headless to the camera and whole to the light, so the head left the
shadow pass with it.

The player model is a single skinned `MeshInstance3D` with several surfaces
under one `Skeleton3D`, so per surface `cast_shadow` cannot separate the
head, and camera cull masks cannot either: the head is a bone, not an
object. So the local player now gets a second copy of the same mesh on its
own skeleton. `ModelAnimator::step` takes an optional second skeleton and
writes the same pose into it without the shrink; that copy is
`SHADOW_CASTING_SETTING_SHADOWS_ONLY` and the copy the camera sees is
`SHADOW_CASTING_SETTING_OFF`. The cost is one extra skinned draw for one
entity.

"Show own body" now hides only the copy the camera sees, so turning it off
leaves you a complete shadow to judge the sun by, which is what a player
turning it off actually wants.

### The arm pointed backwards, and was not where the tool was

Two causes, and the second is the interesting one.

Goanna posed the arm with an absolute euler of its own on
`Arm_Right_Pitch_Control`. Mineclonia's character model bakes a half turn
into that joint's rest and expresses it as a scale of (1, -1, -1), which is
why the game's own animation code carries a table of "bone workaround
scales". Replacing the joint's rotation while leaving that scale alone
mirrors the arm. It also threw away the pitch the game itself sets on that
bone for the held item, every step, which was already correct.

So Goanna no longer replaces the arm's rotation. It adds to it, in the same
euler degrees and the same inverted storage a Luanti bone override uses, and
only while the swing is running, so at rest the arm is exactly where the
model and the server left it. Which arm is yours is now decided by the bone
the game hangs the wield item from rather than by which arm projects to the
camera's right, which was a guess that only held for models laid out the way
Luanti's character is.

The second cause is that Goanna never told the server it was digging.
`GoannaSession::writePlayerPosTo` sent the keypress field of
TOSERVER_PLAYERPOS as a hardcoded zero, so no game ever saw the local
player's dig button down, and no game ever played its mining animation on
the body. Mineclonia switches to its `mine` animation and aims the arm down
the look direction while that button is held, and none of that reached us.
Goanna now reports the dig and place bits, which is what a vanilla client
sends and what `player:get_player_control()` reads. Movement and sneak are
still not reported.

With the game driving the arm during a dig, Goanna's own swing would only
overshoot, so it stands down whenever the server has a bone override on the
arm bone. It stays as the fallback for a game that never touches it.

Confirmed by reading the animation frame while digging: the local player's
frame goes from about 3 (standing) to about 193 (mining) while the button is
held and back to 3 when it is released.

## The magenta shape at the hand

Reported separately, and not reproduced here: a large flat magenta shape
where the hand and wield item are drawn, in one case filling the upper half
of the frame after a teleport. It was not seen in any of the forty odd
frames captured for this work, before or after, including at (3000, 90,
3000) on a freshly generated Mineclonia world, and a pixel scan of all of
them found no magenta at all.

What can be said from the code is that Goanna has exactly one flat magenta,
`Color(0.8, 0.3, 0.8)` in `EntityRenderer::materialForTexture`, used when a
texture name does not resolve. It is an entity colour, so the shape is an
entity, and the two entities at your hand are your own body and the wield
item attached to its `Wield_Item` bone. Luanti's own `unknown_node.png` is a
checkerboard, so a clean shaded magenta face is not that.

The most likely path to it is the placeholder in
`EntityRenderer::rebuildVisual`: a model that fails to load falls back to a
capsule sized by the entity's collision box, tinted with its first texture,
and if that texture does not resolve either the capsule is magenta. For the
local player that capsule is your own collision box, so the camera is inside
it, and before the placement fix above its feet were at the eye in fly mode,
which would put a magenta wall across the upper half of the frame. That is
the third report exactly.

Two guards are in place now. `EntityRenderer::modelFor` no longer caches a
failed load, so one lookup that ran before the model's media arrived cannot
condemn that model to the placeholder for the whole session. And the local
player no longer falls back to the placeholder at all: nothing is better
than a magenta capsule around the camera, and the body returns on the next
visual version once the model loads.

If it recurs, `tools/goanna-control set show_body 0` decides it: if the
shape goes, it is the body, and if it survives it is the wield item, which
is the same fallback one entity along. The client log names the cause
either way, with "Goanna: could not load model" from `ModelLoader::load` or
"Goanna: mesh not found in media" from `ModelCache::getMesh`.

## What is still wrong

Looking straight down, your own torso and the top of your arms fill the
lower half of the frame. That is what a body at the camera looks like and
every first person body does it, but the neck is an open hole because the
head is shrunk rather than removed, and you can see into it.

The swing is smaller than a vanilla client's, because a vanilla client also
gets the server's mining animation from the moment the button goes down,
while Goanna's own swing only fires when the game leaves the arm bone alone.
On Mineclonia the game does drive it, so this only shows on games that do
not.

Goanna still reports no movement or sneak keys, so a game cannot see the
local player walking or sneaking from the keypress field. Sneak in
particular changes eye height and player properties on Mineclonia, so
sending it is a behaviour change rather than a rendering fix and was left
out of this work.

Whether the body should be drawn at all under the free flying debug camera
is open. You are not in your body in that mode: the camera has detached from
the physics and the body follows it around like a ghost. Hiding it there
would want to be conditional on the camera having detached rather than on
the "Show own body" setting, and would want to keep the shadow, so that the
frame still tells you where the player is.
