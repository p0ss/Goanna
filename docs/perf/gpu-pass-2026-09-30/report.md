# GPU pass across five games, 2026-09-30

The same fixture in each game, rendered by Godot 4.5.1 Forward+ on the RTX
3090 (headless gamescope with its compositor on the CPU,
`goanna-headless start --cpu-compositor`), against Luanti 5.17.0 servers,
one client at a time, with no kernel NVRM or Xid lines during the pass.
Everything in the earlier software checks of 2026-09-29 was until now seen
only on lavapipe.

Each image has four poses: A over the glass row into a water pool and a
lava pool, B at a gem row, C close over the water pool and its lily pads,
D at the gem row with Asuna's Everness cave vines on the wall behind. The
`*-shaders.txt` files list the textures the client put on the water, lava,
ice, glass and plants shaders (`GOANNA_DEBUG_WHITE`).

- minetest_game: both lily pads show on the water, the waving one on the
  plants shader; water, lava, clear glass and panes, and the diamond and
  mese gems as in the software checks.
- Mineclonia: emerald ore and block, amethyst and quartz ore take the gem
  treatment; ice on the ice shader; the red stained glass tint is still
  faint, as before. Mineclonia's weather was overcast.
- VoxeLibre: the same nodes as Mineclonia, the same result. First time it
  has been rendered at all in this work.
- Kythen: water and lava on their shaders, both glasses on the glass
  shader, its ice classed and drawn as ice.
- Asuna: water on the water shader and not lava; both thin ice nodes and
  the translucent Everness ice on the ice shader; the three cave vines and
  the waving lily pad on the plants shader.

The fixtures are fresh worlds with the nodes placed by a worldmod, so this
is how each node renders, not a survey of play. The pass was not compared
against a GPU render of the previous code.
