"""One line: build hardened_clay_stained_blue from hardened_clay_family's shared ceramic."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hardened_clay_family

if __name__ == "__main__":
    lines = hardened_clay_family.run("hardened_clay_stained_blue", sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
