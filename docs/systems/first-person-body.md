# The first person body

Goanna draws the local player's own model, so you can look down and see your
torso, your legs and the tool in your hand. The vanilla client does not: it
marks the local player invisible and draws a separate hand and wield item in
a second scene. Drawing the real body is nicer and it is also more fragile,
because the body stands exactly where the camera is and any error in placing
it lands in the middle of the frame rather than somewhere you can ignore.

This is its own document rather than a section of
[protocol coverage](protocol-coverage.md) because almost none of it is
protocol: it is placement, bone posing and shadow casting, and the protocol
parts (the keypress field and the local animations packet) are a line each.
Protocol coverage says what Goanna sends and receives, not how it poses an
arm.

The dated record of the faults reported against the body, their causes and the
fixes is in the [first person body log](../history/first-person-body-log.md).
What is described here was observed against local Mineclonia and Minetest Game
servers (Luanti 5.16.1 and 5.17.0, and a 5.10.0 server for the local animations)
with Godot 4.5.1 on Linux, on the dates the log gives.

## Main files

| File | What it does |
| --- | --- |
| `src/goanna_entities.cpp` | `EntityRenderer::buildMeshVisual` (the shadow copy), the `is_self` blocks in `EntityRenderer::sync` (placement, visibility, arm), `chooseArmBone`, `rebuildVisual` and `modelFor` |
| `src/goanna_models.cpp`, `src/goanna_models.h` | `ModelAnimator::step`: the pose, the head shrink, the shadow skeleton, `setFirstPerson` |
| `src/goanna_mining_cycle.h` | The mining clock that times the arm's stroke against the dig |
| `src/goanna_client_player.cpp` | `GoannaClient::set_player_pose`, the keys reported to the server, `set_show_body` |
| `src/goanna_session.cpp` | `writePlayerPosTo` (the keypress field), `onLocalPlayerAnimations` |
| `src/transplant/client/content_cao.cpp` | Upstream's `setLocalPlayerAnimation` and the local player part of `GenericCAO::step` |
| `project/game/main.gd` | The lean over the body looking down (`_body_lean`), the camera modes and third person placement |

## Where the body stands

The body stands on the local player's position, which is the feet. Every
caller of `GoannaClient::set_player_pose` hands it the camera, which is the
eye, so it sets the player's position an eye height below what it is given;
walking goes through `step_player`, which leaves the feet alone and returns
an eye position the camera is set from. What Goanna reports to the server
is the camera, so block streaming centres on it.

In `EntityRenderer::sync` the body is pinned to the predicted local player
rather than the server interpolated object, so it does not trail the camera.
Its yaw follows the look yaw and its pitch stays level. It stands where the
player stands, with no nudge along the look.

## The head and the shadow

To keep the head out of the camera, `ModelAnimator` collapses the model's
`Head` joint (or lowercase `head` on framed folk) to a hundredth of its
size each step, and any hat layers
attached to it go with it.

The player model is a single skinned `MeshInstance3D` with several surfaces
under one `Skeleton3D`, so per surface `cast_shadow` cannot separate the
head, and camera cull masks cannot either: the head is a bone, not an
object. So the local player gets a second copy of the same mesh on its own
skeleton. `ModelAnimator::step` takes an optional second skeleton and writes
the same pose into it without the shrink; that copy is
`SHADOW_CASTING_SETTING_SHADOWS_ONLY` and the copy the camera sees is
`SHADOW_CASTING_SETTING_OFF`. The shadow therefore has a head. The cost is
one extra skinned draw for one entity.

## Show own body and the camera modes

**Show own body** (`show_body`, in the Graphics settings under Camera; the
environment variable `GOANNA_BODY=0` or `1` sets it at start) hides only the
copy the camera sees. Turning it off leaves a complete shadow to judge the
sun by, which is what a player turning it off wants.

`F7` cycles first person, the view from behind and the view from the front.
Holding Alt and moving the mouse steps out from first person to the view
behind and orbits from there; Alt with the wheel moves the camera in and out
(1 to 2.75 nodes), and in past the closest goes back to first person. The
third person views draw the whole body, head included, whatever Show own body
says (`EntityRenderer::setThirdPerson` turns the head shrink off), as does
the overseer camera. A third person camera pulled in closer than 0.8 nodes
by a wall draws the body as first person does, head shrunk, rather than
showing the inside of the head; it backs off 0.3 nodes from a wall where the
vanilla camera backs off 0.5.

## Looking down

Mineclonia's eye height (1.5) is the model's shoulder line, so a camera
pitched about the eye shows the top of the torso and an open neck looking
down. Instead, with the body shown, the camera leans out over the body as
the gaze drops, 0.45 nodes forward and a little up when looking straight
down (`_body_lean`, `BODY_LEAN_FORWARD` and `BODY_LEAN_DOWN` in `main.gd`),
so it shows the front of the shirt and an arm. Nothing changes looking level
or up, or with the body hidden. The dig ray follows the camera
(`set_view_offset`), as the vanilla client's shootline follows its camera,
so the crosshair still covers what is pointed at.

## The arm

Mineclonia's character model bakes a half turn into the rest of
`Arm_Right_Pitch_Control` and expresses it as a scale of (1, -1, -1), which
is why the game's own animation code carries a table of "bone workaround
scales". Replacing that joint's rotation mirrors the arm and throws away the
pitch the game sets for the held item. So Goanna never replaces the arm's
rotation: it adds to it, in the same euler degrees and the same inverted
storage a Luanti bone override uses, and at rest the arm is exactly where
the model and the server left it.

Which arm is yours is decided by the bone the game hangs the wield item from
(`chooseArmBone`; where a game hangs one off each hand, as Mineclonia does
for the offhand, the one holding something). The pitch control bone is
preferred on each side, since turning it turns the whole arm.

While digging, the mining clock (`src/goanna_mining_cycle.h`) drives one
lift and downstroke per blow, timed so the last blow lands at the dig's tool
time, and the contact pose is the aimed one. A game that aims the
arm itself with a bone override (Mineclonia aims it down the look direction
while the dig button is held) keeps its aim, and Goanna adds only the
stroke. For other interactions Goanna's own swing is a fallback that stands
down whenever the server has a bone override on the arm bone. The swing's
size and how much of the look pitch it follows can be tuned with
`GOANNA_ARM="chop,pitch_follow"` (default `-20,1`), and `GOANNA_DEBUG_ARM`
prints the arm bone chosen. In first person the elbows keep only a quarter
of the walking bend (`FIRST_PERSON_ELBOW`), so the hand and what it holds do
not rise into the view with every step; see [limbs](limbs.md).

## What the server hears

Goanna reports the whole keypress field of TOSERVER_PLAYERPOS, as the
vanilla client does, from `PlayerControl::getKeysPressed`: movement, jump,
aux1, sneak, dig and place. That is what `player:get_player_control()`
reads, so a game that animates the player from it (Mineclonia picks its walk
and mining animations this way) animates the body as it would a vanilla
player's. Sneak reaching the server changes the eye height and the model's
pose on Mineclonia, as it does for a vanilla player.

## The game's own local animations

A game can give the player's own model animations that the client plays from
its own controls: `player:set_local_animation(idle, walk, dig,
walk_while_dig, speed)`, which arrives as TOCLIENT_LOCAL_PLAYER_ANIMATIONS.
The vanilla client plays them whenever it shows the local player's model,
which for it means third person, and does not interrupt them with a server
animation on the first track that uses one of the same frame ranges. Goanna
plays them whenever the body is drawn, through upstream's own
`setLocalPlayerAnimation` and the local player part of `GenericCAO::step`,
with the dig and place buttons recorded in the player's controls as the
vanilla client records them.

Minetest Game's `player_api` sets local animations, so there the body plays
its walk range (frames 168 to 187) while W is held and its dig
range (189 to 198) while digging. Mineclonia sets none, so its body plays
what the server sends.

## A model that fails to load

Goanna has one flat magenta, `Color(0.8, 0.3, 0.8)`, used for an entity
texture that does not resolve. `EntityRenderer::rebuildVisual` falls back to
a capsule sized by the collision box when a model fails to load, tinted with
the first texture, which for the local player would be a capsule round the
camera. Two guards keep that away from the lens:

- `EntityRenderer::modelFor` caches only a successful load, so a lookup that
  ran before the model's media arrived does not condemn that model to the
  placeholder for the session.
- The local player never falls back to the placeholder. It draws nothing
  until the model loads, and the body returns on the next visual version.

If a magenta shape is seen at the hand, `tools/goanna-control set show_body
0` decides it: if the shape goes, it is the body, and if it survives it is
the wield item, which is the same fallback one entity along. The client log
names the cause either way, with "Goanna: could not load model" from
`ModelLoader::load` or "Goanna: mesh not found in media" from
`ModelCache::getMesh`.

## Known limits and open work

- **Looking down, the legs are mostly hidden** by the chest at Mineclonia's
  eye height, even with the lean.
- **The magenta shape at the hand** was reported and has never been
  reproduced; the guards above address the most likely path to it. See the
  log for what was checked.
- **The free flying debug camera.** Whether the body should be drawn under
  it is open. You are not in your body in that mode: the camera has detached
  from the physics and the body follows it around like a ghost. Hiding it
  there would want to be conditional on the camera having detached rather
  than on Show own body, and would want to keep the shadow, so that the
  frame still tells you where the player is.
