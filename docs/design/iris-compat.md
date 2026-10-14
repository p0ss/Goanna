# Plan for loading Iris shader packs

The aim is to load an Iris or OptiFine shader pack and have it render, not to
be a drop in replacement for Iris. Drop in compatibility means implementing
Minecraft's renderer, and that is not a compatibility layer, it is a second
renderer. What follows is the line between the two, and it is a real line
rather than a matter of effort.

What 22 popular packs actually ask for, and the order of work that follows
from it, is in the [survey of popular shader packs](shaderpack-survey.md).

## Status, 2026-10-11

Rungs 1 and 3 below are done for the screen space chain, and rung 4 runs
every program a pack enables. What has been observed live is still only the
proof pack, on 2026-08-21 and 2026-10-10; real packs have so far been
loaded, translated and compiled offline, not run. Per pack results are in
`docs/develop/shaderpack-status.md`.

What is new since 2026-08-21, all in `src/iris/` and checked by
`goanna_iris_pack_test` and the offline compile check:

- `shaders.properties` goes through a preprocessor first (`iris_preproc.cpp`,
  the one `#if` engine the loader, the chain and the gbuffers translator
  share since later the same day):
  `#if`, `#ifdef`, `#elif`, `#define` and the rest, against the MC_ and
  IRIS_ macros and the pack's option defaults, which the loader gathers from
  the `#define` lines of its sources. `program.<name>.enabled` (and the
  `world0/` form) switches chain programs off. Option defaults can be
  overridden with `GOANNA_SHADERPACK_OPTIONS`, which rewrites the sources'
  `#define` lines as an Iris options file would.
- `uniform.<type>.<name>` and `variable.<type>.<name>` are parsed into an
  evaluator with OptiFine's function set (`if`, `smooth`, `in`, `between`,
  `frac`, `vec3` and so on, matrix elements as `m.1.2`), evaluated every
  frame against the standard block, and written into each pass's extra
  uniform block. A custom uniform named like a standard one replaces it.
- Each program's own conditionals are resolved per stage before
  translation, so a declaration in a pack's `#ifdef FSH` branch no longer
  collides with the vertex stage's.
- `iris.features.required` is read; Goanna declares no optional Iris
  feature, so a pack that requires one (Noble, Rethinking Voxels, Shrimple)
  is refused with the reason in `report()`.
- Depth reaches the pack in OpenGL's convention. Godot 4.5 stores reversed
  Z, so the effect copies the depth buffer inverted into the texture a pack
  reads; before this a pack's sky test (`depth == 1.0`) and every position
  reconstruction were inside out. `depthtex1` is a copy taken at
  `PRE_TRANSPARENT` by a companion effect (`make_depth_capture`), so depth
  writing translucents such as glass are in `depthtex0` only. Water writes
  no depth in Goanna, so it is in neither, which a pack's water detection
  will notice. `depthtex2` is `depthtex1`: the hand is drawn with the
  opaque pass. `centerDepthSmooth` is the centre pixel of `depthtex0`, read
  back asynchronously and smoothed with the pack's `centerDepthHalflife`.
  The readback's callback arrives on the main thread a frame or two later
  and may outlive the effect, so it holds a small shared state, never the
  effect itself. Bound to the effect, it crashed a client that freed the
  effect with a readback in flight (two core dumps on 2026-10-11,
  reproduced on 2026-10-12 with Godot 4.5.1 on the RTX 3090).
  `tests/iris_teardown.tscn` frees the effect at that moment, through
  `tools/goanna-headless fixture`; it needs the GPU, because lavapipe
  crashes earlier, clearing one of the pack's colour targets.
- `texture.noise` and `texture.deferred.*` and `texture.composite.*` image
  files are loaded and bound in place of the named sampler; raw (`.dat`)
  and resource textures are reported and skipped.
- `sampler2DShadow` gets a comparison sampler, over the pack's own shadow
  map since 2026-10-12 (rung 7, "The shadow map, as built"), and until it
  is drawn over a cleared 1x1 depth texture that says lit.
- The translator fixes the real packs needed are listed in the status page.

All of the effect side is in commit `a4410a9c`. Its first GPU run came
later on 2026-10-11, as a side effect of the gbuffers frames (see "The
gbuffers translator, as built" below): Eclipse's chain (3 of 3 passes) and
Mellow's (9 of 9) compiled and ran on the RTX 3090 against the render
service's fixture world (Luanti 5.17.0, Mineclonia, Godot 4.5.1), and both
clients then crashed with signal 11 in a `GoannaIrisEffect` callable taking
a `PackedByteArray`, which reads as the centre depth readback arriving
after the effect is gone; the frames had already been taken. How the
chain looks was not judged.

On 2026-10-13 a probe pack (a `final` that paints `near`, `far` and the
distance rebuilt from `depthtex0`) showed that until commit `0fce1c1b` the
chain's projection was wrong for every pack: `RenderSceneData` hands a
compositor effect the projection Godot renders with, its depth already in
Vulkan's reversed [0, 1], and `near` and `far` read off it came out as
-0.05. The effect now undoes the z row to OpenGL's form (the y flip stays,
because the chain's texture coordinates run top down). That was the whole
of Mellow's pale haze, and part of Eclipse's darkness; see "What was
observed" below.

The rest of this section is the state of 2026-08-21, kept because it is
still true unless a line above says otherwise.

On 2026-08-21 rung 1 was done and rung 4's machinery in place, measured
rather than claimed. `src/iris/` holds a pack loader (`iris_pack.cpp`), the GLSL translator
(`iris_glsl.cpp`) and `GoannaIrisEffect`, a `CompositorEffect` that runs a
pack's `deferred*`, `composite*` and `final` programs at `POST_TRANSPARENT`.
`GOANNA_SHADERPACK=/path/to/pack` loads one from `main.gd`. Against a local
Mineclonia server on Luanti 5.16.1, Godot 4.5.1 Forward+ on Vulkan (NVIDIA), the
proof pack in `project/tests/shaderpacks/proof/` renders: a `composite` writing
two targets through `/* DRAWBUFFERS:12 */`, and a `final` reading them back
through the ping pong, plus `depthtex0`, `noisetex` and live uniforms. The check
is `tools/test/test-shaderpack.sh`; see `docs/develop/shaderpack-testing.md`.

What that proves: GLSL 120 dialect packs translate and compile through
`shader_compile_spirv_from_source`; `colortex` targets live in the scene
buffers as named textures and resize with them; the uniform block and
sampler bindings are right; the chain order, DRAWBUFFERS mapping, clearing
and ping pong behave. What it does not prove: any real pack. The proof pack
is ours, written to exercise the dialect, and the long tail of pack variety
is untested.

Things learnt on the way, recorded so they are not relearnt:

- `gl_FragData[n]` is the n-th entry of the DRAWBUFFERS list, not colortex
  n. With `DRAWBUFFERS:12`, `gl_FragData[0]` is colortex1. The first draft
  had this backwards and Godot refused the pipeline with an output mask
  mismatch, which is at least a loud failure.
- Vulkan GLSL wants every varying located and every sampler bound, and bare
  `uniform float x;` is not allowed. So the pack's declarations are removed
  and re-emitted: one std140 block for the Iris uniforms, with a second per
  program for uniforms we do not know (they read zero, and are listed in the
  effect's `report()`), samplers declared only where a stage references
  them, varyings located by sorted name across both stages.
- std140 rounds the block size to 16 but members only to their own
  alignment. Rounding after every member silently moved every scalar.
- Colour space. Godot's colour buffer is linear HDR and is tonemapped after
  the effect; Minecraft's is gamma space LDR and a pack's `final` is the
  finished image. The effect encodes on the way into `colortex0` and decodes
  `final`'s output back to linear, and `main.gd` sets a linear tonemap while
  a pack owns `final`. `GOANNA_SHADERPACK_RAW=1` turns the bridge off for
  comparison. Without it a pack's result is tonemapped twice.
- Texture coordinates are not flipped: Vulkan's top left origin agrees with
  image row order, so an identity pass is an identity pass. `gl_FragCoord.y`
  runs the other way from GL, which a pack using it for anything other than
  a texture lookup will notice. Untested so far.
- The uniform set (rung 2) is partly live, 2026-08-21. From the session:
  the matrices, sun and moon, `sunAngle` and `worldTime`, `skyColor` (the
  server's day, dawn and night sky blended as `main.gd` blends it) and
  `fogColor` (the environment's fog colour, so the underwater tint while
  submerged), `rainStrength` and `wetness` (Luanti has no weather in the
  protocol; a rain or snow particle spawner attached to the player, which is
  how Mineclonia rains, reads as 1.0, and the effect ramps the two the way
  Minecraft and Iris do: 0.2 a second, then half lives of 30 s wetting and
  10 s drying), `isEyeInWater` (1 in any liquid, never 2: the node definition
  does not say which liquids are lava), `eyeAltitude`, `near`, `far`.
  Still constant on 2026-10-11: `eyeBrightness` and `eyeBrightnessSmooth`
  (240, 240; the client does not expose node light at a position yet),
  `moonPhase` and `worldDay` (0; the protocol carries no day count), health,
  hunger, air, `nightVision`, `blindness`, `atlasSize`, `fogStart`,
  `fogEnd`, `biome`. In custom uniform expressions `biome_precipitation`
  reads as rain and the OptiFine player flags (`is_on_ground` and the rest)
  read false.
- Not yet done: compute (`.csh`), `prepare`, `begin`, `setup` and
  `shadowcomp` programs, custom images and SSBOs, resource custom textures
  (`minecraft:...`), the `scale` and `flip` directives and multiview.
  Done on 2026-10-13, for Photon:
  - Varyings of struct type (its `clouds_params`) are left where the pack
    declared them, after their struct, and located there with a location
    per member.
  - `size.buffer.colortexN` sizes the buffer: a fraction of the screen
    when written with a decimal point (`0.5 0.5`), else pixels (`192
    108`). A pass drawing into it covers it whole, as Iris sets the
    viewport to the target.
  - Raw custom textures (`scattering.dat TEXTURE_3D RGB16F 32 64 32 RGB
    HALF_FLOAT`) are read as 1D, 2D or 3D textures in the layout the line
    gives, three components widened to four. A custom texture binds only
    to a sampler of its own dimension, so Photon's 3D noise named
    `colortex0` in the composite stage leaves its `sampler2D colortex0`
    reading the scene, and a trailing `.1` on the name is dropped.
  - A legacy sampler alias (`shadow`, `gaux1`) is renamed only where the
    pack declares a sampler by it; Photon's local `float shadow` had been
    turned into a second `shadowtex0`.
  - A `#if` continued over lines with a backslash is read whole by the
    loader's conditional pass.

  The gbuffers translator (rungs 5 to 7) is built
  since 2026-10-11 and the pack's own shadow map since 2026-10-12; see "The
  gbuffers translator, as built".

`GOANNA_SHADERPACK_DUMP=<dir>` writes each pass's translated GLSL, which is
the first thing to look at when a pack fails to compile: the error line
numbers refer to the pack's own file because the translator keeps lines.

Changed on 2026-08-22: the default pack will be a real one rather than one
of ours. Base-Shader first, Eclipse after it. Both are licensed to ship, the
lightmap coordinate a gbuffers pack needs turned out to be carried already,
and Base asks for little else, so the translator rungs move ahead of writing
a pack. See "The first target, and why it is Base-Shader" below, and task 5
in `docs/develop/launch-target.md`.

## What Godot gives us, checked rather than assumed

Two APIs decide whether this is possible at all, and both exist in 4.5.

`CompositorEffect` injects work into the scene render at five points:
`PRE_OPAQUE`, `POST_OPAQUE`, `POST_SKY`, `PRE_TRANSPARENT`,
`POST_TRANSPARENT`, through `_render_callback(type, RenderData *)`.

`RenderingDevice::shader_compile_spirv_from_source` compiles GLSL to SPIR-V
at runtime, so a pack's `.vsh`/`.fsh`/`.csh` can be compiled after
preprocessing without going anywhere near `.gdshader`. That is the whole
reason this approach beats translating to Godot's shader language: we
recreate the environment the GLSL expects instead of rewriting the GLSL.

`RenderSceneBuffersRD` is better than expected. Alongside
`get_color_texture()`, `get_depth_texture()` and `get_velocity_texture()` it
has `create_texture(context, name, format, ...)` and `get_texture(context,
name)`, which means `colortex0` through `colortex15`, the shadow maps and the
ping pong buffers can be allocated as named textures in Godot's own render
buffer pool, with its lifetime and resizing handling, rather than managed by
hand.

## Where the line falls

An Iris pack is not one kind of program. It is several, and they divide
cleanly on whether they draw geometry.

**The screen space chain: `deferred1..N`, `composite1..N`, `final`.** These
read `colortex*` and `depthtex*` and write `colortex*`. They are full screen
passes. They map onto `CompositorEffect` almost directly, and they are where
most of what people mean by "a shader pack" lives: volumetric light, screen
space reflection, ambient occlusion, colour grading, bloom, tonemapping, the
sky. This part is tractable.

**The geometry programs: `gbuffers_*` and `shadow`.** These do not
post process anything. They *are* how the world is drawn: Iris swaps them in
for Minecraft's own geometry rendering. There is no equivalent hook in
Godot, because `CompositorEffect` runs around the scene render, not instead
of it.

That is the line. Everything on the first side is a compatibility layer.
Anything that requires the second side is writing a renderer.

There is a further wrinkle behind it. Iris packs assume Minecraft's deferred
G buffer: `colortex0` is albedo, `colortex1` tends to be normals, and so on
by convention. **Godot's Forward+ is a clustered forward renderer and has no
such G buffer.** What it hands us is an already lit colour buffer. So even
the screen space chain is being fed something different in kind from what it
expects.

## The shape that resolves it

The way through is not one mechanism but two, chosen per program class:

```
                    IRIS PACK
                        |
        +---------------+---------------+
        v               v               v
 gbuffers_terrain  gbuffers_water     shadow
        |               |               |
        v               v               v
 Godot terrain      Godot water      Godot shadow
 SpatialShader      SpatialShader        pass
 vertex()           vertex()
 fragment()         fragment()
 light()            light()
                        |
                        v
                 Godot Forward+
                        |
              colour / depth / normal
                        |
                        v
             deferred / composite / final
                        |
                        v
                CompositorEffects
```

The geometry programs are **translated** into Godot spatial shaders, where
`vertex()`, `fragment()` and `light()` already have the shape a gbuffers
program has, and Godot's own forward and shadow passes then run them. The
screen space chain is **not** translated: it is compiled as GLSL through
`shader_compile_spirv_from_source` and run as `CompositorEffect`s, in the
environment Iris supplies. Each mechanism is used where it fits, and the
"there is no hook to replace geometry rendering" objection goes away, because
nothing is being replaced.

### Translated gbuffers must be unshaded

The subtlety that decides whether this works at all. An Iris gbuffers program
does not light anything: it writes G buffer data, and lighting happens later
in `deferred`. A Godot spatial shader, left alone, is lit by Godot. Translate
one naively and the surface is lit twice, once by Godot's model and once by
the pack's.

So a translated gbuffers program takes `render_mode unshaded`. Godot then
leaves the fragment alone, the colour buffer holds what the program wrote
rather than a lit result, and it behaves like a G buffer. This also answers
the forward versus deferred mismatch noted above, for the geometry the pack
actually supplies a program for: it is not that Godot's renderer is made
deferred, it is that the surfaces the pack owns stop being forward lit.

### Two translations, not one

Worth separating, because they have different shapes, different risks and
different amounts of prior art:

**1. API translation.** Iris uses its G buffer as an API between pack
authored geometry and pack authored postprocessing: the pack decides what
`colortex1` means and both halves agree. Godot has a fixed API between a
spatial shader and Forward+: `ALBEDO`, `NORMAL`, `ROUGHNESS` and the rest,
with meanings the engine picks. Translating one API onto the other is what
makes a surprising amount survive, and it is a semantic mapping job rather
than a compiler one. The hard cases are packs using `colortex*` or
`shadowcolor*` as arbitrary intermediate data with no corresponding material
concept, which is where extra targets or a `RenderingDevice` pass are the
answer; that low level API exists precisely for work outside the renderer's
abstraction.

**2. Language translation.** Compatibility profile GLSL into Godot's shader
language. Godot's own porting guide is clear this is not trivial: separate
programs merge into one file, `main` becomes `vertex()` and `fragment()`,
declarations and outputs work differently. Expect most of a pack's body to be
ordinary GLSL expressions and functions, with the work concentrated in legacy
syntax, Iris substitutions and semantic rewrites rather than spread evenly.

The second is much smaller than it first looks, because **the target is
known**. This is not general GLSL to Godot translation. It is
`gbuffers_terrain` into one specific spatial material, `gbuffers_water` into
another, against a shell we write by hand: a `.gdshader` that already
declares the Iris uniform and varying environment and provides its helper
functions, into which the pack's `main` bodies are placed. That reduces the
translator to expression level work inside a fixed harness, which is
glslang style parsing, the inverse of Godot's lowering rules, and a few dozen
Iris specific rewrites. Write the shell first and the translator's job
becomes obvious.

### Reference material, and which version of it

`servers/rendering/shader_types.cpp` in godotengine/godot is the authoritative
table of what each shader type's functions may read and write, and
`servers/rendering/shader_compiler.cpp` is the lowering that has to be
inverted. Both MIT, both current, and both readable without licence concern.

dfranx/GodotShaderTranscompiler is the same idea packaged, and is MIT, but it
is Godot **3.x GLES3** extracted verbatim in 2019. Godot 4's spatial shader
differs substantially: Vulkan, different built ins, different render modes.
Use it to see the shape of the problem; take the tables from current upstream.

### Unshaded is not a decision, and light() is always unused

`render_mode unshaded` skips Godot's lighting entirely, so `light()` never
runs in a translated gbuffers program. That is not a trade off to weigh per
program: it is always right, because a gbuffers program never wants engine
lighting in either shape a pack can take.

- The pack lights inline in the gbuffers fragment, sampling the lightmap
  through `lmcoord`, and outputs a lit pixel. Godot lighting it again is
  double lighting.
- The pack writes raw G buffer data and lights in `deferred`. Godot lighting
  it corrupts `colortex0` before the pack ever sees it.

Godot's lighting model is the wrong one either way, so it goes off, and the
`light()` box in the diagram above is never reached.

What is worth inferring is a different question with a trivial answer: does
the pack ship `deferred*` programs? That tells you where lighting happens,
which decides whether `colortex0` after the geometry pass holds lit colour or
raw albedo, and therefore what the composite chain is entitled to assume. It
is a directory listing, not an analysis.

### What lmcoord needs from Goanna, which is now carried

Both cases above have a dependency that is easy to miss. A pack reads
Minecraft's baked lightmap through `lmcoord`: block light in one axis, sky
light in the other. A pack that lights inline reads it in the gbuffers
fragment. A pack that lights in `deferred` reads it in gbuffers all the same
and writes it to a colortex for the lighting pass to use, because the
lightmap is the only source of torch and lava light either kind has. So this
is not a subset of packs; nearly every pack reads it somewhere. That is the
same data Luanti carries as per vertex light on mapblock meshes.

This was a hole until 2026-08-21, when per vertex light landed for its own
reasons. `CUSTOM0` now carries Luanti's `LIGHTBANK_NIGHT` in `r` and
`LIGHTBANK_DAY` in `g` on every node surface, near mesh and far tier alike;
`docs/systems/mesh-attributes.md` is the contract. So `lmcoord` is a scale of
what is already on the vertex, `CUSTOM0.rg * 255.0`, rather than a path to
revive. Earlier drafts of this page said otherwise and were right when they were
written.

The `lightmap` sampler itself, the small texture a pack multiplies that
coordinate through, is generated since 2026-10-11 by `GoannaIrisGbuffers`
each frame: sixteen by sixteen, block light against sky light, white at
noon under full sky as Minecraft's is, a dim blue at night, a warm torch
colour for block light. `CUSTOM0` holds brightness rather than a light
level, so the coordinate is `CUSTOM0.rg * 240.0`, Minecraft's own range,
and the table is linear in it rather than carrying a second light curve. A
first version tinted noon by the sky's colour and turned Base-Shader's gold
block brown on lavapipe, which is the kind of mistake only a frame shows.

### The limit is multiple render targets

`/* DRAWBUFFERS:0125 */` is a gbuffers program declaring it writes four
targets at once. Godot spatial shaders write a fixed set of built ins,
`ALBEDO`, `NORMAL`, `ROUGHNESS`, `METALLIC`, `EMISSION`, into Godot's own
pipeline. There is no MRT, so a program writing custom data to `colortex5`
cannot be expressed and that write is simply lost.

This is the real ceiling on the translation half, and it is worth being
precise about rather than discovering late:

- The common conventions map: `colortex0` to `ALBEDO`, normals to `NORMAL`,
  a specular or LabPBR target to `ROUGHNESS` and `METALLIC`. A pack following
  the usual layout is mostly expressible.
- A pack storing bespoke data in a spare target loses it, and whichever
  composite pass reads that target gets nothing.
- `Material::set_next_pass` can emulate MRT by drawing the geometry again per
  target. It costs a full geometry pass each and is worth it for two, not for
  eight. It also draws into the same colour buffer, so on its own it does
  not reach a `colortex`; each extra pass would need a target of its own.

So: most packs mostly work, a pack with an unusual G buffer layout does not,
and the failure is legible rather than mysterious once the DRAWBUFFERS
declaration is parsed and compared against what can be expressed.

What was built (2026-10-12) is the extra geometry pass per target, drawn
by a camera of its own into a target of its own rather than by
`set_next_pass`, and with every output kept rather than mapped onto
Godot's built ins; see "Second outputs" below.

### The LOD terrain has to be the same terrain

`docs/systems/far-rendering.md` draws distant terrain as coarse tiers. If those
tiers run the same node array shader against the same vertex layout as the
near mesh, then translating `gbuffers_terrain` into that shader covers the
vista for free. If they do not, the pack shades the near bubble and the
horizon stays as Godot drew it, which is the familiar broken look of an LOD
mod under a pack with no programs for it; Iris had to grow separate Distant
Horizons programs and a second depth texture to fix exactly that. Goanna
avoids it by having the LOD vertex layout carry `lmcoord`, the occlusion
term and the block ID from the start, and by drawing far terrain in the same
scene against the same depth buffer. That is why far rendering rungs 2 and
3 precede rung 5 here in `docs/design/roadmap.md`, and it is a real dependency
rather than a preference.

## The order of work

1. **Parse a pack and prove the pipeline.** Done, 2026-08-21, see the status
   section. `shaders.properties`, the program list, the `colortex` format
   directives. Allocate the buffers, compile one trivial `final.fsh` through
   `shader_compile_spirv_from_source`, run it as a `POST_TRANSPARENT` effect.
   This proved the approach in a day, which is why it sat first on this page and
   early in `docs/design/roadmap.md`'s order: its answer decides how much
   tonemap, bloom and reflection work is worth doing in `.gdshader` under
   `docs/design/pbr-plan.md`, "Lighting and exposure". The answer is: little,
   packs bring it.
2. **The uniform set.** Iris supplies a large, well documented set:
   `gbufferModelView`, `shadowLightPosition`, `frameTimeCounter`,
   `sunAngle`, `cameraPosition` and the rest. Goanna has all of these or can
   compute them. This is bookkeeping, not difficulty.
3. **The preprocessor.** Discussed below; the real work.
4. **The screen space chain in order**, with the ping pong buffer rules and
   `/* DRAWBUFFERS: */` honoured. The machinery is in and proven on a two
   pass pack; what remains here is the option and custom uniform parsing,
   and real packs.
5. **Translate `gbuffers_terrain`**, unshaded, into the node array shader
   path. One program, the most visible one, and the first real test of the
   translator. Its DRAWBUFFERS declaration says immediately whether the pack
   is expressible. The target is Base-Shader; the section below says why and
   lists what it asks for. Built and observed on the GPU, near and far,
   2026-10-11; see "The gbuffers translator, as built".
6. **`gbuffers_water`, then the rest.** Water is the one whose absence is
   most obvious, and it exercises vertex displacement. Base has no water
   program, so this rung is measured against Eclipse. The translation runs,
   displacement included. Eclipse draws its water in `composite` from
   targets only a second output can reach, so until 2026-10-12 its water
   surface was transparent; the second outputs now reach them, and on the
   GPU its water is drawn, tinted and reflecting the stage. See "Second
   outputs" below.
7. **Shadow.** This item first assumed Godot's own shadow pass would do,
   given vertex displacement that agrees with the terrain program. It does
   not: a pack looks its shadows up in a map drawn by its own `shadow`
   program, with its own matrices and distortion, and Godot's shadow atlas
   is neither. Built 2026-10-12 as a pass of Goanna's own that draws the
   near terrain with the translated shadow program into the pack's map,
   read by the gbuffers programs and the chain; observed on the GPU with
   Eclipse, on the stage and on `r1tod1`. See "The shadow map, as built".

Rungs 1 to 4 are the screen space chain and need no translator at all. Rungs
5 to 7 are the translator, and each is separately useful: a pack with only
its composite chain running already looks like a shader pack.

## The gbuffers translator, as built

Built 2026-10-11 by rungs 5 to 7 above. The parts:

- `src/iris/iris_preproc.cpp`, the preprocessor the whole loader shares
  (see "The preprocessor, which is the hard part"). The translator runs it
  in full on each stage the loader hands over, because a declaration
  inside an `#ifdef` cannot be parsed before the `#ifdef` is decided and
  Godot's shading language has no preprocessor of the right kind.
- `src/iris/iris_glsl_ast.cpp`, a parser into a syntax tree.
- `src/iris/iris_gbuffers.cpp`, the translator. It types every expression
  as it emits it in Godot's shading language, and that turned out to be the
  heart of the job rather than "expression level work inside a fixed
  harness": Godot converts nothing implicitly (`vec2(int, int)` is an
  error), has no global variables, no function prototypes, no comma
  operator, no non-square matrices and no shadow samplers, will not let a
  local share a global's name, builds a matrix only from whole columns,
  and lets no function but `vertex()` and `fragment()` write a varying or
  read a stage built in such as `FRAGCOORD`. Each has a rewrite: the
  conversions are written out; a global initialised from a uniform becomes
  a function returning its initialiser, a constant one a `const`, and any
  other a local of the main body; varyings, outputs and such globals a
  helper writes are passed to it as `inout` parameters, and the built in
  inputs it reads as `in` ones, which costs no interpolator; functions are
  emitted callees first; and a function both stages include is emitted
  once.
- Varyings are packed (since 2026-10-13). On the GPU Godot counts each
  varying declaration as one against a limit of 32, with its own spatial
  varyings included: MakeUp's terrain declared 21 and Godot counted 33. The
  front end, which does not count, accepted it. Every pack varying is a
  local of `vertex()`, copied at its end into `goanna_pk` slots of four
  components, one set per base type and interpolation (smooth float, flat
  float, flat int, flat uint), filled largest first and split over the
  room left when that saves a slot; `fragment()` starts by unpacking a
  local of each, which helpers get as `inout` parameters like any other
  local of main. A varying the fragment stage never names gets no slot,
  `gl_FogFragCoord` is carried the same way, a `bool` travels as a flat
  `int`, a matrix by its columns and a struct field by field. MakeUp's
  terrain went from 21 declarations to 10, its water from 24 to 15; no
  translated program of the seven packs checked declares more than 15.
- Fragment outputs keep the type the pack declared (Photon's shadow
  program writes a `vec3`) and are widened to a `vec4` where they reach
  `ALBEDO`, as GL fills missing components.
- `project/shaders/iris_gbuffers_shell.gdshaderinc`, the hand written
  shell. It answers the pack's inputs from the node mesh contract
  (`docs/systems/mesh-attributes.md`): `gl_Vertex` the world position,
  `gl_Color` the tile tint times Goanna's traced occlusion and, with
  `oldLighting`, Minecraft's face shading (top 1.0, bottom 0.5, sides 0.8
  and 0.6), `gl_MultiTexCoord1` the block and sky light, `mc_Entity.x` the
  pack's `block.properties` number for the node's block, `at_tangent`,
  `mc_midTexCoord` and `at_midBlock`, and `gl_FragCoord` in OpenGL's
  convention with a depth the pack's own `gbufferProjection` agrees with.
  The atlas is the material's texture array sampled at the face's layer,
  without `source_color`, so the pack reads gamma values as Minecraft gives
  them, and its colour output is converted to linear on the way into
  `ALBEDO`.
- `src/iris/goanna_iris_gbuffers.cpp`, `GoannaIrisGbuffers`: loads the
  programs through `iris::Pack`, with the same options, overrides
  (`GOANNA_SHADERPACK_OPTIONS`), `program.*.enabled` and macros as the
  chain, and with Iris's fallbacks (`gbuffers_terrain_cutout` to
  `gbuffers_terrain` to `gbuffers_textured_lit` to `gbuffers_textured` to
  `gbuffers_basic`; water to terrain first). It registers the Godot global
  parameters the translated code reads and sets them each frame from the
  player's camera: the Iris matrices (`gbufferModelView` is the camera's
  rotation alone, so player space is world less `cameraPosition`, as in
  Minecraft), the fixed function stand ins, the sun, time, fog, rain, the
  lightmap, and the pack's custom uniforms, evaluated from those values by
  the same evaluator the chain uses. `GoannaClient` puts the shaders on
  four surfaces: opaque array tiles (`gbuffers_terrain`), cut-out array
  tiles (`gbuffers_terrain_cutout`, alpha tested at `alphaTestRef`), the
  single texture leaves and plants (the cut-out program again), and water
  (`gbuffers_water`, blended). The far tiers share the array materials, so
  they take the same programs with nothing added for them.

`GOANNA_SHADERPACK` loads it beside the screen space chain, and
`GOANNA_SHADERPACK_GBUFFERS=0` leaves it out for comparison. Without a pack
none of it is created and every material is as it was.

A displaced vertex. A pack writes `gl_Position` in clip space with the
player camera's matrices. The shell takes it back to a world position and
writes `VERTEX`, so Godot transforms it for whatever pass is running, the
shadow pass included. It rebuilds the view position from `x`, `y` and `w`,
which a perspective projection keeps exactly; rebuilding from `z`, where
depth precision went, would move a vertex at a thousand nodes by about half
a node (worked out, not measured). Plain `ftransform()` leaves `VERTEX`
alone.

### Second outputs

Built 2026-10-12 (commit `e6c842a1`). A program writes more than its
colour: Eclipse's water puts a water mask in `colortex4`, its normal in
`colortex1` and its sky light in `colortex3`, and its terrain its normal
in `colortex1`, and the chain reads all of them. Godot's spatial shader
has one colour output, so each target is drawn by a pass of its own.

- The translator keeps every output (`GbuffersResult::second`): each
  `colortex` from 1 to 15 a program writes, and the colour's own target
  when that is not `colortex0`, so a pack keeping its colour in
  `colortex1` finds it there. `fragment()` ends in a branch on
  `CAMERA_VISIBLE_LAYERS`: the five cull mask bits from bit 15
  (`iris::kGbuffersPassShift`) hold the colortex plus one under a second
  output camera, and there the program writes that output raw to `ALBEDO`
  (and `ALPHA` where blended). A target the program does not write gets 0,
  or alpha 0 where blended, so an opaque surface still hides what is
  behind it. Every ordinary camera, and the shadow pass, has all five bits
  or none, and gets the colour as before.
- `game/effects/iris_targets.gd` makes one `SubViewport` per target some
  program writes and the chain samples (`GoannaIrisEffect::reads_colortex`),
  up to eight. Each shares the world, renders HDR with a transparent
  background, an environment with no sky, fog, glow or exposure and a
  linear tonemap, and an empty `Compositor` so the chain does not run in it
  too. Its camera follows the player's every frame, at the main view's 3D
  resolution, and sees only layer 15 (`NODE_SURFACE_LAYER`, which the node
  meshes near and far carry beside layer 1) plus its marker bits.
- `GoannaIrisEffect::set_gbuffers_target` takes each viewport's texture
  every frame, and the chain copies it into the colortex at its start in
  place of the clear.
- Translated water writes depth when the pack has a screen space chain, as
  Minecraft's does, so `depthtex0` holds the water surface and `depthtex1`
  does not, which is how Eclipse measures the water it looks through. Not
  without a chain, which is the only reader: written depth also hides any
  translucent surface Godot sorts after the water. Base-Shader's frames on
  `r1tod1` were the same with and without it (0.8 per cent of pixels
  differing by more than 15 levels, looking down on a lake).

- A target only the water program writes (Photon's translucent layer in
  `colortex13`, Eclipse's `colortex3`) cannot be left clear by opaque
  terrain in its pass: the terrain writes zero there and Godot gives an
  opaque surface alpha 1, so Photon's chain found an opaque black layer
  over all its land. `GoannaIrisGbuffers::translucent_targets()` names
  such targets, and the chain copies them only where `depthtex0` (with
  translucent geometry) is nearer than `depthtex1` (without), leaving the
  clear elsewhere, as Minecraft's masked write does (since 2026-10-13).

`GOANNA_SHADERPACK_SECOND=0` leaves the targets cleared, for comparison.
What it costs and where it stops:

- A whole geometry pass per target: four for Eclipse (`colortex1`, 3, 4
  and 6). Not measured.
- Values pass through a half float target, so a pack packing bits into a
  16 bit target (Photon keeps its material data in `colortex1` and 2 as
  `RGBA16`) loses them.
- Only node surfaces are in these views. What else is in a node mesh
  (Goanna's own grass) draws there with its own shader, which no light
  reaches, so near black; entities, the sky and particles are absent and
  hide nothing.
- Whether Godot renders the subviewports before the main view in the same
  frame, or a frame late, was not checked; a still camera cannot show it.

### The shadow map, as built

Built 2026-10-12 for rung 7. A pack's shadows come from its `shadow`
program drawn into a map its own lookups agree with, distortion and all;
Godot's shadow atlas is not that. The first slice draws the near terrain
only. The parts, and the choices behind them:

- **What is drawn.** Copies of the near terrain meshes, nothing else: the
  regional batches and the per block special meshes, which are what
  `GoannaClient` gives terrain materials to. Each copy is a child
  `MeshInstance3D` named `iris_shadow` (`GoannaClient::irisShadowTwin`),
  sharing the mesh, on render layer 13 alone, casting nothing into Godot's
  shadow maps and out of GI. Each surface takes the shadow program
  translated for its shell (opaque array tiles, cut-out array tiles,
  foliage), with the base material's uniforms copied; a surface the pack
  draws no shadow for (water, glass, lava, glow, anything not on a pack
  program) takes a material that puts every vertex on one point outside
  the clip volume. The far tiers are not drawn: they share the array
  materials, but have no copies, and most of them lie beyond a pack's
  `shadowDistance` (160 by default) anyway.
- **How the meshes are reached.** Through Godot's renderer, not a
  `RenderingDevice` draw of Goanna's own. Godot 4.5 exposes no mesh's
  vertex buffer as an RD resource, so a pass of our own would need a second
  copy of every near mesh uploaded by hand and kept in step with every
  remesh. A `SubViewport` sharing the world, with an orthographic `Camera3D`
  whose cull mask is layer 13 alone, draws exactly the copies and nothing
  else: entities, sky, particles and lights are all on other layers, so
  Godot does no lighting, no shadow maps and no sky for it, and its own
  `Environment` clears to white with fog, glow and GI off. The camera is
  the pack's shadow box (`shadowDistance` either side, 0.05 to 256 deep,
  100 nodes out along the light), so Godot's culling is the pack's.
- **Where the pack's maths runs.** In the translated shadow program
  (`GbuffersOptions::shadow_pass`). Its fixed function matrices are the
  light's (`iris_shadow_gl_ModelViewMatrix` is `shadowModelView` after the
  camera's translation, `gl_ProjectionMatrix` is `shadowProjection`), so
  `ftransform()` and the pack's own `shadowProjection * shadowModelView`
  agree. Its `gl_Position`, displacement and distortion included, goes
  straight to `POSITION`: x, y and w as written, so the map's texels sit
  where the pack's lookups put them, and z moved from OpenGL's `-w..w` to
  the reversed `0..w` Godot's depth test wants
  (`goanna_shadow_position` in the shell). Its colour reaches `ALBEDO`
  unconverted, for `shadowcolor0`.
- **Keeping the program out of other cameras.** The shadow program writes
  its position only when `CAMERA_VISIBLE_LAYERS` is exactly layer 13, the
  shadow camera's mask; in any other camera every vertex lands on one point
  outside the clip volume. The player's camera also drops layer 13 from
  its mask, so it does not even cull the copies. Layer 13 (bit 12) is
  clear of `NODE_SURFACE_LAYER` (bit 14) and of the second output pass
  bits (15 to 19), which the shadow camera leaves all clear, so the
  programs draw their colour there.
- **The matrices** (`src/iris/iris_shadow.cpp`, pure arithmetic with a
  native test). `shadowModelView` looks from the light at the player:
  view +z is the direction to the sun by day and the moon by night (the
  same choice as `shadowLightPosition`), x stays across the sun's path so
  the map does not spin, the player is 100 nodes out, and the frame snaps
  to `shadowIntervalSize` (2 by default) so texels do not crawl as the
  player walks. `shadowProjection` is the orthographic box above. Both are
  built from Goanna's own sun, not from `sunAngle` and the pack's
  `sunPathRotation`: the shadows have to fall from the sun the server
  shows, so `sunPathRotation` is read, reported and not applied. The
  settings come from the pack's const directives (`shadowMapResolution`,
  `shadowDistance`, `shadowIntervalSize`), an option's name resolved to its
  value; a perspective map (`shadowMapFov`) is reported and drawn
  orthographic. `GoannaIrisGbuffers::update` sets the matrices for the
  shadow program and every gbuffers program, `main.gd` moves the culling
  camera and hands them to the screen space chain, all from the same
  numbers in the same frame.
- **Keeping the result.** `GoannaIrisShadow`, a `CompositorEffect` in the
  shadow camera's `Compositor`, copies the viewport's depth and colour at
  `POST_TRANSPARENT` into textures of its own, made once at the first
  frame's size: shadowtex0 as `D32` (a comparison sampler in the chain
  needs a depth format) and as `R32F` (for Godot shaders, through a
  `Texture2DRD`), both in OpenGL's convention (0 at the light's near
  plane, 1 where nothing was drawn), and `shadowcolor0` as `RGBA16F`.
  `GoannaIrisEffect` binds the depth copy for `shadowtex0` and
  `shadowtex1` and the colour for `shadowcolor0`; the gbuffers programs
  read the `Texture2DRD`s as the globals `iris_shadowtex0`,
  `iris_shadowtex1` and `iris_shadowcolor0`, sampled nearest. A
  `sampler2DShadow` lookup in a gbuffers program, which Godot's shading
  language cannot express, is written out as a `step` against the stored
  depth. Until the first map is drawn every one of them reads white, so
  nothing is in shadow, as before the pass existed. Frees go through the
  render thread in a callable that owns only the RIDs, after the
  `Texture2DRD`s have let go of them.
- **Synchronisation.** Godot draws a `SubViewport` before the viewport that
  contains it, so in a frame the map is drawn and copied before the
  player's view samples it, all on the render thread, ordered by the render
  graph's barriers. The matrices are set on the main thread before the
  frame is drawn, so the map and its lookups use the same ones. Were the
  order ever the other way, the lookups would be one frame behind the map.

What the first slice leaves out: `shadowtex1` is the same map as
`shadowtex0`, because no translucent geometry is drawn into it, so a pack's
coloured shadows through glass and water (the `shadowtex0` against
`shadowtex1` test) never trigger; entities, the player, the far tiers,
glowing surfaces and the procedural grass cast nothing; `shadowcolor1`,
`shadowcomp` and per program shadow variants (`shadow_solid`,
`shadow_cutout`) are not read; `shadowDistanceRenderMul` and the
`shadow.culling` directives are ignored; and a pack that sets
`sunPathRotation` sees its shadows fall from Goanna's sun. With
`GOANNA_SHADERPACK_SHADOW=0` the pass is left out and the map reads as all
lit, for comparison.

### What was observed

Offline, no GPU, Godot 4.5.1, 2026-10-11: `goanna_iris_gbuffers_test` (in
`cmake --build build --target check`) and `tests/iris_gbuffers.gd` pass,
the second against Base-Shader 3.0, which is CC0-1.0 and is in
`project/tests/shaderpacks/base-shader/` as test data. With
`GOANNA_IRIS_PACK` pointing at them, the terrain, cut-out, water and
foliage programs of Eclipse 1.0, Mellow 3.4.1a, BSL 10.1.8, Complementary
Reimagined r5.9.3 and MakeUp Ultra Fast 9.5g also pass Godot's shader
front end (and, before the reboot that day, those of Miniature, Sildur's
Enhanced Default and Photon's terrain; Photon's water puts a struct in a
varying, which Godot refuses). The front end is not the GPU backend: it
does not count varyings, and Mellow passed it and then failed on lavapipe
with 33 against Godot's limit of 32, which is what moved the built in
inputs from varyings to parameters. Complementary's translation crashed
Godot's compiler outright, because constant folding `mat4(1.0) * vec4(...)`
indexes past an array in Godot 4.5.1; the translator drops an identity
texture matrix rather than write that expression, and the client would
otherwise crash on load.

On lavapipe, before the reboot, through `tools/goanna-render --software`
(640 by 360, the fixture world): the first Base-Shader frame turned the
gold block brown, which led to the white noon lightmap; Mellow failed with
the varying limit above; and Mellow's terrain, once compiling, was black,
because its lighting reads custom uniforms that then read zero.

On the GPU, the same evening, through `tools/goanna-render` on an RTX
3090, 1280 by 720, Luanti 5.17.0 server, Mineclonia (release 38561),
Godot 4.5.1, the branch clean at the commit named:

- Base-Shader, near and far (`r1tod1`, a v7 Mineclonia world, at
  `36fe743e`): the near bubble, the far tiers out to the horizon and the
  water all drawn by the pack, in its flat face shaded look, with its own
  fog closing on the far tiers in the fog colour; no shader errors in the
  client log. The far tiers needed nothing of their own, as "The LOD
  terrain has to be the same terrain" predicted.
- Base-Shader on the fixture's stage (at `f745b425`): grass, stone bricks,
  gold, oak leaves (now through the foliage surface) and water, beside the
  same stage with no pack.
- Eclipse on the stage: terrain drawn through `gbuffers_textured_lit`
  (it has no terrain program) and nearly black, with the whole frame dark
  under its chain; the water surface transparent, as its water program
  writes colour 0 with alpha 0 for water and puts the water in
  `colortex4`, `colortex1` and `colortex3`, which are dropped and listed in
  `report()`. Not traced further.
- Mellow on the stage, with custom uniforms: no longer black, but the whole
  frame is a pale haze over faint shapes. Its chain runs over the result,
  and which half makes the haze was not traced.

On 2026-10-12 and 13, the same card, server, game and Godot, through
`tools/goanna-render` on the fixture's stage (grass, stone bricks, gold,
oak leaves and a water source spreading over the stone floor, noon,
clear), the branch clean at the commit named; frames compared by eye and
by averaging regions of the PNGs:

- At `19f48140`, before this work: Base-Shader as on 2026-10-11; Eclipse
  dark with its water transparent, as above. The client with Eclipse
  loaded was stopped through the launcher with no signal 11 and no core
  dump, where on 2026-10-11 both pack clients crashed; that is a stop, not
  a quit from inside.
- A debug copy of Eclipse whose `final` shows the targets: `colortex1`
  holds the normals (the floor (0.5, 1, 0.5), the block faces towards the
  camera blue, the water's wave normals rippling), and where the water is,
  `colortex4` and `colortex3` are 1 and the rest 0, edges where they
  should be; the sky and Goanna's grass are 0. So the second outputs reach
  the chain, raw and aligned.
- Eclipse with second outputs, at `e6c842a1`: the water drawn, pale
  blue-grey with the darker shapes its screen space reflections find,
  where without them (`GOANNA_SHADERPACK_SECOND=0`) the floor shows
  through; the rest still dark.
- Mellow split into its halves: the geometry programs alone (the chain's
  files removed from a copy) give a lit, recognisable stage; the chain
  alone (`GOANNA_SHADERPACK_GBUFFERS=0`) gives the haze; with
  `BORDER_FOG=false` the haze is gone. A probe pack then showed `near` and
  `far` reading -0.05 in the chain, the projection fault described in the
  status section, fixed in `0fce1c1b`.
- At `0fce1c1b` (this run's service had another session's copy of
  `r1tod1` for its world, so real terrain stands behind the stage): Mellow
  draws the stage by day under its own sky and fog, the terrain beyond the
  stage clear. Eclipse is in daylight: a blue
  sky with clouds, the water blue and reflecting the grass and the blocks
  in it, the floor a dark blue-grey; its block faces stay dark, which is
  its own lighting for faces the noon sun does not face (`shadowColor`
  for a surface edge on to the light), not compared with Iris. Without
  second outputs the water is a flat dark plane with no reflection.
  Base-Shader is as before, region by region within a level or two,
  except Goanna's own grass, which the pack does not draw and whose
  colour differed in every run, the baseline included. Photon, now
  translating, draws its terrain magenta under the 15 of its 20 chain
  passes that compile.
- At `0fce1c1b` on `r1tod1`, near (110 nodes up, looking down on the lake
  and along it) and far (240 up, out to the horizon): Eclipse's lake is
  blue water with fine ripples and the islands reflected dark under them,
  out to where the far tiers take over; the land and trees are washed
  white by its fog, which is thick beyond a few tens of nodes; from 240 up
  only the water and the sky keep their colour. Without second outputs the
  lake is a flat dark grey under the same fog. Mellow is clear and green
  near and far, its border fog closing the far tiers at the camera's far
  plane; its lake reads as the lake bed in pale squares, the water itself
  nearly clear. Base-Shader is as on 2026-10-11.

The shadow map, 2026-10-12, through `tools/goanna-render` on the RTX 3090
(NVIDIA 615.71.09), 1280 by 720, Luanti 5.17.0 server, Mineclonia
(release 38561), Godot 4.5.1, Eclipse 1.0 with `SSAO_ENABLED=false` (its
SSAO reads normals and turns the stage nearly black), each frame against
the same with `GOANNA_SHADERPACK_SHADOW=0`:

- On the stage, at `24530daa` (the shadow commit before the rebase onto
  rung 6, with the debug overlay uncommitted): the shadow viewport, shown
  in a corner with `GOANNA_SHADERPACK_SHADOW_SHOW=1`, holds the stage seen
  from the sun, barrelled by Eclipse's distortion, the trunk, leaves,
  pillars and gold slab where they stand, and the kept `shadowtex0` is the
  same shape in depth, 1.0 round it. With `SOFT_SHADOWS=false` the floor
  takes Eclipse's teal shadows of the leaf canopy, the pillar, the wall and
  the slab on its posts, at 8:24 in the morning falling west, as Godot's own
  shadows fall in the frame without a pack, and at 15:36 falling east. With
  Eclipse's default soft shadows the frames with and without the map differ
  in fewer than 400 pixels: its filter scores a point fully in shadow 0.15
  (`docs/develop/shaderpack-status.md`, "The shadow map"). A probe pack of
  ours (a plain `shadow` program and a terrain program that halves the
  light where its lookup is in shadow) shows the same shadows, hard, with
  the jagged edges a 1024 map over 320 nodes gives without distortion.
- On `r1tod1`, with the code as committed, on rung 6 (`b41c0f40`): from
  14 nodes over a frozen lake looking at a snowy island with spruces, the
  snow tops west of the spruces are in shadow in the morning and lit in
  the afternoon, and from 22 up looking north the steps of the slope to
  the east are shadowed in bands on the side away from the morning sun.
  The ice, which Goanna draws with its own shader, takes no shadow. The
  far tiers are as without the map. The dark blue grid on the lake behind
  the island is in the frames without the map too.

MakeUp and Photon, 2026-10-13, through `tools/goanna-render` on the RTX
3090, 1280 by 720, Luanti 5.17.0, Mineclonia, Godot 4.5.1, a copy of
`r1tod1`, noon, clear, three poses (110 nodes up looking down on the lake
and along it, and 14 up facing a snowy island); Base-Shader, Eclipse and
Mellow beside them for regressions:

- Before (main at `5575c88a`), from the client logs of the run that
  queued this work: MakeUp's frame black, with "Too many varyings used in
  shader (33 used, maximum supported is 32)" from its geometry programs;
  Photon magenta, with "Invalid arguments to operator '=': 'vec4,
  vec3'" (its shadow program's `vec3` output) and 5 of 20 chain passes
  failing.
- At `e3848de3` (varyings packed, Photon's chain compiling): no shader
  errors in either client log, the render service's problems list empty
  for every job, and the effect reporting MakeUp 5 of 5 and Photon 20 of
  20 passes compiled. MakeUp draws: its clouds, its terrain dark and
  fading to black with distance, its water black. Both are its geometry
  programs reading targets Goanna cannot give them: its terrain fogs
  towards `gaux4`, the sky colour its `gbuffers_skybasic` would write, and
  its water refracts `gaux1`, the opaque scene its `deferred` pass copies
  before Minecraft draws translucent geometry; both read black. Photon drew
  a quarter size copy of its frame in the top left corner over black,
  which was `size.buffer` (its debug view of `colortex5` showed the copy
  already in the history buffer, and turning bloom and TAA off changed
  nothing).
- At `b9bffecc` (`size.buffer`, raw textures): Photon fills the frame with
  its sky, horizon haze and fog over dark land silhouettes. A debug copy
  of Photon writing its decoded albedo from `deferred4` still showed the
  land black, which led to the water only second output above.
- At `c0ecc01d`: Photon draws the land lit in its own palette, warm
  sandstone and dirt, green and dark spruce canopies, snow on the island
  and its spruces with soft contact shading, a deep navy sky going hazy
  at the horizon, and red and white specks where its lake surface meets
  the lake bed. Its water is near black, and from 14 nodes up the frozen
  lake reads as its terraced bed, the ice not shown. Eclipse's frames
  differ from the build before in under 3 per cent of pixels; Base-Shader,
  Eclipse, Mellow and MakeUp at `b9bffecc` differ from `e3848de3` in
  under 4 per cent, and each looks as in the entries above.

Not observed: any displaced vertex (Eclipse's waves, Mellow's waving
leaves) on the GPU; any pack at night, in rain or under water; the shadow
map at night; performance, the shadow pass's included.

### Additional camera and world inputs

Both the screen space chain and geometry programs receive the integer and
fractional camera position, their previous frame values, camera movement
per frame (`velocity`) and the server's cloud height. Geometry custom
uniforms can override a standard uniform, as they can in the chain.
The added player flags and end-flash uniforms currently have false or zero
fallbacks; `firstPersonCamera` is true. These declarations do not establish
support for every Minecraft player state or dimension effect.

### Targets a geometry program reads

Geometry programs can sample `colortex0` to `colortex15`, including the
legacy `gaux` names. The translator records the targets it reads and
registers texture globals. Translucent programs also read the opaque scene
through Godot's depth texture, with reversed depth converted to OpenGL
window depth. Screen coordinates and gradients are flipped; targets with
absolute `size.buffer` dimensions retain their data map coordinates.

This is an approximation of Iris's ordering, not full deferred rendering:

- Geometry reads receive the actual target after the prepare and deferred
  passes, available on the next frame. Targets written beside colour can
  store depth or masks in alpha, so they are not replaced with native
  scene colour. `texture.gbuffers` custom images are not loaded here.
- Fragment `prepare` programs and their numbered variants run before
  deferred in the screen chain. Where they write a background into a
  geometry target, existing geometry pixels are restored over it using
  depth, leaving the prepared sky intact. This does not move execution
  before Godot's geometry; geometry still sees the previous snapshot.
- A sampler passed through a helper function does not receive the direct
  call's coordinate conversion; the translator reports this limitation.
  Offset and gather operations still have the existing approximations.

`report().gbuffers_reads` names the source used for each target. Copies use
RGBA32F, which Godot can bind through `Texture2DRD`. This avoids losing
further bits in the copy, but cannot recover data already lost in the half
float second output viewports.
On resize the render thread creates replacement textures; the main thread
queues their binding before old textures are released on the render
thread. `iris_teardown.tscn` exercises resizing and disposal.

The chain honours legacy format and clear declarations as well as modern
names. New targets are initialised to zero even when `Clear=false`, and
the last written ping pong side is retained across frames. The small
`tests/shaderpacks/history` pack checks accumulation independently of a
real pack's exposure or temporal filter.

### Pack sky geometry

The loader translates `gbuffers_skybasic` and `gbuffers_skytextured`, with
Iris's basic and textured fallbacks. A dome centred on the camera receives
the server's sky colour. Stars and textured sun/moon geometry use the same
programs with their own `renderStage` values. Sky vertices keep the pack's
projected direction at the far depth, without writing depth. The secondary
output cameras include this geometry, so sky masks reach the chain too.

When this sky program is present, the native sky background steps aside.
The pack may draw procedural stars, sun and moon in its dome shader and
suppress the supplied geometry itself. These meshes approximate Minecraft's
sky geometry; the server still supplies celestial textures, time and star
settings. Custom sky textures and the separate sunset gradient are not
implemented. Missing custom samplers read transparent black and are reported.

### What is left

- **The second outputs' cost and precision.** Built (see "Second
  outputs"), but each target is a whole geometry pass, not yet measured,
  and values pass through half floats, which loses the bits Photon packs
  into its 16 bit material targets. One render target per pass would need
  the geometry drawn through `RenderingDevice`, which neither the
  second outputs nor the shadow map do. Of the packs whose terrain programs were checked, BSL and MakeUp
  write `colortex1` and Complementary `colortex3`, 4 and 6 besides the
  colour. All six checkpoint packs have now been captured with them.
- **Photon's water and its approximations.** It runs whole since
  2026-10-13 (above), but its water is near black and its ice is not
  shown, not traced. Its sky light comes from a compute pass
  (`deferred4_a`, `SH_SKYLIGHT`) Goanna does not run, so that ambient term
  reads zero; its material data loses the low byte of each 16 bit channel
  in the half float second outputs. History now retains the last written
  ping pong side, but explicit `flip` directives remain unsupported.
  Not compared with Iris.
- **Geometry inputs and pass ordering.** Geometry can now read copied
  colortex targets and opaque depth, as described above. Full fidelity
  needs the deferred chain before translucent geometry and geometry
  custom textures. Target copies arrive one frame late.
- **The rest of the shadow map.** The first slice draws opaque, cut-out
  and foliage near terrain only; see the end of "The shadow map, as
  built" for what it leaves out: translucent casters and so `shadowtex1`
  and coloured shadows, entities, the far tiers, glow and Goanna's own
  grass, `shadowcomp`, the per program shadow variants, `sunPathRotation`.
  Its cost is not measured: a second scene render of the near terrain,
  with Godot's depth prepass, each frame.
- **Other scene geometry**: entities, clouds, the hand, particles
  and the procedural grass keep Godot's shaders; their programs
  (`gbuffers_entities`, `gbuffers_clouds` and the rest) are not loaded.
- `atlasSize` is a single tile's 16 by 16 because there is no atlas, so a
  pack that does arithmetic on atlas coordinates (parallax, neighbouring
  tiles) is not answered; `moonPhase` and `worldDay` remain constants.
  Eye brightness now samples the camera node's raw light banks, with the
  pack's smoothing half-life. Sky light is conservative where lamp light
  dominates the daytime bank; Luanti does not send separate sky values.
- A pack whose translation Godot's compiler crashes on takes the client
  with it. One such construct is avoided; others may exist.
- Local multiplayer: the globals are not scoped per view as `RenderScope`
  scopes Goanna's own, so two players with a pack would share one camera.

## The first target, and why it is Base-Shader

Read on 2026-08-22, from the pack sources rather than from their pages.
Base-Shader is CC0-1.0, source at `github.com/Bestsoft101/Base-Shader`. Eclipse
is CC-BY-4.0, distributed as a zip through Modrinth with no public source
repository. Both are licensed for Goanna to ship, Eclipse with attribution. An
earlier draft of `docs/develop/launch-target.md` said no third party pack was
licensed for us to ship. That was wrong, and it is the reason this plan changed.

**Base-Shader has no screen space chain at all.** Fourteen `gbuffers_*`
programs, `block.properties`, `entity.properties`, `fog.glsl`, and no
`deferred`, `composite` or `final`. So it is not a pack the machinery from
rungs 1 to 4 can run: `Pack::load` succeeds because it finds `.fsh` files,
`compositeChain()` comes back empty, no passes are built and the frame is
untouched. A pack that loads and changes nothing is the worst failure
available here, because nothing reports it, and `GoannaIrisEffect::report()`
should say so rather than leave it to be noticed.

That is also what makes it the right first target for rung 5. Every one of
its programs is the same handful of lines. `gbuffers_terrain` entire:

```glsl
// vsh
color = gl_Color * texture2D(lightmap, clamp(gl_MultiTexCoord1.xy / 255.0f,
                                             0.5f / 16.0f, 15.5f / 16.0f));
texcoord = gl_MultiTexCoord0.xy;
gl_Position = ftransform();
// fsh
vec4 albedo = texture2D(texture, texcoord) * color;
albedo.rgb = mix(albedo.rgb, gl_Fog.color.rgb,
                 getFogStrength(fogShape, gl_Fog.start, gl_Fog.end));
gl_FragData[0] = albedo;
```

There are no normals, no second render target, no vertex displacement, no
parallax and no shadow sampling anywhere in the pack. So the MRT ceiling
described above is never reached, and rung 5 against Base is a hand written
shell plus a substitution table, which is the shape this page predicted the
work would take.

| What the pack asks for | What Goanna answers with |
| --- | --- |
| `gl_Vertex`, `gl_Color`, `gl_MultiTexCoord0` | `VERTEX`, `COLOR`, `UV` |
| `gl_MultiTexCoord1` (`lmcoord`) | `CUSTOM0.rg * 240.0` |
| `ftransform()` | Godot's own transform: leave `VERTEX` alone |
| `texture2D(texture, uv)` | `texture(albedo_array, vec3(uv, UV2.x))` |
| `lightmap` | generated per frame from the sky and torch colour |
| `gl_Fog.color`, `.start`, `.end`, `fogShape` | uniforms from the drawn distance |
| `mc_Entity.x` | `UV2.y`, the block semantic ID |
| `gl_FragData[0]` | `ALBEDO` and `ALPHA`, under `unshaded` |
| `MC_RENDER_STAGE_*` | preprocessor constants |

The one genuine mismatch in that table is the atlas. Minecraft hands a pack
one 2D atlas and the pack's `texcoord` indexes it directly; Goanna's node
material is a `sampler2DArray` with the layer in `UV2.x`. Base never does
arithmetic on `texcoord`, so the substitution is exact for it. A pack that
offsets within the atlas, for parallax or for a neighbouring tile, cannot be
answered this way and will have to be met with an atlas built for the
purpose. Base not needing that is precisely why it goes first.

**Eclipse is the second target, and it is a different shape.** It has
`composite`, `composite1` and `final`, plus `gbuffers_water` and `shadow`,
so it exercises rungs 6 and 7 where Base does not. Four things about it are
worth knowing before starting:

- Its `final.fsh` is an identity pass. The ACES fit is written out in full
  and then commented out of the call. So "the pack's final pass is visible"
  cannot be a test against Eclipse.
- `composite.fsh` wraps its whole body in `if (water >= 0.1)`, where `water`
  is `colortex4.r` written by `gbuffers_water`, and `composite1.fsh` reads
  its normals from `colortex1`. Without the geometry programs those targets
  are never written, so the chain is inert. Eclipse is not a rung 4 pack
  that happens to have geometry; it is a whole pack or nothing.
- It is `#version 330 compatibility`, not 120: `in`, `out`,
  `layout(location = 0) out vec4`, `texture()`, and `RENDERTARGETS` rather
  than `DRAWBUFFERS`. The translator already handles both comment forms and
  both declaration keywords, but it blanks only unlocated `in` and `out`
  declarations, so an already located output will collide with the output
  emission and needs handling.
- `composite1.fsh` declares `vec3 sample`. `sample` is reserved from GLSL
  4.20, so it is rejected at the `#version 450` the translator emits. A pack
  is entitled to that name in its own dialect, so renaming reserved words is
  the translator's job, not the pack's problem.

### Fog ownership, settled

A pack that supplies `gbuffers_terrain` does its own fog in that program,
which is what Base's `fog.glsl` is for. Godot's environment fog must then be
switched off, or terrain is fogged twice, once by `main.gd` and once by the
pack. Unlike the tonemap rule this needs no declaration from the pack and no
Goanna specific property: supplying a terrain program is the signal, because
a pack that has one has taken over the surface the fog is applied to.

The rule, then, and it applies to every pack rather than to ours alone:

- The pack has `final`: Godot's tonemap goes linear. Already implemented in
  `project/game/main.gd`.
- The pack has a translated terrain program: the drawn distance `main.gd`
  already computes (the environment's depth fog begin and end) is handed to
  the pack as `gl_Fog.start` and `gl_Fog.end`. `far` on its own is the
  camera's far plane, not what Goanna draws, so a pack scaling fog by `far`
  would fog the far tiers wrongly. As built on 2026-10-11 the environment's
  fog is not switched off: every translated shader takes
  `render_mode fog_disabled` instead, which keeps Godot's fog off exactly
  the surfaces the pack fogs and on everything else (the sky, entities, the
  procedural grass), with no change to `main.gd`'s fog writes. The same
  holds for the volumetric cloud layer, so a camera inside it sees pack
  terrain through it while Godot's own surfaces stay clouded. The tonemap
  goes linear, as for a pack with `final`, because the terrain program
  writes display colour.
- Neither: Godot keeps both, as today.

### What unshaded costs, stated plainly

`render_mode unshaded` is not optional, for the reasons above, and it takes
Godot's lighting off every surface the pack supplies a program for. Normal maps,
roughness, specular, SSAO, SDFGI and the node lights stop applying to terrain
while such a pack is running. Base-Shader recreates vanilla Minecraft's flat
look by design, which is what "vanilla-like" on its page means, so with Base
running the baked PBR pack and the lighting defaults settle nothing about what
the player sees. That is a real conflict with the sentence at the top of
`docs/develop/launch-target.md`, and it is a decision about what the default
should be rather than a defect to fix.

## The preprocessor, which is the hard part

Iris rewrites pack GLSL before the driver sees it, and packs depend on that
rewriting having happened. The work is bounded but it is not small:

- Legacy dialect. Packs are written against old GLSL: `attribute`,
  `varying`, `texture2D`, `gl_FragData[]`, fixed function matrices like
  `gl_ModelViewMatrix`. All of it has to be rewritten to something a modern
  compiler accepts, with the fixed function state supplied as uniforms.
- `/* DRAWBUFFERS:0125 */` and `/* RENDERTARGETS: 0,1,2 */` comments, which
  are not comments at all but the pack declaring its outputs.
- `#define` driven feature toggles from `shaders.properties`, and the option
  menus packs expose.
- `#include`, with its own path rules.

Iris does this with glsl-transformer, which is **AGPL-3.0**. Do not use it
and do not read it. Write a preprocessor against the documented dialect
instead: it is a rewriter over a small, well specified subset, not a general
GLSL compiler, because the output only has to satisfy the driver.

That last clause holds for the screen space chain, whose output goes to
glslang. It does not hold for the gbuffers programs, whose output goes to
Godot's shading language, which needs every type written out; there the
translator is a parser and a typed emitter (see "The gbuffers translator,
as built"). Both sides run their `#if` and `#define` lines through the same
preprocessor, `src/iris/iris_preproc.cpp`, in two modes: conditionals only,
text left for glslang (the loader's pass over `shaders.properties`,
`block.properties` and every program), and full expansion on top of that
(the gbuffers translator). Function-like macros work in both.

## On licence, corrected

The reasoning that a rewrite avoids adopting Iris's licence is right, but
the framing is off in a way worth fixing, because this repository has got
licences wrong before.

Goanna's built binary is **already LGPL-3.0-or-later**, because Goanna's and
Luanti's terms are both "or later" and mini-gmp is LGPL-3.0-or-later. See
`THIRD-PARTY.md`. So Iris's LGPL-3.0 would be *compatible* with the binary;
it is not the barrier.

The real reasons to write rather than copy:

- Goanna's **source** is LGPL-2.1-or-later. Copying LGPL-3.0 source in would
  make those files LGPL-3.0 and fragment the tree.
- **glsl-transformer is AGPL-3.0**, which is a genuine problem and the one
  piece to stay clear of entirely.
- Iris is Java against Minecraft's OpenGL renderer. Nothing survives the trip
  to a C++ GDExtension on Vulkan anyway, which was the conclusion in
  `docs/systems/far-rendering.md` and holds here.

So: work from Iris's **documentation** and the shader pack format, which is a
de facto interface specification and the part that is not the copyrightable
expression. Do not work from its source. That distinction is what keeps a
reimplementation a reimplementation.

## Why the block map matters here

This is the part that is easy to miss and is the reason the texture mapping
work pays for itself twice.

Since 2026-08-21 the node side of this exists: `src/goanna_materials.h`
builds, per session, a table of the Minecraft block each node most
resembles (through the texture map and the nodedef, one vote per tile) and
writes its index into `UV2.y` on every node surface, near and far. What is
still to do here is the pack side: parsing `block.properties` and mapping
its block names onto that table's `block_names`, so `mc_Entity.x` answers
with the pack's own numbers.

Shader packs branch on block semantics, not on block names. A pack ships a
`block.properties` assigning Minecraft blocks to numeric IDs, and its shaders
read that ID through `mc_Entity.x` to decide that this surface is leaves and
should wave, that one is water and should refract, that one emits light.
Without those IDs a pack still runs and renders flat: no waving, no water,
no emission.

Goanna needs to answer "which Minecraft block is this Luanti node" to fill
that in, which is exactly what `project/texture_maps/mineclonia.csv` and
kooostia16's CC0 mapping already do, from the other direction. The same
correspondence that lets a Minecraft resource pack dress a Luanti game lets
a Minecraft shader pack understand it.

Where the map is blank the node gets no ID and renders unspecialised, which
is the correct failure: unremarkable rather than wrong.

## Where this is most likely to fail

- **The forward renderer mismatch.** Packs are written against a deferred G
  buffer that Godot does not have. Rung 5 approximates it; how convincing
  that is across real packs is unknown and should be tested early, on rung 1,
  with a pack that does something visible.
- **The translator is a real transpiler.** Godot's shader language is GLSL
  shaped but is not GLSL: no `gl_` built ins, its own uniform and varying
  declarations, its own function set. Translating gbuffers programs is source
  to source work on a legacy dialect, bounded but not small.
- **MRT is the ceiling**, per the section above.
- **Pack variety.** Iris compatibility in practice means a long tail of packs
  each depending on something slightly different. The roadmap above reaches a
  look; it does not reach "most packs work", and that gap is open ended.
- **Performance.** A pack's composite chain can be a dozen full screen passes
  at native resolution, on top of what Goanna already renders.
