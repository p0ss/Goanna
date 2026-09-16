"""Hand authored height and smoothness for kythen_khmer_brick_stucco.

The 32 px art carries only two shades: a lighter one (0.406, 67 percent of
the texels) and a darker one (0.338, the rest). The lighter shade forms
full width rows every four rows (0, 4, 8, ... 28, wrapping cleanly) and
dominates everywhere else too; the darker shade never appears in those
rows at all, only scattered through the three body rows of each course,
16 to 66 percent of a course depending which one. That is stucco surviving
over a coursed brick wall: the joint between courses is always covered (a
joint is the first place render fails on a real wall, so if anything it
should be the last place a texture keeps its coat, but this art keeps it
uniformly covered, so the recess there is drawn as part of the wall, not
as bare brick), and the light shade elsewhere is intact render, with the
dark shade the patches where it has come away and the coursed brick shows
through.

lib.class_of reads "cloth" back from the bake, a level readback artefact
(brick and stucco are both mineral, and cloth's own level happens to be
nearest); this script overrides to "stone".

Two layers, per the brief: a coursed brick relief from the joint rows,
present everywhere the way the masonry is present everywhere under the
render, and a stucco layer sitting proud and flat over the top, fading out
at a patch's own edge so the brick relief shows through where it is bare.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_brick_stucco"
CLS = "stone"
SIZE = lib.SIZE
ART = 32
REP = SIZE // ART


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.4f} max {lum.max():.4f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 4).tolist())))

    stucco_mask = lum > 0.37  # the lighter, dominant shade
    joint_rows = np.array([r % 4 == 0 for r in range(ART)])
    print(f"stucco texels: {int(stucco_mask.sum())} of {ART * ART}, "
            f"joint rows {np.where(joint_rows)[0].tolist()}")
    print("stucco fraction per row:", np.round(stucco_mask.mean(axis=1), 2).tolist())

    # The coursed brick underneath, present everywhere: a groove at every
    # joint row, a flat course face between. Built from the joint rows the
    # same way mcl_core_sandstone_normal.py builds a stratum profile,
    # because there is no column joint in this reduced art to flood fill
    # bricks from, only the course band.
    mortar_hi = np.repeat(joint_rows, REP)[:, None] * np.ones((1, SIZE), dtype=bool)
    max_dist = 3  # narrow, steep sided groove, the joint band itself is REP wide
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    brick_relief = t

    # The stucco patch layer: nearest upscale of the mask keeps the patch
    # edges exactly where the art draws them (never warped: this is a
    # render peeling off a wall, a manufactured surface, not a natural
    # one). A patch is flat and proud in its middle, fading to the bare
    # brick level at its own boundary rather than stepping straight down.
    stucco_hi = np.repeat(np.repeat(stucco_mask, REP, axis=0), REP, axis=1)
    bound = lib.region_edges(stucco_hi.astype(int))
    dist_b = lib.distance_to_edge(bound, max_dist=6)
    taper = np.clip(dist_b / 6.0, 0.0, 1.0)
    taper = taper * taper * (3 - 2 * taper)
    # The render still follows the joint's own recess (t is 0 there): a
    # coat of stucco is thin enough to show the masonry under it, so its
    # own proud rise is damped near a joint even where the art draws it as
    # intact, rather than burying the groove under a dead flat patch.
    stucco_extra = np.where(stucco_hi, taper * t, 0.0)
    # A signed distance to the nearest stucco/bare boundary, positive
    # inside a patch and negative outside it, gives a blend factor that is
    # continuous straight through the boundary: np.where's hard 0/1 switch
    # tiles fine in the height above (it always fades to 0 at the boundary
    # from the stucco side and sits at 0 outside anyway) but broke the
    # smoothness map's own seam, since that field gave the two sides flatly
    # different levels with no taper between them at all.
    signed = np.where(stucco_hi, dist_b, -dist_b)
    blend = np.clip(signed / 6.0, -1.0, 1.0) * 0.5 + 0.5
    blend = blend * blend * (3 - 2 * blend)

    # Fine texture: coarser grain and pores on the bare brick, finer,
    # fainter texture on the render.
    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=751, gain=0.55)
    pores = lib.blur(lib.white_noise(SIZE, seed=752), 1)
    fine = blend * (0.25 * grain + 0.15 * pores) + (1 - blend) * (0.45 * grain + 0.30 * pores)
    # Damped right at the joint: a clean, deep groove floor rather than
    # noise filling in the very depth the groove needs for its own self
    # shadow, the grain living on the raised course faces instead.
    fine = fine * (0.25 + 0.75 * t)

    layout = 0.85 * brick_relief + 0.35 * stucco_extra + fine
    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: the render wears smoother than the bare fired brick it
    # covers, and both stay rough right at the joint, which never sheds
    # its dirt. blend carries the stucco/bare split continuously through
    # the patch boundary, the fix described above.
    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=753, gain=0.55)
    smooth = 0.30 + 0.25 * blend + 0.14 * (t - 0.5) + 0.30 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 16.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=ART)
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
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
