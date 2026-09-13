#!/usr/bin/env python3
"""Check the asset catalogue against the archives about to be published.

The catalogue is served from the repository rather than from the release, so
nothing verifies the two agree unless this does. A release whose archives the
catalogue does not name is not a broken download, it is a bundle that silently
does not exist as far as any client is concerned.
"""

import argparse
import hashlib
import json
from pathlib import Path


CATALOGUE_SCHEMA = "org.goanna.asset-catalogue/v1"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalogue", default="asset_bundles/catalogue.json")
    parser.add_argument("--repository", help="OWNER/REPOSITORY the epoch is published to")
    parser.add_argument("--tag", help="the epoch tag being published")
    parser.add_argument("--archives", nargs="*", default=[],
                        help="archives about to be uploaded under that tag")
    args = parser.parse_args()

    catalogue = json.loads(Path(args.catalogue).read_text())
    failures = []
    if catalogue.get("schema") != CATALOGUE_SCHEMA:
        failures.append("catalogue schema is %r" % catalogue.get("schema"))
    bundles = catalogue.get("bundles", [])
    by_sha = {}
    for row in bundles:
        url = str(row.get("url", ""))
        name = "%s %s" % (row.get("id"), row.get("version"))
        if not url.startswith("https://"):
            failures.append("%s has a relative url %r; a catalogue served from the "
                            "repository cannot resolve one" % (name, url))
        if len(str(row.get("sha256", ""))) != 64:
            failures.append("%s has no usable sha256" % name)
        by_sha[str(row.get("sha256", ""))] = row

    expected_prefix = None
    if args.repository and args.tag:
        expected_prefix = "https://github.com/%s/releases/download/%s/" % (
            args.repository, args.tag)

    uploading = set()
    for path in args.archives:
        archive = Path(path)
        blob = archive.read_bytes()
        sha = digest(blob)
        row = by_sha.get(sha)
        if row is None:
            failures.append("%s is not in the catalogue; publishing it would put an "
                            "archive on the release that no client can discover"
                            % archive.name)
            continue
        uploading.add(sha)
        if row.get("bytes") != len(blob):
            failures.append("%s byte count disagrees with the catalogue" % archive.name)
        url = str(row.get("url", ""))
        # A relative url is already reported above; saying it also names the
        # wrong file would be untrue and would bury the real reason.
        if url.startswith("https://") and not url.endswith("/" + archive.name):
            failures.append("%s is catalogued at %r, which is not that file"
                            % (archive.name, url))
        if expected_prefix and url.startswith("https://") \
                and not url.startswith(expected_prefix):
            failures.append("%s is being uploaded to %s but catalogued at %r"
                            % (archive.name, args.tag, url))

    if expected_prefix:
        for row in bundles:
            url = str(row.get("url", ""))
            if url.startswith(expected_prefix) and row.get("sha256") not in uploading:
                failures.append("%s %s points at %s but is not being uploaded"
                                % (row.get("id"), row.get("version"), args.tag))

    for failure in failures:
        print("FAIL " + failure)
    print("asset catalogue: %d bundles, %d archives checked, %d failed"
          % (len(bundles), len(args.archives), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
