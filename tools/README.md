# Tools

Scripts for running, testing, measuring and releasing Goanna, and for
building its PBR packs. Every Python and shell script prints its usage on
`-h` or `--help`. Run them from the repository root.

Status says whether a tool is part of current work or kept as the record of how
something was made or measured. Historical tools are not maintained against the
current code, so expect to fix something first. Several of them start the client
as an ordinary window on the desktop, which `AGENTS.md` rule 6 now forbids: do
not run those as they stand, but start a client with `tools/goanna-headless` and
drive it instead.

## Entry points

These stay at the top of `tools/` because `AGENTS.md`, `CLAUDE.md`, the docs,
MCP registrations in users' Claude settings and `core.hooksPath` name them.
All are current.

- `goanna-headless`, `goanna_headless.py`: run Goanna or the vanilla Luanti
  client in headless gamescope, wait for one to quit (`wait`), and check the
  GPU (`gpu-free`, `gpu-lock`). `goanna_headless.Instance` gives a started
  client the `poll`, `wait` and `terminate` of a `subprocess.Popen`.
  `tools/goanna-headless --help`. See `docs/agent-interfaces.md`.
- `goanna-render`, `goanna_render.py`, `render-fixture.lua`: the render
  service, one long lived server and client that hold the GPU lock and take
  shot jobs. `render-fixture.lua` is its worldmod.
  `tools/goanna-render --help`.
- `goanna-mcp`: MCP server over the control channel, for developers.
  `claude mcp add goanna <checkout>/tools/goanna-mcp`.
- `goanna-control`: talk to a running client's control channel from a shell.
  `tools/goanna-control status`. See `docs/control-channel.md`.
- `goanna-player`, `goanna-player-mcp`, `goanna_player.py`: act as the player
  of a client started with `GOANNA_PLAYER_AGENT`, from a shell or over MCP.
  `goanna_player.py` is the shared library.
- `goanna-director-mcp`, `goanna-director-cli`: the director (game master)
  service over MCP, and a shell front end that keeps one running. See
  `docs/director.md`.
- `check-style.sh`: the text style and repository rules gate. Must exit
  clean before every commit. `tools/check-style.sh`.
- `install-git-hooks.sh`, `git-hooks/`: point `core.hooksPath` at
  `tools/git-hooks`, whose `commit-msg` checks commit message format.
  `tools/install-git-hooks.sh` once per checkout.

## pbr: material maps and asset bundles

Current: the authoring, gates and bundle tools.

- `pbr_author/`: hand authored height and smoothness maps per stem, and
  `build_pack.py` to build a pack from them. Current. Has its own
  `README.md`.
- `check-pbr-quality.py`: the quality gate for baked and authored maps.
  Current. `python3 tools/pbr/check-pbr-quality.py --help`.
- `check-pbr-height.py`: fail a pack whose height maps do not fill the
  height byte. Current; `pbr_bundle.py` runs it too.
- `check-pbr-licenses.py`: enforce the media licence policy in
  `pbr_packs/MEDIA_POLICY.json`. Current.
- `check-pbr-packs.py`: check the bundled PBR worldmods are laid out so
  Luanti serves them. Current; `release/package-release.sh` runs it.
- `pbr_bundle.py`: build, verify, catalogue and install versioned asset
  bundles. Current. See `docs/asset-bundles.md`.
- `pbr_census/`: worldmod and ranking script that measure which textures a
  player sees, to order authoring. Current. Has its own `README.md`.
- `pbr_audit_voxelibre.py`: per file media audit of VoxeLibre stems, read by
  the licence gate. Current.
- `pbr_review_from_defs.py`: draft a classification review from a game's
  definition dump. Current.
- `pbr_spec_variance.py`: add roughness variation to baked specular maps.
  Historical as a pass, current as a library: `pbr_author/lib.py` reads
  material classes through it.
- `pbr_relief_normalise.py`: lift flat baked relief to a target tilt.
  Historical, from the material calibration of September 2026.
- `pbr_bake.py`: the ComfyUI and DeepBump bake. Historical as a bake, since
  authored maps replaced it, but current as a library: the gates and
  `pbr_author/lib.py` import its class tables.
- `comfy_nodes/`, `comfy_workflow.py`: the bake's ComfyUI custom nodes and an
  editable copy of its graph. Historical.
- `goanna_nodedef_dump.lua`, `goanna_itemdef_dump.lua`,
  `goanna_entitydef_dump.lua`: worldmods that dump a game's node, item and
  entity definitions to JSON for the bake and reviews. Current.
- `pbr_review_manifest.py`, `pbr_review_sheet.py`: turn a classification
  review into a bake manifest, and make contact sheets of a bake. Historical.
- `pbr_community_lock.py`, `pbr_community_select.py`,
  `pbr_stage_sources.py`, `pbr_texturepack_intake.py`: pin, select, stage and
  take in community mod sources for a bake. Historical; `pbr_stage_sources.py`
  is still how the pinned sources in `pbr_packs/COMMUNITY_LOCK.json` are
  rebuilt.
- `run-pbr-overnight.sh`: the resumable licence cleared terrain bake with its
  QA. Historical.
- `run-kythen-bake.sh`: the Kythen bake in three tranches. Historical: Kythen
  work has stopped, but the published Kythen bundle recipes name it.
- `pbr_deploy.py`, `pbr_texturepack.py`: deploy a bake as a server side
  worldmod, or as a client side texture pack. Historical.
- `pbr_pack.py`, `pbr_maps/`, `goanna_pbr_gallery.lua`: compose LabPBR maps
  from a PixelGraph pack through mapping CSVs, and a gallery worldmod to view
  them. Historical, from August 2026.
- `mm_export.py`, `mm_export.gd`, `pbr_from_mm.py`: export Material Maker
  materials and pack them as LabPBR sets. Historical. `mm_export.py` opens a
  Material Maker window for the duration.
- `mc_texture_map.py`: build the game texture to Minecraft path map that
  lets Goanna read an unmodified Minecraft resource pack. Current.
- `texture_census.py`: count the textures a multi game pack would need, as a
  CSV. Historical.
- `test-pbr-quality.py`, `test-pbr-bundle.py`, `test-pbr-atlas-obj.py`: unit
  tests for the quality gate, the bundle tool and `pbr_author/atlas.py`.
  Current. No GPU, no server.

## test: tests and review harnesses

- `test-formspec.sh`, `check-formspec-coverage.py`: formspec coverage and
  conformance under Godot's `--headless` dummy renderer. Current.
  `GODOT_BIN=/path/to/godot tools/test/test-formspec.sh`.
- `test-local-play.py`: local sessions with the dummy renderer and a scratch
  server. Current.
- `test-portals.py`, `portal-fixture.lua`: portal routing on a disposable
  Mineclonia server, no GPU. Current.
- `test-block-updates.py`, `block-update-fixture.lua`: terrain block
  replacement across a mapblock boundary, with a CPU only client. Current.
- `test-item-use.py`, `item-use-fixture.lua`: DorfCraft tool clicks on
  Mineclonia, with a CPU only client. Current.
  `--dorfcraft /path/to/DorfCraft`.
- `test-director.py`: end to end director test on a real Mineclonia server.
  Current. `--dummy` runs the players under `--headless`.
- `test-director-logic.lua`: unit tests for the director's pure logic.
  Current. `luajit tools/test/test-director-logic.lua`.
- `director-probe/`: throwaway worldmod, and an HTTP sink, that check the
  engine calls the director builds on. Historical, from September 2026.
- `test-fine-server.lua`, `test-surface-server.lua`,
  `test-forest-preview.lua`, `test-tdl-columns.lua`, `test-lod-material.lua`:
  server mod and terrain unit tests under plain LuaJIT. Current.
  `luajit tools/test/test-fine-server.lua` from the repository root.
- `test-fresh-install.sh`: "Get ready to play" from nothing in clean distro
  containers with podman. Current; needs `dist/luanti-server`.
- `test-launch-target.sh`: the fresh install harness of
  `docs/launch-target.md`, on the GPU in headless gamescope. Current.
- `test-shaderpack.sh`, `shaderpack_check.py`: run with the proof shader pack
  in headless gamescope and check the screenshot. Current; needs a server.
  `shaderpack_check.py` alone checks a saved shot.
- `dig-review/`, `forest-review/`, `grass-review/`, `ice-review/`,
  `lava-review/`: live capture harnesses behind the reviews in `docs/perf/`.
  Historical. Most start the client as a desktop window; read the script
  before running one. `dig-review/check_kythen.py` checks the radial damage
  reference copy against a Kythen checkout and needs no client.

## bench: benchmarks and measurements

- `goanna-bench.py`, `bench_plans/`: run a plan of graphics settings against
  a world and report what each costs. See `docs/benchmark.md`. Desktop
  exception: it opens a real window, because frame pacing depends on the
  real present path, so it is run by the owner, or by an agent only when
  the owner has said the machine is free. It takes the GPU lock for the
  whole run, waiting for it, and its report records the mode. `--dry-run`
  takes the lock and makes the GPU checks without a client. Also a library:
  `bench-local-play.py` and the `docs/perf` run scripts import it.
- `check-bench-plans.py`: check the plans' tier values against
  `project/graphics_profiles.gd`. Current; run before believing a profile
  report.
- `bench-local-play.py`, `local-feature-fixture.lua`,
  `local-feature-scenes.json`: measure local players in one rendered process
  on a disposable world copy, through `goanna_headless.py`. Current. Headless,
  so its frame rates are relative only, and every result says so; it holds
  the GPU lock from the first client to the last (`--lock-wait`).
- `test-local-bench.py`: unit tests for `bench-local-play.py`. Current.
- `far-baseline.py`: record a far rendering baseline from a running client.
  Current. See `docs/baseline.md`. It starts nothing; its manifest records
  whether the client was on the desktop or headless, and a headless run's
  frame rates are relative only.
- `chart_summary.py`: reduce a lighting chart run to pass or fail lines.
  Current. See `project/lighting_chart.gd`.
- `terrain-baked-review.py`, `terrain-storage-flight.py`,
  `terrain-surface-descent.py`: the terrain storage and surface flights of
  September 2026, against a running client. Historical.

## release: packaging and publishing

All current. See `docs/building.md` and `docs/asset-bundles.md`.

- `build-goanna-extension.sh`: build the GDExtension in Ubuntu 22.04 with
  podman, so releases load on glibc 2.35.
- `build-luanti-server.sh`: build the portable Linux Luanti server from the
  pinned submodule, unmodified.
- `package-release.sh`: export a standalone build.
  `tools/release/package-release.sh <linux|windows> [version]`.
- `sign-release.sh`: sign a release's manifest for the self updater.
  `tools/release/sign-release.sh <tag>`.
- `publish-assets.sh`: publish an asset bundle epoch as a draft GitHub
  release. `tools/release/publish-assets.sh OWNER/REPOSITORY assets-YYYY.MM.N`.
- `check-asset-catalogue.py`: check `asset_bundles/catalogue.json` against
  the archives, and with `--live` against the published URLs.

## dev: small helpers

- `shotcheck.py`: measure what a screenshot contains before trusting it.
  Current; `goanna-mcp` uses it. `python3 tools/dev/shotcheck.py shot.png`.
- `menu-background.sh`: retake the main menu stills in headless gamescope.
  Current. Needs the GPU free.
- `make-icon.py`: draw `project/icon.svg` from a voxel list. Current.
