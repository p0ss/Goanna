# Goanna visual test mod

This worldmod builds deterministic renderer fixtures for Goanna. It is not a
gameplay mod and refuses to operate unless the world uses the `singlenode`
mapgen.

Use it only in a fresh, dedicated test world. Copy or link this directory to
`<world>/worldmods/goanna_visual_test`, enable it in `world.mt`, and create the
world with `mg_name = singlenode` in its configuration.

The fixtures are selected with:

```text
/goanna_fixture lighting_walk
/goanna_fixture ao
/goanna_fixture materials
/goanna_fixture ice
```

Each site is cleared and built only when requested. Sites are 1024 nodes
apart, which keeps their geometry, lights and SDFGI cascades out of every
other test. The mod fixes time at midday, removes clouds for the test player
and places the player at a defined position and facing.

`lighting_walk` is the automated capture target. The other sites establish
isolated locations for the AO, material and ice tests as those captures are
added.
