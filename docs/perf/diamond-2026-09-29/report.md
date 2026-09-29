# Diamond material study, 2026-09-29

Shared diamond shading for node arrays and entity surfaces. Colour plateaus
receive small planar normal tilts, polished dielectric highlights and a
bounded approximation of coloured internal reflection. The original height
maps and parallax remain in use. Ore masks select cyan gem pixels, leaving
the host stone alone. Tools keep their handles, and armour uses the same
response on its separate texture layer.

[Open the comparison](index.html).

## Validation

- C++ build: `cmake --build build -j 3` passed.
- GDScript parse check for `project/diamond_study.gd` passed on Godot 4.5.1.
- Production opaque and cut-out node/entity shaders rendered in the offline
  study. Moving the lamp changes the highlights without changing the art.
- With every illumination source disabled, treatment on/off frames are
  byte-identical. No self-light from the diamond shader.
- With the texture's diamond mode disabled, treatment on/off frames are
  byte-identical under the lamp. Ordinary materials retain their response.
- Live test: unmodified Luanti 5.17.0, Mineclonia ContentDB release 38561,
  Godot 4.5.1 Forward+, software Vulkan inside headless gamescope. A temporary
  world mod placed the display wall and equipped a diamond pick and armour.
  The final client loaded `pbr_packs/mineclonia/textures` at startup.
- Live inspection confirmed ore mode 1 and block mode 2 on node arrays,
  mode 1 on the equipped pick, and mode 1 with the 64 by 32 atlas on both
  the visible and shadow meshes of the equipped armour. The armour uses
  `entity_double_sided_scissor.gdshader`, preserving the player's culling.
- The final live client log contained no shader or script errors. Style and
  whitespace checks passed. Test clients, compositors and server stopped.

`live-wall.png` is the real server's display wall and equipped pick.
`live-armour.png` is the same server's player, with the camera detached and
its existing full-body shadow mesh made visible for inspection. The game
normally shrinks the local player's head out of the first-person camera.
The other images are offline material cards/cubes, not gameplay captures.

## Limits

The fire lobe is an artistic approximation, not optical dispersion or
transmission through a volume. The mask assumes cyan diamond pixels and
familiar 16-texel tiles or 64 by 32 armour atlases. Recoloured packs or
mixed armour overlays containing other cyan parts may need a semantic mask.
Alpha-blended entity materials and CPU inventory icons retain their existing
render paths. No GPU performance claim is made from software renders.
