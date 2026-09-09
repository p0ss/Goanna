#!/usr/bin/env python3
"""Enforce Goanna's narrower-than-ContentDB media redistribution policy."""

import argparse
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default="pbr_packs/MEDIA_POLICY.json")
    parser.add_argument("--lock", default="pbr_packs/COMMUNITY_LOCK.json")
    parser.add_argument("--audit", default="pbr_packs/MEDIA_AUDIT.json")
    parser.add_argument("--ledger", help="reviewed per-file JSON: {textures:{stem:{license,...}}}")
    args = parser.parse_args()
    policy = json.loads(Path(args.policy).read_text())
    accepted = set(policy["accepted_media_licenses"])
    rejected = tuple(policy["rejected_media_license_prefixes"])
    failures = []
    lock = json.loads(Path(args.lock).read_text()).get("packages", {})
    audit_path = Path(args.audit)
    audit = json.loads(audit_path.read_text()).get("packages", {}) if audit_path.exists() else {}
    for package, record in sorted(lock.items()):
        decision = audit.get(package, {})
        if decision.get("decision") == "excluded":
            continue
        licence = canonical(decision.get("media_license") or
                            record.get("declared_media_license"))
        if licence.startswith(rejected):
            failures.append("%s declares rejected media licence %s" % (package, licence))
        elif licence not in accepted:
            failures.append("%s has unrecognised media licence %s" % (package, licence or "(none)"))
    checked = len(lock)
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
    for failure in failures:
        print("FAIL " + failure)
    print("PBR licences: %d records checked, %d failed" % (checked, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
