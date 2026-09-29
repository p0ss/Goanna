# Diamond interiors, 2026-09-29

[Open the comparison](index.html).

The surface treatment now has two apparent inner planes. A refracted view
ray shifts them below the polished skin. Neighbouring gem-mask samples
estimate thin rims and thicker centres, and the longer optical paths absorb
more red light. An inner facet highlight and a small wrapped scattering
term respond to the existing lights and their shadows.

Opaque depth and silhouettes remain intact. This supplies apparent
translucency within the material; it does not show the scene behind a block
or model. Ore remains backed by material, and neither wood handles nor host
stone is drawn into its inner planes. There is no new scene capture or
transparency sorting pass. The shade palette, cyan mask and conventional
texture scales retain the limitations described in the original study.

## Validation

- Godot 4.5.1 Forward+, software Vulkan in headless gamescope.
- `project/diamond_study.gd` parses and renders production shaders.
- Interior on/off produces different frames at all three tested viewing
  angles. The comparison retains the same lamp and camera for each pair.
- Scattering on/off produces different frames with surface and inner
  specular highlights held constant.
- With illumination disabled, treatment on/off remains byte-identical.
- Materials with diamond mode 0 remain byte-identical under the lamp.
- Live Mineclonia release 38561 on unmodified Luanti 5.17.0: ore wall,
  equipped pick and equipped armour captured with the authored pack.
  The armour view uses the existing full-body shadow mesh and a detached
  camera, as in the original study.
- No shader or script errors in the final live renderer log. Style and
  whitespace checks pass. No C++ changed in this follow-up.

The angle images are offline cubes and cards, not gameplay. `live-wall.png`
and `live-armour.png` come from the temporary display world. The software
renders establish correctness, not a GPU performance estimate. The extra
texture reads run only on selected gem pixels. All owned test processes
were stopped afterwards.
