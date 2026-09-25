#!/usr/bin/env bash
# Publish one immutable asset epoch. Individual bundles remain update units;
# one GitHub release groups the files operationally.
#
# The release carries archives only. The catalogue that indexes them is
# asset_bundles/catalogue.json, served from the repository, so clients see a
# new epoch by refetching one small tracked file rather than by being rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."

REPOSITORY="${1:-}"
TAG="${2:-}"
if [ -z "$REPOSITORY" ] || [ -z "$TAG" ]; then
    echo "usage: $0 OWNER/REPOSITORY assets-YYYY.MM.N" >&2
    exit 2
fi

CATALOGUE=asset_bundles/catalogue.json
test -f "$CATALOGUE"
shopt -s nullglob
BUNDLES=(dist/assets/*.zip)
if [ "${#BUNDLES[@]}" -eq 0 ]; then
    echo "no versioned bundles found under dist/assets" >&2
    exit 1
fi
for bundle in "${BUNDLES[@]}"; do
    python3 tools/pbr_bundle.py verify "$bundle"
done

# Nothing else checks that the catalogue and the release agree, and the
# failure is silent: an archive the catalogue does not name is not a broken
# download, it is a bundle no client can discover. Point the catalogue at
# this tag first with `pbr_bundle.py catalogue --base-url`.
python3 tools/check-asset-catalogue.py --catalogue "$CATALOGUE" \
    --repository "$REPOSITORY" --tag "$TAG" --archives "${BUNDLES[@]}"

# A new epoch is created once. Re-running before publication may replace the
# draft files; published immutable releases intentionally reject mutation.
# --prerelease keeps an epoch out of the repository's "latest release", which
# is how the client's own releases stay findable in the same repository.
if ! gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPOSITORY" --draft --prerelease \
        --title "Goanna assets ${TAG#assets-}" \
        --notes "Versioned enhanced-material bundles. They are indexed by asset_bundles/catalogue.json in this repository, not by a file on this release."
fi
gh release upload "$TAG" --repo "$REPOSITORY" --clobber "${BUNDLES[@]}"
echo "Draft asset epoch ready: https://github.com/$REPOSITORY/releases/tag/$TAG"
echo "It is a pre-release, so it cannot become the repository's latest release."
echo
echo "NOT DONE YET. The epoch is a draft, and every URL on a draft answers 404."
echo "On 2026-09-13 this step was missed and no client could install anything"
echo "for a week. Publish it:"
echo
echo "  gh release edit $TAG --repo $REPOSITORY --draft=false"
echo
echo "then check that every catalogued URL answers 200 with the right size:"
echo
echo "  python3 tools/check-asset-catalogue.py --live --catalogue $CATALOGUE"
echo
echo "and only when that passes, commit $CATALOGUE so clients can see these bundles."
