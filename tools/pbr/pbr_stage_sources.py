#!/usr/bin/env python3
"""Stage the pinned community source archives a PBR bake reads from.

The bake, the quality gate and the licence gate all walk an extracted tree
of ContentDB packages. That tree is large, entirely regenerable, and was
previously staged under /tmp, which is tmpfs here: a reboot loses it and the
run cannot be repeated without it. This rebuilds it from
pbr_packs/COMMUNITY_LOCK.json, which pins the release number and the archive
hash of every admitted package.

A hash that does not match the lock is a provenance failure, not a download
to retry: the licence audit in docs/pbr-community-review.md is written
against the archive the lock names, so the package is skipped and reported.
"""

import argparse
import hashlib
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

CONTENTDB = "https://content.luanti.org/packages/%s/releases/%d/download/"
USER_AGENT = "goanna-pbr-stage/1 (+https://github.com/p0ss/Goanna)"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def release_url(entry):
    # The lock stores the human package page. Its author/name pair is what
    # the release download endpoint wants.
    page = entry["contentdb"].rstrip("/")
    author_name = "/".join(page.split("/")[-2:])
    return CONTENTDB % (author_name, entry["release"])


def download(url, dest):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request) as response:
        dest.write_bytes(response.read())


def safe_members(archive):
    """Reject absolute paths and traversal before anything is written."""
    for name in archive.namelist():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("unsafe archive member: %s" % name)
    return archive.namelist()


def stage(name, entry, dest_root, cache, force):
    archive = cache / ("%s-%d.zip" % (name, entry["release"]))
    expected = entry["archive_sha256"]
    if archive.exists() and digest(archive) != expected:
        archive.unlink()
    if not archive.exists():
        url = release_url(entry)
        print("  fetching %s release %d" % (name, entry["release"]))
        download(url, archive)
    found = digest(archive)
    if found != expected:
        print("  %s: archive hash %s does not match the lock's %s, skipped"
              % (name, found[:16], expected[:16]))
        archive.unlink()
        return False
    target = dest_root / name
    if target.exists() and any(target.iterdir()) and not force:
        print("  %s already staged" % name)
        return True
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as opened:
        safe_members(opened)
        opened.extractall(target)
    print("  %s staged at %s" % (name, target))
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("packages", nargs="+")
    parser.add_argument("--lock", default="pbr_packs/COMMUNITY_LOCK.json")
    parser.add_argument("--dest", required=True,
                        help="directory to extract each package below")
    parser.add_argument("--cache",
                        help="where downloaded archives are kept "
                             "(default: <dest>/../archives)")
    parser.add_argument("--force", action="store_true",
                        help="re-extract a package that is already staged")
    args = parser.parse_args()

    lock = json.loads(Path(args.lock).read_text())["packages"]
    dest_root = Path(args.dest)
    dest_root.mkdir(parents=True, exist_ok=True)
    cache = Path(args.cache) if args.cache else dest_root.parent / "archives"
    cache.mkdir(parents=True, exist_ok=True)

    failures = []
    for name in args.packages:
        entry = lock.get(name)
        if not entry:
            print("  %s is not in the lock, skipped" % name)
            failures.append(name)
            continue
        try:
            if not stage(name, entry, dest_root, cache, args.force):
                failures.append(name)
        except Exception as error:
            print("  %s failed: %s" % (name, error))
            failures.append(name)
    if failures:
        print("not staged: %s" % ", ".join(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
