#!/usr/bin/env bash
# Publish one immutable asset epoch. Individual bundles remain update units;
# one GitHub release groups the files operationally.
set -euo pipefail
cd "$(dirname "$0")/.."

REPOSITORY="${1:-}"
TAG="${2:-}"
if [ -z "$REPOSITORY" ] || [ -z "$TAG" ]; then
    echo "usage: $0 OWNER/REPOSITORY assets-YYYY.MM.N" >&2
    exit 2
fi

test -f asset_bundles/catalogue.json
shopt -s nullglob
BUNDLES=(dist/assets/*.zip)
if [ "${#BUNDLES[@]}" -eq 0 ]; then
    echo "no versioned bundles found under dist/assets" >&2
    exit 1
fi
for bundle in "${BUNDLES[@]}"; do
    python3 tools/pbr_bundle.py verify "$bundle"
done

# A new epoch is created once. Re-running before publication may replace the
# draft files; published immutable releases intentionally reject mutation.
if ! gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPOSITORY" --draft \
        --title "Goanna assets ${TAG#assets-}" \
        --notes "Versioned enhanced-material bundles and catalogue."
fi
gh release upload "$TAG" --repo "$REPOSITORY" --clobber \
    asset_bundles/catalogue.json "${BUNDLES[@]}"
echo "Draft asset epoch ready: https://github.com/$REPOSITORY/releases/tag/$TAG"
echo "Publish it after setting catalogue URLs to this tag and re-running the integrity checks."
