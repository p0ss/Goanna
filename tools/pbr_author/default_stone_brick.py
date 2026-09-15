"""Hand authored LabPBR height and smoothness for default_stone_brick.

The 16 px art carries eight grey shades. The two darkest, 0.339 and 0.379,
appear nowhere except two full width rows (7 and 15, wrapping cleanly: row
15 is a joint and row 0 goes straight back to block colour) and two
vertical strips (column 7 for rows 8 to 14, column 15 for rows 0 to 3
only). Everywhere else those two shades never occur. That is the mortar:
two courses, each seven texels of block plus one mortar row, the lower
course split into two blocks by its column 7 joint, the upper course a
single wide block whose column 15 joint only shows for its top four rows,
the rest of that edge healing back to block colour. The art draws it that
way, not as a slip: an upper course of one big flagstone, a lower course
of two normal blocks, a real running bond stagger.
"""
import sys

import numpy as np

import lib

STEM = "default_stone_brick"
CLS = "stone"


def label_blocks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped: a block is whatever the mortar encloses. The lower course
    here has only one joint column (7) running its whole body height, and
    one cut around a closed loop does not open it: flood filled and
    wrapped as normal, columns 0 to 6 and 8 to 15 stay joined by going the
    long way round through the tile seam, leaving what should be two
    blocks reading as a single slab with a slit down the middle instead of
    a joint. Where a course has exactly one such full height column, this
    also cuts the flood fill at the tile's own left and right seam, giving
    the two blocks the art's own docstring describes. The upper course has
    no full height column at all (it is genuinely one wide flagstone) so
    this never touches it, and a course with two or more columns already
    separates correctly without any of this."""
    h, w = mortar_mask.shape
    full_rows = [r for r in range(h) if mortar_mask[r].all()]
    seam_cut_rows = set()
    if full_rows:
        fr = sorted(full_rows)
        for i in range(len(fr)):
            r0, r1 = fr[i], fr[(i + 1) % len(fr)]
            body = []
            r = (r0 + 1) % h
            while r != r1:
                body.append(r)
                r = (r + 1) % h
            if not body:
                continue
            full_cols = [c for c in range(w) if all(mortar_mask[r, c] for r in body)]
            if len(full_cols) == 1:
                seam_cut_rows.update(body)

    labels = np.full((h, w), -1, dtype=int)
    next_id = 0
    for y in range(h):
        for x in range(w):
            if mortar_mask[y, x] or labels[y, x] >= 0:
                continue
            stack = [(y, x)]
            labels[y, x] = next_id
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = (cy + dy) % h, (cx + dx) % w
                    if dy == 0 and cy in seam_cut_rows and abs(nx - cx) != 1:
                        continue  # this course's one joint needs the tile
                                  # seam as its second cut, or it never
                                  # separates the two blocks either side
                    if mortar_mask[ny, nx] or labels[ny, nx] >= 0:
                        continue
                    labels[ny, nx] = next_id
                    stack.append((ny, nx))
            next_id += 1
    return labels, next_id


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))

    mortar_mask = lum <= 0.40
    print(f"mortar texels: {int(mortar_mask.sum())} of 256")
    print("mortar mask:")
    for r in range(16):
        print(r, "".join("#" if mortar_mask[r, c] else "." for c in range(16)))

    labels, n_blocks = label_blocks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_blocks)]
    print(f"blocks found: {n_blocks}, sizes {sizes}")

    # Target height per block: the block's own mean brightness sets how far
    # it rises above the joint floor, the way a lighter block in the art
    # catches more of the light. Mortar sits near the groove floor. The
    # normalising range comes from the whole dressed face, not from the
    # two or three block means found here: the seam cut above can split a
    # course into two blocks whose means differ by a whisker, and
    # stretching that whisker across the full range would invent a height
    # step the art never drew, sitting right at the tile's own seam where
    # there is no groove to carry it.
    block_lum = np.array([lum[labels == i].mean() for i in range(n_blocks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    block_target = 0.55 + 0.35 * (block_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_blocks):
        target_dict[i] = float(block_target[i])

    # High res joint geometry straight from the mask: a nearest upscale is
    # exact, so the column 7 joint (or any other) still runs the whole
    # course height at 256 px and meets the mortar rows above and below by
    # construction, rather than by way of a warped label lookup.
    mortar_hi = np.repeat(np.repeat(mortar_mask, 16, axis=0), 16, axis=1)
    labels_hi = np.repeat(np.repeat(labels, 16, axis=0), 16, axis=1)

    max_dist = 5  # groove half width in 256 map texels, a real mortar joint
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    # A little coherent wobble on the groove's own edge, not on which side
    # of it a texel is: the taper can widen or narrow locally so the joint
    # looks dressed by hand, but a mortar texel stays a mortar texel, so
    # the joint can never pinch shut or drift off the row it belongs to.
    wobble = lib.fbm(lib.SIZE, base_cells=36, octaves=2, seed=26) * 1.3
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: broad flat block tops, sharp fall to the joint

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # Each block a very slightly convex face: a wide, low bulge rounds off
    # the flat crown the taper alone would leave in the middle of a block,
    # the biggest of which (the upper course) is most of the tile wide.
    crown = lib.fbm(lib.SIZE, base_cells=4, octaves=2, seed=22) * 0.05
    layout = layout + crown * t

    # Fine tooling marks: short, dense scratches from dressing the face,
    # plus sparser pores where the stone has pitted a little.
    tooling = lib.fbm(lib.SIZE, base_cells=48, octaves=3, seed=23, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=24), 1) * 0.05
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the joint gathers dust and stays rough,
    # the dressed block faces are what wears smooth. The stone's own patchy
    # variation rides on top; pack() moves the mean, the spread is ours.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=25)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the block and joint edges the height field was
    # built to line up with.
    albedo = lib.upscale(src[..., :3])

    normal_strength = 40
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
