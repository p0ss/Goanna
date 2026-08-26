# Third party code and licences

Goanna's own code is LGPL-2.1-or-later, in `LICENSE`. Goanna is not,
however, a self-contained program. It links a subset of Luanti's engine and
several libraries that Luanti vendors, and it uses Godot's C++ bindings.
This file lists everything that ends up in a built
`libgoanna.linux.template_debug.x86_64.so`, and the runtime components shipped
beside it, where they come from, and under what terms.

The engine dependencies are not copied into Goanna: `luanti/` and
`godot-cpp/` are git submodules pinned to release tags, so upstream's own
notices travel with the source. The optional Terrain Diffusion runtime is a
small vendored worldmod and is called out separately below.

## Summary

| Component | Source | Linkage | Licence |
| --- | --- | --- | --- |
| Goanna | this repository | n/a | LGPL-2.1-or-later |
| Luanti engine subset | `luanti/src`, submodule at 5.16.1 | static | LGPL-2.1-or-later |
| IrrlichtMt, CPU image classes only | `luanti/irr/src` | static | zlib licence, Copyright (C) 2002-2012 Nikolaus Gebhardt |
| mini-gmp | `luanti/lib/gmp` | static | LGPL-3.0-or-later **or** GPL-2.0-or-later, Copyright 1991-2022 Free Software Foundation |
| sha256 | `luanti/lib/sha256` | static | OpenSSL licence (the old, four clause form), Copyright (c) 1998-2011 The OpenSSL Project |
| JsonCpp | `luanti/lib/jsoncpp` | static | Public domain, or MIT where public domain is not recognised |
| Zstandard | system library, static if available | static | BSD-3-Clause or GPL-2.0, at your option |
| zlib | system library | dynamic | zlib licence |
| godot-cpp | `godot-cpp/`, submodule on branch 4.5 | static | MIT, Copyright (c) 2017-present Godot Engine contributors |
| Terrain Diffusion for Luanti runtime | `project/vendor/terrain_diffusion` | deployed as an optional worldmod | MIT, Copyright (c) 2026 p0ss |
| Terrain Diffusion default output | optional [versioned download](https://github.com/p0ss/terrain-diffusion-luanti/releases/tag/default-1m-v1) | copied from the shared cache into new local worlds | generated data from MIT-licensed generator and model |

## Optional Terrain Diffusion runtime

`project/vendor/terrain_diffusion/` is the lightweight Luanti mapgen runtime
from Terrain Diffusion for Luanti. Goanna deploys it only for a prepared
Mineclonia + Terrain Diffusion world. Its complete MIT notice is shipped as
`project/vendor/terrain_diffusion/LICENSE`.

The inference environment, model weights, upstream source checkout, source
training datasets and generated default bake are not vendored. The optional
default is generated model output rather than a copy of those source rasters:
a format-4, 4 by 4 tile bake made with seed 1234. Goanna downloads its immutable
6.9 MB release archive on first use and verifies SHA-256 before extracting it.
Players choosing a freshly generated world download and run the inference
environment separately.

The exact source list is `cmake/luanti_core.cmake`. It is deliberately a
small subset: the network layer, serialisation, node and item definitions,
MapBlock and Map, inventory and metadata, the SRP authentication stack, and
the CPU-only Irrlicht image classes. No renderer, no GUI, no scripting, no
server.

## What this means for the built binary

The extension combines LGPL-2.1-or-later code (Goanna, Luanti) with
LGPL-3.0-or-later code (mini-gmp). Because both Goanna's and Luanti's terms
are "or later", the combination is distributable, and the effective licence
of the built binary is **LGPL-3.0-or-later**, not LGPL-2.1. The source in
this repository remains LGPL-2.1-or-later.

This is the same combination that upstream Luanti's own builds contain, for
the same reason, so it is not a situation Goanna has invented. It is
recorded here because "LGPL-2.1-or-later" on its own understates what is in
the binary.

Anyone distributing built binaries should read this section rather than
just the README. If mini-gmp's terms are a problem for a particular
distribution, Luanti can be built against system GMP instead
(`USE_SYSTEM_GMP`), which Goanna does not currently do.

## Required acknowledgements

These are obligations that attach to binary distribution, not just source.

**OpenSSL**, for `luanti/lib/sha256`, clauses 3 and 6 of its licence:

> This product includes software developed by the OpenSSL Project for use in
> the OpenSSL Toolkit (http://www.openssl.org/)

**IrrlichtMt / Irrlicht**, for the CPU image classes. The zlib licence does
not require acknowledgement, but Irrlicht's own notice asks for one, and
notes that Irrlicht is based in part on the work of the Independent JPEG
Group:

> This software is based in part on the Irrlicht Engine, Copyright (C)
> 2002-2012 Nikolaus Gebhardt, and on the work of the Independent JPEG
> Group.

**Godot**, via godot-cpp, MIT. The MIT licence text and copyright notice
must accompany distribution; they are in `godot-cpp/LICENSE.md`.

## Shader code in this repository

`project/shaders/` holds Goanna's own GDShader. None of it is linked into
`libgoanna`, so it is not in the table above, but one method in it is
adapted rather than invented and carries a licence with it.

**`water.gdshader`, the wave field.** The sum of octaves, the drag term that
shifts each octave by the slope of the ones before it, and the constants
that space them out (the weight, frequency and time multipliers, and the
step between wave directions) are from afl_ext's "Very fast procedural
ocean", <https://www.shadertoy.com/view/MdXyzX>, MIT, by way of the Glimmer
shader pack, <https://github.com/jbritain/glimmer-shaders>, MIT, Copyright
(c) 2024 Josh Britain. The MIT licence asks that its copyright notice and
permission notice travel with any substantial portion of the work, so both
projects are named in the file's own header as well as here. The code in
`water.gdshader` is a rewrite against Godot's shading language rather than a
copy: the surrounding absorption, refraction, screen space reflection and
far tier handling are Goanna's.

## Media in this repository

The screenshots under `docs/` are renders of worlds served by Luanti games,
using media those games sent to the client. They are derivative works of
that media.

- `docs/e0b_*.png` show Luanti's Development Test game (devtest). Its media
  are covered by Luanti's own media licence: CC BY-SA 3.0, Copyright (C)
  2010-2012 celeron55, Perttu Ahola and contributors, with some assets under
  CC BY-SA 4.0. See `luanti/LICENSE.txt`.
- `docs/e0a_*.png`, and the other Mineclonia screenshots under `docs/`, show
  a Mineclonia world. Mineclonia separates its code licence from its media
  licence, and it is the media that applies here. Per its `LEGAL.md`, the
  code is GPL-3.0 but the textures are CC BY-SA 4.0, being based on Pixel
  Perfection by XSSheep and Pixel Perfection Legacy by Nova Wostra, of which
  most are verbatim copies; other media there defaults to CC BY-SA 3.0.
  Individual mods add their own files naming further authors, 27 of them in
  release 37652, so `LEGAL.md` is the floor rather than the whole account.
  None of this is Luanti's own media licence, which covers only the engine's
  own assets.

Both sets are reproduced here under those terms, for documentation.

## Trademarks

"Luanti" and "Minetest" are used in this repository only to identify the
software Goanna interoperates with. Goanna is an independent project and is
not affiliated with, endorsed by or supported by the Luanti project. No
Luanti or Minetest branding, logo or icon is included here.

"Godot" is used likewise, to identify the engine.

## Keeping this current

Update this file whenever `cmake/luanti_core.cmake` gains a dependency, a
submodule is bumped to a release with different vendored libraries, or a
screenshot from a new game is added. It is the file an upstream reviewer and
a distribution packager will both read first.
