"""Per stem PBR authoring script for mcl_colorblocks_concrete_powder_magenta.

Calls concrete_powder_family.run; the design decisions are in that module,
shared across the whole concrete powder family.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import concrete_powder_family  # noqa: E402

if __name__ == "__main__":
    lines = concrete_powder_family.run("mcl_colorblocks_concrete_powder_magenta", sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
