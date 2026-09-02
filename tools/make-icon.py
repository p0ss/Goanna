#!/usr/bin/env python3
"""Draw project/icon.svg: a goanna built out of isometric voxels.

The projection is the one Luanti's own icon uses, a 2:1 isometric where a cube
reads as three rhombi, so the two sit together in a launcher. Everything here
is generated from the voxel list in `goanna()` rather than written as path
data, because the only way to shape a voxel model is to move blocks around and
look at it again, and hand-edited path data cannot be moved around.

    tools/make-icon.py            # writes project/icon.svg
    tools/make-icon.py --png out.png   # also rasterises, needs ImageMagick

Faces are shaded by orientation, not by light position: top full strength,
left three quarters, right half. That is what makes a stack of one colour read
as separate blocks, and it is why the palette below only names one colour per
material.
"""

import argparse
import os
import subprocess
import sys

# Half width and quarter height of a tile, then the height of a cube's side.
# HW = 2 * HH is what makes it 2:1 isometric; VH equal to HW keeps a cube
# looking like a cube rather than a slab.
HW, HH, VH = 18.0, 9.0, 18.0

# One colour per material; the faces are derived from it.
PALETTE = {
    "hide": "#7d8f45",       # olive back and tail, the goanna's ground colour
    "band": "#efdc8d",       # the cream banding a lace monitor carries
    # Feet only a shade under the hide: a dark foot vanishes into the
    # background at 32 px and the animal loses its legs.
    "claw": "#5d6b33",
    "eye": "#15170f",
}

# Where the eyes are painted, as (x, y, z) of the top face they sit on.
EYES = ((5, 6, 1), (6, 5, 1))

OUTLINE = "#191b16"
# Near neutral and dark, so an olive animal has something to be olive against;
# an olive ground made the whole icon one colour at small sizes.
BACKGROUND = "#22241e"
BORDER = "#171a14"


def shade(hex_colour, factor):
    hex_colour = hex_colour.lstrip("#")
    rgb = [int(hex_colour[i:i + 2], 16) for i in (0, 2, 4)]
    return "#%02x%02x%02x" % tuple(min(255, int(c * factor)) for c in rgb)


def project(x, y, z):
    """Voxel centre to screen. z is up; +x goes down-right, +y down-left."""
    return ((x - y) * HW, (x + y) * HH - z * VH)


def cube(x, y, z, colour):
    """The three visible faces of one cube, back to front."""
    px, py = project(x, y, z)
    top = [(px, py - HH), (px + HW, py), (px, py + HH), (px - HW, py)]
    left = [(px - HW, py), (px, py + HH), (px, py + HH + VH), (px - HW, py + VH)]
    right = [(px + HW, py), (px, py + HH), (px, py + HH + VH), (px + HW, py + VH)]
    faces = (
        (left, shade(colour, 0.74)),
        (right, shade(colour, 0.52)),
        (top, colour),
    )
    out = []
    for points, fill in faces:
        d = " ".join("%.2f,%.2f" % p for p in points)
        out.append('<polygon points="%s" fill="%s"/>' % (d, fill))
    return out


def eye_dot(x, y, z, size=0.30):
    """A small dark rhombus on a cube's top face.

    An eye has to be smaller than a block. Drafted as a whole dark voxel it
    dominated the head and the animal read as a skull, so the eye is painted on
    the face it belongs to instead, at the same isometric angle as everything
    else so it sits flat on the skull rather than floating over it.
    """
    px, py = project(x, y, z)
    pts = [(px, py - HH * size), (px + HW * size, py),
           (px, py + HH * size), (px - HW * size, py)]
    d = " ".join("%.2f,%.2f" % q for q in pts)
    return '<polygon points="%s" fill="%s" stroke="none"/>' % (d, PALETTE["eye"])


def goanna():
    """The model, as (x, y, z, material).

    Two decisions here are worth keeping, because the drafts that ignored them
    read as a caterpillar rather than a lizard.

    The pose is from above: body, four splayed legs, long tail. That is the
    silhouette a lizard is recognised by. A side-on animal at this size is a
    sausage with bumps.

    The body runs along the grid diagonal (1, 1), which in this projection
    points straight down the screen, and the legs run along (1, -1), which
    points across it. A body laid along a single grid axis is drawn twice as
    wide as it is tall, so it can only ever be a thin band across a square
    icon; on the diagonal it fills the square and the blocks come out twice
    the size.
    """
    v = []

    def put(x, y, z, m):
        v.append((x, y, z, m))

    # Body, two wide, running down the screen. t is distance along the spine.
    for t in range(0, 5):
        m = "band" if t % 2 else "hide"
        put(t, t, 1, m)
        put(t + 1, t, 1, m)

    # Head: a full two by two block, wider than the neck it sits on, with a
    # snout beyond it. A head the same width as the body is just more body.
    for hx, hy in ((5, 5), (6, 5), (5, 6), (6, 6)):
        put(hx, hy, 1, "hide")
    put(6, 7, 1, "hide")
    # (the eyes are painted on, see EYES below)

    # Tail: continues the spine, then curves off and drops to a single block.
    # Banding runs so the tip lands on olive, not cream: a bright block at the
    # very end of the tail is the first thing the eye goes to, and it should be
    # going to the head.
    for i, (x, y) in enumerate([(-1, -1), (-2, -2), (-2, -3), (-3, -4)]):
        put(x, y, 1, "hide" if i % 2 else "band")

    # Legs, two blocks each, splayed along (1, -1) and (-1, 1) so all four are
    # clear of the body instead of hiding behind it.
    for (bx, by), (dx, dy) in (
            ((4, 4), (1, -1)), ((4, 4), (-1, 1)),   # front pair, at the shoulders
            ((1, 1), (1, -1)), ((1, 1), (-1, 1))):  # back pair, at the hips
        put(bx + dx, by + dy, 1, "hide")
        put(bx + 2 * dx, by + 2 * dy, 1, "claw")
    return v


def render(voxels, size=512):
    # Back to front: larger x + y + z is nearer the camera.
    voxels = sorted(voxels, key=lambda v: (v[0] + v[1] + v[2]))
    body = []
    for x, y, z, material in voxels:
        body.extend(cube(x, y, z, PALETTE[material]))
    # After the blocks, so they land on the skull rather than under it.
    for ex, ey, ez in EYES:
        body.append(eye_dot(ex, ey, ez))

    # Fit the drawing to the canvas rather than guessing a transform: the model
    # changes shape every time a block moves, and a hand-set scale goes stale.
    xs, ys = [], []
    for x, y, z, _ in voxels:
        px, py = project(x, y, z)
        xs += [px - HW, px + HW]
        ys += [py - HH, py + HH + VH]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    pad = size * 0.055
    scale = min((size - 2 * pad) / w, (size - 2 * pad) / h)
    tx = (size - w * scale) / 2 - min(xs) * scale
    ty = (size - h * scale) / 2 - min(ys) * scale

    r = size * 0.18
    return """<svg xmlns="http://www.w3.org/2000/svg" width="{s}" height="{s}" viewBox="0 0 {s} {s}">
  <rect x="0" y="0" width="{s}" height="{s}" rx="{r:.1f}" ry="{r:.1f}" fill="{bg}"/>
  <g transform="translate({tx:.2f},{ty:.2f}) scale({sc:.4f})"
     stroke="{ol}" stroke-width="{sw:.2f}" stroke-linejoin="round">
    {body}
  </g>
  <rect x="{hb:.1f}" y="{hb:.1f}" width="{iw:.1f}" height="{iw:.1f}" rx="{r:.1f}" ry="{r:.1f}"
        fill="none" stroke="{bd}" stroke-width="{bw:.1f}"/>
</svg>
""".format(s=size, r=r, bg=BACKGROUND, tx=tx, ty=ty, sc=scale, ol=OUTLINE,
           sw=1.6 / scale, body="\n    ".join(body), bd=BORDER,
           bw=size * 0.035, hb=size * 0.0175, iw=size - size * 0.035)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None, help="SVG path (default project/icon.svg)")
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--png", default="", help="also rasterise here, needs ImageMagick")
    args = ap.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(repo, "project", "icon.svg")
    svg = render(goanna(), args.size)
    with open(out, "w") as f:
        f.write(svg)
    print("wrote %s" % out)
    if args.png:
        subprocess.run(["magick", "-background", "none", out, args.png], check=True)
        print("wrote %s" % args.png)
    return 0


if __name__ == "__main__":
    sys.exit(main())
