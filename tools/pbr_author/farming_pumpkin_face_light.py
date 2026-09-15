"""Hand authored height and smoothness for farming_pumpkin_face_light.

The same carved shell as farming_pumpkin_face.py: the same ribs
(farming_pumpkin_side.rib_taper), the same cut, at the same depth, because
it is the same hole cut into the same gourd, lit or not. The cut mask
itself comes from farming_pumpkin_face.py's own function rather than being
found again here, because this texture's own dark texels do not trace the
shape any more: inside the cut, luminance here runs 0.226 to 0.867 (mean
0.540) against the plain shell's own narrow 0.305 to 0.598 (mean 0.425),
the candle behind the cut having washed the carved shape out into a bright
blur, some of it brighter than the shell around it. That is exactly the
signal the emission comes from: whatever is both inside the cut and
brighter than about 0.5 becomes the glow, so the shell itself never lights
up and the dim texels right at the cut's own edge do not either, only the
lit orange and yellow of the opening itself, the way the brief asks for.
"""

import sys

import numpy as np

import lib
import farming_pumpkin_side as side
import farming_pumpkin_face as face

STEM = "farming_pumpkin_face_light"
CLS = "wood"
SIZE = lib.SIZE

GRAIN_SEED = side.GRAIN_SEED
PORES_SEED = side.PORES_SEED
GLOW_LUM_THRESH = 0.50


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    rib_t, valley = side.rib_taper()
    ribs = 0.10 * (1.0 - rib_t) + 0.85 * rib_t

    cut_t, mask, mask_hi = face.cut_taper()
    print(f"cut texels: {int(mask.sum())} of 256 ({mask.mean() * 100:.1f}%)")

    cut_floor = 0.05
    layout = ribs * (1.0 - cut_t) + cut_floor * cut_t

    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=GRAIN_SEED, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=PORES_SEED), 1) * 0.03
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=103, gain=0.55)
    smooth = 0.55 * height + 0.5 * rough_noise - 0.2 * cut_t
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    # Emission: bright, inside the cut, nowhere else. mask_hi already marks
    # the cut at map size; the brightness gate uses this texture's own
    # nearest-upscaled luminance so the glow keeps the art's own crisp
    # texel edges, then a light blur lets it bleed a little into the
    # surrounding shell the way light through a thin wall does.
    lum_hi = lib.upscale(np.stack([lum] * 3, axis=-1))[..., 0]
    glow = np.clip((lum_hi - GLOW_LUM_THRESH) / (lum_hi.max() - GLOW_LUM_THRESH), 0.0, 1.0)
    emission = np.clip(lib.blur(glow * mask_hi.astype(np.float32), 2), 0.0, 1.0)
    print(f"emission min {emission.min():.3f} max {emission.max():.3f} "
          f"mean {emission.mean():.3f} coverage(>0.05) {(emission > 0.05).mean():.3f}")

    normal_strength = 17.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, emission=emission)
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
