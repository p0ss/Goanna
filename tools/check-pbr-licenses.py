#!/usr/bin/env python3
"""Enforce Goanna's narrower-than-ContentDB media redistribution policy."""

import argparse
import collections
import json
from pathlib import Path


ALIASES = {
    "CC-BY-SA-2.0-DE": "CC-BY-SA-2.0",
    "CC-BY-SA-3.0-UNPORTED": "CC-BY-SA-3.0",
    "CC-BY-SA-4.0-INTERNATIONAL": "CC-BY-SA-4.0",
    "CC0": "CC0-1.0",
    "PUBLIC DOMAIN": "Public-Domain",
    "ZLIB": "Zlib",
}


def canonical(value):
    value = (value or "").strip()
    return ALIASES.get(value.upper(), value)


def per_file_licences(manifest_dir):
    """Exact per-file media licences recorded at intake, keyed by package.

    An archive-wide notice qualifies a package only when it unambiguously
    covers all media. A mixed notice requires this per-file mapping instead
    (see the licence gate in docs/pbr-community-review.md). Manifests written
    before per-file recording leave the field unset, which counts as
    unqualified rather than as an absent package.
    """
    by_package = {}
    for path in sorted(Path(manifest_dir).glob("*.sources.json")):
        for record in json.loads(path.read_text()).values():
            package = record.get("package")
            if not package:
                continue
            counts = by_package.setdefault(package, collections.Counter())
            counts[canonical(record.get("media_license"))] += 1
    return by_package


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default="pbr_packs/MEDIA_POLICY.json")
    parser.add_argument("--lock", default="pbr_packs/COMMUNITY_LOCK.json")
    parser.add_argument("--audit", default="pbr_packs/MEDIA_AUDIT.json")
    parser.add_argument("--manifests", default="pbr_packs/manifests",
                        help="intake manifests carrying per-file media licences")
    parser.add_argument("--ledger", help="reviewed per-file JSON: {textures:{stem:{license,...}}}")
    args = parser.parse_args()
    policy = json.loads(Path(args.policy).read_text())
    accepted = set(policy["accepted_media_licenses"])
    rejected = tuple(policy["rejected_media_license_prefixes"])
    failures = []
    qualified = []
    lock = json.loads(Path(args.lock).read_text()).get("packages", {})
    audit_path = Path(args.audit)
    audit = json.loads(audit_path.read_text()).get("packages", {}) if audit_path.exists() else {}
    manifest_dir = Path(args.manifests)
    per_file = per_file_licences(manifest_dir) if manifest_dir.is_dir() else {}
    checked = len(lock)
    for package, record in sorted(lock.items()):
        decision = audit.get(package, {})
        if decision.get("decision") == "excluded":
            continue
        licence = canonical(decision.get("media_license") or
                            record.get("declared_media_license"))
        if licence.startswith(rejected):
            failures.append("%s declares rejected media licence %s" % (package, licence))
            continue
        if licence in accepted:
            continue
        # Not a single accepted licence, so the package-level string is a
        # summary of a mixed notice. Only the exact licences recorded against
        # the selected files can qualify it, and every one of them must pass.
        files = per_file.get(package)
        if not files:
            failures.append("%s has unrecognised media licence %s and no per-file mapping"
                            % (package, licence or "(none)"))
            continue
        unqualified = sorted((lic, n) for lic, n in files.items() if lic not in accepted)
        for lic, count in unqualified:
            failures.append("%s has %d selected file(s) with %s media licence %s"
                            % (package, count,
                               "rejected" if lic.startswith(rejected) else "unrecognised",
                               lic or "(none)"))
        checked += sum(files.values())
        if not unqualified:
            qualified.append("%s qualified per file: %d files, %s"
                             % (package, sum(files.values()), ", ".join(sorted(files))))
    if args.ledger:
        ledger = json.loads(Path(args.ledger).read_text()).get("textures", {})
        for stem, record in sorted(ledger.items()):
            licence = canonical(record.get("license"))
            if not record.get("source") or not record.get("author"):
                failures.append("%s lacks exact source or author" % stem)
            if licence.startswith(rejected):
                failures.append("%s uses rejected media licence %s" % (stem, licence))
            elif licence not in accepted:
                failures.append("%s has unrecognised media licence %s" %
                                (stem, licence or "(none)"))
        checked += len(ledger)
    for line in qualified:
        print(line)
    for failure in failures:
        print("FAIL " + failure)
    print("PBR licences: %d records checked, %d failed" % (checked, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
