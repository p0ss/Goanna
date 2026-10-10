"""Hand authored LabPBR height and smoothness for kythen_norse_sea_ice,
a flat, glassy ice sheet with cracks.

The 32 px art has three shades in roughly equal shares: a dark network
(0.718, 10.7%) that reads as cracks, winding thin lines rather than
blocky regions, and two brighter shades (0.732, 45.6% and 0.889, 43.7%)
that read as broad ice plates at a slightly different sheen rather than
separate stones. Per the brief this stem is authored to class "ice"
outright (lib.class_of reads "leaves" from the bake, plausible for its
measured smoothness but plainly wrong for what the art draws), so the
surface stays flat and glassy: the cracks are the only real relief, the
rest is held close to level with a high, tightly grouped smoothness.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_sea_ice"
CLS = "ice"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, overriding to {CLS} per brief")

    crack_mask = lum < 0.725
    print(f"crack texels: {int(crack_mask.sum())} of {crack_mask.size} "
          f"({crack_mask.mean()*100:.1f}%)")
    plate_mask = lum > 0.80
    print(f"bright plate texels: {int(plate_mask.sum())} ({plate_mask.mean()*100:.1f}%)")

    # Nearest upscale, only a very light wobble: ice cracks fracture in
    # fairly straight runs, not the rounded warp a natural stone gets.
    crack_hi = lib.upscale(crack_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0] > 0.5
    plate_hi = lib.upscale(plate_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0] > 0.5

    max_dist = 3  # a narrow, sharp fracture edge, not a wide mortar joint
    dist = lib.distance_to_edge(crack_hi.astype(np.float32), max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=48, octaves=2, seed=111) * 0.6
    dist = np.where(crack_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # 0 in the crack, 1 across the level plate

    # A very slight step between the two plate shades, the way two sheets
    # frozen at slightly different times sit a hair apart, not a joint.
    plate_step = np.where(plate_hi, 0.06, 0.0)
    layout = t + plate_step

    # Fine surface texture: a light crystalline stipple, far shallower
    # than the cracks.
    grain = lib.fbm(lib.SIZE, base_cells=36, octaves=3, seed=112, gain=0.55) * 0.06
    height = lib.normalise01(layout + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: high and tightly held everywhere (glassy ice), the
    # cracks a little rougher where frost has grown into the fracture.
    variation = lib.fbm(lib.SIZE, base_cells=24, octaves=3, seed=113, gain=0.55)
    smooth = 0.85 + 0.10 * variation
    # A blurred crack mask rather than the raw boolean edge: the art's own
    # crack pattern is not guaranteed to line up across its own wrap (the
    # albedo seam is informational for exactly this reason), and a hard
    # step straight off that mask carried the mismatch into the _s map's
    # own seam, which check() does hold to account.
    crack_soft = lib.blur(crack_hi.astype(np.float32), 2)
    smooth = smooth - 0.30 * crack_soft
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 38
    # Flat and glassy: the cracks are real but shallow, so the range is
    # held to a narrow band rather than a stone's full depth.
    height = lib.band(height, 0.36)
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
