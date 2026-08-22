#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
"""Check that every upstream formspec parser has an explicit Goanna status."""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "luanti/src/gui/guiFormSpecMenu.cpp"
MANIFEST = ROOT / "project/tests/formspec_coverage.json"
VALID_STATUSES = {"supported", "partial", "missing"}


def fail(message: str) -> None:
    print(f"formspec coverage: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def upstream_elements(source: str) -> set[str]:
    marker = "GUIFormSpecMenu::element_parsers = {"
    start = source.find(marker)
    if start < 0:
        fail(f"element parser registry not found in {UPSTREAM}")
    end = source.find("\n};", start)
    if end < 0:
        fail(f"end of element parser registry not found in {UPSTREAM}")
    block = source[start:end]
    return set(re.findall(r'\{"([a-z0-9_]+)"\s*,', block))


def main() -> int:
    upstream = upstream_elements(UPSTREAM.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

    if not isinstance(manifest, dict):
        fail(f"{MANIFEST} must contain a JSON object")

    covered = set(manifest)
    missing = sorted(upstream - covered)
    stale = sorted(covered - upstream)
    if missing:
        fail("new upstream elements need classification: " + ", ".join(missing))
    if stale:
        fail("manifest elements are absent upstream: " + ", ".join(stale))

    bad_entries: list[str] = []
    for name, entry in manifest.items():
        if not isinstance(entry, dict) or entry.get("status") not in VALID_STATUSES:
            bad_entries.append(name)
        elif entry["status"] != "supported" and not entry.get("note"):
            bad_entries.append(name)
    if bad_entries:
        fail("invalid status or missing gap note: " + ", ".join(bad_entries))

    counts = Counter(entry["status"] for entry in manifest.values())
    summary = ", ".join(f"{status}={counts[status]}" for status in sorted(VALID_STATUSES))
    print(f"formspec coverage: PASS: {len(upstream)} upstream elements ({summary})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
