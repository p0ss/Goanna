"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_rubble_core.

The 32 px art carries five grey shades. The brightest, 0.512, runs full
width every four rows (0, 4, 8, ... 28) and, within each three row course
band, full height every four columns as well, offset by two columns from
the band above (columns 0, 4, 8, ... in rows 1 to 3, columns 2, 6, 10, ...
in rows 5 to 7, back to 0, 4, 8, ... in rows 9 to 11, and so on). That is a
mortar grid in both directions, staggered course to course, enclosing small
stones about three texels square: a coursed rubble fill, many small
irregular stones set in a lot of mortar, not the wide dressed blocks the
ashlar and stone flag stems draw. This is the wall's core, so the mortar
stays generous and the stones stay small and rounded rather than fitted.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_rubble_core"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def label_blocks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped. The mortar grid runs full height and full width in every
    band, several joints each direction, so the wrap never merges two
    stones into one; no seam cut is needed."""
    h, w = mortar_mask.shape
    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mortar_mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if mortar_mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print(f"lib.class_of reads: {CLS}")

    mortar_mask = lum >= 0.5
    print(f"mortar texels: {int(mortar_mask.sum())} of {lum.size}")

    labels, n_stones = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_stones)]
    print(f"stones found: {n_stones}, sizes {sorted(sizes, reverse=True)[:12]} ...")

    # Each stone's own brightness in the art, real but faint, plus a small
    # per-stone jitter: physically, small rubble sits proud by different
    # amounts regardless of colour, the same reasoning
    # kythen_habesha_terrace_face.py gives its dry stone face.
    stone_lum = np.array([lum[labels == i].mean() for i in range(n_stones)])
    lo, hi = stone_lum.min(), stone_lum.max()
    brightness_share = (stone_lum - lo) / max(hi - lo, 1e-6)
    jitter = np.random.default_rng(841).uniform(-1.0, 1.0, n_stones)
    stone_target = 0.6 + 0.12 * brightness_share + 0.18 * jitter
    target_dict = {-1: 0.05}
    for i in range(n_stones):
        target_dict[i] = float(stone_target[i])

    # Stones this small (three art texels) need a real, if modest, warp to
    # read as irregular rubble rather than the art's own square grid; a
    # dressed stem like the ashlar keeps amp 0, this one does not.
    labels_hi = lib.warp_labels(labels, amp=4.0, seed=842, cells=16)
    edges = lib.region_edges(labels_hi)
    max_dist = 4  # a generous mortar bed for the wall's core, not a fine joint
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=36, octaves=2, seed=843) * 1.2
    dist = np.clip(dist + wobble, 0.0, max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # A low dome on each small stone, and fine pitting on top.
    crown = lib.fbm(SIZE, base_cells=10, octaves=2, seed=844) * 0.12
    layout = layout + crown * t
    tooling = lib.fbm(SIZE, base_cells=48, octaves=3, seed=845, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(SIZE, seed=846), 1) * 0.06

    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=847)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 20.0
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
