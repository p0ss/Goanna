#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check a screenshot taken with the proof shader pack loaded.

The proof pack at project/tests/shaderpacks/proof paints marks that are easy
to measure: a magenta band across the bottom 4 per cent of the frame, the
composite pass's luma target (pure grey) on the right third, its inverted
scene on the middle third, and a 48 px noise square along the top edge. This
script measures each of those and prints one PASS or FAIL line per check.

Usage: shaderpack_check.py [--json] shot.png
"""

from __future__ import annotations

import argparse
import json
import sys

import numpy as np
from PIL import Image


# Mirrors PROOF_BAND in the pack's lib/common.glsl.
BAND = 0.04
# The three small squares in final.fsh are 48 px tall, starting at the top.
SQUARE = 48
NOISE_X0, NOISE_X1 = 112, 160


def chroma(px: np.ndarray) -> np.ndarray:
    """Per pixel max minus min over RGB, 0 for a grey, 255 for a pure hue."""
    return px.max(axis=-1) - px.min(axis=-1)


def measure(path: str) -> dict:
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    h, w, _ = img.shape
    band_y0 = int(round(h * (1.0 - BAND)))
    # Skip a few rows each side of the band edge and of the top squares so the
    # measurements do not straddle a boundary.
    pad = 4
    body = img[SQUARE + pad : band_y0 - pad]
    band = img[band_y0 + pad :]
    third = w / 3.0
    right = body[:, int(2 * third) + pad :]
    middle = body[:, int(third) + pad : int(2 * third) - pad]
    noise = img[:SQUARE, NOISE_X0:NOISE_X1]
    band_mean = band.reshape(-1, 3).mean(axis=0)
    magenta_pixels = (
        (band[..., 0] > 200) & (band[..., 1] < 55) & (band[..., 2] > 200)
    )
    return {
        "width": w,
        "height": h,
        "band_mean_rgb": [round(float(v), 2) for v in band_mean],
        "band_magenta_fraction": round(float(magenta_pixels.mean()), 4),
        "right_chroma_mean": round(float(chroma(right).mean()), 3),
        "right_chroma_p99": round(float(np.percentile(chroma(right), 99)), 3),
        "middle_chroma_mean": round(float(chroma(middle).mean()), 3),
        "noise_std": round(float(noise.reshape(-1, 3).std(axis=0).mean()), 3),
        "frame_std": round(float(img.reshape(-1, 3).std(axis=0).mean()), 3),
    }


def checks(m: dict) -> list[tuple[str, bool, str]]:
    """Each entry is (name, passed, detail). Thresholds are deliberately
    loose: the frame is a real scene, not a synthetic image, so the test
    looks for the pack's marks rather than exact values."""
    band_ok = m["band_magenta_fraction"] > 0.95
    right_ok = m["right_chroma_mean"] < 4.0 and m["right_chroma_p99"] < 12.0
    middle_ok = m["middle_chroma_mean"] > 10.0
    noise_ok = m["noise_std"] > 40.0
    frame_ok = m["frame_std"] > 8.0
    return [
        (
            "bottom band is magenta",
            band_ok,
            f"{m['band_magenta_fraction'] * 100:.1f}% of pixels magenta, "
            f"mean rgb {m['band_mean_rgb']}",
        ),
        (
            "right third is grey (colortex1 luma)",
            right_ok,
            f"chroma mean {m['right_chroma_mean']}, p99 {m['right_chroma_p99']}",
        ),
        (
            "middle third is not grey (colortex2 inverted)",
            middle_ok,
            f"chroma mean {m['middle_chroma_mean']}",
        ),
        (
            "noise square is noisy (noisetex)",
            noise_ok,
            f"std {m['noise_std']}",
        ),
        (
            "frame is not one flat colour",
            frame_ok,
            f"std {m['frame_std']}",
        ),
    ]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("shot", help="PNG written by Goanna with the proof pack")
    ap.add_argument("--json", action="store_true", help="dump the measurements")
    args = ap.parse_args()

    m = measure(args.shot)
    if m["width"] < NOISE_X1 or m["height"] < 2 * SQUARE:
        print(f"shaderpack check: FAIL: frame {m['width']}x{m['height']} too small")
        return 1
    if args.json:
        print(json.dumps(m, indent=2))

    failed = 0
    for name, ok, detail in checks(m):
        print(f"shaderpack check: {'PASS' if ok else 'FAIL'}: {name} ({detail})")
        failed += 0 if ok else 1
    if failed:
        sys.stdout.flush()
        print(f"shaderpack check: {failed} check(s) failed on {args.shot}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
