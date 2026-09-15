"""Shared build for the wood door family: mcl_doors_door_wood_lower,
mcl_doors_door_wood_upper, mcl_doors_door_wood_side_lower and
mcl_doors_door_wood_side_upper.

The front art (lower and upper) is a frame drawn in six grey shades: the
two outer columns are the stiles, flat and the second brightest shade; a
shadow column either side of them is the darkest shade, where the panel
meets the stile; the columns between are the panel field, its grain the
three middle shades, with the brightest shade a rare highlight (a knot).
mcl_doors_door_wood_upper cuts two round windows through the panel field
(alpha zero, merging into one wide gap across the middle rows); the frame
is otherwise the same drawing in the same shades, so both textures are
built from one shade to height mapping and one set of noise seeds, which
is what makes the two halves read as one door rather than two.

The side art is the door's edge: a three texel wide strip at the left in
the same shades as the stile and its shadow (the stile's own end grain,
seen from the side) and a flat field the rest of the way across, the
door's thin plank edge with no frame on it at all.
"""

import numpy as np

import lib

SIZE = lib.SIZE

# The art's own shading says what is proud and what is sunk (a pixel
# artist paints the bevel with light and dark), so height follows the
# shade directly rather than a layout invented here. Darkest to brightest,
# groove to highlight.
SHADE_HEIGHT = {
    0.191: 0.05, 0.223: 0.20, 0.258: 0.34, 0.312: 0.50, 0.38: 0.70, 0.447: 0.92,
}
HOLE_FLOOR = 0.04


def _shade_height_16(lum16):
    keys = sorted(SHADE_HEIGHT.keys())
    shades = np.array(keys, dtype=np.float32)
    heights = np.array([SHADE_HEIGHT[k] for k in keys], dtype=np.float32)
    idx = np.abs(lum16[..., None] - shades[None, None, :]).argmin(-1)
    return heights[idx]


def _layout(lum16, chamfer=0.6):
    base16 = _shade_height_16(lum16)
    base = lib.upscale(base16)
    # Unsharp blur across every step, the plank set's trick: both sides of
    # a step keep one matched slope instead of kinking at the crossing,
    # which also steepens the groove enough for real ambient occlusion.
    narrow = lib.blur(base, 1)
    wide = lib.blur(base, 2)
    return narrow + chamfer * (narrow - wide)


def _smoothness(layout01, seed):
    variation = lib.fbm(SIZE, base_cells=18, octaves=2, seed=seed, gain=0.5)
    return 0.55 * layout01 + 0.45 * (variation * 0.5 + 0.5)


def build_front(stem, out_dir, seed, normal_strength):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print("%s: shades %s" % (stem, sorted(set(np.round(lum[alpha > 0.5], 3).tolist()))))

    layout = _layout(lum)
    grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=seed, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=seed + 1), 1) * 0.02
    height = layout + grain + pores

    # The window is a real gap through the door: carved to the floor
    # regardless of what panel height would otherwise sit there, the cut
    # itself softened over a texel so it is an edge, not a single step.
    alpha_soft = lib.blur(lib.upscale(alpha), 1)
    height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.5, 99.5)

    smooth = _smoothness(lib.normalise01(layout), seed + 2)

    albedo = lib.upscale(src)  # keeps the window's alpha a real hole
    m = lib.pack(stem, out_dir, albedo, height, smooth, "wood",
            normal_strength=normal_strength)
    return m


def build_side(stem, out_dir, seed, normal_strength):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("%s: shades %s" % (stem, sorted(set(np.round(lum.ravel(), 3).tolist()))))

    layout = _layout(lum)
    # The side is mostly one flat plank face (thirteen of its sixteen
    # columns carry no shading at all), so the grain has to do more of the
    # work here than on the front: a stronger amplitude than the front's,
    # or the flat two thirds of the tile would sit dead level.
    grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=seed, gain=0.55) * 0.18
    pores = lib.blur(lib.white_noise(SIZE, seed=seed + 1), 1) * 0.08
    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)

    smooth = _smoothness(lib.normalise01(layout), seed + 2)

    albedo = lib.upscale(rgb)
    m = lib.pack(stem, out_dir, albedo, height, smooth, "wood",
            normal_strength=normal_strength)
    return m


def report(stem, m):
    lines = lib.check(m, "wood")
    print("\n".join(lines))
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    return lines
