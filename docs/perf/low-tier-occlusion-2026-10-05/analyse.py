#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Summarise run.py's samples: OUT/<tier>/<place>/<variant>-r<n>/frames.csv.

Per variant: the GPU median and 95th percentile of all its frames pooled,
the range of the per round medians, and the 10th percentile (the quiet
frames, see the report). Per round, each variant's median minus the
baseline variant's median in the same round, so drift across rounds
cancels: the median of those differences and their range.
"""

import csv
import pathlib
import re
import statistics
import sys


def q(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(p * len(s)))]


def main(out, baseline_suffix="_today"):
    out = pathlib.Path(out)
    for tier_dir in sorted(p for p in out.iterdir() if p.is_dir() and p.name in ("low", "medium")):
        for place_dir in sorted(p for p in tier_dir.iterdir() if p.is_dir() and p.name != "frames"):
            runs = {}
            for run in place_dir.iterdir():
                m = re.match(r"(.+)-r(\d+)$", run.name)
                if not m or not (run / "frames.csv").exists():
                    continue
                with open(run / "frames.csv") as f:
                    g = [float(r["gpu_ms"]) for r in csv.DictReader(f)]
                runs.setdefault(m.group(1), {})[int(m.group(2))] = g
            base = next((v for v in runs if v.endswith(baseline_suffix)), None)
            print("\n%s / %s" % (tier_dir.name, place_dir.name))
            print("| variant | rounds | frames | GPU median | GPU p95 | GPU p10 | round medians | "
                  "vs %s, per round | range |" % base)
            print("| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |")
            for name in sorted(runs):
                rounds = runs[name]
                pooled = [x for g in rounds.values() for x in g]
                meds = [statistics.median(g) for g in rounds.values()]
                diffs = [statistics.median(rounds[r]) - statistics.median(runs[base][r])
                         for r in rounds if base and r in runs[base]]
                d = ("%+.3f" % statistics.median(diffs)) if diffs and name != base else "-"
                dr = ("%+.3f to %+.3f" % (min(diffs), max(diffs))) if diffs and name != base else "-"
                print("| %s | %d | %d | %.3f | %.3f | %.3f | %.3f to %.3f | %s | %s |" % (
                    name, len(rounds), len(pooled), statistics.median(pooled), q(pooled, 0.95),
                    q(pooled, 0.10), min(meds), max(meds), d, dr))


if __name__ == "__main__":
    main(*sys.argv[1:])
