# Shader pack status

What each real Iris or OptiFine shader pack does in Goanna's screen space
chain (`deferred*`, `composite*`, `final`), pack by pack. How the checks are
run is in [Shader pack testing](shaderpack-testing.md); why the chain alone
cannot show any of these packs as its author intended is in the
[survey of popular shader packs](../design/shaderpack-survey.md).

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
