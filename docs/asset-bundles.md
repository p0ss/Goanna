# Versioned asset bundles

Goanna code releases do not own PBR bake output. Large generated maps are
published as independently versioned ZIP bundles, downloaded once, verified,
and installed below `user://content/goanna-assets`.

Each bundle uses schema `org.goanna.asset-bundle/v1`. Its identity separates
the upstream package release and archive hash from Goanna's pipeline version.
Every payload file has a size and SHA-256 entry. Normal and material maps must
form complete `_n`/`_s` pairs. Generated albedo is review evidence and is not
part of a companion-map bundle.

The catalogue uses `org.goanna.asset-catalogue/v1`. Catalogue entries name the
bundle ID, version, compatible games, tranche, URL, byte size and archive
SHA-256. Updating a bundle means adding a new immutable version; an installed
old version is never edited in place.

The Godot runtime validates the archive hash, rejects unsafe ZIP paths,
checks every payload size and hash, and requires complete normal/material
pairs before activation. It then composes the newest installed version of
each compatible bundle into `profiles/<game>/textures`. Duplicate filenames
from different bundle IDs are rejected instead of being resolved by an
unstated load order.

Build and verify a release with:

```sh
python3 tools/pbr_bundle.py build \
  --textures baked/minetest-game-terrain \
  --quality baked/minetest-game-terrain-quality.json \
  --attribution pbr_packs/minetest_game/ATTRIBUTION.md \
  --id org.goanna.minetest-game.terrain --version 1.0.0 \
  --tranche terrain --game minetest --game minetest_game \
  --source-package Luanti/minetest_game --source-release 38214 \
  --source-sha256 5b364f... --pipeline-version 1 \
  --output dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip \
  --catalogue dist/assets/catalogue.json
python3 tools/pbr_bundle.py verify dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip
python3 tools/pbr_bundle.py install \
  dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip \
  --root "$XDG_DATA_HOME/Goanna/content/goanna-assets"
```

Packagers publish `asset_bundles/catalogue.json` beside its named archives and
set the public catalogue URL in their distribution/update channel. A local or
CI install can use `tools/pbr_bundle.py`; downloaded archives use the same
checks in `project/asset_store.gd`.

The player archive embeds a stable core bundle under `assets/`. Goanna installs
it before resolving the first connection's material profile. When automatic
enhanced materials are enabled, `GOANNA_ASSET_CATALOGUE_URL` selects the
channel catalogue. As soon as the server announces its media inventory, exact
filename stems are matched against each catalogue entry's `provides` list
while ordinary server media continues downloading. Missing whole bundles
are downloaded and become active on the next connection; failure is non-fatal.

Periodic updates first refresh the source lock, then regenerate tranche
manifests, bake into staging, run the quality and licence gates, visually
review failures-first sheets, and finally create a new bundle version. The
archive is reproducible from identical inputs. APIs, ineligible media and
ambiguous per-file licences never enter a release merely because a package is
popular.

GitHub distribution groups changed individual bundles into a periodic draft
release rather than making one release per mod. Run
`tools/publish-assets.sh OWNER/goanna-assets assets-YYYY.MM.N`; inspect the
draft and publish it as immutable. The public catalogue URL is the release
asset URL ending in `/catalogue.json`, supplied to packaged clients as
`catalogue_url` in `project/bootstrap_assets.json` (the
`GOANNA_ASSET_CATALOGUE_URL` environment variable overrides it for testing).
Relative bundle URLs then resolve beside it.
