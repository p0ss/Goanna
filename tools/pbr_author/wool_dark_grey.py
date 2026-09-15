"""One line: build wool_dark_grey from wool_family's shared weave."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wool_family

if __name__ == "__main__":
    lines = wool_family.run("wool_dark_grey", sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
