# Goanna next release (unreleased)

These notes cover the cloud and night-sky changes queued for the next
release.

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

## Checks and limits

The cloud-layer tests and offline production-shader studies passed on
Godot 4.5.1. Night-sky visibility and unchanged-daylight checks passed on
headless software rendering. The final night-sky treatment has not had an
extended live-server day/night cycle check, and GPU performance has not
been measured for these revisions. Sampling budgets are unchanged, but
more enabled cloud layers can add rendering work.

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
