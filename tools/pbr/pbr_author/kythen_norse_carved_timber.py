"""Norse carved timber: a flat board with the drawn carving as a shallow
engraving, no warp.

32 px art, eight shades, and a design that repeats twice across the tile
in both directions (a 16 px motif, two copies wide and two tall). Rows 0,
8, 16 and 24 carry a thin key-pattern border (a short rising ramp of
shades over eight columns, the same eight columns twice per row); the
seven rows following each border row hold a woven interlace motif, mostly
one flat background shade with corner and edge flourishes picked out in
the brighter shades. lib.segments at tolerance 0.04 to 0.06 finds this
cleanly: 66 regions, two large flat fields of 103 and 104 texels (the
board's own bare face, one per motif copy) and a long tail of 20 to 21
texel shapes (the carved key pattern and interlace strokes), the same
kind of read kythen_khmer_carved_sandstone.py gives its own engraved
face.

This is dressed, manufactured work (a mason's or a carpenter's engraving,
not a natural surface), so amp 0 on the label warp, the same choice
kythen_khmer_carved_sandstone.py and kythen_habesha_timber_laced.py both
make for their own dressed faces. Unlike that sandstone carving, this is
class wood, whose tilt target (18 to 28 degrees) sits well above sand's
shallow band, so the carve here reaches deeper into its own region step
and carries a wood grain on top, rather than staying inside lib.band the
way a fired tile or a polished stone would.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_carved_timber"
SIZE = lib.SIZE
SEED = 9301


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
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls = lib.class_of(STEM, GAME)
    print(f"class_of reads: {cls}")

    tolerance = 0.05
    labels, n_reg = lib.segments(rgb, tolerance=tolerance)
    sizes = [int((labels == i).sum()) for i in range(n_reg)]
    print(f"segments: n={n_reg} tolerance={tolerance} sizes {sorted(sizes, reverse=True)[:12]} ...")

    region_lum = np.array([lum[labels == i].mean() for i in range(n_reg)])
    lo, hi = lum.min(), lum.max()
    region_target = 0.15 + 0.70 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=0.0, seed=SEED, cells=14)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # The flat board face, with the carved motif reaching all the way to
    # its own region target: a real, if shallow, engraving, deeper than
    # kythen_khmer_carved_sandstone.py's 0.35 share since this is class
    # wood, not sand, and needs a real tilt band to match. A separate
    # uniform "groove" subtracted at every region edge (independent of how
    # different the two regions' own targets were) was tried for the
    # ambient occlusion this carve needs, but it roughly doubled the wrap
    # seam measure regardless of normal_strength (the seam ratio depends
    # on the height field's own tiling, not on how it is scaled
    # afterward): this art's small engraved regions sit close enough to
    # the tile edge that an edge-triggered term, added independently of
    # each region's own step, reads a denser set of edges right at the
    # wrap than a typical interior row carries. Widening max_dist instead
    # (a gentler, wider bevel) recovers the occlusion this carve needs
    # without adding a second edge-triggered term.
    flat = 0.42
    target_map = region_target[labels_hi]
    layout = flat + (target_map - flat) * t

    # Wood grain along the board (y), faint: an engraved board still shows
    # its own timber grain under the carving.
    grain_src = lib.fbm(SIZE, base_cells=22, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=12, axis=0) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1) * 0.03

    # A handful of unblurred splits, the same recovery
    # kythen_norse_roof_timber.py and kythen_norse_riven_plank.py use for
    # ambient occlusion the bevel alone cannot give: placed by modulo
    # indexing at random positions rather than tied to a region edge, so
    # unlike the edge-triggered groove tried above (see the note further
    # up) they add no extra weight at the tile's own rare content-to-border
    # transitions and leave the wrap seam alone.
    rng = np.random.default_rng(SEED + 6)
    tears = np.zeros((SIZE, SIZE), dtype=np.float32)
    for _ in range(7):
        cy = rng.integers(0, SIZE)
        cx = rng.integers(0, SIZE)
        length = rng.integers(6, 14)
        depth = rng.uniform(0.30, 0.55)
        for i in range(length):
            y = (cy + i) % SIZE
            x = (cx + rng.integers(-1, 2)) % SIZE
            tears[y, x] = max(tears[y, x], depth)

    height = lib.normalise01(layout + grain + pores - tears, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=SEED + 5, gain=0.55)
    smooth = 0.55 * height + 0.40 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 10.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
