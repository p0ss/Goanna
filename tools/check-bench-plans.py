#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# The profile bench plans name their tier values literally, and nothing in
# the harness checks them against project/graphics_profiles.gd. That has
# already produced a report of the wrong client: three settings were added
# to the profiles and not to the plans, and a twenty-five minute sweep came
# back with a healthy noise floor, tidy percentages, and the old tiers under
# the new names. Nothing in the output said so.
#
# Run this before believing a profile report, and after changing a tier.
#
#   tools/check-bench-plans.py
#
# Exits non-zero on any drift, so it can sit in front of a benchmark run.
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PROFILES_GD = REPO / "project" / "graphics_profiles.gd"
PLANS = [
    REPO / "tools" / "bench_plans" / "profiles.json",
    REPO / "tools" / "bench_plans" / "profiles-night.json",
    REPO / "tools" / "bench_plans" / "profiles-move.json",
]


def shipped_profiles():
    """The PROFILES table, read out of the GDScript rather than duplicated."""
    text = PROFILES_GD.read_text()
    start = text.index("const PROFILES")
    end = text.index("const ORDER", start)
    out = {}
    for tier in re.finditer(r'"(\w+)":\s*\{(.*?)\},\n', text[start:end], re.S):
        out[tier.group(1)] = {
            key: float(value)
            for key, value in re.findall(r'"(\w+)":\s*(-?[\d.]+)', tier.group(2))
        }
    if not out:
        sys.exit("could not parse PROFILES out of %s" % PROFILES_GD)
    return out


def main():
    profiles = shipped_profiles()
    bad = 0
    for path in PLANS:
        if not path.exists():
            print("missing plan: %s" % path.name)
            bad += 1
            continue
        plan = json.loads(path.read_text())
        for variant in plan.get("variants", []):
            name = variant.get("name")
            if name not in profiles:
                continue
            want = profiles[name]
            got = {k: float(v) for k, v in (variant.get("set") or {}).items()
                   if k in want}
            missing = sorted(set(want) - set(got))
            wrong = sorted(k for k in got if abs(got[k] - want[k]) > 1e-6)
            if missing or wrong:
                bad += 1
                print("%s / %s" % (path.name, name))
                for key in missing:
                    print("    missing %-22s profile has %s" % (key, want[key]))
                for key in wrong:
                    print("    %-22s plan %s, profile %s"
                          % (key, got[key], want[key]))
    if bad:
        print("\n%d variant(s) disagree with graphics_profiles.gd; a report "
              "from these plans would describe a client nobody runs." % bad)
        return 1
    print("bench plans match graphics_profiles.gd (%s)"
          % ", ".join(sorted(profiles)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
