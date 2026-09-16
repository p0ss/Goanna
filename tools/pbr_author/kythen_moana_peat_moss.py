"""Hand authored height and smoothness for kythen_moana_peat_moss.

The 32 px art has luminance 0.148 to 0.526, sd 0.092, with real greenness
(G minus the average of R and B, up to 0.206, higher than kythen_moana_
lava_lichen's own lichen signal): a moss cushion growing over a peaty base,
matching the brief's fibrous and soft reading but with visible plant matter
on top, unlike kythen_moana_swamp_peat's flat, near uniform waterlogged
art. lib.segments finds a more clumped structure than swamp_peat's single
background too (223 regions at tolerance 0.08, a 314 texel matrix plus
graded patches from 12 to 94 texels rather than one dominant blob), so the
base leans more on broad lumps than kythen_firecountry_reed_peat.py's own
tangled fibre mat, and the greenness carries a real moss overlay built the
same way default_mossycobble.py's own moss layer is, a soft, proud, matte
patch rather than a fibre streak.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_peat_moss"
CLS = "soil"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    greenness = rgb[..., 1] - (rgb[..., 0] + rgb[..., 2]) / 2.0
    print(f"greenness min {greenness.min():.3f} max {greenness.max():.3f} mean {greenness.mean():.3f} (real moss signal)")
    print(f"class_of reads: {lib.class_of(STEM, GAME)}; used here: {CLS} "
          "(peaty organic matter, not bark)")

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    # Tangled fibre, weaker than reed_peat's own since this art reads more
    # clumped than streaky.
    fibre_a = blur_axis(lib.fbm(SIZE, base_cells=26, octaves=2, seed=941, gain=0.5), radius=8, axis=1)
    fibre_b = blur_axis(lib.fbm(SIZE, base_cells=26, octaves=2, seed=942, gain=0.5), radius=8, axis=0)
    fibre = 0.4 * fibre_a + 0.4 * fibre_b

    # Broader, stronger lumps than reed_peat's own: this reads as clumped
    # moss hummocks over the peat, not an even trodden mat.
    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=943, gain=0.55) * 0.34

    layout = 0.28 * guide + 0.42 * lumps + 0.30 * fibre

    fuzz = lib.blur(lib.white_noise(SIZE, seed=944), 1) * 0.05
    # A scatter of small, genuinely deep settled hollows, the same low
    # percentile cut kythen_habesha_aksumite_ashlar.py and kythen_habesha_
    # basalt_country.py use for their own real deep pits: a broad shallow
    # noise field alone never gives the horizon based ambient occlusion a
    # wall steep enough to see.
    hollow_field = lib.blur(lib.white_noise(SIZE, seed=945), 1)
    hollow_cut = float(np.percentile(hollow_field, 1.0))
    hollows = np.where(hollow_field < hollow_cut, (hollow_field - hollow_cut) * 9.0, 0.0)

    base_height = lib.normalise01(layout + fuzz + hollows, 0.5, 99.5)

    # The moss layer: greenness normalised, upscaled keeping its own edges,
    # then blurred into the soft, rounded clump real moss grows in, sitting
    # a little proud of the peat around it.
    moss01 = lib.normalise01(greenness, 2.0, 98.0)
    moss_hi = lib.upscale(np.stack([moss01] * 3, axis=-1))[..., 0]
    moss_amount = np.clip(lib.blur(moss_hi, 2), 0.0, 1.0)
    print(f"moss_amount hi-res mean {moss_amount.mean():.3f}")
    moss_bump = moss_amount * 0.14

    height = lib.normalise01(base_height + moss_bump, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: soft and matte throughout, with the moss itself pulling
    # smoothness down further wherever it grows, the same reasoning
    # default_mossycobble.py gives its own moss layer.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=946, gain=0.55)
    # The moss pull is kept small: moss_amount covers over a third of the
    # tile once blurred out to a real clump size, and a strong pull over
    # that much area drags the class level recentring so far that pack()'s
    # own ordinary-texel ceiling clips away most of the spread on the high
    # side, the opposite of what lava_lichen.py's own smaller, sparser
    # patch needs.
    smooth = 0.34 * (height - height.mean()) + 0.74 * variation - 0.10 * moss_amount
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 14.0
    height = lib.band(height, 0.42)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
