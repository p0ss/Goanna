# Diamond items and armour, 2026-09-29

[Open the comparison](index.html).

The wall crystals had more readable relief than the item and armour paths.
Luanti's item and skinned model streams supply positions, normals and UVs,
but no texture-aligned tangents. Godot fills the missing stream with a
fallback basis. On the live dropped diamond, the tangent pointed along -Y
while texture U ran horizontally. That rotated the normal-map detail and
misaligned the internal facets and refraction.

The diamond entity shader now reconstructs its UV frame from the rendered
surface derivatives. This follows skin deformation and mirrored UVs, with
Godot's -V binormal convention. Degenerate UVs retain the existing fallback.
Narrow planar bevels follow source-art colour boundaries, giving native
armour and loose diamonds crisp edge highlights. They retain the gem mask
and fade out when texels become unresolved. The refractive depth of tools,
armour and loose gems rises from two to 3.5 source texels; the held block's
six-texel depth and the wall material stay unchanged.

Dropped items already use the same entity material binding as held items.
The test server spawned an ordinary `mcl_core:diamond` and diamond pick
through `core.add_item`; their real `__builtin:item` entities use
`entity_diamond.gdshader`, diamond mode 1, and normal maps. The loose gem
uses native 16x16 art, the pick uses the authored 256x256 pack, and worn
armour uses the 64x32 atlas with the double-sided diamond shader.

## Validation

- Godot 4.5.1 Forward+, software Vulkan in headless gamescope.
- Fresh offline item meshes with generated tangents and with their tangent
  stream omitted render byte-identically through the repaired shader.
- The previous shader on meshes lacking texture-aligned tangents produces
  a different frame. The comparison keeps camera and lighting fixed.
- The updated refraction transmits the background through sampled diamond
  pixels, leaves wood handles opaque and respects foreground occlusion.
- No added light in darkness; diamond mode 0 remains byte-identical.
- Live Mineclonia release 38561 on unmodified Luanti 5.17.0: actual dropped
  loose diamond and pick, held pick and worn armour inspected and captured.
  The drop close-ups use a detached camera at FOV 30; object geometry and
  scale are unchanged. Armour uses the full-body shadow mesh made visible
  for inspection. Neither is presented as normal first-person framing.
- No shader or script errors in the final renderer log. Script parsing,
  style and whitespace checks pass. No C++ changes in this follow-up.

Screen refraction still samples only opaque objects visible on screen.
Other transparent objects and offscreen scenery are absent, and there are
no coloured transmission shadows. Inventory icons retain the CPU art.
Software rendering verifies behaviour, not GPU performance. The extra
bevel samples run only on resolved diamond texels.

All owned test servers and renderers were stopped after validation.
