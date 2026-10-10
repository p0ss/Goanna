"""Hand authored height and smoothness for kythen_moana_dressed_coral.

The 32 px art draws a clean running bond ashlar: the darkest shade (0.516,
18 percent of the tile) forms a full width mortar row every eight rows (0,
8, 16, 24) and, within each course, two full height mortar columns 16
texels apart, staggered by four texels between courses (0 and 16, then 12
and 28, then 8 and 24, then 4 and 20), the same geometry kythen_habesha_
aksumite_ashlar.py finds in its own art, just with two stones a course
instead of that ashlar's own four. This is coral cut into dressed blocks,
so it is built the same way: exact joint geometry from the mortar mask, no
lib.warp_labels on this dressed, flat faced surface, each block's own
target height off its own brightness (three shades, 0.818 to 0.88, coral's
own pale, slightly uneven cut faces), plus small pore pits standing in for
coral's natural porosity showing through the dressed face.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_dressed_coral"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def label_blocks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped, matching kythen_habesha_aksumite_ashlar.py: every course
    here carries two full height joint columns, so the wrap never merges
    two blocks into one."""
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

    mortar_mask = lum <= 0.55
    print(f"mortar texels: {int(mortar_mask.sum())} of {lum.size}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.60 + 0.30 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    up = SIZE // lum.shape[0]
    mortar_hi = np.repeat(np.repeat(mortar_mask, up, axis=0), up, axis=1)
    labels_hi = np.repeat(np.repeat(labels, up, axis=0), up, axis=1)

    max_dist = 3  # groove half width in 256 map texels, a real dressed joint
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=32, octaves=2, seed=891) * 0.8
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    crown = lib.fbm(SIZE, base_cells=5, octaves=2, seed=892) * 0.03
    layout = layout + crown * t

    # Fine dressing marks and coral's own natural porosity, small pits
    # showing through the cut face.
    tooling = lib.fbm(SIZE, base_cells=52, octaves=3, seed=893, gain=0.55) * 0.04
    pore_field = lib.blur(lib.white_noise(SIZE, seed=894), 1)
    pore_cut = float(np.percentile(pore_field, 6.0))
    pores = np.where(pore_field < pore_cut, (pore_field - pore_cut) * 3.0, 0.0)

    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=895)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 24.0
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
