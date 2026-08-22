#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Reduce a lighting chart run to docs/pbr-plan.md step 3's pass or fail lines.

    godot --path project lighting_chart.tscn   (with CHART_OUT=chart.json)
    tools/chart_summary.py chart.json [other.json]

With two files, every figure is printed side by side, which is how a change
to the environment or the shader is judged: as a number that moved, not as
an impression of a screenshot.

The thresholds are the ones written into step 3's "done when", made
numeric here so they can be argued with in one place.
"""
import json
import sys

# What step 3 asks for, as numbers.
SEPARABLE_GAP = 0.05     # sRGB distance between the two closest classes on the
                         # front face, over the stone top luma at that time,
                         # so a dim dawn is judged at its own exposure
SEPARABLE_TIMES = ("noon", "afternoon", "dawn")
SNOW_SD_KEEP = 0.35      # rendered luma sd over albedo sd, snow top. The
                         # complaint was 99 per cent pure white and no sd at
                         # all; at noon the ACES shoulder leaves snow about
                         # 0.4 of its contrast, and filmic gave 0.44 while
                         # taking stone from 1.0 to 0.78, so this is the bar
SNOW_CLIP_MAX = 0.25     # fraction of the snow top patch that clips
FRAME_CLIP_MAX = 0.10    # fraction of the frame below the horizon that clips
BAY_DARK_MAX = 0.35      # bay stone front over open stone top, noon
BLUE_CAST_MAX = 12.0     # b minus r on the open stone front, neutral albedo
BAY_CAST_MAX = 25.0      # b minus r on the bay stone top, lit by sky alone
VERTICAL_MIN = 0.30      # open stone front over open stone top, noon
NIGHT_MIN = 30.0         # open stone top luma at night: visible, near the
                         # vanilla client's 17.5 per cent of day
NIGHT_MAX = 95.0         # and not daylight
SKY_CHANNEL_MAX = 0.80   # dark over lit stone front, noon: the channel bites


def load(path):
    with open(path) as f:
        return json.load(f)


def cell(d, time, key, field):
    try:
        return d[time][key][field]
    except KeyError:
        return None


def luma(d, time, key):
    return cell(d, time, key, "luma")


def check(name, ok, detail):
    print("%-4s %-34s %s" % ("PASS" if ok else "FAIL", name, detail))
    return ok


def summarise(d):
    passed = 0
    total = 0
    for t in SEPARABLE_TIMES:
        sep = d.get(t, {}).get("open/separability")
        if sep is None:
            continue
        top_t = luma(d, t, "open/stone/top") or 1.0
        total += 1
        passed += check("classes told apart, %s" % t, sep["gap"] / top_t >= SEPARABLE_GAP,
                "closest front colour distance %.1f (%s) over stone top %.0f = %.3f, want >= %.2f" % (
                        sep["gap"], sep["pair"], top_t, sep["gap"] / top_t, SEPARABLE_GAP))
    for t in ("noon", "afternoon"):
        sd = cell(d, t, "open/snow/top", "sd")
        asd = cell(d, t, "open/snow/top", "albedo_sd")
        clip = cell(d, t, "open/snow/top", "clip")
        if sd is None:
            continue
        keep = sd / max(asd, 1e-6)
        total += 1
        passed += check("snow keeps its texture, %s" % t, keep >= SNOW_SD_KEEP and clip <= SNOW_CLIP_MAX,
                "sd ratio %.2f (want >= %.2f), clip %.2f (want <= %.2f)" % (keep, SNOW_SD_KEEP, clip, SNOW_CLIP_MAX))
    for t in d:
        fc = d[t].get("frame_clip")
        if fc is None:
            continue
        total += 1
        passed += check("clipping outside the sky, %s" % t, fc <= FRAME_CLIP_MAX,
                "%.1f%% of the frame below the horizon, want <= %.0f%%" % (fc * 100.0, FRAME_CLIP_MAX * 100.0))
    bay = luma(d, "noon", "bay/stone/front")
    top = luma(d, "noon", "open/stone/top")
    front = luma(d, "noon", "open/stone/front")
    if bay is not None and top:
        total += 1
        passed += check("roofed bay dark, noon", bay / top <= BAY_DARK_MAX,
                "bay front %.0f over open top %.0f = %.2f, want <= %.2f" % (bay, top, bay / top, BAY_DARK_MAX))
    if front is not None and top:
        total += 1
        passed += check("verticals lit, noon", front / top >= VERTICAL_MIN,
                "front %.0f over top %.0f = %.2f, want >= %.2f" % (front, top, front / top, VERTICAL_MIN))
        rgb = cell(d, "noon", "open/stone/front", "rgb")
        cast = rgb[2] - rgb[0]
        total += 1
        passed += check("verticals not blue, noon", cast <= BLUE_CAST_MAX,
                "stone front %d,%d,%d, b minus r %.0f, want <= %.0f" % (rgb[0], rgb[1], rgb[2], cast, BLUE_CAST_MAX))
    brgb = cell(d, "noon", "bay/stone/top", "rgb")
    if brgb is not None:
        total += 1
        passed += check("bay not blue, noon", brgb[2] - brgb[0] <= BAY_CAST_MAX,
                "bay stone top %d,%d,%d, b minus r %.0f, want <= %.0f" % (brgb[0], brgb[1], brgb[2], brgb[2] - brgb[0], BAY_CAST_MAX))
    night = luma(d, "night", "open/stone/top")
    if night is not None:
        total += 1
        passed += check("night visible, not day", NIGHT_MIN <= night <= NIGHT_MAX,
                "stone top %.0f, want %.0f to %.0f" % (night, NIGHT_MIN, NIGHT_MAX))
    dark = luma(d, "noon", "dark/stone/front")
    if dark is not None and front:
        total += 1
        passed += check("sky light channel bites, noon", dark / front <= SKY_CHANNEL_MAX,
                "sky 0 front %.0f over sky 255 front %.0f = %.2f, want <= %.2f" % (dark, front, dark / front, SKY_CHANNEL_MAX))
    print("%d of %d" % (passed, total))
    return passed, total


def compare(a, b):
    keys = []
    for t in a:
        for k in a[t]:
            if isinstance(a[t][k], dict) and "luma" in a[t][k]:
                keys.append((t, k))
    print("%-28s %8s %8s %8s" % ("cell", "a luma", "b luma", "change"))
    for t, k in keys:
        la = a[t][k]["luma"]
        lb = b.get(t, {}).get(k, {}).get("luma")
        if lb is None:
            continue
        print("%-28s %8.0f %8.0f %+8.0f" % ("%s %s" % (t, k), la, lb, lb - la))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    a = load(argv[1])
    print("== %s" % argv[1])
    summarise(a)
    if len(argv) > 2:
        b = load(argv[2])
        print("== %s" % argv[2])
        summarise(b)
        print("== change, a to b")
        compare(a, b)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
