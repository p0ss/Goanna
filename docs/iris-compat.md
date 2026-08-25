# Plan for loading Iris shader packs

The aim is to load an Iris or OptiFine shader pack and have it render, not to
be a drop in replacement for Iris. Drop in compatibility means implementing
Minecraft's renderer, and that is not a compatibility layer, it is a second
renderer. What follows is the line between the two, and it is a real line
rather than a matter of effort.

## Status, 2026-08-21

Rung 1 below is done and rung 4's machinery is in place, measured rather
than claimed. `src/iris/` holds a pack loader (`iris_pack.cpp`), the GLSL
translator (`iris_glsl.cpp`) and `GoannaIrisEffect`, a `CompositorEffect`
that runs a pack's `deferred*`, `composite*` and `final` programs at
`POST_TRANSPARENT`. `GOANNA_SHADERPACK=/path/to/pack` loads one from
`main.gd`. Against a local Mineclonia server on Luanti 5.16.1, Godot 4.5.1
Forward+ on Vulkan (NVIDIA), the proof pack in
`project/tests/shaderpacks/proof/` renders: a `composite` writing two
targets through `/* DRAWBUFFERS:12 */`, and a `final` reading them back
through the ping pong, plus `depthtex0`, `noisetex` and live uniforms. The
check is `tools/test-shaderpack.sh`; see `docs/shaderpack-testing.md`.

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
  Still constant: `eyeBrightness` and `eyeBrightnessSmooth` (240, 240; the
  client does not expose node light at a position yet), `moonPhase` (0; the
  protocol carries no day count), health, hunger, air, `nightVision`,
  `blindness`, `centerDepthSmooth`, `atlasSize`, `fogStart`, `fogEnd`.
- Not yet done, and not far off: `shaders.properties` option `#define`s and
  custom uniforms, compute (`.csh`) programs, `depthtex1`/`depthtex2` (both
  are `depthtex0` today), `shadowtex*` (a 1x1 depth of 1.0, so nothing is in
  shadow), multiview. The gbuffers translator (rungs 5 to 7) has not been
  started, and `docs/roadmap.md` says why it waits.

`GOANNA_SHADERPACK_DUMP=<dir>` writes each pass's translated GLSL, which is
the first thing to look at when a pack fails to compile: the error line
numbers refer to the pack's own file because the translator keeps lines.

Changed on 2026-08-22: the default pack will be a real one rather than one
of ours. Base-Shader first, Eclipse after it. Both are licensed to ship, the
lightmap coordinate a gbuffers pack needs turned out to be carried already,
and Base asks for little else, so the translator rungs move ahead of writing
a pack. See "The first target, and why it is Base-Shader" below, and task 5
in `docs/launch-target.md`.

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
`docs/mesh-attributes.md` is the contract. So `lmcoord` is a scale of what
is already on the vertex, `CUSTOM0.rg * 255.0`, rather than a path to
revive. Earlier drafts of this page said otherwise and were right when they
were written.

What is still absent is the `lightmap` sampler itself, the small texture a
pack multiplies that coordinate through. Minecraft generates it from the
time of day, so Goanna has to generate its own from the server's sky colour
and its torch colour. Without it a translated gbuffers program samples
nothing and the world renders fullbright, which is the same symptom the
missing coordinate would have caused and is worth not confusing with it.

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
  eight.

So: most packs mostly work, a pack with an unusual G buffer layout does not,
and the failure is legible rather than mysterious once the DRAWBUFFERS
declaration is parsed and compared against what can be expressed.

### The LOD terrain has to be the same terrain

`docs/far-rendering.md` draws distant terrain as coarse tiers. If those
tiers run the same node array shader against the same vertex layout as the
near mesh, then translating `gbuffers_terrain` into that shader covers the
vista for free. If they do not, the pack shades the near bubble and the
horizon stays as Godot drew it, which is the familiar broken look of an LOD
mod under a pack with no programs for it; Iris had to grow separate Distant
Horizons programs and a second depth texture to fix exactly that. Goanna
avoids it by having the LOD vertex layout carry `lmcoord`, the occlusion
term and the block ID from the start, and by drawing far terrain in the same
scene against the same depth buffer. That is why far rendering rungs 2 and
3 precede rung 5 here in `docs/roadmap.md`, and it is a real dependency
rather than a preference.

## The order of work

1. **Parse a pack and prove the pipeline.** Done, 2026-08-21, see the
   status section. `shaders.properties`, the program list, the `colortex`
   format directives. Allocate the buffers, compile one trivial `final.fsh`
   through `shader_compile_spirv_from_source`, run it as a `POST_TRANSPARENT`
   effect. This proved the approach in a day, which is why it sat first on
   this page and early in `docs/roadmap.md`'s order: its answer decides how
   much tonemap, bloom and reflection work is worth doing in `.gdshader`
   under `docs/pbr-plan.md` step 3. The answer is: little, packs bring it.
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
   lists what it asks for.
6. **`gbuffers_water`, then the rest.** Water is the one whose absence is
   most obvious, and it exercises vertex displacement. Base has no water
   program, so this rung is measured against Eclipse.
7. **Shadow.** Godot already runs a shadow pass, so a translated shadow
   program mostly needs vertex displacement to agree with the terrain
   program, or waving grass casts unwaving shadows. Base has no shadow
   program either; Eclipse ships one.

Rungs 1 to 4 are the screen space chain and need no translator at all. Rungs
5 to 7 are the translator, and each is separately useful: a pack with only
its composite chain running already looks like a shader pack.

## The first target, and why it is Base-Shader

Read on 2026-08-22, from the pack sources rather than from their pages.
Base-Shader is CC0-1.0, source at `github.com/Bestsoft101/Base-Shader`.
Eclipse is CC-BY-4.0, distributed as a zip through Modrinth with no public
source repository. Both are licensed for Goanna to ship, Eclipse with
attribution. An earlier draft of `docs/launch-target.md` said no third party
pack was licensed for us to ship. That was wrong, and it is the reason this
plan changed.

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
| `gl_MultiTexCoord1` (`lmcoord`) | `CUSTOM0.rg * 255.0` |
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
  `project/main.gd`.
- The pack has a translated terrain program: Godot's `fog_density`,
  `fog_aerial_perspective` and `fog_sky_affect` writes are skipped, and the
  drawn distance `main.gd` already computes is handed to the pack as
  `gl_Fog.start` and `gl_Fog.end` instead. `far` on its own is the camera's
  1000, not what Goanna draws, so a pack scaling fog by `far` would fog the
  far tiers wrongly.
- Neither: Godot keeps both, as today.

### What unshaded costs, stated plainly

`render_mode unshaded` is not optional, for the reasons above, and it takes
Godot's lighting off every surface the pack supplies a program for. Normal
maps, roughness, specular, SSAO, SDFGI and the node lights stop applying to
terrain while such a pack is running. Base-Shader recreates vanilla
Minecraft's flat look by design, which is what "vanilla-like" on its page
means, so with Base running the baked PBR pack and the lighting defaults
settle nothing about what the player sees. That is a real conflict with the
sentence at the top of `docs/launch-target.md`, and it is a decision about
what the default should be rather than a defect to fix.

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
  `docs/far-rendering.md` and holds here.

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
