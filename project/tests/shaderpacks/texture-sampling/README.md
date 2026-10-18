# Custom texture sampling proof

All code and two-texel images here are authored for Goanna and licensed
LGPL-2.1-or-later. Each image has a black left texel and a white right texel.
Their adjacent metadata files exercise all four `blur` and `clamp` pairs.

The final pass samples the centre between texels into red, outside the
left edge into green and outside the right edge into blue. Its four
quadrants must contain these colours, regardless of their screen order:

| Filter | Edge | RGB |
| --- | --- | --- |
| Linear | Clamp | 128, 0, 255 |
| Nearest | Clamp | 255, 0, 255 |
| Linear | Repeat | 128, 255, 0 |
| Nearest | Repeat | 255, 255, 0 |

The final colour conversion can quantise 128 down to 127. Run through the
render service, with a fresh output directory:

```sh
tools/goanna-render minecraft tools/minecraft/texture-sampling.json --only goanna
python tools/test/check-iris-texture-sampling.py \
  build/minecraft/texture-sampling/calibration-goanna.png
```
