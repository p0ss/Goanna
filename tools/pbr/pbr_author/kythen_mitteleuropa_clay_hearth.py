"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_clay_hearth.

The 32 px art is seven warm brown shades, luminance 0.212 to 0.437, no
drawn joint or block: a fired clay slab with soot staining, the darkest
shades sitting in patches rather than a coherent crack network (checked
with lib.segments the way hardened_clay_family.py checks its own tile: no
stone or brick sized regions appear at any tolerance). lib.class_of reads
back "wood" from the bake, the same level-readback artefact
kythen_khmer_stucco.py's docstring explains, not a material judgement: a
fired clay hearth slab is a ceramic, hard like stone, the same call
hardened_clay_family.py and kythen_khmer_earthenware_tile.py make for their
own fired clay, so this overrides to "stone".

Built flat, the way a fired slab must be (lib.band, the same call
hardened_clay_family.py makes): a gentle mottled undulation from the art's
own shading, with the darkest, sootiest patches read back as slightly
recessed and distinctly duller in the smoothness, since soot is what
collects in a low spot and stays matte while the clean fired clay around it
keeps a slight sheen.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_clay_hearth"
CLS = "stone"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print(f"class_of would read: {lib.class_of(STEM, GAME)}, overridden to {CLS} "
          f"(fired clay is a ceramic, hard like stone)")

    for tol in (0.04, 0.08, 0.12):
        labels, n = lib.segments(rgb, tolerance=tol)
        sizes = sorted([int((labels == i).sum()) for i in range(n)], reverse=True)
        print(f"segments tol={tol}: n={n}, sizes {sizes[:8]}{' ...' if len(sizes) > 8 else ''}")
    print("no brick or stone sized region at any tolerance; soot patches, not joints")

    # The slab's own mottling, smoothly upscaled and rounded, the same
    # construction hardened_clay_family.py uses for its own fired tile.
    norm_lum = (lum - lum.min()) / max(lum.max() - lum.min(), 1e-6)
    mottle = lib.blur(lib.upscale(norm_lum, smooth=True), 3)

    # Soot: the darkest quarter of the art's own range, read back as a
    # shallow recess (soot sits in the low spots and builds up there) with
    # a soft edge.
    soot_mask = norm_lum < 0.25
    soot_hi = lib.blur(lib.upscale(soot_mask.astype(np.float32), smooth=True), 2)
    print(f"soot texels: {int(soot_mask.sum())} of {soot_mask.size}")

    ripple = lib.fbm(SIZE, base_cells=44, octaves=2, seed=931, gain=0.5)
    pits = lib.blur(lib.white_noise(SIZE, seed=932), 1)
    grain = lib.blur(lib.white_noise(SIZE, seed=933), 2)

    field = 0.30 * mottle - 0.20 * soot_hi + 0.30 * ripple + 0.10 * pits + 0.10 * grain
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    # Kept in a narrow band: a fired slab is as flat as hardened_clay's own
    # tile, not a joint bearing surface.
    height = lib.band(field, 0.14)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the fired body keeps a slight sheen, soot is matte and
    # dulls it right down, well below the class level there.
    variation = lib.fbm(SIZE, base_cells=28, octaves=3, seed=934, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.70 * variation - 1.0 * soot_hi
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 12.0
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
