"""Norse roof timber: hewn beams with joints where drawn.

32 px art, nine shades, with just two columns standing well clear of the
rest: column 0 at 0.141 and column 16 at 0.172, against every other
column's 0.223 to 0.251. Two joints, evenly spaced sixteen columns apart,
cutting the tile into two sixteen column beams, a wider board than any of
this family's other timber stems (driftwood and stave_wall both cut eight
narrow strips; this cuts two wide ones). The fill between the joints is
busy and chunky rather than streaky (values jump between 2, 5, 6, 7 and 8
texel to texel with no clear grain direction), which reads as adze facets,
the short, angled chops an axe or adze leaves on a hewn beam, not the fine
combed streaks a sawn plank's grain shows.

Only two joints means the same "few furrow groups" seam problem
kythen_norse_riven_plank.py hits and kythen_bark_family.py's own
stepped_dish records: the layout step here is a plain wide blur, not the
sharpened unsharp-mask step default_tree.py's straight furrow uses, and
the joint's own depth for ambient occlusion comes from a handful of
unblurred splits rather than from the blur itself.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_roof_timber"
SIZE = lib.SIZE
SEED = 9001


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
    n = src.shape[0]
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))
    col_mean = lum.mean(axis=0)
    print("column mean:", np.round(col_mean, 3).tolist())

    margin = 0.32 * (col_mean.max() - col_mean.min())
    is_joint = col_mean < (col_mean.min() + margin)
    joint_cols = np.where(is_joint)[0]
    print("joint columns:", joint_cols.tolist())

    col_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(n):
        if is_joint[x]:
            col_id[x] = -(1 + list(joint_cols).index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    print("column ids:", col_id.tolist())

    beam_lum = {}
    for b in set(col_id.tolist()):
        cols = np.where(col_id == b)[0]
        beam_lum[b] = lum[:, cols].mean()
    beam_means = np.array([v for k, v in beam_lum.items() if k >= 0])
    lo, hi = beam_means.min(), beam_means.max()
    beam_target = {}
    for b, m in beam_lum.items():
        beam_target[b] = 0.08 if b < 0 else 0.55 + 0.25 * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(beam_target.keys()))}
    col_id_shifted = np.vectorize(remap.get)(col_id)
    target = np.array([beam_target[c] for c in sorted(beam_target.keys())])

    scale = SIZE // n
    labels16 = np.broadcast_to(col_id_shifted[None, :], (n, n)).copy()
    labels_hi = lib.warp_labels(labels16, size=SIZE, amp=0.0, seed=SEED, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # A plain wide blur, not an unsharp-mask step: see module docstring,
    # only two joint groups here.
    step = target[labels_hi]
    layout = lib.blur(step, max_dist)

    # A very slow crown, a hewn beam's own gentle convexity.
    crown = lib.fbm(SIZE, base_cells=3, octaves=2, seed=SEED + 1) * 0.10
    layout = layout + crown * t

    # Adze facets: a scatter of short, angled flat chops rather than
    # streaky sawn grain, built the way kythen_khmer's own tooled stone
    # scripts stamp chisel strokes, here as shallow planar facets at random
    # angles and moderate spacing so the beam face reads as hand hewn.
    def facet_stamp(length, width, angle, amp):
        r = int(np.ceil(max(length, width)))
        d = np.arange(-r, r + 1, dtype=np.float32)
        dy, dx = np.meshgrid(d, d, indexing="ij")
        ca, sa = np.cos(angle), np.sin(angle)
        u = dx * ca + dy * sa
        v = -dx * sa + dy * ca
        inside = (np.abs(u) <= length) & (np.abs(v) <= width)
        face = np.where(inside, amp * (1.0 - (v / width) ** 2), 0.0)
        return face.astype(np.float32), r

    rng = np.random.default_rng(SEED + 6)
    facets = np.zeros((SIZE, SIZE), dtype=np.float32)
    n_facets = 70
    cx = rng.integers(0, SIZE, n_facets)
    cy = rng.integers(0, SIZE, n_facets)
    ang = rng.uniform(-0.35, 0.35, n_facets) + rng.integers(0, 2, n_facets) * np.pi / 2
    amp = rng.uniform(-0.16, 0.10, n_facets)
    for i in range(n_facets):
        stamp, r = facet_stamp(rng.uniform(8, 16), rng.uniform(3, 6), ang[i], amp[i])
        ys = (np.arange(-r, r + 1) + cy[i]) % SIZE
        xs = (np.arange(-r, r + 1) + cx[i]) % SIZE
        idx = np.ix_(ys, xs)
        facets[idx] = facets[idx] + stamp

    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 2, gain=0.5)
    grain = blur_axis(grain_src, radius=10, axis=0) * 0.06

    # A few unblurred splits for the ambient occlusion pass to find, real
    # checking a heavy hewn beam still gets.
    tears = np.zeros((SIZE, SIZE), dtype=np.float32)
    for _ in range(6):
        tcy = rng.integers(0, SIZE)
        tcx = rng.integers(0, SIZE)
        length = rng.integers(10, 24)
        depth = rng.uniform(0.30, 0.55)
        for i in range(length):
            y = (tcy + i) % SIZE
            x = (tcx + rng.integers(-1, 2)) % SIZE
            tears[y, x] = max(tears[y, x], depth)

    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1) * 0.03

    height = lib.normalise01(layout + facets + grain + pores - tears, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: adze facets stay duller than a plane could ever leave a
    # beam, with the material's own patchy variation on top.
    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=SEED + 5, gain=0.55)
    smooth = 0.4 * t - 0.10 * (facets > 0.0) + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 32.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
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
