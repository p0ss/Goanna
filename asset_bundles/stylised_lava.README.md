# Stylised lava in Goanna

The supplied `stylised_lava.tres` is a Material Maker shader export. Its
numbered PNGs are graph inputs, not a set of albedo/normal/roughness maps.
The export itself samples textures 1 and 4; 2 and 3 are not referenced by
its shader. The original files are retained unchanged.

Bake its colour graph into a native lava pack with:

```sh
../Godot_v4.5.1-stable_linux.x86_64 --path project \
    --script res://tests/bake_stylised_lava.gd
```

This writes three lava texture names and `texture_pack.conf` under
`baked/stylised-lava/textures`. The bake preserves the export's palette,
distortion and overlay at time zero. Goanna supplies continuous world-space
flow, shared inverse height/glow, edge taper and falling crust, rather than
using the export's independent parallax and glow animation.

For this local review the directory links to the other textures from
`baked/authored-mineclonia/textures`, and the three generated lava files have
also been copied into that currently selected pack. Restart the client to
load the rebuilt renderer and the new artwork. To select the standalone
directory, use **Texture pack > Other** and its absolute path.

The generated assets remain under `baked/`; rerun the bake after changing
the source export, then copy its three `default_lava*.png` files into the
selected pack. Do not rename the numbered source inputs as game textures.

See [the Mineclonia cave review](../docs/perf/lava-mineclonia-2026-09-18/README.md)
for captures through the real game renderer.
