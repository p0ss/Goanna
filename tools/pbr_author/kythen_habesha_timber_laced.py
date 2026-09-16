"""Hand authored LabPBR height and smoothness for kythen_habesha_timber_laced,
Aksumite style masonry: horizontal timber bands laced through a stone wall.

The 32 px art reads cleanly. Row means show rows 0, 8, 16 and 24 sitting at
luminance 0.238 with every other row between 0.44 and 0.58; those four full
width rows are one uniform colour, (0.302, 0.227, 0.149), a warm brown
distinct from every stone shade in the tile (checked directly: no panel
texel anywhere in the tile falls below 0.396, well clear of the timber's
0.238). Reading columns inside each of the four eight row bands the same
way turns up more of that exact timber colour running the full height of
each band: columns 0, 8, 16, 24 in bands 1 and 3 (rows 1 to 7 and 17 to
23), columns 4, 12, 20, 28 in bands 2 and 4 (rows 9 to 15 and 25 to 31), a
stagger of half a panel width between bands. So the timber is not only
horizontal bands, as first guessed: it is a full lattice, horizontal
courses and vertical posts both, laced through the wall with a running
bond stagger, the way Aksumite masonry actually ties timber through a
stone face. A single luminance threshold (lum < 0.30) picks out all 240
timber texels cleanly, with nothing else in the tile close to that shade.

Flood filling what is left gives sixteen panels of 49 texels each, every
one fully enclosed by timber on all four sides (no panel touches another
panel, and no panel touches the timber shade either: verified directly,
the darkest texel in any panel is 0.396), so this needs none of
default_stone_brick.py's seam cutting for a course with only one joint
column. Panel means run 0.451 to 0.564, a real if modest spread, carried
into each panel's own flat target level; within a panel the texels
themselves range wider still (0.396 to 0.577), which is ordinary stone
mottle, not timber bleeding into the panel (that range sits entirely
above the timber shade with a clear gap), left to the shared, unmasked
fine grain the way default_stone_brick.py treats a block's own texture
rather than read as a second material to blend per panel.

Timber sits on a slightly higher flat plateau (proud, as an actual timber
lacing would be), stone panels flat at their own level, both held nearly
flat: amp 0 on the layout, no lib.warp_labels, this is dressed masonry and
the known failure here is domes where the art wants flat faces and a thin
proud step. The mask boundary itself, via lib.distance_to_edge, is both
the timber's proud step and the panel to panel joint at once, since every
panel edge is a timber edge.

A first pass with a narrow, unwobbled ramp (max_dist 3) hit tilt and ao
easily but failed the wrap seam (seam_n up to 2.15): the ramp from panel
level up to the timber plateau is a real ~0.35 to 0.4 magnitude step, and
squeezed into three texels every row-to-row difference inside that ramp
became far steeper than the tile's average, so whichever transition
happened to land on the wrap read as an outlier against that diluted
average, the same effect default_stone_brick.py's own joints would hit if
its blocks differed by this much over so narrow a ramp. Widening the ramp
alone traded tilt and ao away before the seam cleared. What actually
fixes it is the same wobble default_stone_brick.py already gives its own
joint, a little coherent noise on the distance field so the steepest part
of the ramp does not land on the same row for every column at once: with
a wider ramp (max_dist 6) and that wobble, the steep part of the
transition spreads across more of the tile's rows instead of concentrating
in two or three, which is what the seam measure actually penalises.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_timber_laced"


def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def flood_fill_panels(mask):
    """Connected components of the non-timber texels, 4 connected and
    wrapped: a panel is whatever the timber lattice encloses. Every panel
    here is bordered by timber on all four sides (checked below), so this
    needs none of default_stone_brick.py's extra seam cut for a course
    with a single full height joint column."""
    h, w = mask.shape
    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    uniq = sorted(set(np.round(lum.ravel(), 3).tolist()))
    print("unique shades:", uniq)
    cls = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls}")

    for tol in (0.03, 0.06, 0.1):
        seg_labels, n = lib.segments(rgb, tolerance=tol)
        sizes = sorted([int((seg_labels == i).sum()) for i in range(n)], reverse=True)
        print(f"lib.segments tolerance {tol}: {n} regions, sizes {sizes[:10]}"
              f"{' ...' if len(sizes) > 10 else ''}")

    timber_mask = lum < 0.30
    print(f"timber texels: {int(timber_mask.sum())} of {timber_mask.size}")
    full_rows = [r for r in range(32) if timber_mask[r].all()]
    print("full timber rows:", full_rows)

    labels, n_panels = flood_fill_panels(timber_mask)
    sizes = [int((labels == i).sum()) for i in range(n_panels)]
    print(f"panels found: {n_panels}, sizes {sizes}")
    panel_lum = np.array([lum[labels == i].mean() for i in range(n_panels)])
    panel_min = np.array([lum[labels == i].min() for i in range(n_panels)])
    print("panel lum means:", np.round(panel_lum, 3))
    print("panel lum minimums (checking none reach the timber shade 0.238):",
          np.round(panel_min, 3))

    touches_other = False
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb = np.roll(labels, (dy, dx), axis=(0, 1))
        nb_timber = np.roll(timber_mask, (dy, dx), axis=(0, 1))
        mismatch = (labels >= 0) & (~nb_timber) & (nb != labels)
        if mismatch.any():
            touches_other = True
    print(f"any panel touching another panel directly: {touches_other}")

    scale = lib.SIZE // src.shape[0]
    timber_hi = np.repeat(np.repeat(timber_mask, scale, axis=0), scale, axis=1)
    labels_hi = np.repeat(np.repeat(labels, scale, axis=0), scale, axis=1)

    lo, hi = panel_lum.min(), panel_lum.max()
    panel_share = (panel_lum - lo) / max(hi - lo, 1e-6)
    panel_target = 0.42 + 0.10 * panel_share
    timber_target = 0.82

    # labels_hi carries -1 on every timber texel (flood_fill_panels never
    # labels a masked texel), so indexing panel_target with it directly
    # would silently read panel_target's last entry there. Only read it
    # where a texel actually belongs to a panel.
    safe_labels_hi = np.where(labels_hi < 0, 0, labels_hi)
    panel_base = panel_target[safe_labels_hi]

    # The mask boundary is both the timber's proud step and the only
    # joint a panel has, since every panel edge is a timber edge (checked
    # above). A little coherent wobble on the distance field, the same
    # trick default_stone_brick.py uses on its own joint, so the ramp's
    # steepest point does not land on the same row for every column: see
    # the module docstring for why that is what actually clears the wrap
    # seam here, not a narrower or wider ramp on its own.
    edge = lib.region_edges(timber_hi.astype(int))
    max_dist = 5
    dist0 = lib.distance_to_edge(edge, max_dist=max_dist)
    wobble = lib.fbm(lib.SIZE, base_cells=48, octaves=2, seed=59) * 2.2
    dist = np.where(timber_hi, 0.0, np.clip(dist0 + wobble, 0.0, max_dist))
    t = smoothstep(dist / max_dist)
    panel_layer = panel_base + (timber_target - panel_base) * (1 - t)
    layout = np.where(timber_hi, timber_target, panel_layer)

    # A very small crown, the same low crown trick default_stone_brick.py
    # uses for a dressed face that should read as very slightly convex,
    # not flat as a sheet of paper, on both the panels and the timber.
    crown = lib.fbm(lib.SIZE, base_cells=4, octaves=2, seed=51) * 0.03
    layout = layout + crown

    # Fine tooling and pitting, unmasked across the whole face the way
    # default_stone_brick.py applies its own: this is also where each
    # panel's real internal mottle (0.40 to 0.58 within one panel) and
    # the timber's own worked finish both show up, at texel scale, rather
    # than a second target level switched in per material, which is what
    # introduced the seam problem in an earlier pass (two independent
    # noise fields meeting at the mask boundary on top of the layout's
    # own ramp, doubling up the discontinuity the wobble above already
    # has to absorb).
    tooling = lib.fbm(lib.SIZE, base_cells=44, octaves=3, seed=52, gain=0.55) * 0.03
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=53), 1) * 0.025

    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the proud timber wears smoother, the
    # stone panels keep a matt, worked finish with the art's own patchy
    # variation riding on top.
    rough_noise = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=56)
    smooth = 0.5 * height + 0.45 * rough_noise
    smooth = np.where(timber_hi, smooth + 0.05, smooth)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 30
    m = lib.pack(STEM, out_dir, albedo, height, smooth, "stone",
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, "stone")
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
