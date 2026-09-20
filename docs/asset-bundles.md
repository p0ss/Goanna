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
  --output dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip
python3 tools/pbr_bundle.py verify dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip
python3 tools/pbr_bundle.py install \
  dist/assets/org.goanna.minetest-game.terrain-1.0.0.zip \
  --root "$XDG_DATA_HOME/Goanna/content/goanna-assets"
```

`asset_bundles/catalogue.json` is the one catalogue. It is tracked, and it is
the file clients read, so it is written by pointing it at wherever the
archives are published rather than by hand:

```sh
python3 tools/pbr_bundle.py catalogue dist/assets/*.zip \
  --output asset_bundles/catalogue.json \
  --base-url https://github.com/p0ss/Goanna/releases/download/assets-2026.09.1
```

That rereads each archive and re-derives its hash, size and `provides` list,
and it leaves rows alone for bundles it was not given, so an epoch that
changes two bundles re-points two rows and every other bundle keeps pointing
at the release it was published in. An unchanged bundle is never re-uploaded.

A local or CI install can use `tools/pbr_bundle.py`; downloaded archives use
the same checks in `project/asset_store.gd`.

The player archive embeds a stable core bundle under `assets/`. Goanna installs
it before resolving the first connection's material profile. When automatic
enhanced materials are enabled, `GOANNA_ASSET_CATALOGUE_URL` selects the
channel catalogue. As soon as the server announces its media inventory, exact
filename stems are matched against each catalogue entry's `provides` list
while ordinary server media continues downloading. Missing whole bundles
are downloaded and become active on the next connection; failure is non-fatal.

A stem only counts when the catalogue agrees on which game it belongs to.
Mineclonia and Minetest Game both ship a `default_cobble`, so that name says
nothing about which of them the server is running, and a bundle is never
queued on it. Tranches of one game may share a name legitimately, and there
the answer is not in doubt, so a stem is discounted only when the bundles
providing it have no game in common. This is the only filter available: a
remote server's game is unknown at the launcher, so `menu.gd` leaves
`GOANNA_GAME` empty for a remote join, and `installed_for_game` can do no more
than ignore a bundle that has already been downloaded. A bundle whose every
stem is shared in this way can never be asked for. That is a fault in the
catalogue rather than in a connection, so the updater warns and names it.

Periodic updates first refresh the source lock, then regenerate tranche
manifests, bake into staging, run the quality and licence gates, visually
review failures-first sheets, and finally create a new bundle version. The
archive is reproducible from identical inputs. APIs, ineligible media and
ambiguous per-file licences never enter a release merely because a package is
popular.

GitHub distribution groups changed individual bundles into a periodic draft
release rather than making one release per mod. Run
`tools/publish-assets.sh p0ss/Goanna assets-YYYY.MM.N`; inspect the draft and
publish it as immutable.

Assets share the client's repository. Two things keep that from being
confusing. The release carries archives only, never the catalogue, so there
is no second copy to diverge from the tracked one. And an epoch is published
as a pre-release, which GitHub excludes from a repository's latest release,
so asking for the latest Goanna still returns a client rather than a pile of
textures. Splitting the assets into their own repository later changes only
the `--base-url` given to `pbr_bundle.py catalogue` and the URL below.

Clients read the catalogue from the repository at

```
https://raw.githubusercontent.com/p0ss/Goanna/main/asset_bundles/catalogue.json
```

supplied to packaged clients as `catalogue_url` in
`project/bootstrap_assets.json` (the `GOANNA_ASSET_CATALOGUE_URL` environment
variable overrides it for testing). Bundle URLs in it are absolute, so a
client that already has the file needs nothing else to find an archive, and a
new epoch reaches an installed client as soon as that one small file changes
on the default branch. The archives themselves stay immutable at their tag
with their hashes, so the moving pointer costs no integrity: `asset_store.gd`
refuses an archive whose SHA-256 does not match before reading anything out
of it.

Nothing else checks that the catalogue and a release agree, and the failure
is silent, so `tools/check-asset-catalogue.py` gates the upload. It fails an
archive the catalogue does not name, a catalogued URL that points at a
different tag from the one being published, a catalogued URL left relative,
and a size or hash that disagrees with the file on disk.
