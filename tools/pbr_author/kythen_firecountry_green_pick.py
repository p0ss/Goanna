"""Hand authored height and smoothness for kythen_firecountry_green_pick.

Checked and this art is not a cut-out: alpha is 255 everywhere, 32 by 32,
fully opaque. Splitting the texels by hue instead (green channel clearly
above red, against not) finds two real materials painted into the one
tile: 710 of 1024 texels (69 percent) are a true brown, R greater than G
greater than B (for example 0.184, 0.165, 0.122), the soil the pick grows
from; the other 315 are green foliage, G clearly above R and B (for
example 0.361, 0.420, 0.235). This is a small harvestable green sitting
on visible ground, the background painted in rather than cut away, so it
is read as two blended materials the way mcl_core_dirt_podzol_side.py
blends its litter and dirt: a soil base carrying the jointed ao rule
default_dirt.py itself uses, with the foliage's own small raised sprigs
sitting proud of it.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_green_pick"
CLS = "soil"
SIZE = lib.SIZE


def blade_stamp(radius, angle, length, width, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_blades(size, guide, inside, n, seed, length_range, width_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    placed = 0
    attempts = 0
    max_attempts = n * 8
    while placed < n and attempts < max_attempts:
        attempts += 1
        cx = int(rng.integers(0, size))
        cy = int(rng.integers(0, size))
        if inside[cy, cx] < 0.5:
            continue
        angle = rng.normal(np.pi / 2.0, 0.5)
        length = rng.uniform(*length_range)
        width = rng.uniform(*width_range)
        jitter = rng.uniform(0.85, 1.15)
        amp = jitter * (0.4 + 0.9 * guide[cy, cx])
        radius = int(np.ceil(length / 2.0 + width))
        stamp = blade_stamp(radius, angle, length, width, amp)
        ys = (np.arange(-radius, radius + 1) + cy) % size
        xs = (np.arange(-radius, radius + 1) + cx) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
        placed += 1
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    alpha = src[..., 3]
    print("alpha min/max:", float(alpha.min()), float(alpha.max()), "(fully opaque, not a cut-out)")
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    green_mask = (g > r + 0.02) & (g > b + 0.02)
    print(f"soil texels {int((~green_mask).sum())} of {rgb.shape[0]*rgb.shape[1]}, "
          f"foliage texels {int(green_mask.sum())}")
    print("mean rgb soil texels:", rgb[~green_mask].mean(axis=0))
    print("mean rgb foliage texels:", rgb[green_mask].mean(axis=0))
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    art_rgb = lib.upscale(rgb)
    # Nearest upscale then a wrapped blur, not a bilinear smooth upscale:
    # PIL's own resize does not wrap at the tile edge, and this mask feeds
    # a hard switch between two different smoothness formulas, so its own
    # seam would otherwise show up strongly in the _s map.
    green_hi = lib.blur(lib.upscale(green_mask.astype(np.float32)), 3)
    soil_weight = 1.0 - green_hi

    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    # Soil base: small clod texture, the same device as default_dirt.py,
    # carved down under the foliage so the sprig reads as standing above
    # visible ground rather than merged into it.
    soil_lumps = lib.fbm(SIZE, base_cells=10, octaves=3, seed=311, gain=0.55) * 0.26
    soil_grit = lib.blur(lib.white_noise(SIZE, seed=312), 1) * 0.05
    soil_pit_field = lib.blur(lib.white_noise(SIZE, seed=313), 2)
    soil_pit_cut = float(np.percentile(soil_pit_field, 38))
    soil_pits = np.where(soil_pit_field < soil_pit_cut, soil_pit_field - soil_pit_cut, 0.0) * 6.5
    soil_height = 0.30 + soil_lumps + soil_grit + soil_pits

    # Foliage: small blades scattered only where the green mask allows,
    # standing proud of the soil base.
    blades = scatter_blades(SIZE, guide, green_hi, 420, seed=314, length_range=(8, 16), width_range=(3, 5))
    blades = lib.normalise01(blades) * 0.55 + 0.35

    height = soil_weight * soil_height + green_hi * blades
    height = lib.normalise01(height, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    soil_variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=315, gain=0.55)
    foliage_variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=316, gain=0.55)
    smooth = soil_weight * (0.30 * (soil_height - soil_height.mean()) + 0.55 * soil_variation) \
            + green_hi * (0.5 + 0.15 * foliage_variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 11.0
    height = lib.band(height, 0.50)
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
