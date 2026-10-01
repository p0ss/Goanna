# Goanna next release (unreleased)

These notes cover the cloud, night-sky, water, animation and settings
changes queued for the next release.

## Changes

- **Golden hour on land again.** Since the far field began reaching real
  hills in mid September, the land dimmed while the sun was still white and
  high above a ridge, and was dark by the time the sun turned gold, so
  sunsets never lit the ground. The sun's light on the land now keeps its
  strength until the sun meets the terrain ridge toward it, and turns gold
  as it gets there. Golden hour therefore falls earlier behind hills than
  on open ground. The sky and clouds are unchanged.
- **Third person camera.** `F7` cycles first person, behind the player and
  in front looking back, as the vanilla client does. Holding `Alt` and
  moving the mouse turns the camera around the player without turning the
  player, and steps out of first person into the view behind; `Alt` with
  the mouse wheel brings the camera closer. It goes no further than the
  vanilla client's 2.75 nodes and stops short of walls. The whole body,
  head included, is drawn in third person, and in the front view nothing
  can be dug or placed, as in the vanilla client.
- **Looking down at your own body.** In first person with the body shown,
  looking down leans the view out over the body, so it shows the front of
  the body instead of the inside of the neck.
- **Your body walks.** Goanna now tells the server every key held, as the
  vanilla client does: movement, jump, sneak and aux1 as well as dig and
  place. Games that pick the walk animation from those keys, Mineclonia
  among them, now animate your body when you move, and sneaking reaches the
  server. Digging and placing aim from where the camera actually is,
  including view bob.
- **Sugar cane and plants lit properly.** Sugar cane drew blue grey, near
  black at dusk, beside green grass tinted from the same palette. Plants are
  now lit mostly from above, as the vanilla client lights them, so they show
  their colour.
- **Three menu backgrounds.** The main menu shows one of three new stills
  at random: a coastal village at sunset, a lantern lit street at dusk and
  a lava pool in a birch forest. Each is framed so the menu panel does not
  cover its subject.
- **Clouds at different heights.** Plain blocks, fluffy blocks and regular
  volumetric clouds now use up to three layers, with coverage that varies
  with the weather. Upper layers sit above the regional terrain, including
  high Terrain Diffusion landscapes. Individual block clouds also vary in
  height, width and position. Broader shapes and staggered spacing reduce
  the rows of small tiles, and a traversal fix removes square cut-offs and
  speckled patches. Middle and high layers use four and nine times the low
  layer's horizontal scale, so distant clouds read as larger banks.
- **Choose how many cloud layers to draw.** Advanced, Lighting, Cloud layers
  saves a choice of one, two or three. Lowest and Low graphics profiles use
  one, Medium uses two, and High and Ultra use three. Reduced counts retain
  a layer above high terrain. The setting is separate from cloud style and
  quality, and changing it does not resize the remaining clouds.
- **A more varied night sky.** A fictional galactic band has dark dust
  lanes, subdued nebular colour and stepped relief. Square stars vary in
  colour and brightness, twinkle gently and form four recognisable
  constellations. Three steady points suggest planets, and occasional
  meteors cross the sky. The panorama turns with game time; twilight gains
  blue/violet upper sky and a faint pink arch opposite the sun. Server star
  visibility, tint, scale and daylight settings still apply. Clouds and
  terrain cover the celestial detail. The added panorama is decorative,
  not a real star catalogue, and is omitted from ambient lighting and its
  reflection fallback.
- **Water that reacts to you.** A patch of water round the player now
  keeps what is done to it. Swimming or wading pushes a bow wave ahead and
  leaves a V-shaped wake that curves when you turn. Falling in, bobbing and
  climbing out send rings outward, and holding still leaves the water
  still. Waves meet, reflect off banks and settle. Animals in the same water
  make smaller waves; animals further away keep the simpler rings.
- **Splashes.** Falling or jumping in throws up a crown of droplets, sized
  by how hard you hit the water. Climbing out fast drips, and running or
  swimming through the surface throws spray off your front. Punching or
  digging at the water, including from the bank, splashes where the blow
  lands. Droplets land back on the water as small rings.
- **Sunlight through the ripples.** In direct sun, ripples throw moving
  bright and dark lines (caustics) onto the bed below, and they bend the
  view of the bed, so they show when you look down into clear shallows.
- **Water that fits its place.** Water now reads its surroundings the way a
  player would: a sand, gravel or stone bed is clear like a beach or reef,
  clay and dirt make a lake, river water carries silt, and mud or lily pads
  make a murky brown-green swamp. Clarity and colour ease between them over
  a couple of seconds as you move.
- **Clear shallows, murky depths, one water above and below.** Underwater
  visibility is clear near the surface and murkier with depth, faster in a
  swamp than on a beach. The murk is the same colour deep water shows from
  above. The underside of the surface shows the same waves as the top, with
  the sky visible only through the window straight up, as in real water.
  The murk no longer lingers for a second after you surface.
- **Waves sized to the water.** Background waves scale with the size of the
  water round you. A small pond lies nearly flat under short ripples, and
  the open sea runs longer and higher. The bed no longer sways as much under
  deep water.
- **Cleaner reflections.** Water seen from near its surface no longer has a
  pale white film over the reflected trees. At night, bright bands of sky
  no longer appear down the sides of the screen on water.
- **Knees and elbows.** Player models now bend at the knee and elbow, so
  walking and running lift the feet through and swing the forearms. The
  game's own animations still drive the gait; the bend is added on top, and
  held items stay in the hand. Mineclonia's and Minetest Game's player
  models are supported, including Mineclonia's armour layers; other models
  are drawn as before.
- **Swimming and treading water.** Swimming bodies do the crawl, arms over
  the back and a flutter kick, and a body upright in deep water treads
  water with sculling arms and egg-beater legs. Hands going into the water
  splash and ripple it, and treading laps small rings outward.
- **Fixes.** Changing the graphics preset during play now applies it in
  stages over a few frames instead of all at once, which could hang the GPU
  and freeze the machine on one NVIDIA setup. Sliders apply when released.
  Leaf blocks no longer flicker where two meet. A flashing blue sheet no
  longer appears at dig sites seen from under the water. On Linux, Goanna
  marks itself as the first process to end if memory runs out, so
  Alt+SysRq+F ends just the game if a GPU hang freezes the desktop.

## Checks and limits

The cloud-layer tests and offline production-shader studies passed on
Godot 4.5.1. Night-sky visibility and unchanged-daylight checks passed on
headless software rendering. The final night-sky treatment has not had an
extended live-server day/night cycle check, and GPU performance has not
been measured for these revisions. Sampling budgets are unchanged, but
more enabled cloud layers can add rendering work.

The water changes have native and headless tests (`goanna_ripples_test`,
`goanna_allfaces_test`, and the `ripples`, `water_optics` and `wake`
scripts). The ripples and wakes have been tried in play on the GPU. The
ripple patch and splashes also ran live once on software rendering, with a
player treading water in a scratch Mineclonia world, and logged nothing
wrong; the region optics, underwater colour, caustics, splashes and wave
sizing have not yet been looked at in play on a GPU. Water regions are read
from node names round the player only, so a distant swamp seen from a sandy
beach looks like beach water until you are near it. A step of the ripple
patch costs about 0.2 ms on the CPU. The preset hang was not reproduced, so
staging is a mitigation, not a confirmed fix. See [water
optics](water-optics.md) and the Ripples and Splashes sections of
[weather](weather.md).

Knees, elbows and strokes have a native test on a character built in code
and on the installed Mineclonia and Minetest Game models, checking the
cut, the bends, the strokes and that a held item stays in the hand. In the
same software rendered run the player's own body trod water steadily
through the bobbing at the surface, after two fixes that run found: a
drowned player lying on the bottom no longer does the crawl, and the pose
no longer drops out at the top of each bob. They have not been looked at
on a GPU, and other players and animals have not been seen with them. See
[limbs](limbs.md).

See the [cloud shape comparison](perf/cloud-shapes-2026-09-29/report.md),
[upper cloud comparison](perf/cloud-altitude-2026-09-29/report.md) and
[night-sky study](perf/night-sky-2026-09-29/report.md) for images, test
conditions and remaining limits.

The golden hour, camera, body, key and plant changes were checked on the
RTX 3090 with Godot 4.5.1 against a Luanti 5.17.0 server on a Mineclonia
world (`test_world`): golden hour at a village with a 112 m ridge and in a
birch forest behind a 340 m mountain, the walk animation in third person
while walking, and sugar cane at noon and dusk. Holding `Alt` in first
person to step out has not been tried with a real mouse; the test client
does not capture the pointer. The camera jumps in and out when a wall pulls
it close, as the vanilla camera does.
