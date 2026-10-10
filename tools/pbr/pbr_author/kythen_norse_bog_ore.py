"""Hand authored LabPBR height and smoothness for kythen_norse_bog_ore,
lumpy iron nodules sitting in wet peat.

The 32 px art has six shades. The lightest two, 0.306 (69.6% of the tile)
and 0.320 (7.1%), join into one broad connected matrix: the peat itself.
The darker shades, 0.222 to 0.262 (23.2% together), form about twenty
small rounded clusters of two to forty five texels scattered over the
tile, not a single background blob: these are the ore nodules, darker
than the surrounding peat the way raw bog iron reads against wet ground.
lib.class_of reads this stem as "leaves" (its bake measured a smoothness
near the leaves level, plausible for damp organic peat, but the stem is
plainly not foliage), so the class here is set to "soil" for the peat
matrix by hand; the nodules carry their own metal_mask and a rusty, rough
smoothness rather than the matrix's class level.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_bog_ore"
CLS = "soil"


def label_nodules(mask):
    """Connected components of the nodule mask, wrapped, everything else
    (the peat matrix) collapsed to label 0, so the result is a single full
    label grid ready for lib.warp_labels the way default_gravel.py's own
    dome regions are built."""
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=int)
    next_id = 1
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or labels[y, x] != 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if not mask[ny, nx] or labels[ny, nx] != 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, overriding to {CLS} (peat, not foliage)")

    nodule_mask = lum < 0.28
    print(f"nodule texels: {int(nodule_mask.sum())} of {nodule_mask.size} "
          f"({nodule_mask.mean()*100:.1f}%)")
    labels, n_nodules = label_nodules(nodule_mask)
    sizes = [int((labels == i).sum()) for i in range(1, n_nodules)]
    print(f"nodules found: {n_nodules - 1}, sizes {sorted(sizes, reverse=True)}")

    nodule_hi = lib.upscale(nodule_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0] > 0.5
    labels_hi = lib.warp_labels(labels, amp=4.0, seed=91, cells=8)

    edges = lib.region_edges(labels_hi)
    max_dist = 2  # each nodule is a texel or two of art, small domes
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # 0 at a nodule's rim, 1 at its crown or deep in the matrix
    nodule_bump = np.where(labels_hi > 0, t, 0.0) * 0.45

    # Peat matrix: a broad, soft guide from the art's own brightness, like
    # kythen_firecountry_reed_peat.py, plus gentle settled hummocks.
    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))
    lumps = lib.fbm(lib.SIZE, base_cells=9, octaves=3, seed=92, gain=0.55) * 0.22

    # Sparse, deep settled hollows in the peat itself, the same device
    # reed_peat.py uses to get real ambient occlusion out of an otherwise
    # gentle surface: a minority of the area carved well below the rest,
    # rather than spreading a little depth over everything.
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=95), 2)
    hollow_cut = float(np.percentile(hollow_field, 32))
    hollows = np.where(hollow_field < hollow_cut, hollow_field - hollow_cut, 0.0) * 2.2

    layout = 0.30 * guide + 0.20 * lumps + nodule_bump + hollows

    fuzz = lib.blur(lib.white_noise(lib.SIZE, seed=93), 1) * 0.05
    height = lib.normalise01(layout + fuzz, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: peat stays matte and rough throughout; the nodules are
    # picked out separately below as rough, slightly metallic rust.
    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=94, gain=0.55)
    smooth = 0.35 * (height - height.mean()) + 0.6 * variation
    smooth = np.where(nodule_hi, smooth - 0.10, smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    # F0 on the nodules rather than a full metal_mask: bog iron is a rusty
    # oxide crust, not bright reflective metal, so it keeps the albedo's
    # own colour and just sits a little more reflective than the peat
    # around it, with metal_mask reserved for a true bare-metal texel.
    f0 = np.where(nodule_hi, 0.09, lib.DIELECTRIC_F0)

    normal_strength = 14
    height = lib.band(height, 0.42)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0], f0=f0)
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
