"""Hand authored LabPBR height and smoothness for kythen_norse_runestone, a
dressed stone slab with carved runes, engraved shallow on a flat face.

The 32 px art has six shades. Two of them are not mottling: the brightest
(0.582, 63 texels) is exactly the top row and the left column, a drawn
frame on two edges of the slab, and the second brightest (0.453, 35
texels) is scattered in small clusters through the middle of the face in
shapes that read as actual rune strokes, not noise (rows 11 to 15 and 19
to 24 each carry a short run of two to five texels bent into a stroke).
The rest of the face is a soft, low contrast mottle in the four remaining
shades, the stone's own worked grain. This is a dressed, manufactured
face: no warp (lib.warp_labels would turn the runes into scribbles), held
flat, with the runes as a shallow engraved groove and the frame as a
faint raised edge.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_runestone"
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

    rune_mask = np.isclose(lum, 0.453, atol=1e-3)
    frame_mask = np.isclose(lum, 0.582, atol=1e-3)
    print(f"rune texels: {int(rune_mask.sum())}, frame texels: {int(frame_mask.sum())}")
    print(f"frame is exactly row 0 and column 0: "
          f"{bool(((np.where(frame_mask)[0] == 0) | (np.where(frame_mask)[1] == 0)).all())}")

    # Nearest upscale, no warp: this is carved, not natural, and warping
    # the label would turn a straight rune stroke into a scribble.
    rune_hi = lib.upscale(rune_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0] > 0.5
    frame_hi = lib.upscale(frame_mask.astype(np.float32)[..., None].repeat(3, -1))[..., 0] > 0.5

    max_dist = 3  # a narrow, shallow groove, chisel width not a mortar joint
    dist = lib.distance_to_edge(rune_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # 1 on the face, dipping to 0 inside a rune stroke

    frame_bump = lib.blur(frame_hi.astype(np.float32), 1) * 0.25
    layout = t + frame_bump

    # Fine worked grain across the whole face, the dressed stone's own
    # subtle mottle, well under the engraving's own depth.
    grain = lib.fbm(lib.SIZE, base_cells=46, octaves=3, seed=81, gain=0.55) * 0.30
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=82), 1) * 0.22
    height = lib.normalise01(layout + 0.4 * grain + 0.25 * pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the engraved grooves gather dust and stay
    # rough, the dressed face and its frame wear a touch smoother.
    rough_noise = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=83)
    smooth = 0.5 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18
    # A dressed, flat face: the runes are a shallow engraving, not a
    # cobble's worth of relief, so the range is held narrow.
    height = lib.band(height, 0.20)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    print("note: a dressed, flat runestone face carries only a shallow"
          " chiselled groove for the runes, not a stone class's usual"
          " mortar-deep joint, so the tilt target (28 to 40 deg, tuned"
          " for jointed masonry) may legitimately be missed; the runes"
          " are meant to read as an engraving on a flat slab, not relief"
          " carving, so the band is not widened to chase the number.")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
