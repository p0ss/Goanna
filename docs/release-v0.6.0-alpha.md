# Goanna v0.6.0-alpha

Goanna 0.6 is the performance release. In many situations it can deliver
more than twice the frame rate of 0.5, while keeping the long views, dynamic
lighting and detailed materials that define the project.

The largest gains come from moving terrain work off the main thread, reducing
the number of distant-region submissions, and giving the graphics profiles
control over the effects that actually cost frames. Streaming a new area is
also substantially smoother: the worst warm terrain publish measured 7.3 ms,
where the old path routinely spent 10–29 ms building a region on the main
thread.

## Highlights

- Near-region batch and occluder construction now run on mesh workers. The
  main thread only assembles and publishes the finished surfaces, guarded by
  generation stamps so stale work cannot replace newer terrain.
- Distant terrain uses a more aggressively coarsened region ladder. In the
  reference vista this reduced region meshes from 3,116 to 604 and camera draw
  calls from 4,703 to 1,895 without changing the rendered geometry.
- Box terrain occluders are now the default. Together with arrival-aware
  rebuild debouncing, they cut the measured movement hitch rate from 299–304
  to 199 per minute and improved the 1% low from 22.6 ms to 15.2 ms on the
  validation route.
- Retiering, far-summary requests, horizon extraction and renderer-stat
  collection are now bounded or amortised instead of occasionally scanning
  large retained-world structures in one frame.
- Far terrain no longer casts low-value shadows or participates in SDFGI,
  avoiding work as new geometry arrives.

## Graphics profiles

Medium, High and Ultra now vary screen-space resolution, shadow-map detail and
SSIL as well as view distance and lamp count. These are the controls that
measurement showed actually move frame time; the material-quality sliders
remain unchanged where lowering them did not produce a meaningful gain.

On the reference RTX 3090 at 2560×1371, settled live sweeps measured:

| Profile | Vista by day | Village at night | Frame-time change vs Ultra |
| --- | ---: | ---: | ---: |
| Ultra | control | control | — |
| High | 104 FPS | 123 FPS | -21% / -24% |
| Medium | 157 FPS | 172 FPS | -47% / -46% |

That is roughly 1.9× Ultra's frame rate for Medium in the controlled scenes.
Results will vary by world, view, resolution and hardware; gains above 2× have
also been observed in other play situations.

## A horizon that belongs to the world

The sky now responds to the terrain horizon instead of treating sunrise and
sunset as unobstructed astronomical events. Hills can hold the sun below the
land while high clouds catch the first light, fog and cloud colour follow the
same lighting authority, and biome sky changes ease rather than switching in
one frame.

Known distant terrain is also baked off-thread into an albedo-and-distance
panorama and relit by the sky shader. This keeps silhouettes continuous beyond
the mesh horizon without adding draw calls, and lays the groundwork for
drawing less geometry while retaining a convincing long view.

## Other improvements

- The main menu now opens immediately over a settled, full-detail village
  still instead of launching and streaming a live server behind its controls.
  The live path remains as a reproducible capture tool for refreshing the
  image when the renderer or scene changes.
- Bundled PBR material packs cover 345 Minetest Game textures and 1,023
  Mineclonia textures. Local worlds serve the matching pack by default with an
  opt-out in Start Game; remote joins can select either companion set without
  replacing style textures supplied by server submods.
- Fixed the bundled worldmods' media layout so their albedo, normal and
  material maps are served from Luanti's `textures/` root. The developer
  channel now exposes per-texture PBR provenance and shader-binding checks,
  making missing companions visible before release.
- Torch placement responds promptly again, with stable light-pool ordering and
  slot eviction that only replaces a less useful lamp.
- Entering a storm cloud now retains diffuse daylight instead of extinguishing
  the whole sky to black, while local cloud depth attenuates the sun halo and
  screen-space shafts drawn over it.
- Render statistics now separate camera, shadow and other passes, making draw
  cost and culling behaviour easier to diagnose.
- A movement benchmark covers cold streaming, and profile plans are checked
  against the shipped profile definitions before their results are trusted.
- The control channel now fails clearly when its port cannot be bound, and the
  benchmark wrapper no longer terminates clients it did not start.
- An offline dawn-sweep fixture and horizon unit tests cover the new sky and
  terrain-horizon behaviour.

## Still alpha

Goanna remains an alpha-quality Linux project targeting Godot 4.5 and a
Vulkan-capable GPU. Mineclonia is still the most thoroughly tested game, and
the Luanti client remains the compatibility reference. Some dropped items are
placeholder boxes, animated node textures remain incomplete, and parts of
particle, formspec and model support are still being filled in.

The remaining streaming tail is not gone: first-time material creation can
still produce a large cold publish, and movement through rapidly arriving
terrain can still hitch. This release makes that path markedly cheaper and
better instrumented rather than claiming it is finished.
