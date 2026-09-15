"""Hand authored LabPBR height and smoothness for default_mossycobble.

The 16 px art has 27 distinct shades, far more than default_cobble's own
six: this is not a recolour with a separate moss layer laid on top, it is
one continuous mottled surface, moss tint blended in per texel at varying
strength. Subtracting the green (greenness = G - avg(R, B)) finds the moss:
a soft patch of raised, positive greenness covering about 30 percent of the
tile, that also reads as darker luminance than the bare stone under it
(moss is a darker material than the grey rock here, not a lighter one).

Running lib.segments on the de-mossed proxy (R + B) / 2 at the same
tolerance default_cobble.py uses (0.03) does find default_cobble's kind of
layout after all: about a hundred regions, mostly one to a few texels,
which is the same shape of result cobble's own 83 regions has (a couple of
dozen middling chips and a long tail of single texel flecks), not the
handful of large cells a first look at the number might suggest. An
earlier version of this script judged that "too fragmented" and fell back
to a wrapped Voronoi partition instead, which gave every stone a straight
edged, jigsaw silhouette instead of the rounded, irregular one
lib.warp_labels and lib.distance_to_edge build from a segment map. The
segments are what the art draws; used the way default_cobble.py uses them,
they give the same kind of stones.
"""
import sys

import numpy as np

import lib

STEM = "default_mossycobble"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", len(set(np.round(lum.ravel(), 3).tolist())))

    greenness = rgb[..., 1] - (rgb[..., 0] + rgb[..., 2]) / 2.0
    print(f"greenness min {greenness.min():.3f} max {greenness.max():.3f}, "
          f"moss coverage (>0.02) {float((greenness > 0.02).mean()):.3f}")

    proxy_val = (rgb[..., 0] + rgb[..., 2]) / 2.0  # de-mossed brightness
    proxy_rgb = np.stack([proxy_val] * 3, axis=-1)

    # Segment the de-mossed proxy exactly as default_cobble.py segments its
    # own art: the moss tint is gone, so what is left is shading steps
    # between one stone and the next, the same kind of signal cobble's own
    # mortar to stone cliff gives lib.segments, just without a cliff as
    # wide, hence the same tolerance and a result the same shape as
    # cobble's own (a long tail of small regions, not a few big ones).
    tolerance = 0.03
    labels, n_stones = lib.segments(proxy_rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    print(f"segments: n={n_stones} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))

    stone_lum = np.array([proxy_val[labels == i].mean() for i in range(n_stones)])
    lo, hi = proxy_val.min(), proxy_val.max()
    target = 0.55 + 0.35 * (stone_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 5  # groove half width in 256 map texels
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: domed stone tops, sharp fall to the joint

    target_map = target[labels_hi]
    layout = target_map * t

    # Each stone a slightly convex dome; the taper alone saturates flat in
    # the middle of a stone, a wide slow bulge rounds that off, matching
    # default_cobble's own crown.
    crown = lib.fbm(lib.SIZE, base_cells=4, octaves=2, seed=61) * 0.05
    layout = layout + crown * t

    # Sub texel structure: stone grain a couple of texels across, sparse
    # pores about half a texel across, matching default_cobble's own.
    grain = lib.fbm(lib.SIZE, base_cells=32, octaves=3, seed=62, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=63), 1) * 0.05

    # The moss layer: a soft, organic patch, not a texel hard mask, so the
    # 16 px greenness is normalised, upscaled keeping its own edges, then
    # blurred into the rounded clump real moss grows in. It sits mostly in
    # the joints (a low absolute height there means the same bump reads as
    # filling the groove) and creeps a little way up over whichever stone
    # edges it happens to cover.
    moss01 = lib.normalise01(greenness, 2.0, 98.0)
    moss_hi = lib.upscale(np.stack([moss01] * 3, axis=-1))[..., 0]
    moss_amount = np.clip(lib.blur(moss_hi, 3), 0.0, 1.0)
    print(f"moss_amount hi-res mean {moss_amount.mean():.3f}")
    moss_bump = moss_amount * 0.12

    height = lib.normalise01(layout + grain + pores + moss_bump, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: joints stay rough, dome tops wear smooth.
    # Moss is soft and matte regardless of what it sits on, so it pulls
    # smoothness down wherever it grows, over a joint or over a stone top.
    rough_noise = lib.fbm(lib.SIZE, base_cells=16, octaves=3, seed=64)
    smooth = 0.55 * height + 0.55 * rough_noise - 0.3 * moss_amount
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    # Close to default_cobble's own strength, so the two blocks read as
    # the same stone with and without moss on it; a touch under it because
    # the moss bump adds its own relief on top of the stone's, and at 12
    # even the tilt runs just past the stone class ceiling.
    normal_strength = 11
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
