"""Hand authored LabPBR height and smoothness for kythen_habesha_scoria_fresh.

The 32 px art carries only two grey shades, 0.339 and 0.459, sd 0.060. It
segments (tolerance 0.05) into 24 regions, but only two are large: one dark
blob of 480 texels (47 percent) and one bright blob of 312 texels (30
percent), interlocking across most of the tile, with the remaining small
patches of both shades scattered through the rest. That reads as pitted,
bubbled lava rather than a drawn layout of separate stones: the whole face
is one continuous undulating surface of shadowed hollows and lit crests,
which is what fresh scoria genuinely is, full of vesicles from the gas that
left the rock when it cooled.

class_of reads "stone" here. Unlike a dressed or polished stone this
surface really does have depth everywhere, so the height keeps the full
normalise01 range and pack() is called with fine_detail=1.0 instead of the
default 0.35: the default damps one-texel-scale relief because on most
stems that scale is grazing-lamp grain, an artefact of the source pixels
rather than the material, and full strength there reads as rubble. Here the
one and two texel scale pitting *is* the material; a real piece of pumice
is riddled with holes at exactly that scale, so damping it would erase the
one thing that makes this stem different from a plain dressed rock face.
Confirmed by sweeping fine_detail from 0.35 to 1.0 at a fixed normal
strength: the mean tilt only clears the stone band at 1.0 (0.35 gives 21.9
degrees at the same normal_strength that gives 32.2 at 1.0), and the ao
minimum only reaches comfortably under target there too (0.64 against 0.13).
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_scoria_fresh"
CLS = lib.class_of(STEM, GAME)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}, class_of reads {CLS}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} "
          f"mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    order = np.argsort(-sizes)
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes (top 10):", [(int(sizes[i]), round(float(region_lum[i]), 3)) for i in order[:10]])

    # Only two shades, so this is a straight low to high map: the dark blob
    # is the shadowed floor between bubbles, the bright blob is a crest
    # catching the light. lo/hi come from the region means, not the raw
    # shades, since a region's own average is what the taper below targets.
    lo, hi = region_lum.min(), region_lum.max()
    target = 0.30 + 0.55 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, amp=6.0, seed=61)
    edges = lib.region_edges(labels_hi)
    max_dist = 6  # the two dominant blobs are large; a wider taper lets
                  # the coarse hollow and crest shape read as one continuous
                  # undulation rather than a field of separate small domes
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    layout = 0.5 + (target[labels_hi] - 0.5) * t

    # A coarser bump field for the larger bubble shapes the two-tone art
    # only hints at, then real vesicle pitting at sub texel scale: a finer
    # fractal layer and a white noise layer, both kept at full strength by
    # fine_detail=1.0 below rather than damped as grazing-lamp grain.
    bubble = lib.fbm(lib.SIZE, base_cells=10, octaves=2, seed=62) * 0.15
    vesicle = lib.fbm(lib.SIZE, base_cells=6, octaves=4, seed=63, gain=0.55) * 0.20
    pit = lib.white_noise(lib.SIZE, seed=64) * 0.10
    height = lib.normalise01(layout + bubble + vesicle + pit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height with the material's own patchy variation on
    # top; the hollows gather dust, the crests are what wears smoother.
    rough_noise = lib.fbm(lib.SIZE, base_cells=24, octaves=3, seed=65)
    smooth = 0.45 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 11
    fine_detail = 1.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0],
            fine_detail=fine_detail)
    print(f"normal_strength={normal_strength} fine_detail={fine_detail} "
          "(the vesicle pitting is genuine texel scale structure, not "
          "grazing-lamp grain, so it is kept at full strength)")
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
