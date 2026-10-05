#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Summarise run.py's results.json: per configuration, the video memory
monitors and the GPU time per place, as the median of the sessions' burst
medians with the range over every burst.

    python3 analyse.py OUT/results.json
"""
import json
import statistics
import sys

res = json.load(open(sys.argv[1]))
for label, sessions in res.items():
    tex = [s["vista_memory"]["texture_mib"] for s in sessions]
    vid = [s["vista_memory"]["video_mib"] for s in sessions]
    wtex = [s["wall_memory"]["texture_mib"] for s in sessions]
    print("%-10s texture %s MiB (wall %s), video %s MiB" % (
        label, "/".join("%.0f" % t for t in tex), "/".join("%.0f" % t for t in wtex),
        "/".join("%.0f" % v for v in vid)))
    for place in ("vista", "wall"):
        meds = [b["median"] for s in sessions for b in s[place]]
        p95 = [b["p95"] for s in sessions for b in s[place]]
        per = [statistics.median([b["median"] for b in s[place]]) for s in sessions]
        print("    %-5s GPU median %.3f ms (bursts %.3f to %.3f; sessions %s), p95 %.3f" % (
            place, statistics.median(meds), min(meds), max(meds),
            "/".join("%.3f" % p for p in per), statistics.median(p95)))
