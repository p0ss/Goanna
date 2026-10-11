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

**No pack has been run live.** A render service job for every pack below
against a local Mineclonia server was queued twice. The first waited two
hours for the GPU lock, which another session's client held, and timed
out. The second, on lavapipe, had just started when the machine rebooted.
So there is no frame, no GPU compile and no pipeline result for any pack,
and the "Live" column says not run. The proof pack's last live pass is the
one in [Shader pack testing](shaderpack-testing.md).

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
| Photon v1.3b | 15 of 20 | composite2, 3, 15, 17 | no | `clouds_offset` | not run |
| Noble 1.9.9 | 32 of 33 | none | yes: `SSBO`, `COMPUTE_SHADERS` | `gbufferPreviousModelViewInverse` | not run |
| Rethinking Voxels r0.1-beta9 | 6 of 8 | composite2 | yes: `CUSTOM_IMAGES`, `SSBO`, `COMPUTE_SHADERS` | several | not run |
| Shrimple v0.12 | 21 of 28 | deferred14, composite10, 16, 41, 42 | yes: `COMPUTE_SHADERS`, `CUSTOM_IMAGES` | several | not run |

Notes on the rows that are not clean:

- **Photon**: five passes declare varyings of struct type
  (`flat out CloudsParameters clouds_params;`). The translator moves every
  varying declaration to its prelude, ahead of the struct definition, so
  they do not parse. Fixing it means declaring such varyings where the pack
  wrote them; that is translator work not yet done.
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
compositor effect cannot run. Until rungs 5 and 7 land, judge a pack here
by whether it loads, compiles and runs, not by its look.
