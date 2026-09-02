# Goanna v0.6.1-alpha

Goanna 0.6.1 is a focused reliability and distant-rendering update for the
0.6 series.

## Changes

- Coarse distant terrain now follows the connected ground surface instead of
  filling an entire low-resolution cell. Valleys retain their shape rather
  than acquiring broad floating lids, while genuinely disconnected geometry
  remains available to the ordinary LOD path.
- Remote connections now try the alternate resolved address family when the
  first IPv4 or IPv6 address does not answer. This helps players whose DNS and
  network route disagree about which family is usable.
- Media loading no longer enters the world with an incomplete announced media
  set after a quiet transfer. Missing assets are requested again, progress
  resets the retry allowance, and a persistent failure produces a clear error
  instead of a partially textured scene.
- Dense cloud undersides retain ambient cloud colour rather than multiplying
  the darkened sky down to black.

## Still alpha

Goanna remains an alpha-quality Linux project targeting Godot 4.5 and a
Vulkan-capable GPU. Mineclonia is still the most thoroughly tested game, and
the Luanti client remains the compatibility reference.

One hardware-specific report of severely fragmented or missing scene assets
in 0.6 has not been reproduced or attributed, so this release does not claim
to resolve it. The media retry change does ensure that an incomplete server
media transfer is reported rather than silently accepted.
