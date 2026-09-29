# Diamond refraction and ore recesses, 2026-09-29

[Open the comparison](index.html).

Diamond items now sample the opaque scene through a refracted ray. Facet
normals supply the direction; texture-coordinate derivatives estimate a
source texel's world size for the optical thickness. The refractive index is
2.42. The screen offset is bounded, fades at screen edges, and rejects
samples whose depth places them in front of the crystal. The sampled light
is composed with the crystal's surface response. Zero refraction strength
retains the preceding straight alpha transmission.

Ore previously shifted cyan copies of its own surface texture. It now
traces a shallow crystal-filled recess, intersecting the cyan mask's walls
before reaching a recessed rock backing. The combined ore texture has no
stone under its painted gems, so the backing extends nearby stone texels
into that area. Absorption tints this stone through the crystal. The shader
uses the existing parallax coordinate and adds no mesh vertices. It never
samples scenery behind the ore block. Placed solid diamond blocks retain
their existing internal planes.

This is a bounded rendering approximation. The item background contains
only opaque objects currently on screen, not other transparent surfaces.
It does not trace the item's actual rear mesh, solve multiple refractions,
or provide coloured transmission shadows. Ore backing is reconstructed
art, not new geometry. Protruding crystals, silhouette changes and proper
side faces would need a separate mesh treatment.

## Validation

- Godot 4.5.1 Forward+, software Vulkan under headless gamescope.
- Script parsing, shader compilation, style and whitespace checks pass.
- Matched straight/refracted images show checkerboard boundaries displaced
  through facets, most clearly on the held block cube.
- Background changes affect 23 sampled gem texels while leaving 24 wooden
  handle texels identical. An opaque foreground cover hides the sampled
  gem. Ore and placed block backing remain unchanged by their background.
- Ore recess on/off differs at all three captured viewing angles.
- With all illumination disabled and the background black, treatment
  on/off remains byte-identical. Diamond mode 0 also remains identical.
- Live Mineclonia release 38561 on unmodified Luanti 5.17.0: ore wall,
  equipped pick and equipped armour render with the production shaders.
  The armour view uses a detached camera and the full-body shadow mesh
  made visible for inspection. No shader or script errors in the log.

The checkerboard and ore angle views are offline studies. The `live-*`
images come from the local server fixture. Software rendering establishes
behaviour, not GPU performance. The ore work adds a bounded search on close
selected gem pixels; item refraction uses the opaque screen colour/depth
copy. No C++ or mesh generation code changed in this follow-up.

All owned test servers and renderers were stopped after validation.
