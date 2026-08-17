# Plan for materials and shading

Written after a day of per texture work that did not add up, to say where
this actually stands and what order the remaining work goes in.

## Where it stands, measured

Not claimed, measured, with the instruments named at the end.

- **Coverage is 20 per cent.** In the Mineclonia jungle, 294 of 1442 texture
  layers load an authored companion. The other 80 per cent get a neutral
  fallback: flat normal, roughness 1.0, no emission. They are featureless
  matte by construction, and no amount of mapping work moves that much.
- **The decode is correct**, case by case, against a differential probe:
  roughness within 1 of Godot's own material at 8 bit, metalness within 2.6,
  emission at 0.0525 linear where the arithmetic wants 0.0542.
- **One real decode bug was found and fixed**: Godot defines
  `F0 = 0.08 * SPECULAR`, and we passed LabPBR's F0 through doubled, so the
  standard dielectric byte became an F0 of 0.006 rather than 0.04. Dielectric
  specular was effectively off.
- **The exposure is wrong.** Mineclonia's snow texture has a standard
  deviation of 8.0 and renders at 0.2 with 99 per cent of its pixels at pure
  white. Vertical faces are lit almost entirely by sky ambient, so a dirt
  side reads 193,194,211, blue rather than brown.

So the material path works and almost nothing is plugged into it, in a
lighting environment that would hide it if it were.

## Why the pack matching approach caps out

The maps pair a Minecraft pack against a Luanti game by texture name. That
is worth having and it is finished: 155 pairs for Mineclonia, 154 for
VoxeLibre, 65 for Asuna, 32 for Minetest Game.

It cannot go much further. The pack holds 434 blocks and Mineclonia has
3245 textures, and the shortfall is not a naming problem. Most of what is
missing does not exist in Minecraft at all: the flowers, the mob drops, the
decorative variants, everything a Luanti game adds. No Minecraft pack will
ever cover them, and a better matcher does not change that.

The conclusion is structural. **Authored data has to be an override on top
of something that covers everything, not the only source of material.**

## The order of work

### 1. A standalone pipeline scene

Develop the pipeline outside the game. A material chart: one row per
material class, one column per lighting condition, each cell a node sized
cube, rendered with reference values printed alongside. Fixed camera, fixed
lights, no world.

The jungle is the worst place to develop this. It has no repeatable
viewpoint, its lighting changes under you, and the effects being judged are
small. Every wrong conclusion recorded in this repository's history came
from trying to read one of those frames.

Done when the chart renders, its numbers are logged, and a change to the
shader shows up as a number rather than an impression.

### 2. A material for every node

Derive a material for every node from what the server already sends, and let
authored maps override it where they exist.

Luanti gives us more than we use. `groups` (cracky, crumbly, snappy,
oddly_breakable_by_hand) separate stone from soil from plant from glass.
`sound_footstep` is a strong material classifier on its own. Add `drawtype`,
`liquid_viscosity`, `light_source`, `damage_per_second`, and a small table of
material classes covers every node in every game, including the ones no pack
will ever ship.

Relief comes from the diffuse texture, which we already infer and which
already covers everything. That generator currently only feeds
`StandardMaterial3D`, so it has to move onto the array path where the rest of
the materials live.

Done when the coverage number reads 100 per cent for class and relief, with
the 20 per cent authored data overriding cleanly on top.

### 3. Lighting and exposure

None of the above is visible until this is right, and it is a rework rather
than a tuning pass: the balance between sun, sky ambient and global
illumination, the tonemap and its white point, specular anti aliasing, and
the sky ambient that turns every vertical face blue.

Done when the chart's classes are told apart at three times of day, snow
keeps its texture, and clipping outside the sky stays in single figures.

### 4. The audit

Per game and per node: the class assigned, whether authored data exists,
and a rendered swatch. A table, generated, over every registered node.

Done when we can point at a row rather than at a screenshot.

## What we are not doing

Porting Iris. Iris loads Minecraft's shader pipeline for Minecraft's
renderer; we have Godot's. What that world has that we want is the LabPBR
convention, which costs a decode and is done, and a handful of techniques
worth reimplementing against Godot. Its licence is LGPL-3.0, which would
also move this project off LGPL-2.1-or-later and away from Luanti.

## Instruments

Build these before trusting any result, because each was written after a
wrong conclusion that it would have caught.

- `project/material_probe.tscn` renders each material case twice, once
  through our shader and once through Godot's own, with everything else off.
  Any difference is ours. It found the specular bug.
- `project/tangent_probe.tscn` answers "does Godot do X" offline, by
  measurement rather than argument. It showed Godot derives a tangent basis
  when a mesh has none.
- `tools/shotcheck.py` says what is actually in a frame, and whether two
  frames share a viewpoint. A shot taken before the world streams in is a
  photograph of the sky and looks exactly like a render with the feature
  under test switched off.
- `tools/goanna_pbr_gallery.lua` builds 23 materials in open sky, as walls
  and floor patches, which is where materials get judged.
- `GOANNA_TP="x,y,z"` teleports through the server, so a viewpoint repeats
  between runs and an A/B means something.
- `GOANNA_DEBUG_PBR=1` reports the coverage above, per array.
