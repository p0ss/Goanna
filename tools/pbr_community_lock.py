#!/usr/bin/env python3
"""Write an immutable source lock from ContentDB metadata and archives."""

import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--archives", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    metadata = Path(args.metadata)
    archives = Path(args.archives)
    packages = {}
    for path in sorted(metadata.glob("*.json")):
        data = json.loads(path.read_text())
        release = data.get("release")
        archive = archives / f"{path.stem}-{release}.zip"
        if not release or not archive.exists():
            continue
        packages[path.stem] = {
            "archive_sha256": digest(archive),
            "contentdb": "https://content.luanti.org/packages/%s/%s/" %
                         (data["author"], data["name"]),
            "declared_media_license": data.get("media_license"),
            "release": release,
            "repository": data.get("repo"),
        }
    Path(args.out).write_text(json.dumps({"packages": packages}, indent=2,
                                         sort_keys=True) + "\n")
    print("locked %d packages" % len(packages))


if __name__ == "__main__":
    main()
