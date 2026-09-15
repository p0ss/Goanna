"""Hand authored height and smoothness for mcl_core_grass_path_top.

lib.class_of reports this stem as "leaves": it is reading back the pack's
own existing bake, whose median subsurface byte for every grass named
texture in the game was set to leaves' own value regardless of what each
tile actually draws, a footstep or node level classification that never
looked at this tile's own art. The art itself is four grey shades, 0.352,
0.380, 0.420 and 0.463, a per texel dither with no drawn stone or leaf
shape, the same device default_dirt.py's own art uses at a narrower,
slightly lighter band (dirt's four shades run 0.284 to 0.418). This is
plainly soil, trodden earth, not foliage, so the script overrides to
lib.class_of's usual role and builds it as CLS = "soil" instead.

Trodden earth is dirt with the loose crumb pressed flat by footsteps and
the lighter texels are not a different material, they are the same clay
compacted smooth and pale where the organic crumb has worn away: this
script segments the art exactly as default_dirt.py does (lib.segments,
tolerance loosened slightly to 0.04 for this narrower shade band, the same
warp seed) and shares its lumps, grit and variation noise seeds (21, 22,
24), but the target height band is narrower, the layout's own crown fade
is wider (see the comment at max_dist below, this art's own wrap forced
that), and the fine structure's amplitude is damped wherever the art
itself is lighter, so a worn patch is not just paler, it is flatter, the
same "recesses stay rough, worn faces smooth" idea default_dirt.py's own
smoothness already follows, applied here to the height as well as the
shine. A wide crown fade cannot carry a real joint, so the soil class's
own ao minimum comes instead from a new, sparse, narrow pit field (seed
25) standing in for the gravel a footpath's crumb still has.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_grass_path_top"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print('class_of would say "leaves" (the old bake\'s footstep level '
          'classification); the art is plainly dirt, overridden to "soil"')

    # 0.04 is looser than default_dirt's own 0.05 because this art's four
    # shades sit in a narrower band (0.352 to 0.463 against 0.284 to
    # 0.418), so the same absolute tolerance would under segment it; 0.04
    # still sits comfortably under the roughly 0.04 gap between neighbour
    # shades, so a region still only grows by matching, not by crossing a
    # shade boundary.
    tolerance = 0.04
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True))
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    # A narrower target band than default_dirt's 0.15 to 0.80: trodden
    # ground has already had its own loose relief walked flat, so the
    # region to region contrast this layout carries is smaller from the
    # start, on top of which the fine structure below is damped further.
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.40 + 0.30 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels)  # default seed 7, shared with dirt
    edges = lib.region_edges(labels_hi)
    # A wider crown fade than default_dirt.py's own 4: this art's row 15
    # carries a handful of single texel regions at the top of the target
    # band (0.70) right where row 0 carries the dominant region near the
    # bottom of it (0.46), a real local swing of 0.24 once region
    # brightness is stretched to the target band, at the wrap on both the
    # row and the column axis. default_dirt.py's own 4 texel fade left
    # that step almost as sharp as the art itself draws it (layout seam
    # energy 2.45, against 1.61 for default_dirt's own layout); widening
    # the fade to 6 spreads the same real content over more texels rather
    # than inventing new content to hide it (layout seam energy 1.51), and
    # suits a trodden surface that wants a gentler crown anyway. The joints
    # this costs are put back below as their own, sharper feature, because
    # a region step this wide cannot carry the deep, narrow dip a soil
    # class ao minimum needs.
    max_dist = 6
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep, 1 mid region, 0 right at a boundary

    # Same unsharp mask device as default_dirt.py, wider radii for the
    # same reason as the crown fade above.
    step = target[labels_hi]
    narrow = lib.blur(step, 6)
    wide = lib.blur(step, 12)
    layout = narrow + 1.1 * (narrow - wide)

    # Wear: how compacted the ground is, read from the same smoothed per
    # region brightness the layout above already built (narrow), not the
    # raw blocky albedo, whose own wrap jump (seam_albedo, the art's own
    # design) would otherwise ride straight through the damp factor and
    # into the lumps, grit and pits it scales, seaming them for no reason
    # the height layout does not already seam for. Lighter texels are the
    # packed, worn patches, used to damp the fine structure below rather
    # than to raise it: a worn patch is flatter, not taller.
    wear = lib.normalise01(narrow)
    damp = 1.0 - 0.25 * wear
    print(f"wear mean {wear.mean():.3f}, damp mean {damp.mean():.3f} "
          f"(1 = untouched crumb, 0.75 = compacted)")

    # Same lumps and grit seeds as default_dirt.py (21, 22), each damped
    # where the ground is worn. Widening the crown fade above cost the
    # region step its own small, sharp joints, the thing that actually
    # gave default_dirt.py its ao minimum, so pits is rebuilt here as its
    # own sparse, narrow dip (a new seed, 25, rather than default_dirt's
    # own broader seed 23 blur, which is too shallow and too wide once the
    # region step can no longer add to it) standing in for the gravel and
    # small stones a footpath's own crumb still has between the compacted
    # patches.
    lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=21, gain=0.55) * 0.20 * damp
    grit = lib.blur(lib.white_noise(SIZE, seed=22), 1) * 0.05 * damp
    pit_noise = lib.white_noise(SIZE, seed=25)
    pit_threshold = np.percentile(pit_noise, 85.0)
    pit_mask = np.clip((pit_noise - pit_threshold) / (pit_noise.max() - pit_threshold), 0.0, 1.0)
    pit_mask = lib.blur(pit_mask, 1)
    pits = -0.40 * pit_mask * damp

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the region boundary the same way default_dirt.py's
    # does, plus the same wear reading: a compacted patch is worn smooth
    # underfoot on top of whatever its own region contrast gives it.
    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=24, gain=0.55)
    smooth = 0.35 * t + 0.40 * variation + 0.25 * wear
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 9.0
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
