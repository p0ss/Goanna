# Diamond transparency, 2026-09-29

[Open the comparison](index.html).

The preceding interior treatment still had an opaque surface. Dedicated
blended entity shaders now let the background show through diamond tools,
held and dropped blocks, and worn armour. Face-on gem opacity is 24%, or
32% for blocks, with reflective grazing edges rising towards 90%. The cyan
mask keeps wood handles and dark joins opaque; empty texels are discarded.
Ordinary entities keep their existing opaque and cut-out shader paths.

Placed blocks and ore retain their material backing. Their apparent inner
planes now absorb less light and receive less of the front surface colour,
but they do not reveal hidden terrain. No protocol or meshing changes were
made. This is alpha transmission, without background distortion, coloured
transmission shadows or order-independent transparency. Blended diamond
surfaces no longer cast their former cut-out shadows. The existing cyan
mask and armour atlas assumptions still apply.

## Validation

- C++ build, Godot script parse, style and whitespace checks pass.
- Godot 4.5.1 Forward+, software Vulkan under headless gamescope.
- The offline study renders production node and entity shaders against a
  contrasting background, with matched transmission on/off captures.
- Changing the background changes 23 sampled gem texels by an average RGB
  distance of 1.147. The 24 sampled wooden handle texels remain identical.
- Opaque foreground geometry occludes the transparent item. Placed block
  and ore backing remain unchanged when their background changes.
- With all illumination and the background black, treatment on/off remains
  byte-identical. Materials with diamond mode 0 also remain byte-identical.
- No shader or script errors in the final renderer log.
- Live Mineclonia release 38561, unmodified Luanti 5.17.0: the held pick
  selects `entity_diamond.gdshader`; equipped armour selects
  `entity_diamond_double_sided.gdshader`. The captured player clothing is
  visible through the armour, with the dark joins retained.
- Live armour captures use a detached camera and the full-body shadow mesh
  made visible for inspection. They are not normal first-person gameplay.

The comparison's cubes and flat cards are an offline study; `live-*` images
come from the temporary server fixture. Software rendering checks behaviour,
not GPU performance. See `transparency-checks.json` for numeric results.

All owned test servers and renderers were stopped after validation.
