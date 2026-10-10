"""Hand authored LabPBR height and smoothness for kythen_habesha_river_gravel.

The 32 px art has eight grey shades, standard deviation 0.074. There is a
clean gap in the shade list between 0.444 and 0.519, splitting it four
shades low (0.315 to 0.444) and four high (0.519 to 0.612): the low group
sits in the shadowed gaps between pebbles, the high group is pebble tops
catching the light, the same split default_gravel.py finds in Mineclonia's
art. Segmenting at tolerance 0.05 gives 205 regions, most a handful of
texels and a few chains up to sixty four: many small river pebbles packed
edge to edge, not a few big stones.

Note: an earlier draft of this file (found on disk mid session, not written
by this run) set fine_detail=1.0 to fight a low tilt reading. That traded
away the brief's hard rule of keeping fine_detail at its default for every
stem but scoria_fresh, and was not needed: the actual shortfall was that
lib.band's 0.3 half width, copied from default_gravel.py without checking
whether it still cleared the target after "Hold natural relief in a band"
(535d589) landed, was holding real pebble relief to less than a third of
the byte. Gravel is not a nearly flat material, so this script keeps the
full normalise01 range instead of banding it, and leaves fine_detail alone.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_river_gravel"
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

    # Connected regions of near identical colour, wrapping at the tile edge.
    # 0.05 keeps a pebble's own texels together without bridging pebble to
    # pebble.
    tolerance = 0.05
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes (top 15):", sorted(sizes.tolist(), reverse=True)[:15])

    # Target height per region: the low shade group is a true gap, cut down
    # near the floor regardless of exactly how dark; the high shade group is
    # a pebble dome, its own height rising with its own brightness so a
    # sunlit pebble stands taller than a merely lit one. 0.48 sits in the
    # clean gap between the low group's top shade (0.444) and the high
    # group's bottom shade (0.519).
    baseline = 0.08
    gap = region_lum <= 0.48
    dome = ~gap
    print(f"gap regions: {int(gap.sum())} of {n}, {int(sizes[gap].sum())} texels; "
          f"dome regions: {int(dome.sum())}, {int(sizes[dome].sum())} texels")
    dlo, dhi = region_lum[dome].min(), region_lum[dome].max()
    target = np.where(gap, baseline,
            0.55 + 0.40 * (region_lum - dlo) / max(dhi - dlo, 1e-6))

    labels_hi = lib.warp_labels(labels)
    edges = lib.region_edges(labels_hi)
    max_dist = 3  # pebbles are one to eight source texels across; a tight
                  # taper keeps each one a distinct small dome
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: rounds a square texel into a dome, or lets a gap sink cleanly
    layout = baseline + (target[labels_hi] - baseline) * t

    # Sub texel structure: grit a couple of texels across on the pebble
    # tops, and a scatter of finer pores and dirt down in the gaps.
    grit = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=131, gain=0.55) * 0.08
    dirt = lib.blur(lib.white_noise(lib.SIZE, seed=132), 1) * 0.08
    height = lib.normalise01(layout + grit + dirt, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the gaps hold dust and stay rough, pebble
    # tops are what a boot rounds smooth. Gravel's own variation, loose and
    # ungraded, rides on top; pack() moves the mean to the class level, the
    # spread is ours to set.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=133)
    smooth = 0.5 * height + 0.55 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the pebble and gap edges the height field lines
    # up with.
    albedo = lib.upscale(src[..., :3])

    # Real pebbles genuinely stand this proud of the gaps between them, so
    # the full normalise01 range is kept rather than held in lib.band: a
    # band half width scaled to look right on the 16 px cobble left this 32
    # px gravel's tilt and ao well short of target (see the module note
    # above). fine_detail is left at its default too.
    normal_strength = 28
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
