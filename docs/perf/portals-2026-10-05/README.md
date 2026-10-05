# Portal shader study

Offline captures from `project/portal_study.tscn`, Godot 4.5.1 Forward+,
RTX 3090, 1280 by 800, through `tools/goanna-headless fixture`. Synthetic
flat textures and block frames; these are not live Mineclonia screenshots.
These initial captures predate the underwater absorption and alpha
blending fixes. The expanded fixture's rendering checks remain pending.

- [Both portals](portals.png): warped purple transmission and frame glow,
  with the End starfield beside it.
- [End depth](end-depth.png) and [moved camera](end-moved.png): eight star
  planes behind the same opaque sheet, with different parallax per plane.
- [Nether foreground](nether-foreground.png): the red bar stays in front
  of the membrane; the blue columns behind it are refracted.

The fixture reported zero failures. It checks visible animation, the
change from zero to nonzero End parallax depth, matching Nether images
with and without the lamp grid, and matching images at clock 0 and 60.
See [portal materials](../../portal-materials.md) for reproduction and
known limits.
