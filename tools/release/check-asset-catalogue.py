#!/usr/bin/env python3
"""Check the asset catalogue against the archives about to be published.

The catalogue is served from the repository rather than from the release, so
nothing verifies the two agree unless this does. A release whose archives the
catalogue does not name is not a broken download, it is a bundle that silently
does not exist as far as any client is concerned.

With --live it also asks the server for every catalogued URL. That is the
check to run after an epoch is published: on 2026-09-13 the epoch was left as
a draft, every URL in the catalogue answered 404 for a week, and nothing
offline could have noticed.
"""

import argparse
import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


CATALOGUE_SCHEMA = "org.goanna.asset-catalogue/v1"


def digest(data):
    return hashlib.sha256(data).hexdigest()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Hand each redirect back, so the loop in head() follows it as a HEAD.

    Left to itself urllib may reissue a redirected HEAD as a GET, which
    would download a 95 MB archive to learn its size.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def head(url, timeout=30.0, hops=10):
    """Final status, Content-Length (or None) and URL, following redirects.

    A release download answers with a 302 to an object store, so the status
    that matters is the one at the end of the chain. An error comes back as
    a status rather than an exception, so one dead URL does not hide the
    rest.
    """
    opener = urllib.request.build_opener(_NoRedirect)
    for _ in range(hops):
        request = urllib.request.Request(
            url, method="HEAD", headers={"User-Agent": "goanna-catalogue-check"})
        try:
            with opener.open(request, timeout=timeout) as response:
                length = response.headers.get("Content-Length")
                return response.status, int(length) if length else None, url
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.headers else None
            if error.code in (301, 302, 303, 307, 308) and location:
                url = urllib.parse.urljoin(url, location)
                continue
            return error.code, None, url
        except (urllib.error.URLError, OSError) as error:
            return "unreachable (%s)" % getattr(error, "reason", error), None, url
    return "more than %d redirects" % hops, None, url


def check_live(bundles, fetch=head):
    """Every catalogued URL must answer 200, with the catalogued size."""
    failures = []
    for row in bundles:
        url = str(row.get("url", ""))
        name = "%s %s" % (row.get("id"), row.get("version"))
        if not url.startswith("https://"):
            continue  # already reported as relative
        status, length, final = fetch(url)
        # The final URL carries a signed query string; its host is enough to
        # say where the answer came from.
        where = urllib.parse.urlsplit(final).netloc
        if status != 200:
            failures.append("%s answered %s at %s (%s)" % (name, status, where, url))
            continue
        if length is not None and length != row.get("bytes"):
            failures.append("%s is %d bytes on the server and %s in the catalogue (%s)"
                            % (name, length, row.get("bytes"), url))
            continue
        print("ok   200, %s bytes, %s" % (
            length if length is not None else "size not reported", url))
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalogue", default="asset_bundles/catalogue.json")
    parser.add_argument("--repository", help="OWNER/REPOSITORY the epoch is published to")
    parser.add_argument("--tag", help="the epoch tag being published")
    parser.add_argument("--archives", nargs="*", default=[],
                        help="archives about to be uploaded under that tag")
    parser.add_argument("--live", action="store_true",
                        help="also send a HEAD request to every catalogued URL, "
                             "following redirects, and fail on anything but a "
                             "200 with the catalogued byte size; run this after "
                             "publishing an epoch")
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

    fetched = 0
    if args.live:
        fetched = sum(str(row.get("url", "")).startswith("https://") for row in bundles)
        failures.extend(check_live(bundles))

    for failure in failures:
        print("FAIL " + failure)
    print("asset catalogue: %d bundles, %d archives checked, %d urls fetched, %d failed"
          % (len(bundles), len(args.archives), fetched, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
