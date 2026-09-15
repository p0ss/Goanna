"""Hand authored height and smoothness for mcl_core_stonebrick_mossy.

Same masonry as mcl_core_stonebrick_cracked.py and default_stone_brick.py:
thresholding this art's own shading at lum <= 0.38 recovers the same two
course, running bond joint default_stone_brick.py found (rows 7 and 15
full width, column 7 for rows 8 to 14, column 15 for rows 0 to 3), so the
joint is taken as those fixed cells and built with default_stone_brick.py's
own label_blocks, crown, tooling and pore seeds, the same as the cracked
variant.

The moss is not part of that shading step at all. Subtracting the green
(greenness = G - avg(R, B)), the way default_mossycobble.py finds its own
moss, gives a soft, broad tint covering about half the tile (0.496 of it
above 0.02), wider and weaker than mossycobble's own 30 percent patch: this
is a light dusting over most of the face rather than a few thick clumps, so
it is built the same way (normalised, upscaled, blurred into rounded
patches, added as a shallow height bump and pulled out of smoothness) but
at a gentler amount, matching how thin it reads in the art.
"""

import sys

import numpy as np

import lib
import default_stone_brick as dsb

STEM = "mcl_core_stonebrick_mossy"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")

    mortar_mask = np.zeros((16, 16), dtype=bool)
    mortar_mask[7, :] = True
    mortar_mask[15, :] = True
    mortar_mask[8:15, 7] = True
    mortar_mask[0:4, 15] = True
    print(f"structural joint texels: {int(mortar_mask.sum())} of 256")

    labels, n_blocks = dsb.label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.35 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    mortar_hi = np.repeat(np.repeat(mortar_mask, 16, axis=0), 16, axis=1)
    labels_hi = np.repeat(np.repeat(labels, 16, axis=0), 16, axis=1)

    max_dist = 5
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=36, octaves=2, seed=26) * 1.3
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    crown = lib.fbm(lib.SIZE, base_cells=4, octaves=2, seed=22) * 0.05
    layout = layout + crown * t

    tooling = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=23, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=24), 1) * 0.05

    # Moss from the art's own greenness, the way default_mossycobble.py
    # builds it: normalise, upscale keeping its own edges, blur into
    # rounded patches. Weaker than mossycobble's own bump (0.06 against its
    # 0.12) because this moss reads thinner and more widespread in the art,
    # not a few thick clumps.
    greenness = rgb[..., 1] - (rgb[..., 0] + rgb[..., 2]) / 2.0
    print(f"greenness min {greenness.min():.3f} max {greenness.max():.3f}, "
          f"coverage (>0.02) {float((greenness > 0.02).mean()):.3f}")
    moss01 = lib.normalise01(greenness, 2.0, 98.0)
    moss_hi = lib.upscale(np.stack([moss01] * 3, axis=-1))[..., 0]
    moss_amount = np.clip(lib.blur(moss_hi, 3), 0.0, 1.0)
    print(f"moss_amount hi-res mean {moss_amount.mean():.3f}")
    moss_bump = moss_amount * 0.06

    height = lib.normalise01(layout + tooling + pores + moss_bump, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height; moss is soft and matte wherever it grows.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=25)
    smooth = 0.55 * height + 0.5 * rough_noise - 0.22 * moss_amount
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 40  # same masonry depth as default_stone_brick.py
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
