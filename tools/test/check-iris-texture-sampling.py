#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check the four custom-texture sampler modes in the authored GPU proof."""

import argparse
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('frame')
args = parser.parse_args()
with Image.open(args.frame) as source:
    image = source.convert('RGB')
    w, h = image.size
    samples = [image.getpixel((int(x * w), int(y * h)))
               for x, y in ((.25, .25), (.75, .25), (.25, .75), (.75, .75))]
expected = {(128, 0, 255), (255, 0, 255), (128, 255, 0), (255, 255, 0)}
# The final colour handoff may quantise 0.5 down to 127. Screen-space Y
# differs between clients, so require all four colours without fixing order.
if not all(any(max(abs(a - b) for a, b in zip(actual, want)) <= 1 for actual in samples)
           for want in expected):
    parser.error('custom sampler proof failed: %s' % samples)
print('custom texture sampling: ok', samples)
