"""Hand authored height and smoothness for kythen_moana_turtle_pen.

Column mean and row mean carry the identical signature, period four
texels, matching each other and matching kythen_moana_sennit.py's own
weave profile in shape (a dark cell edge climbing to a bright crest), but
at a much lower, wood toned luminance (0.14 to 0.28, against sennit's
fibre toned 0.32 to 0.55) and with column std and row std both climbing
the same way through each cell (0.035 to 0.065), real texture built into
the cell, not flat colour. A turtle pen is a stake wall in a Pacific
building tradition, timber posts lashed together with sennit cord rather
than a European dressed stone wall, and the art's own symmetric grid reads
naturally as exactly that: round stakes standing side by side (the column
profile, each stake's own rounded, lit face between the dark gaps where
one post meets the next) cinched by a horizontal lashing band at
intervals down the wall (the row profile, read as a rope wound around the
stakes and pulled tight, not as a second weave direction), rather than the
flat over-under basket plait the same period-four signature builds
elsewhere in this set.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_turtle_pen"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "wood"
SIZE = lib.SIZE
ART = 32
PERIOD = 4


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def cell_profile(means):
    cells = means.reshape(-1, PERIOD)
    profile = cells.mean(axis=0)
    lo, hi = profile.min(), profile.max()
    return (profile - lo) / max(hi - lo, 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("column mean lum:", np.round(col_mean, 3).tolist())
    print("row mean lum:", np.round(row_mean, 3).tolist())
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} (lashed timber stake wall)")

    stake_profile = cell_profile(col_mean)
    lash_profile = cell_profile(row_mean)
    print("stake cross section profile (gap to crest):", np.round(stake_profile, 3).tolist())
    print("lashing profile (gap to crest):", np.round(lash_profile, 3).tolist())

    stake_1d = np.tile(stake_profile, ART // PERIOD)
    lash_1d = np.tile(lash_profile, ART // PERIOD)
    stake_hi = np.repeat(stake_1d, SIZE // ART)
    lash_hi = np.repeat(lash_1d, SIZE // ART)

    # A wide blur, not the weave family's radius two: this period is half
    # theirs (four texels of art instead of eight), and the plank scripts
    # in this same set found that a narrow, near stepped transition here
    # reads as a periodic feature landing on the tile edge, diluted
    # against a mostly flat inner average, and fails the seam measure even
    # though the wall genuinely tiles (see docs/pbr-authoring-playbook.md's
    # note on this).
    stake_raw = np.broadcast_to(stake_hi[None, :], (SIZE, SIZE)).astype(np.float32)
    stake = lib.blur(stake_raw, 4)
    lash_raw = np.broadcast_to(lash_hi[:, None], (SIZE, SIZE)).astype(np.float32)
    lash = lib.blur(lash_raw, 4)

    # A narrow V riding on the wide taper, height only, the same device as
    # kythen_moana_hardwood.py's own saw kerf: ao_from_height's short
    # radius needs real local steepness at the gap between stakes and at
    # the lashing groove, which the wide blur above traded away to fix the
    # seam measure. A blur of blur difference only gave a faint bump once
    # pack()'s own fine_detail damping took most of it back out; a linear
    # distance based V survives that far better.
    period_map = PERIOD * (SIZE // ART)
    centre_map = SIZE // ART / 2.0
    kerf_half_width = 1.5
    x = np.arange(SIZE, dtype=np.float32)
    dist_x = np.minimum((x - centre_map) % period_map, (-(x - centre_map)) % period_map)
    stake_kerf = np.broadcast_to(np.clip(1.0 - dist_x / kerf_half_width, 0.0, 1.0)[None, :], (SIZE, SIZE))
    y = np.arange(SIZE, dtype=np.float32)
    dist_y = np.minimum((y - centre_map) % period_map, (-(y - centre_map)) % period_map)
    lash_kerf = np.broadcast_to(np.clip(1.0 - dist_y / kerf_half_width, 0.0, 1.0)[:, None], (SIZE, SIZE))

    # Vertical wood grain the length of each stake.
    grain = blur_axis(lib.fbm(SIZE, base_cells=26, octaves=3, seed=2701, gain=0.55), 8, 0) * 0.20
    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=2702), 1), 4, 0) * 0.05

    # The lashing cinches the stakes rather than adding a second weave
    # direction: a shallow groove where the cord bites in, at its
    # strongest right on a stake's own crest (where the cord has more
    # timber to press against) and negligible in the gap between stakes
    # (there is no stake there to cinch).
    lash_dip = (1.0 - lash) * (0.35 + 0.65 * stake) * 0.32

    base = 0.62 * stake - lash_dip + grain + pores
    raw = base - 1.20 * stake_kerf - 1.20 * lash_kerf
    height = lib.normalise01(raw, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness stays off the wide, unkerfed base: the kerf above is a
    # height only device for ao_from_height's short radius, and feeding
    # its own sharper edge into smoothness reopened the same seam problem
    # the wide blur was there to fix.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=20, octaves=3, seed=2703, gain=0.55), radius=6, axis=0)
    smooth = 0.5 + 0.16 * zscore(base) + 0.10 * zscore(directional_rough)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 7.5
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
