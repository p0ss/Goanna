"""Hand authored LabPBR height and smoothness for kythen_habesha_salt_crust.

The 32 px art has only four shades: 0.709 (419 texels, 41 percent of the
tile) and three near identical light shades, 0.848, 0.852 and 0.874 (605
texels together), a clean 0.14 gap above the dark one. The dark shade is
not one connected line: flood filling it wrapped gives 25 separate blobby
patches, sizes one texel up to 86, while the light shade is one single
connected sea (526 texels) plus a few small islands. That is a crazed
crust read honestly: many disconnected dark plates or cracked patches
sitting in a lighter continuous crust colour, not a single unbroken crack
line the way default_stone_brick's mortar is. It is still exactly what
the brief asks for, a distinct dark shade against a lighter crust colour,
so it is taken as the groove mask the mortar recipe uses: dark texels are
the crack floor, light texels the crust plate, with the mask's own shape
kept exactly (no warp_labels amplitude, this is a drawn crazed pattern,
not natural stone) and only a short distance_to_edge taper softening the
boundary.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_salt_crust"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    print(f"lib.class_of reads: {lib.class_of(STEM, GAME)}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    shades = sorted(set(np.round(lum.ravel(), 3).tolist()))
    print("unique shades:", shades)

    crack_mask = lum < 0.78  # the one dark shade, 0.709, clear of the three light ones at 0.848 and up
    print(f"crack mask texels: {int(crack_mask.sum())} of {crack_mask.size} "
          f"({100.0 * crack_mask.mean():.0f} percent)")

    # Component count on the mask, to report honestly whether this reads as
    # one network or a scatter of separate dark patches.
    h, w = crack_mask.shape
    labels = -np.ones((h, w), dtype=int)
    n = 0
    sizes = []
    for y in range(h):
        for x in range(w):
            if not crack_mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = n
            size = 0
            while stack:
                cy, cx = stack.pop()
                size += 1
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if crack_mask[ny, nx] and labels[ny, nx] < 0:
                        labels[ny, nx] = n
                        stack.append((ny, nx))
            sizes.append(size)
            n += 1
    print(f"dark mask components: {n}, sizes {sorted(sizes, reverse=True)[:10]}")
    print("this is a scatter of separate crazed patches, not one continuous "
          "crack line; treated as the groove mask regardless, same as the "
          "mortar recipe, because it is still a distinct dark shade cutting "
          "a lighter crust")

    scale = lib.SIZE // h
    mask_hi = np.repeat(np.repeat(crack_mask, scale, axis=0), scale, axis=1)

    # A narrow groove: max_dist was tried at 5 to 8 first, and wider read
    # as MORE occluded to the eye but LESS occluded to lib.ao_from_height's
    # own measure once pack()'s default fine_detail (0.35) damps texel
    # scale relief, because at that width the crack is exactly the texel
    # scale relief being damped. Measured directly (bypassing the shared
    # file to avoid clashing with a concurrent edit): at max_dist 5 with
    # the default fine_detail, ao_min read 0.64; at max_dist 2 with
    # fine_detail=1.0 it read 0.13. The crack here genuinely is texel
    # scale, one drawn shade wide in 32 px art, so fine_detail=1.0 is the
    # documented exception ("pass fine_detail=1.0 only where texel scale
    # detail is the point"), not a workaround.
    max_dist = 2
    dist = lib.distance_to_edge(mask_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: sharp fall into the crack, flat plate away from it

    # The plate face: held in a small band, no crown, no per-plate doming.
    # This is a crazed flat crust, not rounded natural stone, so the only
    # structure on the plate itself is fine grain and salt crystal sparkle.
    salt_grain = lib.fbm(lib.SIZE, base_cells=40, octaves=3, seed=61, gain=0.55)
    sparkle = lib.blur(lib.white_noise(lib.SIZE, seed=62), 1)
    plate_raw = 0.7 * salt_grain + 0.3 * sparkle
    plate_texture = lib.band(plate_raw, half_width=0.06, centre=0.62)

    crack_floor = 0.08  # a real, if shallow, recess: the groove floor the brief asks for
    layout = crack_floor + (plate_texture - crack_floor) * t
    height = np.clip(layout, 0.0, 1.0).astype(np.float32)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the same taper: the crack collects dust and grime
    # and stays rough, the plate face is what the sun bakes hard and the
    # salt itself catches a little sparkle. Own variation on top, spread is
    # ours, pack() sets the mean.
    rough_noise = lib.fbm(lib.SIZE, base_cells=30, octaves=3, seed=63, gain=0.6)
    smooth = 0.45 * t + 0.4 * rough_noise + 0.2 * sparkle
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 18
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0], fine_detail=1.0)
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
