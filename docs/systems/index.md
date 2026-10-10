# Systems

How each part of Goanna works today, one subsystem a page. Each page says
what is not done yet. Plans live under [design](../design/index.md) and
dated records under [history](../history/index.md); where a page and the
code disagree, the code is right.

## Terrain

- [Far rendering](far-rendering.md): how terrain beyond the server's live
  range is stored, summarised, reduced and drawn.
- [Prepared terrain storage](terrain-storage.md): the on disk LOD cache and
  its background loader.
- [Terrain surfaces](terrain-surface.md): how coarse terrain is shaped and
  how detail is chosen.
- [Baked terrain](baked-terrain.md) and [forest previews](forest-previews.md):
  distant land and trees straight from a Terrain Diffusion bake.
- [Mesh attributes](mesh-attributes.md): the vertex data every terrain mesh
  carries, near and far.
- [Animated node tiles](node-animation.md): how animated textures advance.

## Materials and surfaces

- [Materials](materials.md): the LabPBR maps Goanna reads, which shader
  draws a tile, gems, mob and item companions and texture expressions.
- [Lava](lava-material.md), [fire](fire-material.md),
  [ice](ice-rendering.md) and [portals](portal-materials.md): the special
  materials.
- [Water optics](water-optics.md): water seen from above and below.
- [Procedural grass](procedural-grass.md): the optional grass volume.

## Light, sky and weather

- [Sky orchestration](sky-orchestration.md): keeping sky, fog, clouds and
  sun consistent through dawn and dusk.
- [Shader weather](weather.md): rain, snow, splashes, ripples and lightning
  drawn by shader.
- [Particle coverage](particle-coverage.md): what a particle spawner can ask
  for and what Goanna draws.

## Graphics settings

- [Graphics tiers](graphics-tiers.md): the five presets and what each one
  sets.
- [Render feature switches](render-feature-switches.md): the twenty
  switches that turn a rendering feature's work off.

## Players and interface

- [First person body](first-person-body.md) and
  [knees, elbows and strokes](limbs.md): the player's own model and how
  block limbed models bend and swim.
- [Interface style](interface-style.md): the dark glass style and game
  theme for menus and server forms.
- [Local multiplayer architecture](local-multiplayer.md): splitscreen
  ownership, input and rendering.
- [Overseer camera](overseer.md): the orthographic planning view DorfCraft
  grants.

## Protocol

- [Protocol coverage](protocol-coverage.md): what the session handles from
  a server and how GDScript reads it.
