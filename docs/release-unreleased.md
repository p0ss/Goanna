# Goanna next release (unreleased)

These notes cover the cloud and night-sky changes queued for the next
release.

## Changes

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
