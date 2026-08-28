# Roadmap

The project is organised around a compatibility ladder and a rendering
quality loop. The current priority is a reliable playable world; fidelity is
added only when it does not leave visible gaps or consume the frame budget.

## Complete or substantially working

- Luanti protocol, authentication, world state and server connection.
- Movement prediction, digging, placing, inventory, formspecs, entities,
  sounds, weather and core particle paths.
- Near-terrain regional batching and immutable multithreaded mesh builds.
- Persistent far terrain, multi-tier LOD, server summaries and terrain
  occlusion.
- Terrain Diffusion integration with a versioned downloadable default bake.
- Godot lighting, Luanti light attributes, material defaults and authored
  LabPBR overrides.
- FPS/position/performance diagnostics and local Start Game/Join Game flows.

## Current priorities

### 1. Complete world coverage

The far field must present a continuous, conservative landscape before adding
more detail. Seabeds should occlude underwater caves, unknown frontiers should
close cleanly, and LOD replacement must keep the old mesh until the new mesh
is ready. The server's asynchronous generation and streaming limits remain a
separate backend concern; see [far-rendering.md](far-rendering.md).

### 2. Atmospheric presentation

Volumetric valley mist and raymarched cumulus are now present. The clouds
march a 3D noise body in the sky pass rather than the range-limited froxel
grid, while
local mist retains a quality off/low path for slower GPUs. Continue tuning
both against day, night, weather, altitude and underwater scenes. The
atmosphere must reveal silhouettes rather than hide the map behind a uniform
white wall.

### 3. Material and lighting coverage

Finish the per-game material audit, validate more LabPBR packs, and bring the
far shader closer to near-field lighting without increasing distant texture
reads excessively. The working plan is [pbr-plan.md](pbr-plan.md).

### 4. Compatibility tail

Implement node texture animation, entity animation, connected textures and the
remaining particle and formspec behaviours. Each feature should be gated by
the protocol/game capability it actually needs rather than by a Goanna-only
assumption.

### 5. Shader-pack compatibility

Extend the working Iris compositor path, then decide which gbuffers features
can be translated without creating a second material or lighting contract.
See [iris-compat.md](iris-compat.md).

## Engineering constraints

- Preserve Luanti gameplay and protocol semantics.
- Keep transplanted Luanti code small, attributable and easy to refresh.
- Bound memory, mesh queues and server generation work over long sessions.
- Prefer one coherent lower-detail world to a high-detail world with holes.
- Measure changes with deterministic fixtures and the in-game performance
  overlay before changing defaults.

Open questions and compatibility boundaries belong in the specialised design
documents, not in a chronological implementation diary.
