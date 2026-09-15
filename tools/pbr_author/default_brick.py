"""Hand authored LabPBR height and smoothness for default_brick.

The 16 px art carries seven grey shades in two clusters: a dark cluster,
0.256 to 0.367, and a light cluster, 0.451 to 0.573, separated by a gap
(0.084) wider than any step inside either cluster. The light cluster is
the mortar here, not the dark one: it sits in four full width rows (3, 7,
11, 15, each a joint between a 3 texel course of brick and the next,
wrapping cleanly) and in two or three light columns per course, offset
course to course, the running bond stagger of a real brick wall. The dark
cluster is the fired clay, its own shade varying brick to brick and streak
to streak the way a kiln never fires two bricks quite the same.
"""
import sys

import numpy as np

import lib

STEM = "default_brick"
CLS = "stone"


def label_bricks(mortar_mask):
    """Connected components of the texels that are not mortar, 4 connected
    and wrapped: a brick is whatever the mortar encloses. One wrinkle: a
    course (the band between one full mortar row and the next) that has
    only a single joint column running its whole body height cannot be
    split by that column alone, because one cut around a closed loop does
    not open it, it only leaves a slit. Such a course is also cut at the
    tile's own left and right seam, giving the two bricks the art actually
    draws instead of one slab with a joint that never reaches the edge. A
    course with two or more full height joints (every course this art
    draws has two or three) already separates properly under an ordinary
    wrapped flood fill, so this only ever changes behaviour where it has
    to."""
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
                                  # separates the two bricks either side
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

    mortar_mask = lum > 0.40
    print(f"mortar texels: {int(mortar_mask.sum())} of 256")
    print("mortar mask:")
    for r in range(16):
        print(r, "".join("#" if mortar_mask[r, c] else "." for c in range(16)))

    labels, n_bricks = label_bricks(mortar_mask)
    sizes = [int((labels == i).sum()) for i in range(n_bricks)]
    print(f"bricks found: {n_bricks}, sizes {sizes}")

    # Target height per brick: its own mean brightness sets how far it
    # rises above the joint floor, a lighter fired brick catching more
    # light than a darker one. Mortar sits near the groove floor. The
    # normalising range comes from the whole fired face, not from the
    # handful of brick means found here: two bricks a kiln fired almost
    # the same shade must stay almost the same height, and stretching
    # their tiny mean to mean gap across the full range (as normalising
    # against just the nine brick means would do) invents a difference
    # the art does not draw.
    brick_lum = np.array([lum[labels == i].mean() for i in range(n_bricks)])
    lo, hi = lum[~mortar_mask].min(), lum[~mortar_mask].max()
    brick_target = 0.55 + 0.35 * (brick_lum - lo) / max(hi - lo, 1e-6)
    target_dict = {-1: 0.08}
    for i in range(n_bricks):
        target_dict[i] = float(brick_target[i])

    # High res joint geometry straight from the mask: a nearest upscale is
    # exact, so a joint that runs the whole course height in the art still
    # runs the whole course height at 256 px and meets the mortar rows
    # above and below by construction, rather than by way of a warped
    # label lookup that can lose track of a joint only a texel wide.
    mortar_hi = np.repeat(np.repeat(mortar_mask, 16, axis=0), 16, axis=1)
    labels_hi = np.repeat(np.repeat(labels, 16, axis=0), 16, axis=1)

    max_dist = 4  # groove half width in 256 map texels, courses only 3 texels tall
    dist = lib.distance_to_edge(mortar_hi.astype(np.float32), max_dist=max_dist)
    # A little coherent wobble on the groove's own edge, not on which side
    # of it a texel is: it can widen or narrow the taper locally so the
    # joint looks hand struck rather than ruled, but a mortar texel is
    # always a mortar texel, so the joint can never pinch shut or drift
    # off the row it belongs to.
    wobble = lib.fbm(lib.SIZE, base_cells=40, octaves=2, seed=36) * 1.2
    dist = np.where(mortar_hi, 0.0, np.clip(dist + wobble, 0.0, max_dist))
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)  # smoothstep: flat brick tops, sharp fall to the joint

    target_map = np.zeros_like(labels_hi, dtype=np.float32)
    for lbl, val in target_dict.items():
        target_map[labels_hi == lbl] = val
    layout = target_map * t

    # Each brick a very slightly convex face: a low, brick sized bulge
    # rounds off the flat crown the taper alone leaves in the middle.
    crown = lib.fbm(lib.SIZE, base_cells=6, octaves=2, seed=32) * 0.05
    layout = layout + crown * t

    # Fine tooling marks from the mould and the kiln: short scratches, plus
    # sparser pores where the clay pitted as it fired.
    tooling = lib.fbm(lib.SIZE, base_cells=52, octaves=3, seed=33, gain=0.55) * 0.06
    pores = lib.blur(lib.white_noise(lib.SIZE, seed=34), 1) * 0.05
    height = lib.normalise01(layout + tooling + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the joint gathers dust and stays rough,
    # the fired face is what wears smooth. The brick's own patchy variation
    # rides on top; pack() moves the mean, the spread is ours.
    rough_noise = lib.fbm(lib.SIZE, base_cells=18, octaves=3, seed=35)
    smooth = 0.55 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # Nearest upscale keeps the brick and joint edges the height field was
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
