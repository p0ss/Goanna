"""Hand authored LabPBR height and smoothness for kythen_habesha_terrace_face,
a dry stone retaining wall face, no mortar.

The 32 px art carries almost no colour signal at all: two raw RGBA values
only, (58,55,51) on 992 of the 1024 texels and (84,80,74) on the other 32,
scattered as single and two or three texel flecks with no clustering that
reads as stone silhouettes. lib.segments confirms this at every workable
tolerance (0.02 to 0.10): one background region of 992 texels plus about
twenty three fleck islands of one to three texels, and above tolerance 0.12
the whole tile collapses to a single region. There is no colour boundary
in this art that could be read as a joint between adjacent stones; the
artist is relying entirely on the PBR pass to give the wall its structure,
the way the playbook says an authored set decides what the surface is
rather than reading it wholesale off the picture.

Given that, the stone layout below is not found by colour segmentation
(there is nothing there to find): it is a hand reasoned coursed rubble
layout, four courses of irregular width stones with a running bond stagger
between courses, in the same spirit as default_stone_brick.py's manual
row and column reasoning rather than lib.segments on this tile's colour.
lib.warp_labels is then used on that layout with a real amplitude, exactly
as instructed, to give each stone a rounded, hand fitted silhouette rather
than the straight edged grid it starts as. The sparse flecks the art does
carry are folded in honestly, as texel scale weathering marks riding on
top of the coursed structure, not as stone shapes.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_terrace_face"


def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def build_course_labels(h, seed):
    """Four courses of irregular width stones, offset in a running bond
    stagger between courses, exactly the reasoning default_stone_brick.py
    gives for its own two courses, extended to more and smaller stones
    for a rubble wall rather than large flagstones. Not derived from the
    art's colour: see the module docstring for why.

    The course bands are shifted by half a course height before row 0, so
    row 0 sits in the middle of a course rather than on a course boundary.
    default_stone_brick.py can put a real mortar row on the tile's own
    seam because it has one already, in the art; this layout has no such
    row to spend there, and a course boundary landing on the row wrap
    gave two unrelated, differently warped stones meeting with no
    matching joint on the far side, seam_n 1.67. Centring row 0 in a
    course instead means the wrap crosses no row joint at all, only the
    same column joints every other row crosses."""
    rng = np.random.default_rng(seed)
    n_courses = 4
    ch = h // n_courses
    row_shift = ch // 2
    course_id_of_row = ((np.arange(h) + row_shift) % h) // ch
    labels = np.zeros((h, h), dtype=int)
    next_id = 0
    course_of = {}
    for c in range(n_courses):
        offset = (ch // 2) if c % 2 == 1 else 0
        widths = []
        total = 0
        while total < h:
            w = int(rng.integers(5, 10))
            widths.append(w)
            total += w
        excess = total - h
        widths[-1] -= excess
        if widths[-1] < 3:
            widths[-2] += widths[-1]
            widths.pop()
        cols = np.full(h, -1, dtype=int)
        cursor = offset % h
        for wgt in widths:
            for k in range(wgt):
                cols[(cursor + k) % h] = next_id
            course_of[next_id] = c
            cursor = (cursor + wgt) % h
            next_id += 1
        labels[course_id_of_row == c, :] = cols[None, :]
    return labels, next_id, course_of


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    uniq = sorted(set(np.round(lum.ravel(), 3).tolist()))
    print("unique shades:", uniq)
    cls = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls}")

    for tol in (0.02, 0.06, 0.1, 0.12):
        seg_labels, n = lib.segments(rgb, tolerance=tol)
        sizes = sorted([int((seg_labels == i).sum()) for i in range(n)], reverse=True)
        print(f"lib.segments tolerance {tol}: {n} regions, sizes {sizes[:8]}"
              f"{' ...' if len(sizes) > 8 else ''}")
    # The reading above: no tolerance gives stone sized regions. Take the
    # fleck mask at the tolerance that separates it from the background,
    # for use as weathering detail below.
    fleck_labels, fleck_n = lib.segments(rgb, tolerance=0.06)
    fleck_sizes = np.array([int((fleck_labels == i).sum()) for i in range(fleck_n)])
    background_id = int(np.argmax(fleck_sizes))
    fleck_mask = fleck_labels != background_id
    print(f"fleck texels: {int(fleck_mask.sum())} of {fleck_mask.size}")

    h = src.shape[0]
    labels, n_stones, course_of = build_course_labels(h, seed=5)
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    print(f"hand reasoned coursing: {n_stones} stones over 4 courses, sizes {sizes}")

    # Each stone's own brightness in the art, real but faint (the art is
    # almost flat), plus a per-stone seeded jitter standing in for the
    # brightness signal the art does not carry: physically, stones in a
    # dry wall project by different amounts regardless of their colour.
    stone_lum = np.array([lum[labels == i].mean() for i in range(n_stones)])
    lo, hi = stone_lum.min(), stone_lum.max()
    brightness_share = (stone_lum - lo) / max(hi - lo, 1e-6)
    jitter = np.random.default_rng(6).uniform(-1.0, 1.0, n_stones)
    stone_target = 0.55 + 0.12 * brightness_share + 0.22 * jitter
    print("stone target range:", round(float(stone_target.min()), 3),
          "to", round(float(stone_target.max()), 3))

    labels_hi = lib.warp_labels(labels, amp=7.0, seed=17, cells=10)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # narrow, firm joint: stones fitted directly, no mortar bed
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=40, octaves=2, seed=27) * 1.0
    dist = np.clip(dist + wobble, 0.0, max_dist)
    t = smoothstep(dist / max_dist)

    target_map = stone_target[labels_hi]
    layout = target_map * t

    # Low, broad domes: a dry stone wall's outward face is dressed rough
    # but nearly flat, so the crown is wider and lower than a cobble's.
    crown = lib.fbm(lib.SIZE, base_cells=5, octaves=2, seed=28) * 0.10
    layout = layout + crown * t

    # Fine tooling and pitting on the stone faces themselves.
    tooling = lib.fbm(lib.SIZE, base_cells=44, octaves=3, seed=29, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=30), 1) * 0.05

    # The art's own fleck texels: small weathering marks or mineral glints,
    # a texel scale bump, nearest upscaled so they sit exactly where the
    # art draws them.
    fleck_hi = lib.upscale(fleck_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0]
    fleck_bump = lib.blur(fleck_hi, 1) * 0.08

    height = lib.normalise01(layout + tooling + pores + fleck_bump, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=31)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 42
    m = lib.pack(STEM, out_dir, albedo, height, smooth, "stone",
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, "stone")
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
