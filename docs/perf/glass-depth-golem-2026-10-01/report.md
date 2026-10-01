# Clear glass depth and the iron golem, 2026-10-01

Two faults seen in play in a Mineclonia village at night: a window of
clear glass two blocks thick lost and regained its back edges from one
second to the next, and the iron golem drew black.

Reproduced in a fixture world (Mineclonia, midnight, a glass window three
wide, two high and two thick, a lantern behind it, two iron golems),
software rendered under headless gamescope with Godot 4.5.1 against a
Luanti 5.17.0 server. Each glass image is six shots with the camera moved
sideways in steps of 0.3 nodes.

- `glass-before.png`: the back edges are present in some shots and missing
  in others. The clear glass shader wrote depth for every texel
  (`depth_draw_always`), and its clear texels are drawn at a fifth of
  their alpha or more, so whichever pane drew first hid the other.
- `glass-prepass.png`: `depth_prepass_alpha`, which writes depth only where
  the art is opaque. Every edge shows, but the floor under the glass is
  dark: the prepass puts the glass in the shadow pass.
- `glass-after.png`: no depth writes (`depth_draw_never`). Every edge shows
  in all six shots and the floor is lit.
- `golems-before-after.png`: before, the golems are black silhouettes;
  after, their texture shows. With no authored `_s`, the texture name
  `mobs_mc_iron_golem` matched "iron" and the golem was classed as wholly
  metallic, which has no diffuse. A guess from the name now applies only to
  items, where it was meant for tools; the client log reads
  `entity class: mobs_mc_iron_golem.png -> none`. The golems wander, so the
  two shots are not the same pose.

Stained glass keeps `depth_draw_always`. Not yet checked on the GPU or in
the village where it was seen.
