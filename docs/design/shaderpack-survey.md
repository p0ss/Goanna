# Survey of popular shader packs

A look inside 22 of the most downloaded Iris and OptiFine shader packs, to
decide what Goanna's shader pack support should do next. It sits beside
[Iris shader packs](iris-compat.md), which explains the pipeline, the rungs
and the limits this page refers to. Nothing here was run: every figure comes
from reading the packs' files, and none of it says a pack works in Goanna.

## Method

Read on 11 October 2026.

- **Popularity.** Modrinth download counts come from its public API
  (`api.modrinth.com/v2`, search sorted by downloads, and each project's
  record). CurseForge counts come from its search pages, which show them
  rounded to one decimal place in millions. The two are added. A download
  is not a player, both sites count updates, and the figures favour packs
  that have been around longer, so treat them as a ranking rather than a
  measurement.
- **Selection.** The top of both lists, plus the packs named in the brief
  that rank lower (Kappa, Nostalgia, Miniature, Noble, Shrimple, Eclipse,
  Base-Shader). Spooklementary, Hysteria, Pastel and Potato rank high on
  downloads and were left out as seasonal or close variants of packs that
  are in.
- **Source.** For every pack except SEUS, the latest release zip from
  Modrinth (Chocapic13 from CurseForge, which is its only host), not a
  repository head. The version read is in the table. The zips were read
  in place with Python's `zipfile` from a separate directory and nothing
  in them was run.
- **Detection.** A script listed the program files by name (`gbuffers_*`,
  `shadow*`, `deferred*`, `composite*`, `final`, `prepare*`, `begin*`,
  `setup*`, `dh_*`) across every dimension folder, and expanded each one
  through its `#include`s. Within those it found `#version` lines,
  `DRAWBUFFERS` and `RENDERTARGETS` declarations and located outputs (the
  MRT count), `imageLoad`, `imageStore` and SSBO blocks, and the uniform,
  sampler and attribute names below. From `shaders.properties` it read
  `texture.*`, `uniform.*`, `variable.*`, `image.*`, `bufferObject.*`,
  `program.*.enabled` and `iris.features.*`, and it counted the IDs in
  `block.properties`, `item.properties` and `entity.properties`. Defaults
  of the options that switch voxel and compute paths on were checked by
  hand.
- **What the numbers mean.** All `#if` branches are kept when a program is
  expanded, so the MRT count and the uniform lists are upper bounds across
  every option setting, not what the default settings use. Where the
  difference matters (Complementary and BSL terrain) the default is given
  as well. The scripts live in the session's scratch directory and are not
  part of the repository.

### Packs not inspected

SEUS Renewed 1.0.1 is a free download from `sonicether.com`, but only
through a click-through end user agreement, which was not accepted on the
owner's behalf. SEUS PTGI E12 is distributed through Patreon posts. Neither
is on Modrinth or CurseForge, so neither has a comparable download count.
What follows about them is from their public descriptions only: Renewed is
a 2020 OptiFine pack; PTGI is a path tracer that builds its scene from what
the shadow pass draws. Both are copyright Sonic Ether with redistribution
forbidden.

## The packs

Downloads are in millions, Modrinth plus CurseForge. "Test" means the
licence allows personal use, which is all local testing needs; "ship" means
Goanna could bundle the pack. The GLSL column abbreviates `compatibility`
to `c`. MRT is the most outputs any program of the class writes: gbuffers
first, then the screen space chain. IDs are entries in `block.properties`,
`item.properties` and `entity.properties`. The last column lists only the
inputs that Goanna answers with a constant or a stand in today
(`iris-compat.md`, "Status").

| Pack | Version | Downloads | Licence: test, ship | GLSL | Programs | MRT | Compute, images, SSBO | `iris.features` | IDs | Faked inputs it reads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [Complementary Reimagined](https://modrinth.com/shader/complementary-reimagined) | r5.9.3 | 69.6 + 178.5 = 248.1 | [`Complementary License Agreement` 1.7](https://github.com/ComplementaryDevelopment/ComplementaryReimagined/blob/main/License.txt): yes, no | 130, 400c, 430c | 20 gbuffers, 1 shadow, 1 deferred, 7 composite, final, shadowcomp, 2 dh | 5 (terrain 2 to 3) / 5 | 1 .csh, 7 images, SSBO; all behind `COLORED_LIGHTING`, off by default | optional `CUSTOM_IMAGES SSBO BLOCK_EMISSION_ATTRIBUTE FADE_VARIABLE ENTITY_TRANSLUCENT` | 437/68/59 | shadowtex0/1, shadowcolor0/1, depthtex1, eyeBrightness, moonPhase, atlasSize, centerDepthSmooth, worldDay |
| [Complementary Unbound](https://modrinth.com/shader/complementary-unbound) | r5.9.3 | 45.3 + 145.0 = 190.3 | as Reimagined: yes, no | as Reimagined | as Reimagined | as Reimagined | as Reimagined | as Reimagined | 437/68/59 | as Reimagined |
| [BSL](https://modrinth.com/shader/bsl-shaders) | 10.1.8 | 30.6 + 89.2 = 119.8 | all rights reserved (Modrinth; the author's terms page returned HTTP 526): yes, no | 120, 130, 430c | 17 gbuffers, 1 shadow, 2 deferred, 8 composite, final, shadowcomp, 2 dh | 6 (terrain 1 to 5) / 4 | 1 .csh, 3 images; behind `MULTICOLORED_BLOCKLIGHT`, off by default | optional `CUSTOM_IMAGES FADE_VARIABLE` | 124/20/5 | shadowtex0/1, shadowcolor0, depthtex1/2, eyeBrightnessSmooth, moonPhase, atlasSize, centerDepthSmooth |
| [MakeUp Ultra Fast](https://modrinth.com/shader/makeup-ultra-fast-shaders) | 9.5g | 13.5 + 53.3 = 66.8 | [LGPL-3.0-or-later](https://github.com/javiergcim/MakeUpUltraFast): yes, yes | 120 | 18 gbuffers, 1 shadow, 1 deferred, 3 composite, final, prepare, 2 dh | 2 / 3 | none | none | 32/2/1 | shadowtex0/1, shadowcolor0, depthtex1, eyeBrightnessSmooth, moonPhase, centerDepthSmooth |
| [Solas](https://modrinth.com/shader/solas-shader) | 3.7b | 17.9 + 31.2 = 49.1 | all rights reserved: yes, no | 130, 430c | 13 gbuffers, 1 shadow, 2 deferred, 6 composite, final, shadowcomp, 2 dh | 4 / 3 | 1 .csh, 3 images; `VX_SUPPORT` on by default | optional `CUSTOM_IMAGES` | 151/49/12 | shadowtex0/1, shadowcolor0, depthtex1/2, eyeBrightnessSmooth, moonPhase, atlasSize, centerDepthSmooth, worldDay |
| [Bliss](https://modrinth.com/shader/bliss-shader) | 2.1.2 | 15.2 + 30.7 = 45.9 | [Chocapic13's sharing rules](https://github.com/X0nk/Bliss-Shader/blob/main/LICENSE.md): yes, no | 120, 330c, 430c | 19 gbuffers, 1 shadow, 3 deferred, 14 composite, final, setup, shadowcomp, 3 dh | 4 / 3 | 2 .csh, 4 images; light propagation volume, `LPV_ENABLED` off by default | optional `ENTITY_TRANSLUCENT REVERSED_CULLING COMPUTE_SHADERS CUSTOM_IMAGES BLOCK_EMISSION_ATTRIBUTE` | 309/25/14 | shadowtex0/1, shadowcolor0/1, depthtex1/2, eyeBrightness, eyeBrightnessSmooth, moonPhase, worldDay |
| [Insanity](https://modrinth.com/shader/insanity-shader) | 1.650 | 7.7 + 35.6 = 43.3 | [AGNYA](https://github.com/nvb-uy/AGNYA-License/blob/main/LICENSE.md): yes, no | 120 | 16 gbuffers, 1 shadow, 2 deferred, 8 composite, final | 4 / 3 | none | none | 45/4/2 | shadowtex0/1, shadowcolor0, depthtex1/2, eyeBrightnessSmooth, atlasSize, centerDepthSmooth |
| [Sildur's Vibrant](https://modrinth.com/shader/sildurs-vibrant-shaders) | 2.02 Extreme | 0.6 + 39.0 = 39.6 | all rights reserved: yes, no | 120 | 12 gbuffers (no `gbuffers_terrain`: terrain falls back to `gbuffers_textured`), 1 shadow, 2 deferred, 3 composite, final, 2 dh | 3 / 2 | none | none | 53/0/1 | shadowtex0/1, shadowcolor0, depthtex1/2, eyeBrightnessSmooth, moonPhase, atlasSize, centerDepthSmooth |
| [Photon](https://modrinth.com/shader/photon-shader) | 1.3b | 28.2 + 8.9 = 37.1 | [Photon licence](https://github.com/sixthsurge/photon/blob/main/LICENSE): yes, possibly (redistribution allowed except on platforms that pay creators or for money; ask first) | 400, 400c, 410c, 430, 430c | 25 gbuffers, 6 shadow, 6 deferred, 18 composite, final, prepare, setup, shadowcomp, 2 dh | 3 / 3 | 3 .csh, 4 images; `COLORED_LIGHTS` off by default | optional `CUSTOM_IMAGES ENTITY_TRANSLUCENT` | 79/40/11 | shadowtex0/1, shadowcolor0/1, depthtex1/2, moonPhase, atlasSize, centerDepthSmooth, worldDay |
| [Super Duper Vanilla](https://modrinth.com/shader/super-duper-vanilla) | 1.3.8 | 8.1 + 17.2 = 25.3 | [FlameRender Studios licence 1.6](https://github.com/Eldeston/Super-Duper-Vanilla/blob/master/LICENSE): yes, only inside a modpack or as a distinct modified pack | 330c, 330 core | 18 gbuffers, 7 shadow, 2 deferred, 8 composite, final, 3 dh | 4 / 2 | none | none | 72/0/10 | shadowtex0/1, shadowcolor0, depthtex1, atlasSize, centerDepthSmooth |
| [Mellow](https://modrinth.com/shader/mellow) | 3.4.1a | 7.5 + 11.5 = 19.0 | [MIT](https://codeberg.org/TheCMK/mellow-shader): yes, yes | 400c, 430c | 15 gbuffers, 1 shadow, 2 deferred, 12 composite, final, begin, 2 dh | 1 / 2 | 1 .csh (`begin`), 2 images; behind `COLORED_LIGHTS`, off by default | optional `CUSTOM_IMAGES BLOCK_EMISSION_ATTRIBUTE`, declared only with `COLORED_LIGHTS` | 21/7/0 | shadowtex0/1, shadowcolor0, depthtex1, eyeBrightnessSmooth, atlasSize, centerDepthSmooth, worldDay |
| [AstraLex](https://modrinth.com/shader/astralex) | 93.0 | 5.5 + 9.8 = 15.3 | all rights reserved (a BSL edit): yes, no | 130 | 17 gbuffers, 1 shadow, 1 deferred, 15 composite, final | 7 / 3 | none | none | 115/34/18 | shadowtex0/1, shadowcolor0, depthtex1/2, eyeBrightness, eyeBrightnessSmooth, moonPhase, atlasSize, centerDepthSmooth |
| [Rethinking Voxels](https://modrinth.com/shader/rethinking-voxels) | r0.1-beta9 | 13.5 + 0 (not on CurseForge) = 13.5 | [`Complementary License Agreement` 1.5](https://github.com/gri573/rethinking-voxels/blob/main/License.txt): yes, no | 130, 430, 430c | 17 gbuffers, 1 shadow plus `shadow.gsh`, 2 deferred, 7 composite, final, prepare, shadowcomp, 2 dh | 4 / 5 | 7 .csh, 7 images, SSBO, geometry shader | required `CUSTOM_IMAGES SSBO COMPUTE_SHADERS`; optional `BLOCK_EMISSION_ATTRIBUTE HIGHER_SHADOWCOLOR` | 391/57/31 | shadowtex0/1, shadowcolor0/1, depthtex1/2, eyeBrightness, moonPhase, atlasSize, centerDepthSmooth, worldDay |
| [Nostalgia](https://modrinth.com/shader/nostalgia-shader) | 5.1 | 4.4 + 7.6 = 12.0 | RRe36 licence, all rights reserved: yes, no | 400, 400c, 430c | 17 gbuffers, 1 shadow, 11 deferred, 15 composite, final, prepare, shadowcomp | 4 / 5 | none | none | 32/0/3 | shadowtex0/1, shadowcolor0/1, depthtex1/2, eyeBrightnessSmooth, centerDepthSmooth |
| [Chocapic13](https://www.curseforge.com/minecraft/shaders/chocapic13-shaders) | V9.1 Extreme beta 5 (2021) | 0 + 11.6 = 11.6 | all rights reserved plus Chocapic13's sharing rules: yes, no | 120 | 17 gbuffers, 1 shadow, 3 deferred, 14 composite, final | 2 / 2 | none | none | 11/0/0 | `shadow` (the legacy name for shadowtex0), depthtex1, eyeBrightnessSmooth |
| [Kappa](https://modrinth.com/shader/kappa-shader) | 5.3 | 3.3 + 6.3 = 9.6 | RRe36 licence, all rights reserved: yes, no | 400, 430c, 450c | 18 gbuffers, 1 shadow, 13 deferred, 16 composite, final, prepare, shadowcomp | 4 / 5 | none (its path tracing is screen space, in `deferred`, on by default) | none | 33/0/3 | shadowtex0/1, shadowcolor0/1, depthtex1/2, eyeBrightness, eyeBrightnessSmooth, centerDepthSmooth |
| [Miniature](https://modrinth.com/shader/miniature-shader) | 2.19 | 4.9 + 4.1 = 9.0 | [MIT](https://github.com/mateuskreuch/minecraft-miniature-shader) (the zip carries no licence file): yes, yes | 120 | 11 gbuffers, 1 shadow, final | 3 / 0 | none | optional `BLOCK_EMISSION_ATTRIBUTE` | 23/1/1 | shadowtex1, eyeBrightnessSmooth |
| [Sildur's Enhanced Default](https://modrinth.com/shader/sildurs-enhanced-default-shaders) | 1.20 Fancy | 0.2 + 6.6 = 6.8 | all rights reserved: yes, no | 120 | 5 gbuffers, 1 shadow, 2 composite, final, 2 dh | 2 / 2 | none | none | 53/0/1 | shadowtex0/1, shadowcolor0, depthtex1/2, eyeBrightnessSmooth, atlasSize, centerDepthSmooth |
| [Noble](https://modrinth.com/shader/noble) | 1.9.9 | 2.4 + 1.9 = 4.3 | [GPL-3.0-only](https://github.com/BelmuTM/NobleRT): yes, yes | 430c | 19 gbuffers, 1 shadow, 6 deferred, 26 composite, final, prepare, 3 dh | 2 / 2 | 3 .csh, SSBO | required `SSBO COMPUTE_SHADERS` | 12/0/3 | shadowtex0/1, shadowcolor0/1, depthtex1/2, eyeBrightness, eyeBrightnessSmooth, moonPhase, atlasSize, centerDepthSmooth |
| [Shrimple](https://modrinth.com/shader/shrimple) | v0.12 | 2.2 + 1.1 = 3.3 | [all rights reserved](https://github.com/Null-MC/Shrimple/blob/main/LICENSE): yes, no | 430, 430c, 430 core | 22 gbuffers, 2 shadow, 11 deferred, 34 composite, final, begin, prepare, setup, 4 dh | 4 / 2 | 22 .csh, 15 images, 8 buffer objects, geometry and tessellation shaders | required `COMPUTE_SHADERS CUSTOM_IMAGES`; optional `ENTITY_TRANSLUCENT TESSELATION_SHADERS SEPARATE_HARDWARE_SAMPLERS REVERSED_CULLING SSBO` | 6/70/2 | shadowtex0/1, shadowcolor0/1, depthtex1/2, eyeBrightness, eyeBrightnessSmooth, atlasSize, centerDepthSmooth |
| [Eclipse](https://modrinth.com/shader/eclipseshaders) | 1.0 | 0.4 + 0.4 = 0.8 | CC-BY-4.0 (declared on Modrinth; the zip has no licence file): yes, yes with attribution | 330c, 460c | 7 gbuffers, 1 shadow, 2 composite, final | 5 / 1 | none | none | 4/0/0 | shadowtex0/1, shadowcolor0, depthtex1, eyeBrightnessSmooth |
| [Base-Shader](https://modrinth.com/shader/base-shader) | 3.0 | 0.004 + 0 = 0.004 | [CC0-1.0](https://github.com/Bestsoft101/Base-Shader): yes, yes | 120 | 14 gbuffers | 1 / none | none | none | 1/0/1 | none |
| SEUS Renewed | 1.0.1 (2020) | not listed | Sonic Ether end user agreement: personal use, no redistribution | not inspected | not inspected | not inspected | not inspected | not inspected | not inspected | not inspected |
| SEUS PTGI | E12 | not listed | as Renewed | not inspected | path tracer fed by the shadow pass (description) | not inspected | not inspected | not inspected | not inspected | not inspected |

Complementary Reimagined and Unbound share their program structure in these
releases: every count the script took is identical. Together they are 45 per
cent of the surveyed downloads, so any weighted figure below leans on them.

## How often each feature is needed

Counts are out of the 22 inspected packs (SEUS excluded). "Weighted" is the
share of the 970.5 million combined downloads held by packs that need the
feature.

| Feature | Packs | Weighted | Packs without it |
| --- | --- | --- | --- |
| `gbuffers_*` programs | 22 | 100% | none |
| `block.properties` IDs (`mc_Entity`) | 22 | 100% | none |
| `composite*` or `final` | 21 | 100% | Base-Shader |
| A `shadow` program | 21 | 100% | Base-Shader |
| Dimension folders (`world-1`, `world1`) | 21 | 100% | Base-Shader |
| `screen.*` option menus | 20 | 99.9% | Base-Shader, Eclipse |
| `noisetex` | 20 | 99.1% | Base-Shader, Miniature |
| `depthtex1` | 20 | 99.1% | Base-Shader, Miniature |
| `at_tangent` and `mc_midTexCoord` attributes | 19 | 99.0% | Base-Shader, Eclipse, Miniature |
| Previous frame matrices (TAA) | 19 | 99.0% | Base-Shader, Eclipse, Miniature |
| Custom uniforms or variables (`uniform.*`, `variable.*`) | 19 | 99.0% | Base-Shader, Eclipse, Miniature |
| `deferred*` programs | 18 | 98.3% | Base-Shader, Eclipse, Miniature, Sildur's Enhanced Default |
| gbuffers writing two or more targets | 20 | 98.0% | Base-Shader, Mellow |
| `shadowcolor0` or `shadowcolor1` | 19 | 97.9% | Base-Shader, Chocapic13, Miniature |
| A shadow map read in `deferred` or `composite` | 17 | 97.1% | Base-Shader, Chocapic13 (uses the legacy `shadow` name), Eclipse, Miniature, Sildur's Enhanced Default |
| `program.*.enabled` conditions | 18 | 96.9% | Base-Shader, Eclipse, Noble, Super Duper Vanilla |
| `#if` inside `shaders.properties` | 17 | 96.8% | Base-Shader, Chocapic13, Eclipse, Nostalgia, Sildur's Enhanced Default |
| Custom textures (`texture.*`) | 17 | 94.2% | Base-Shader, Eclipse, Miniature, both Sildur's packs |
| `eyeBrightness` or `eyeBrightnessSmooth` | 19 | 93.6% | Base-Shader, Photon, Super Duper Vanilla |
| `centerDepthSmooth` | 17 | 93.1% | Base-Shader, Bliss, Chocapic13, Eclipse, Miniature |
| Distant Horizons programs (`dh_*`) | 14 | 89.5% | AstraLex, Base-Shader, Chocapic13, Eclipse, Insanity, Kappa, Miniature, Nostalgia |
| gbuffers writing three or more targets | 16 | 88.8% | Base-Shader, Chocapic13, MakeUp, Mellow, Noble, Sildur's Enhanced Default |
| `moonPhase` | 11 | 85.5% | Base-Shader, Chocapic13, Eclipse, Insanity, Kappa, Mellow, Miniature, Nostalgia, Shrimple, Sildur's Enhanced Default, Super Duper Vanilla |
| `prepare`, `begin`, `setup` or `shadowcomp` | 13 | 84.4% | AstraLex, Base-Shader, Chocapic13, Eclipse, Insanity, Miniature, both Sildur's packs, Super Duper Vanilla |
| `atlasSize` | 14 | 84.0% | Base-Shader, Bliss, Chocapic13, Eclipse, Kappa, MakeUp, Miniature, Nostalgia |
| `at_midBlock` attribute | 14 | 81.0% | AstraLex, Base-Shader, Chocapic13, Eclipse, Insanity, MakeUp, both Sildur's packs |
| gbuffers writing four or more targets | 13 | 80.0% | the six above plus Miniature, Photon, Sildur's Vibrant |
| `heldBlockLightValue` | 14 | 78.4% | Base-Shader, Bliss, Eclipse, Kappa, MakeUp, Nostalgia, Solas, Super Duper Vanilla |
| GLSL 400 or later somewhere | 13 | 77.6% | the seven GLSL 120 only packs, AstraLex, Super Duper Vanilla |
| Compute (`.csh`) shipped | 10 | 75.3% | twelve packs |
| Image load and store | 10 | 75.3% | the same twelve |
| Custom images (`image.*`) | 9 | 74.8% | thirteen packs |
| `worldDay` | 7 | 62.1% | fifteen packs |
| SSBOs | 5 | 47.3% | seventeen packs |
| `depthtex2` | 13 | 41.2% | Base-Shader, Chocapic13, both Complementary packs, Eclipse, MakeUp, Mellow, Miniature, Super Duper Vanilla |
| GLSL 120 only | 7 | 18.2% | Base-Shader, Chocapic13, Insanity, MakeUp, Miniature, both Sildur's packs |
| Compute or images on by default, or required | 4 | 7.2% | all but Noble, Rethinking Voxels, Shrimple, Solas |
| `iris.features.required` | 3 | 2.2% | all but Noble, Rethinking Voxels, Shrimple |
| Geometry or tessellation shaders | 2 | 1.7% | all but Rethinking Voxels, Shrimple |

Three readings of that table matter more than the rest.

**No popular pack is a screen space pack.** All 22 ship `gbuffers_*`
programs, and every one with a `composite` chain feeds it from targets those
programs write: normals, material masks, the lightmap, a water flag. What
`iris-compat.md` found for Eclipse holds across the list. Rung 4 on its own,
running a pack's chain over Godot's lit colour, shows no surveyed pack as its
author intended; at best a pack's bloom, tonemap and colour grade survive.
Four packs do not even keep their main colour in `colortex0`: the terrain
programs of MakeUp and Chocapic13 write to `colortex1`, and those of
Sildur's Vibrant and Super Duper Vanilla write to `colortex4`. So the chain is not a usable target in itself, and the
order of work in `iris-compat.md` should treat rung 5 as the first rung a
player would see.

**Multiple render targets are the norm, not the edge case.** 20 of 22 packs
write at least two targets from gbuffers and 13 write four or more. The
"most packs mostly work" expectation in `iris-compat.md`, "The limit is
multiple render targets", is too hopeful: a translator that can only fill
`ALBEDO` serves Base-Shader and Mellow and nothing else. The counts are
upper bounds over every option, and defaults are lower (Complementary
terrain writes `colortex0`, `colortex6` and sometimes `colortex4`; BSL
terrain writes one to five), but the extra targets are what the deferred and
composite passes read, so they cannot be dropped. Getting more than one
output out of the geometry pass is the single feature that decides how many
packs are reachable.

**Compute and voxels are mostly optional.** Compute, custom images and SSBOs
look common (10 packs, three quarters of downloads), but in seven of those
ten they sit behind an option that is off by default and are declared
through `iris.features.optional`, so a loader that declares them unsupported
gets the pack's ordinary path. Only Rethinking Voxels, Noble and Shrimple
require them (2.2 per cent of downloads), and only Solas turns its voxel
path on by default.

## What to support next

In order, with the rung from `iris-compat.md` each belongs to and the share
of surveyed downloads it is a prerequisite for. A feature unlocks a pack
only together with the ones above it.

1. **Finish the preprocessor (rung 3).** Evaluate `#if`, `#ifdef` and
   `#define` inside `shaders.properties` against option defaults, honour
   `program.*.enabled`, apply option defaults as `#define`s, and compute
   `uniform.*` and `variable.*` expressions. 21 packs, effectively all
   downloads. Today `#if` lines in `shaders.properties` are read as
   comments, so every branch's directives apply at once: both Complementary
   packs would have their shadow program switched off and every size of
   their voxel images declared, because those lines sit inside `#if`
   blocks. This is
   bookkeeping with no Godot limit behind it, and nothing else on the list
   is testable on a real pack without it.
2. **Declare no optional Iris features.** Leave the `IRIS_FEATURE_*` macros
   undefined and refuse packs whose `iris.features.required` names a missing
   one, with the reason in `GoannaIrisEffect::report()`. Costs nothing,
   keeps 19 packs on their ordinary path, and makes the three that cannot
   run fail legibly.
3. **Translate `gbuffers_terrain` (rung 5), with the fallback chain.** Iris
   falls back from a missing program to a more general one
   (`gbuffers_terrain` to `gbuffers_textured_lit` to `gbuffers_textured` to
   `gbuffers_basic`); Sildur's Vibrant draws terrain through
   `gbuffers_textured` because it has no terrain program. Needs the
   `lightmap` sampler, `block.properties` mapped onto the block table (all
   22 packs), and the `at_tangent`, `mc_midTexCoord` and `at_midBlock`
   attributes (19, 19 and 14 packs). Alone, with one output, this reaches
   Base-Shader and Mellow, Mellow without its shadows until item 5: 19.0
   million downloads, both licensed to ship.
4. **A second and third gbuffers output (rung 5, the MRT limit).** Either
   `set_next_pass` per extra target as `iris-compat.md` proposes, or
   synthesising a pack's normal target from what Godot's Forward+ already
   keeps for its own screen space effects; the second has not been tried
   and would need the pack's encoding of normals matched per pack. Two
   outputs add MakeUp, Chocapic13, Sildur's Enhanced Default and Noble's
   geometry; three add Miniature, Photon and Sildur's Vibrant. Of those,
   MakeUp (66.8 million, LGPL) and Miniature (MIT) can ship.
5. **A real shadow map (rung 7) and `depthtex1`.** 21 packs have a shadow
   program and 17 read the shadow map in their screen chain; today
   `shadowtex*` is a 1x1 texture of 1.0 and `shadowModelView` is the
   camera's. The pack's `shadow.vsh` decides the projection and its
   distortion, so Goanna has to run the translated shadow program into a
   texture the pack's own maths agrees with, not hand it Godot's shadow
   atlas. `depthtex1` (20 packs) is the depth before translucent geometry,
   a copy taken at `PRE_TRANSPARENT`; `depthtex2` (13 packs) additionally
   excludes the hand, and can stay an alias until hands are drawn by a pack.
6. **The cheap constants (rung 2).** `eyeBrightnessSmooth` (19 packs) from
   node light at the camera, `centerDepthSmooth` (17) from a one pixel depth
   read smoothed over time, `atlasSize` (14), `moonPhase` (11) and
   `worldDay` (7) from the time of day and a day count, and custom textures
   from `texture.*` (17 packs, PNG and raw files in the pack). None needs a
   new mechanism. Without them packs run but misjudge caves, night and
   focus.
7. **Four and more gbuffers outputs.** Solas, Bliss, Insanity, Super Duper
   Vanilla, Kappa, Nostalgia, Eclipse, Complementary (five at most), BSL
   (six) and AstraLex (seven). These hold 78 per cent of the surveyed
   downloads, the three largest packs among them, and four or more targets
   is past what `set_next_pass` should be asked to do. It wants a real answer
   to MRT in the geometry pass, which may mean drawing the node meshes a
   second time through a `RenderingDevice` pipeline of Goanna's own rather
   than through Godot's spatial shaders.
8. **`prepare`, `shadowcomp`, `begin`, `setup` and compute (rung 4
   extended).** 13 packs ship one of the extra stages. `RenderingDevice`
   runs compute and storage images, so these are a scheduling job in the
   compositor effect, with no Godot limit. Low priority because the
   defaults of most packs do not use them.
9. **Distant Horizons programs.** 14 packs ship `dh_*` programs. Goanna's
   far tiers are drawn by the same node shader as the near mesh
   (`iris-compat.md`, "The LOD terrain has to be the same terrain"), so the
   pack's `gbuffers_terrain` already covers them; leave `DISTANT_HORIZONS`
   undefined and the `dh_*` programs unused.

Dimension folders need nothing more: Goanna reads `world0` already, and a
Luanti server has no nether or end for `world-1` and `world1` to serve.

### Realistic early targets

- **Base-Shader and Mellow** after item 3. Base-Shader is the planned first
  target. Mellow is the find of this survey: its gbuffers programs each
  write one lit colour (`out vec4 Color`), its deferred and composite
  chain then works from `colortex0` and depth, its voxel lighting is off
  by default, and it is MIT with 19 million downloads. It needs GLSL 400
  compatibility, which the translator emits already.
- **Miniature and MakeUp** after item 4. Both are GLSL 120 with no compute
  and no required features. MakeUp is the most downloaded pack Goanna may
  ship (LGPL-3.0-or-later), and asks for little beyond item 6. Miniature is
  the simplest real pack with shadows: gbuffers, one shadow program and a
  `final`.
- **Chocapic13 and both Sildur's packs** after items 4 to 6, for local
  testing only.
- **Eclipse** after items 5 and 7: its water and shadow programs are the
  reason it is the second target, and its gbuffers write up to five
  targets.

### Out of reach

- **Rethinking Voxels and Shrimple.** Both voxelise the world from the
  shadow pass, writing images from a geometry shader (`shadow.gsh`) and from
  the shadow program itself, and both require compute and custom images.
  Godot's spatial shaders have no geometry stage and cannot write images or
  buffers, so the translated-shader route cannot feed them. A route that
  could, and has not been designed: Goanna holds the world as nodes and
  could fill a pack's voxel image from mapblocks directly, but every pack
  lays that image out its own way.
- **Noble and SEUS PTGI.** Path tracers. Noble requires SSBOs and compute
  and has 346 files declaring `#version 430 compatibility`; PTGI, by its description, builds its scene
  from the shadow pass in the same way as the voxel packs. The compute half
  is possible in Godot; the scene input is the same wall as above.
- **The voxel paths of Complementary, BSL, Solas, Bliss, Photon and Mellow.**
  The ordinary paths of those packs are in reach; their optional coloured
  lighting is not, for the same reason. Solas turns `VX_SUPPORT` on by
  default without testing for the Iris feature macros, so it may need that
  option forced off.

### Licences in short

Every pack can be tested locally under its own terms; the Complementary
agreement calls this "Normal Usage", which on our reading covers testing in
another client but is the least clear of the set. Six can ship: Base-Shader
(CC0-1.0), Eclipse (CC-BY-4.0), MakeUp (LGPL-3.0-or-later), Mellow (MIT),
Miniature (MIT) and Noble (GPL-3.0-only), which together are 10.3 per cent
of downloads. Photon's terms allow redistribution off paid platforms and
would need the author asked. Everything else is all rights reserved or
forbids redistribution, so none of it goes into the repository, the release
or a test fixture.
