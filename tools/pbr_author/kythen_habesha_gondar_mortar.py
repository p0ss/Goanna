"""Hand authored LabPBR height and smoothness for kythen_habesha_gondar_mortar.

The 32 px art carries five shades and a clean gap: the lightest, 0.671, is
far brighter than the rest (0.315 to 0.444) and appears nowhere except
eight full width rows, every fourth row (0, 4, 8, ... 28). Each of those
three texel high courses also has four full height columns of the same
light shade, eight texels apart, staggered by two texels each course
(0,8,16,24 then 6,14,22,30 then 4,12,20,28 then 2,10,18,26, repeating every
four courses). That is a lime mortar bed a full texel wide running both
ways round small rubble stones, exactly what "the mortar proud between
stones" describes: this is coursed rag rubble, small stones bedded in a
mortar that a mason has pointed proud of the stone faces, not stones proud
of a recessed mortar the way dressed ashlar reads. So the height here is
built backwards from kythen_habesha_aksumite_ashlar: the mortar is the high
plateau and each little stone is a shallow recessed panel sunk below it,
still lightly domed because a set stone is never perfectly flat.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_gondar_mortar"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def label_blocks(mortar_mask):
    """Connected components of the non mortar texels, 4 connected and
    wrapped. Every course has four full height joint columns, so flood
    fill separates the stones cleanly without the single joint wrap
    problem default_stone_brick.py has to work around."""
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

    mortar_mask = lum >= 0.55
    print(f"mortar texels: {int(mortar_mask.sum())} of {lum.size}")

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"stones found: {n_blocks}, sizes {sorted(sizes, reverse=True)[:10]} ... min {min(sizes)}")

    # Each stone's own recessed floor level off its own mean brightness: a
    # stone the art drew lighter sits a touch higher in its own recess,
    # still well below the mortar plateau around it.
    stone_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    stone_target = 0.18 + 0.28 * (stone_lum - lo) / max(hi - lo, 1e-6)

    # Real rubble is never perfectly rectangular even when roughly coursed:
    # a small warp softens the block outline into a stone's own silhouette,
    # unlike the precisely dressed ashlar next door which gets none.
    labels_hi = lib.warp_labels(labels, amp=2.5, seed=71)
    mortar_hi = lib.warp_labels(mortar_mask.astype(int), amp=2.5, seed=71) > 0

    mortar_level = 0.82  # the lime bed, pointed proud
    max_dist = 5  # recess taper, in 256 map texels: these stones are small
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=40, octaves=2, seed=72) * 1.0
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # 0 at the mortar (and through its whole bed), 1 deep in a stone

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for i in range(n_blocks):
        target_map[labels_hi == i] = stone_target[i]
    # Mortar stays at its own plateau throughout its own bed (t=0 there);
    # a stone's own recessed floor only appears once far enough from the
    # mortar to be inside the stone rather than its worn edge.
    layout = mortar_level + (target_map - mortar_level) * t

    # A stone set in mortar is never dead flat: a slight dome on its own
    # recessed face, rounded by weather even though it sits below the bed,
    # scaled by how deep into the stone the texel is and zeroed on mortar.
    crown = lib.fbm(SIZE, base_cells=6, octaves=2, seed=73) * 0.05
    layout = layout + crown * t * (~mortar_hi).astype(np.float32)

    tooling = lib.fbm(SIZE, base_cells=44, octaves=3, seed=74, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=75), 1) * 0.04
    # One real deep pit: a weathered pocket where a stone has pulled away
    # from its bed a little, not the broad even recess every stone gets.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=76), 1)
    pit_cut = float(np.percentile(pit_field, 0.3))
    deep_pit = np.where(pit_field < pit_cut, (pit_field - pit_cut) * 10.0, 0.0)

    height = lib.normalise01(layout + tooling + pores + deep_pit, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    # Smoothness follows height: the mortar bed is what a hand runs over,
    # the recessed stone faces hold the dust and grime, the opposite of a
    # dressed ashlar where the raised block is what wears smooth.
    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=77)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 16.0
    # Pointed rubble: the mortar stands a little proud, not a cage. On the
    # ramp the full range recess read as a waffle.
    height = lib.band(height, 0.3)
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
