#!/usr/bin/env python3
"""Fail a pack whose baked height maps do not fill the height byte.

The height a Goanna `_n` map carries in its alpha is a 0 deep to 1 high field
written straight across the byte. project/shaders/nodes_array.gdshader reads
it as `h = 1.0 - a` and scales it by `goanna_class_depth(cls) *
parallax_depth`, so the material's depth is applied once, at draw time.

From 2026-09-09 to 2026-09-20 the bake pre-multiplied the byte by that same
depth, which applied it twice. A stone map spanned 141 of 255, copper 46.
tools/check-pbr-quality.py measures one map at a time against a rule, and
passed every one of them, because the rule it held was the doubled encoding.
Mineclonia pack 1.0.0 shipped that way with a median span of 77.

This check does not ask what the rule is. It asks whether a pack's baked
maps use the byte at all, which the shader needs whatever the rule: the
bake normalises each field to 0 to 255, so a correctly baked map spans 255
(or 0, where the source has no relief at all) and a pack's median is 255.
Mineclonia pack 1.1.0's 844 baked maps all span 255.

Authored maps, those tools/pbr_author/lib.py stamps with the PNG text chunk
goanna_pipeline=authored, are reported separately and never fail it:
lib.band holds a cast slab inside a few per cent of the byte on purpose.

Takes texture directories or bundle archives. tools/pbr_bundle.py runs it on
every build and verify.
"""

import argparse
import io
import statistics
import sys
import zipfile
from pathlib import Path

# The bake's maps span 255. Every flattened corpus measured so far has a
# median at or below 206 (Kythen terrain 1.1.0 206, the Minetest Game pack
# directory 205, Minetest Game terrain 1.0.0 141, Kythen item 77, Mineclonia
# 1.0.0 77, Kythen billboard 41), because the class depths are 0.10 to 0.55.
# 224 leaves room for a pack with a few genuinely flat maps and none for one
# that has been scaled by a class depth.
MIN_MEDIAN_SPAN = 224

PIPELINE_KEY = "goanna_pipeline"
AUTHORED = "authored"


def alpha_span(data):
    """(span, authored) for one _n PNG's bytes: max minus min of its alpha."""
    from PIL import Image

    with Image.open(io.BytesIO(data)) as image:
        authored = image.info.get(PIPELINE_KEY) == AUTHORED
        alpha = image.convert("RGBA").getchannel("A")
        low, high = alpha.getextrema()
    return high - low, authored


def normal_maps(source):
    """(name, bytes) for every _n map in a texture directory or bundle archive."""
    path = Path(source)
    if path.is_dir():
        return [(item.name, item.read_bytes()) for item in sorted(path.glob("*_n.png"))]
    with zipfile.ZipFile(path) as archive:
        return [(name, archive.read(name)) for name in sorted(archive.namelist())
                if name.endswith("_n.png")]


def height_fill(maps, min_median=MIN_MEDIAN_SPAN):
    """Report on (name, bytes) pairs. failures is empty when the pack passes."""
    baked, authored = [], []
    for name, data in maps:
        span, is_authored = alpha_span(data)
        (authored if is_authored else baked).append((span, name))
    report = {"baked": len(baked), "authored": len(authored), "failures": []}
    for label, rows in (("baked", baked), ("authored", authored)):
        spans = [span for span, _ in rows]
        report[label + "_median"] = statistics.median(spans) if spans else None
        report[label + "_under_128"] = sum(span < 128 for span in spans)
    if baked and report["baked_median"] < min_median:
        flattest = ", ".join("%s %d" % (name.rsplit("/", 1)[-1], span)
                             for span, name in sorted(baked)[:3])
        report["failures"].append(
            "baked height maps do not fill the height byte: median alpha span "
            "%g of 255 over %d maps, %d under 128 (flattest: %s). The shader "
            "applies the class depth itself, so a bake that scaled the byte by "
            "it has applied it twice" % (report["baked_median"], len(baked),
                                         report["baked_under_128"], flattest))
    return report


def summary(source, report):
    def part(label):
        if not report[label]:
            return "%d %s" % (report[label], label)
        return "%d %s, median span %g, %d under 128" % (
            report[label], label, report[label + "_median"], report[label + "_under_128"])
    return "height fill %s: %s; %s" % (source, part("baked"), part("authored"))


def check(source, min_median=MIN_MEDIAN_SPAN, out=sys.stdout):
    """Print the report for one directory or archive; True when it passes."""
    report = height_fill(normal_maps(source), min_median)
    for failure in report["failures"]:
        print("FAIL %s: %s" % (source, failure), file=out)
    print(summary(source, report), file=out)
    return not report["failures"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("sources", nargs="+",
                        help="texture directories or bundle archives")
    parser.add_argument("--min-median", type=float, default=MIN_MEDIAN_SPAN,
                        help="smallest acceptable median alpha span of the "
                             "baked _n maps (default %(default)s)")
    args = parser.parse_args()
    results = [check(source, args.min_median) for source in args.sources]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
