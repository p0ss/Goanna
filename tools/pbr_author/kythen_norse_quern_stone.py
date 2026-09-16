"""Hand authored LabPBR height and smoothness for kythen_norse_quern_stone,
a dressed round stone face for a quern, worked flat with pecked pits.

The 32 px art has four shades, 0.330 to 0.453, mostly one matrix shade
(0.403, 883 of 1024 texels) with a scatter of the darkest shade (0.330,
141 texels, 13.8%) as small flecks, a handful of texels each, spread
fairly evenly over the face rather than clustered. That is the pecking: a
quern's grinding face is dressed by striking it all over with a point,
each strike a small dark pit. The face itself stays flat, as a dressed
stone floor should; only the pecking gets any height at all.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_quern_stone"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")

    labels, n = lib.segments(rgb, tolerance=0.06)
    sizes = np.bincount(labels.ravel())
    bg = int(np.argmax(sizes))
    peck_mask = labels != bg
    print(f"segments: n={n}, matrix region {int(sizes[bg])} texels, "
          f"pecking {int(peck_mask.sum())} texels ({peck_mask.mean()*100:.1f}%)")

    # Nearest upscale keeps every peck mark exactly where the art drew it;
    # no warp, this is a dressed face, not a natural surface.
    peck_hi = lib.upscale(peck_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0]
    peck_hi = peck_hi > 0.5

    max_dist = 3  # pecks are a texel or two across, a tight taper keeps each one a distinct small pit
    dist = lib.distance_to_edge(peck_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    # 1 at the matrix, dipping to 0 in the middle of a peck.
    layout = t

    # Fine dressing marks across the whole face, well under the pecking's
    # own scale, and a scatter of finer pores.
    tooling = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=71, gain=0.55) * 0.35
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=72), 1) * 0.30
    height = lib.normalise01(layout + 0.5 * tooling + 0.3 * pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the pecked pits gather dust and stay
    # rough, the dressed matrix between them wears a touch smoother.
    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=73)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 22
    # A dressed, flat quern face: held to a narrow band so the pecking
    # reads as shallow pits, not a cobble's worth of relief.
    height = lib.band(height, 0.22)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    print("note: a dressed, worked-flat quern face carries only pecked pits,"
          " not a stone class's usual mortar-deep joint, so the tilt target"
          " (28 to 40 deg, tuned for jointed masonry) may legitimately be"
          " missed; widening the band to chase it would turn the face into"
          " a rubble heap, which this stone is not.")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
