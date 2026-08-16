# Transplanting Luanti code

Goanna is built by carrying Luanti's own client logic across, not by
reimplementing it. That only works if the carried code stays recognisable to
the people who wrote it, so that a Luanti change can be re-applied and a
Luanti developer can read a Goanna file without relearning it.

This document is the discipline for doing that. It is also, deliberately,
the answer to the question a Luanti reviewer will ask first: what exactly did
you copy, and what did you change?

## The three tiers

Luanti code enters Goanna in one of three ways. Know which one you are in
before you start.

### Tier 1: compiled from the submodule, untouched

The preferred case. `luanti/` is a git submodule pinned to a release tag, and
`cmake/luanti_core.cmake` compiles a chosen subset of its sources directly
into the `luanti_core` static library. Nothing is copied and nothing is
edited. The network layer, serialisation, node and item definitions, MapBlock
and Map, inventory and metadata, the SRP authentication stack, the raycast
and object properties, and the CPU-only parts of Irrlicht that the meshing
and model code need (`CImage`, colour conversion, `SkinnedMesh`, the B3D,
X, OBJ and glTF mesh loaders and the mesh manipulator, behind a stub scene
manager) all come across this way. The list in `cmake/luanti_core.cmake` is the inventory for
this tier.

If a file can be compiled from the submodule, compile it from the submodule.
Adding a file to the list in `cmake/luanti_core.cmake` costs nothing at merge
time. Copying it costs forever.

### Tier 2: copied into src/transplant, minimally changed

For files that cannot compile unmodified because they reach for Irrlicht's
renderer, or for `Client` and `ClientEnvironment`, which Goanna does not have.
These live under `src/transplant/`, keep their upstream path structure
(`src/transplant/client/mapblock_mesh.cpp` came from
`luanti/src/client/mapblock_mesh.cpp`) and are changed as little as the
compiler will allow.

Rules for a tier 2 file:

1. **Keep the original header.** The upstream `// Luanti`, SPDX tag and
   copyright lines stay exactly as they are, and they stay first, so that
   licence scanners find the SPDX tag near the top of the file.
2. **Add a Goanna note immediately below them.** Say where the file came
   from and what was changed. The note is for a reviewer diffing against
   upstream, so be specific about substitutions:

   ```cpp
   // Luanti
   // SPDX-License-Identifier: LGPL-2.1-or-later
   // Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>
   //
   // Transplanted from luanti/src/collision.cpp.
   // Goanna changes: takes a Map* instead of an Environment*; object
   // collision (which needed the client and server environments) is stubbed
   // until Goanna has its own active objects; profiler names are fixed
   // strings.
   ```

3. **Change nothing you do not have to.** Do not reformat, do not rename, do
   not "improve" the maths, do not apply Goanna's text style to upstream
   comments. Every cosmetic change is a conflict at the next merge and a
   line a reviewer has to read.
4. **Prefer a shim over an edit.** If upstream calls something Goanna does
   not have, consider giving Goanna that thing under the name upstream
   expects. `src/goanna_luanti_client.h` is exactly this: a stand-in class
   named `Client` with the handful of accessors the meshing code calls, so
   `mapblock_mesh.cpp` and `content_mapblock.cpp` compile against unmodified
   headers. Likewise `goanna_image_hooks.h` replaces the Irrlicht video
   driver's image creation for `imagesource.cpp`.
5. **Record it.** Add a row to the inventory below in the same commit.

### Tier 3: Goanna's own code

Anything under `src/` that is not `src/transplant/` and is not a copy. New
files are LGPL-2.1-or-later like the rest, carry an SPDX tag, and follow
Goanna's own conventions rather than Luanti's.

`src/luanti_shims.cpp` sits between tiers. It holds a small number of
functions copied verbatim from a Luanti translation unit that Goanna cannot
compile whole, because compiling it would pull in the server environment and
the scripting layer. It is documented as copied, at the top of the file.

## Inventory of transplanted files

Two rows below are marked **Misplaced**. They are files that grew into tier 2
transplants while carrying a Goanna name in `src/`. Listing them here is the
minimum; moving them under `src/transplant/` is the correct fix, and until
that happens a reviewer diffing against upstream has to be told where to
look. Do not let this pattern spread: if a file crosses into mostly upstream
code, it moves.

Every tier 2 file, what it came from, and why it could not be compiled from
the submodule. Keep this table current. It is the first thing an upstream
reviewer will read.

| Goanna file | Upstream origin | Why copied | Substance of the change |
| --- | --- | --- | --- |
| `src/transplant/collision.h`, `.cpp` | `src/collision.{h,cpp}` | Signatures take `Environment*` | `Map*` instead of `Environment*`; object collision stubbed; fixed profiler names |
| `src/transplant/localplayer.h`, `.cpp` | `src/client/localplayer.{h,cpp}` | Depends on `Client`, the client active object and the event manager | No `Client`, no CAO, no event manager; `Map*` instead of `Environment*`; privileges as plain flags; the legacy `old_move` path dropped |
| `src/transplant/client/mapblock_mesh.cpp` | `src/client/mapblock_mesh.cpp` | Uses the Irrlicht video driver | No hardware mapping hint, no minimap blocks; `PartialMeshBuffer::draw()` is a no-op; defines `g_goanna_no_light`, which makes `encode_light()` return opaque white and so disables the baked vertex lighting; transparent buffers keep their indices; otherwise verbatim |
| `src/transplant/client/content_mapblock.cpp` | `src/client/content_mapblock.cpp` | Reaches `Client` | Compiles against Goanna's `Client` stand-in; `applyFacesShading` calls are skipped while `g_goanna_no_light` is set |
| `src/transplant/client/node_visuals.cpp` | `src/client/node_visuals.cpp` | Uses the video driver for array textures | Array textures unsupported; mesh manipulation and mesh loading via the `Client` stand-in |
| `src/transplant/client/imagesource.cpp` | `src/client/imagesource.cpp` | Creates images through the video driver | Image creation and decoding go through `goanna_image_hooks.h`; otherwise verbatim |
| `src/transplant/environment_raycast.cpp` | `src/environment.cpp` | `Environment::continueRaycast` needs an `Environment` (`getMap`, `getSelectedActiveObjects`) | Only `isPointableNode()` and `continueRaycast()` copied; a free function in namespace `goanna` taking `Map&` and an object-selection callback; body otherwise verbatim |
| `src/luanti_shims.cpp` | `src/inventorymanager.cpp` | The whole file drags in the server environment and scripting | Two functions copied verbatim, nothing else |
| `src/goanna_active_object.h`, `.cpp` | `src/client/content_cao.{h,cpp}` | `GenericCAO` is built around Irrlicht scene nodes | No scene nodes; state snapshot for the Godot side instead; movement calls the transplanted collision code rather than `ClientEnvironment`. **Misplaced:** roughly two thirds of the `.cpp` is upstream, so it is a tier 2 transplant and belongs under `src/transplant/` |
| `src/goanna_sky.cpp` | `src/client/sky.cpp` | Sky rendering is Irrlicht; only the maths is wanted | The wicked time of day and sky body position functions only, each marked at its definition. Also credits numzero |

## Tracking upstream

`luanti/` is pinned to a release tag, currently 5.16.1. When it moves:

1. Bump the submodule to the new tag on its own branch.
2. Rebuild. Tier 1 files either compile or tell you what changed.
3. For each tier 2 file, diff the new upstream against the version the file
   was taken from, and re-apply the Goanna changes listed in its header note
   on top of the new upstream text. Never merge the other way around.
4. Update the inventory if a change of substance moved.
5. Say the new tag in the commit message.

The point of keeping tier 2 small and its changes documented is that step 3
stays an afternoon rather than a project.

## What not to do

- Do not fork Luanti. There is no Goanna patch queue against the engine, and
  there should never be one. If Goanna needs an upstream change, the change
  belongs upstream, proposed on its own merits.
- Do not copy a file because it is convenient. Try tier 1 first. Try a shim
  second.
- Do not change protocol behaviour. Goanna is a client for ordinary servers
  and must ask for nothing a vanilla client does not ask for, and must
  receive nothing a vanilla client would not receive. Anything that gives a
  Goanna player information or reach a vanilla player lacks is out of scope,
  permanently, and will be reverted.
- Do not restyle upstream comments. See `docs/style.md`, which exempts
  `src/transplant/` for this reason.
