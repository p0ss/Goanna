# Shader pack status

What each real Iris or OptiFine shader pack does in Goanna's screen space
chain (`deferred*`, `composite*`, `final`), pack by pack. How the checks are
run is in [Shader pack testing](shaderpack-testing.md); why the chain alone
cannot show any of these packs as its author intended is in the
[survey of popular shader packs](../design/shaderpack-survey.md).

## Emissive material coverage, 2026-10-20

Emissive node tiles now go through the pack's geometry programs. Before,
the native emission fallback gave them a `StandardMaterial3D`, and their
faces sat on the glow render layer alone, which the second output cameras
do not see. An authored probe pack confirmed both: the sea lantern had no
pack marker, block ID or lightmap in any second output. MakeUp, which
keeps its colour in `colortex1`, therefore drew no lamp at all. A new
single texture opaque surface translates `gbuffers_terrain` for these
tiles, and glowing faces now carry the node surface layer and a pack
shadow copy. Goanna's native lamps are unchanged.

MakeUp's night lamp is now drawn, and its fixed lamp sample's maximum mean
channel error falls from 232.37 to 70.59 levels; by day from 74.52 to
47.29. Its floor (13.48 at night) and Complementary's floor and light pool
(17.76 at night) did not change, so the lamp gap does not explain them.
The lamp still differs: BridgeTest sends the whole five-frame sea lantern
strip as one still texture, and MakeUp's halo is absent. Mellow and the
Eclipse control did not regress; Eclipse's lamp sample falls from 42.51 to
24.51, and Mellow's lamp pixels did not change at all, which was not
investigated further. See the
[comparison report](../agents/minecraft-comparison.md) for the runs.

## Translucent glass and foliage inputs, 2026-10-18

Clear glass now selects the translucent program with its glass block ID.
Legacy translucent outputs apply the material alpha test before every
target write. This removes MakeUp's black clear-glass panels in both
calibration and close-foliage captures. The previous mapped control and
the new frames are retained in the labelled side-by-side gallery under
`build/minecraft/glass-leaf-inputs-20261018/`.

Paired authored probes find close foliage AO means within two image
levels, and Goanna's sampled skylight slightly lower than Minecraft's.
Neither result explains Complementary's much brighter mapped foliage.
Its material lighting and shadow response remain under investigation;
glass top edges and distant foliage also remain open. See the
[comparison report](../agents/minecraft-comparison.md) for scope and values.

## Face culling and block IDs, 2026-10-18

The later follow-up corrects two shared input problems. Per-material
back-face culling removes the duplicate glass frame across all four
comparison packs. Mellow's fixed glass mean channel difference falls from
26.53 to 6.84 levels; Eclipse falls from 20.80 to 9.93. Native waving leaves
also preserve the server's culling flag. Imported shadow culling retains
its separate policy.

The comparison profile also lacked a texture-to-block map. Textures
loaded, but shader block IDs were absent. Profiles now generate and record
that map, and an authored leaf-ID probe confirms the corrected transport.
The mapped comparisons enable pack-specific material effects, exposing
further differences rather than guaranteeing a smaller image error.
In particular Complementary's leaf shading still differs substantially
with IDs restored. MakeUp's sampled foliage difference improves from
14.29 to 6.37; Complementary's grows from 1.52 to 35.30. A close-camera
flat cut-out control has nearly equal
visible foliage coverage in the two engines; its result does not justify
changing global leaf opacity. Distant mipmaps remain a separate gap.

The controls and before/after gallery are under
`build/minecraft/face-culling-20261018/`. See the
[comparison report](../agents/minecraft-comparison.md) for the measured
samples, server and renderer versions, excluded probe and limitations.
The earlier matrix below used the missing-map setup and remains evidence
of that checkpoint, not complete pack material fidelity.

## Matched fidelity checkpoint, 2026-10-18

The current checkpoint uses paired captures from the same unmodified
Minecraft Java 26.2 dedicated server, through BridgeTest protocol 52,
with no Luanti game. Goanna uses its Luanti 5.17.0 core, Godot 4.5.1 and
RTX 3090 in headless gamescope. Captures began on the dirty checkout based
on `48cbb9d6`, including unrelated Overseer edits; renderer fixes are in
`7ab84df3` and `32114307`. No performance was measured.

Mellow 3.4.1a, Complementary Reimagined r5.9.3 and MakeUp Ultra Fast 9.5g
were selected from release metadata explicitly listing Minecraft 26.2.
Their archives match the published SHA-512 hashes. The Eclipse control is
a diagnostic copy omitting the suspect unbound cloud blend; it is not the
sky reference. All comparisons use explicit plains calibration, matching
pack content in both clients and recorded camera, clock and shader state.

The final gallery contains 25 paired views, 50 frames in total. Each
listed phase includes calibration, close foliage and sky poses, except
the two diagnostic controls. Every run reports an active chain, all its
passes compiled, no geometry translation errors and no Goanna client
script or shader errors. Successful capture does not establish fidelity.

| Pack or control | Phases | Compiled chain passes per phase | Paired views |
| --- | --- | --- | --- |
| Diagnostic Eclipse | Day | 3 of 3 | 2 |
| Mellow 3.4.1a, default | Day, dusk, night | 9 of 9 | 9 |
| Mellow, native-cloud control | Day | 9 of 9 | 2 |
| Complementary Reimagined r5.9.3 | Day, night | 9 of 9 | 6 |
| MakeUp Ultra Fast 9.5g | Day, night | 6 of 6, including `prepare` | 6 |

Mellow's unmodified default has blue daytime sky, warm dusk and a dark
night sky in both clients. Its nine screen passes compile and run across
all three phases. Honouring the cloud-noise image's `blur` metadata removes
Goanna's blocky procedural clouds. Cloud placement and some colour still
differ. At night a fixed sky-camera region averages RGB 19.52, 24.34, 35.40
in Minecraft and 21.01, 25.55, 36.54 in Goanna. These means establish
neither pixel equality nor a general sky fidelity score.

Mellow's separate `CLOUD_STYLE=0` control selects Minecraft native `FANCY`
clouds. They appear in Minecraft and are absent in Goanna: native cloud
geometry still has no pack program. The default procedural clouds use a
different path. Glass, lamp appearance, water and distant foliage also
remain visibly different.

Complementary Reimagined also runs nine screen passes at day and night,
with no reported client errors. The daytime fixed floor sample differs by
2.30 levels and foliage by 1.59. At night the floor difference grows to
16.75, with a visibly different lamp and pool of light, while the sampled
sky differs by 1.75. A separate sky-camera region's channel means differ
by at most 0.14 levels. Glass, water reflection and foliage softness remain
different. This is a useful shared renderer backlog, not evidence of
complete pack compatibility or a diagnosed cause for every mismatch.

MakeUp Ultra Fast's daytime run has six active screen passes, including
`prepare`, with no geometry translation errors. Its sky and procedural
clouds render, but the lamp is absent, glass has dark patches and water
reflections differ. The native emissive material fallback in
`src/goanna_client_materials.cpp` bypasses the imported geometry shader;
that path needs pack material-buffer coverage. This code gap is consistent
with the lamp mismatch, but has not yet been isolated by a corrected run.
The daytime floor sample differs by 7.06 levels and foliage by 14.32.
Its six passes also run at night without client errors; the lamp remains
absent and the floor differs by 13.49 levels. The sky-camera region's
night means differ by at most 0.91 levels, while individual stars and
clouds do not match.

The diagnostic Eclipse now differs by 0.19 RGB levels for the floor,
0.08 for wood and 0.33 for foliage in fixed-region mean channel samples.
Actual shader-uniform captures exposed the shadow eye offset in the wrong
matrix; raw leaf inputs exposed the wrong alpha reference and missing
canopy corner shading. This supersedes the earlier attribution of the
soft-shadow discrepancy solely to Eclipse's filter arithmetic. Its glass
AO remains different. Leaf mipmap generation remains different too.

The paired frames, per-pass reports, metrics and divider gallery are under
`build/minecraft/iris-fidelity-20261018/`. The
[comparison report](../agents/minecraft-comparison.md) records isolation
controls, excluded diagnostics and remaining input limitations. Earlier
sections below retain their dates and do not describe the latest build.

## What was run, 2026-10-11

Only the offline compile check. Every result below comes from
`tools/test/shaderpack_compile.py` at commit `3f158ab4` on the branch that
added it: Goanna's own loader read each pack (`shaders.properties`
conditionals, options, program toggles, custom uniforms), the translator
produced the Vulkan GLSL the effect would hand Godot 4.5.1, and
`glslangValidator` (conda-forge build, target `vulkan1.1`) compiled each
stage. Godot itself compiled nothing, no pipeline was created, and nothing
was drawn.

**No pack had been run live on that date.** A render service job for each pack
against a local Mineclonia server was queued twice. The first waited two
hours for the GPU lock, which another session's client held, and timed
out. The second, on lavapipe, had just started when the machine rebooted.
That survey produced no frame, GPU compile or pipeline result for any pack,
and the "Live" column says not run. The proof pack's last live pass is the
one in [Shader pack testing](shaderpack-testing.md).

Since then, from 2026-10-11 to 2026-10-13, four chains have run on the
GPU with their geometry programs: Eclipse (3 of 3 passes compiled), Mellow
(9 of 9), MakeUp (5 of 5) and Photon (15 of 20 at first, the five with
struct varyings failing as below; 20 of 20 since 2026-10-13). The "Live"
column is still the offline day's; what those frames showed is under "The
geometry programs".

Pack versions are the releases named in the survey's table, downloaded
from Modrinth (Chocapic13 from CurseForge). None is in the repository.

## The table

"Passes" counts the chain after `program.*.enabled` has been evaluated
against the pack's default options; "Off" lists the programs that switched
off. "Reads zero" lists uniforms a pass declares that neither the standard
block, a custom uniform nor the effect supplies.

| Pack | Passes compiling offline | Off by `program.*.enabled` | Refused | Reads zero | Live |
| --- | --- | --- | --- | --- | --- |
| Proof pack (ours) | 2 of 2 | none | no | none | not run this time |
| Base-Shader 3.0 | 0 of 0: no screen space programs | none | no | none | not run |
| Eclipse 1.0 | 3 of 3 | none | no | none | not run |
| BSL 10.1.8 | 9 of 9 | composite2, composite3 | no | `cloudHeight`, `endFlashIntensity`, `endFlashPosition` | not run |
| Complementary Reimagined r5.9.3 | 9 of 9 | none | no | `cameraPositionInt` and `Fract` (and previous), `cloudHeight`, `heavyFog`, `isElytraFlying`, `is_invisible`, `velocity` | not run |
| Complementary Unbound r5.9.3 | 9 of 9 | none | no | as Reimagined | not run |
| Sildur's Vibrant 2.02 Extreme | 6 of 6 | none | no | `isNether` | not run |
| Sildur's Enhanced Default 1.20 Fancy | 3 of 3 | none | no | none | not run |
| MakeUp Ultra Fast 9.5g | 5 of 5 | none | no | none | not run |
| Super Duper Vanilla 1.3.8 | 11 of 11 | none | no | none | not run |
| Mellow 3.4.1a | 9 of 9 | deferred, composite9 to 13 | no | the `dh*` and `vx*` matrices, `endFlash*` | not run |
| Miniature 2.19 | 1 of 1 | none | no | none | not run |
| Chocapic13 V9.1 Extreme beta 5 | 15 of 15 | composite7 | no | none | not run |
| Insanity 1.650 | 6 of 6 | deferred, composite1 to 3, composite6 | no | none | not run |
| Solas 3.7b | 9 of 9 | none | no | `dhRenderDistance`, `vxRenderDistance` | not run |
| Bliss 2.1.2 | 16 of 16 | deferred2, composite5 | no | the `dh*` matrices, `farPlane`, `Moon_Weather_properties` | not run |
| Nostalgia 5.1 | 19 of 19 | deferred3 to 9, composite | no | `skyCaptureResolution` | not run |
| Kappa 5.3 | 28 of 28 | composite1 | no | none | not run |
| AstraLex 93.0 | 12 of 12 | composite3, 8, 9, 10, 14 | no | none | not run |
| Photon v1.3b | 20 of 20 (15 before 2026-10-13) | composite2, 3, 15, 17 | no | `clouds_offset` | not run |
| Noble 1.9.9 | 32 of 33 | none | yes: `SSBO`, `COMPUTE_SHADERS` | `gbufferPreviousModelViewInverse` | not run |
| Rethinking Voxels r0.1-beta9 | 6 of 8 | composite2 | yes: `CUSTOM_IMAGES`, `SSBO`, `COMPUTE_SHADERS` | several | not run |
| Shrimple v0.12 | 21 of 28 | deferred14, composite10, 16, 41, 42 | yes: `COMPUTE_SHADERS`, `CUSTOM_IMAGES` | several | not run |

Notes on the rows that are not clean:

- **Photon**: five passes declare varyings of struct type
  (`flat out CloudsParameters clouds_params;`), which the translator moved
  to its prelude, ahead of the struct definition. Since 2026-10-13 such a
  varying stays where the pack wrote it, and with a sampler alias fault
  fixed too all 20 compile offline (glslang 16.6.0, commit `cf723467`)
  and on the GPU.
- **Noble, Rethinking Voxels, Shrimple** are refused at load, as Iris
  refuses them on a loader without those features, so their compile
  failures (SSBO blocks, custom images) do not matter yet.
- **Solas** turns its voxel path on by default without testing for the
  Iris feature macros, so it reads `floodfillSampler`, a custom image Goanna
  binds to black. Turning `VX_SUPPORT` off with `GOANNA_SHADERPACK_OPTIONS`
  should give its ordinary path; untried.
- **Eclipse** reads `specular`, which only its gbuffers programs would
  write, and gets black.

## What the offline check found and fixed

Before these fixes, on the same packs, BSL compiled 7 of 9 passes,
Complementary 0 of 9, Super Duper Vanilla 1 of 11, Chocapic13 5 of 15,
Bliss 7 of 16, Nostalgia 13 of 19, Kappa 21 of 28, Miniature 0 of 1 and
Eclipse 2 of 3. The causes, each fixed where it arose:

- Declarations from a pack's `#ifdef FSH` branch were lifted into the vertex
  stage and collided with its own. The loader now resolves each program's
  conditionals per stage, ignoring directives inside `/* */` comments
  (Nostalgia and Kappa switch blocks off that way).
- Names GLSL 4.50 or Vulkan reserve (`sample`, `sampler`, and the 4.30
  storage words), and pack functions named like newer builtins (`round` in
  a GLSL 1.20 pack, `fma` in a 3.30 one).
- A pack global named like a standard uniform (`fogDensity`), or a vertex
  global named like a uniform only the fragment stage declares
  (Chocapic13's `sunVec`).
- `gl_Fog`, `shadow2D` returning a `vec4`, `texelFetch2D`.
- Unlocated fragment outputs all sent to location 0, varyings a pack had
  located itself, `mat4x3` varyings counted as one location, and a second
  `RENDERTARGETS` losing to the first.

## What needs the gbuffers rungs

Every pack above except Base-Shader feeds its chain from targets its
`gbuffers_*` programs write: normals, material IDs, the lightmap, a water
mask. Without those programs the chain runs over Godot's lit colour and
empty targets, so even a pack that compiles cleanly here is not expected to
look right; four (MakeUp, Chocapic13, Sildur's Vibrant, Super Duper
Vanilla) do not even keep their main colour in `colortex0`. A real shadow
map is the same: 17 of these packs read `shadowtex` in the chain, and the
map has to come from the pack's own translated `shadow` program, which a
compositor effect cannot run. Rungs 5 to 7 now draw the geometry
programs, their second outputs and the near terrain's shadow map (below),
but each has been looked at with few packs, so judge a pack here first by
whether it loads, compiles and runs.

Until commit `0fce1c1b` (2026-10-13) the chain also gave every pack a wrong
projection: Godot's own, with its depth already in Vulkan's reversed
[0, 1], so `near` and `far` read -0.05 and every position rebuilt from
depth was wrong. Any chain result in the table above that depends on depth
(fog, ambient occlusion, reflections) was taken with that fault.

## The geometry programs

What `GoannaIrisGbuffers` does with each pack's `gbuffers_terrain`,
`gbuffers_terrain_cutout`, `gbuffers_water` and the foliage surface (the
cut-out program on leaves and plants), with Godot 4.5.1. "Front end" is
`tests/iris_gbuffers.gd` with `GOANNA_IRIS_PACK`, on 2026-10-12 at commit
`e6c842a1`: all four translate and Godot's shader front end accepts them,
headless, with no GPU. "Second outputs" lists the `colortex` targets the
programs write besides `colortex0` (terrain; water where it differs),
each of which the chain reads and so gets a camera of its own (see
`docs/design/iris-compat.md`, "Second outputs"). "GPU" is a frame through
`tools/goanna-render` on the RTX 3090 (Luanti 5.17.0, Mineclonia release
38561); the run details and what each frame showed are in
`docs/design/iris-compat.md`, "What was observed".

| Pack | Terrain program | Front end | Second outputs | GPU |
| --- | --- | --- | --- | --- |
| Base-Shader 3.0 | `gbuffers_terrain` | all four | none | drawn, near and far, in its flat vanilla look |
| Eclipse 1.0 | `gbuffers_textured_lit` | all four | 1, 4, 6 (water: 1, 3, 4) | drawn by day, near and far; water blue, rippled and reflecting; land under its thick fog |
| Mellow 3.4.1a | `gbuffers_terrain` | all four | none | drawn by day, near and far, under its own sky; the haze was the chain's projection |
| Photon v1.3b | `gbuffers_terrain` | all four | 1, its only output (water: 3, 13) | 20 of 20 chain passes; land lit in its own palette under its haze, water near black, ice not shown (was magenta, 5 of 20 failing) |
| BSL 10.1.8 | `gbuffers_terrain` | all four | none (water: 1) | not run |
| Complementary Reimagined r5.9.3 | `gbuffers_terrain` | all four | 4, 6 (water: 3) | not run |
| MakeUp Ultra Fast 9.5g | `gbuffers_terrain` | all four | 1, its only output | drawn, 5 of 5 chain passes; dark, fogging to black, water black: its geometry programs read colortex Goanna cannot give them (was black, too many varyings) |

On 2026-10-13 the front end passed again for all seven packs above at
`e3848de3`, and for Photon, Eclipse and Base-Shader at `c0ecc01d`, with
the varyings packed (`docs/design/iris-compat.md`, "The
gbuffers translator, as built"); the most any translated program now
declares is 15, MakeUp's water. Its terrain had 21, which Godot counts
as 33 with its own on a real backend, over the limit of 32.

Miniature and Sildur's Enhanced Default passed the front end on
2026-10-11, before a reboot and before the later translator changes, and
were not run again.

## The shadow map

A pack's own shadow map (rung 7, `docs/design/iris-compat.md`, "The shadow
map, as built") exists since 2026-10-12: its `shadow` program draws the near
terrain into a map at its `shadowMapResolution`, which the gbuffers programs
and the chain then read. Of the packs above only Eclipse has been run with
it. Before that, every shadow lookup said lit.

| Pack | Shadow program | Front end | GPU |
| --- | --- | --- | --- |
| Eclipse 1.0 | `shadow`, 1024, distorted | all three surfaces | the map is drawn, distortion and all; with `SOFT_SHADOWS=false` its teal shadows fall the right way from the stage's blocks and, on `r1tod1`, from the spruces and terraces; with its default soft shadows barely visible |
| Base-Shader 3.0 | none | none to translate | the pass is not made |

Run on the RTX 3090 with Luanti 5.17.0, Mineclonia release 38561 and Godot
4.5.1, with Eclipse's SSAO off; the frames are described in
`docs/design/iris-compat.md`, "What was observed".

Eclipse's soft shadows are faint by its own arithmetic, not ours: its
filter takes 5 by 5 samples (`SHADOW_SAMPLES` 2 either side) and divides by
`(6 * SHADOW_SAMPLES + 1)` squared, 169, so a point fully in shadow scores
0.15, and two later lighting terms that add `inShadow` brighten most of
that back. With its default options the shadowed and unshadowed frames of
the stage differ in fewer than 400 pixels at 1280 by 720.

## Recovery checks, 13 October 2026

Recovered the additional camera and cloud inputs and the unfinished
geometry texture reads from the input worktree. Native tests pass. The
headless Godot 4.5.1 geometry checks and offline glslang chain checks pass
for Eclipse, Mellow, MakeUp, BSL, Complementary Reimagined and Photon
(3, 9, 5, 9, 9 and 20 chain passes respectively).

On the RTX 3090, Godot 4.5.1, a local Luanti 5.17.0 server and Mineclonia
release 38561, the recovered code initially produced a black MakeUp
frame and texture errors. The copies now use formats `Texture2DRD` can
bind. Initialising preserved targets and retaining their last written
ping pong side also corrected the history handling. With those changes,
MakeUp drew the lake, shoreline and reflected scenery on a copy of
`r1tod1`, at (0, 110, 0), pitch -45, yaw 210, FOV 70, 640 by 360. The
client log contained no shader errors. The background beyond the terrain
remained black; this is not full sky-program support. The render service's
quiet check timed out, so this is a visual observation, not a performance
measurement. Eclipse also drew the lake with blue water and reflections,
with its existing thick pale fog over the land and no shader errors.

The separate history proof produced (255, 0, 0) in every pixel on the
same server and renderer, confirming accumulation across frames. An
expanded GPU teardown fixture passed four create, resize and free cycles.
The live captures used the dirty recovery worktree based on `64e63506`;
the capture library hash was `5bd38b2b22c68ae4`. Software runs crashed in
Godot before a frame and provide no validation of these changes.

Geometry reads are still approximate: scene-copy detection is heuristic,
other targets arrive a frame late, geometry custom textures are missing,
and samplers passed through helper functions do not receive the direct
call's coordinate conversion. Photon was compiled but not rendered again.
See [the design notes](../design/iris-compat.md#targets-a-geometry-program-reads).

## Native effect isolation, 13 October 2026

At the western coastal village, MakeUp Ultra Fast 9.5g drew a black sky
and pale water with Goanna's procedural grass disabled. Disabling native
clouds, cloud shadows, atmosphere, SSAO, SSR, bloom, shafts, SSIL and SDFGI
also left those faults visible. A separate capture removed the Godot sky
resource entirely and retained the black background. These runs used the
render service, an RTX 3090, Godot 4.5.1, Luanti 5.17.0 and Mineclonia
release 38561 on a copy of `goanna_coastal_reference_20261013`. Turning off
native effects alone does not provide the pack's missing sky programs.

Goanna now suppresses its extra procedural grass surfaces while a pack
provides a terrain geometry program. That material does not write the
pack's auxiliary targets. The requested grass setting is retained and
restored when the pack is removed, including its antialiasing ownership.
The headless Godot 4.5.1 regression checks existing near and far meshes,
preference changes while suppressed and restoration after pack removal.

The automatic suppression also ran at the village on that server and
renderer. The saved High preference remained enabled, suppression was
active and grass antialiasing was inactive. The frame omitted Goanna's
extra grass, but retained MakeUp's black sky, pale water and broken distant
terrain. This validates isolation of that material, not complete MakeUp
compatibility.

## Coastal checkpoint follow-up, 13 October 2026

Three corrections address faults visible in the western village checkpoint:

- Geometry texture reads retain the pack's actual prepare/deferred output,
  including alpha. The former scene-copy heuristic replaced Complementary's
  cloud depth with native scene colour, affecting its water discard test.
- Fragment `prepare` programs run before deferred in the screen chain.
  Existing geometry pixels are restored over prepared backgrounds using
  depth. MakeUp's sky target is now populated.
- Clear glass uses the pack's cut-out material path. Native lit glass colour
  must not be interpreted as Photon's packed material data.

On a local Luanti 5.17.0 server, Mineclonia release 38561, Godot 4.5.1 and
RTX 3090, the corrected Complementary shore capture has a visible bay
surface, and Photon's shore capture no longer has the red window artefacts.
MakeUp's two western angles have a blue sky and blue water instead of the
black background and pale water. Its water remains noisy and its terrain
dark. Complementary still has water patches and overlapping cloud layers.
These are visual observations, not full pack compatibility or performance
claims. Geometry inputs still arrive one frame late; execution remains
after Godot's translucent geometry.

Captures use the same copied coastal world, time 0.42, High profile,
1920 by 1080 resolution and requested ranges as the checkpoint. The
combined capture library is `717026c41d44f7a8`, built from a dirty tree
based on `1971d4ae`. Native tests, including prepare-pass ordering, pass.
