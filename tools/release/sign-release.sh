#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (C) 2026 the Goanna contributors
#
# Sign a Goanna release so clients can update to it (project/updater.gd).
# Writes dist/manifest.json, naming each platform's zip with its size and
# SHA-256, and dist/manifest.json.sig, an RSA-SHA256 signature of it made
# with the maintainer's private key, then uploads both to the GitHub release.
# A client offers an update only when the signature checks against the
# public key built into it, project/update_key.pub.pem.
#
# Usage: tools/release/sign-release.sh <tag> [owner/repository]
#   e.g. tools/release/sign-release.sh v0.11.0-alpha
# Run after tools/release/package-release.sh has made both zips for <tag>, and after
# the GitHub release exists. GOANNA_SIGNING_KEY names the private key,
# default ~/.config/goanna-release/update-signing.pem. Keep it out of the
# repository and backed up: without it no release can update clients, and
# replacing it means every player downloads one release by hand.
set -euo pipefail
case "${1:-}" in -h | --help)
    # Usage is the header comment above.
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); if (/^(SPDX|Copyright)/) next
        if (!started && $0 == "") next; started = 1; print }' "$0"
    exit 0 ;;
esac
cd "$(dirname "$0")/../.."
tag=${1:?usage: tools/release/sign-release.sh <tag> [owner/repository]}
repo=${2:-p0ss/Goanna}
key=${GOANNA_SIGNING_KEY:-$HOME/.config/goanna-release/update-signing.pem}
test -r "$key" || { echo "no signing key at $key" >&2; exit 1; }
# The key must match the public half clients carry, or every client
# would refuse the update.
if ! cmp -s <(openssl pkey -in "$key" -pubout) project/update_key.pub.pem; then
	echo "$key does not match project/update_key.pub.pem" >&2
	exit 1
fi
python3 - "$tag" "$repo" <<'PY'
import hashlib, json, os, sys
tag, repo = sys.argv[1], sys.argv[2]
assets = {}
for platform in ("linux", "windows"):
    name = "Goanna-%s-%s-x86_64.zip" % (tag, platform)
    path = os.path.join("dist", name)
    if not os.path.exists(path):
        sys.exit("missing %s; run tools/release/package-release.sh %s %s" % (path, platform, tag))
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    assets[platform] = {"name": name, "bytes": os.path.getsize(path), "sha256": digest,
                        "url": "https://github.com/%s/releases/download/%s/%s" % (repo, tag, name)}
with open("dist/manifest.json", "w") as f:
    json.dump({"schema": "org.goanna.client-release/v1", "version": tag, "assets": assets},
              f, indent=2, sort_keys=True)
    f.write("\n")
PY
openssl dgst -sha256 -sign "$key" -out dist/manifest.json.sig dist/manifest.json
openssl dgst -sha256 -verify project/update_key.pub.pem -signature dist/manifest.json.sig dist/manifest.json
gh release upload "$tag" --repo "$repo" --clobber dist/manifest.json dist/manifest.json.sig
echo "Signed $tag: clients on an older version will offer the update."
