# Community PBR audit and review

Community materials are admitted in three separate tranches. They do not
share a bake merely because all three ultimately use `_n` and `_s` files.

1. **Terrain and solid nodes.** Tile-aware structural upscale, bounded relief,
   class-aware roughness and guarded metalness. Repeating faces are checked
   for wrap seams.
2. **Billboards, plants and flat world items.** Alpha and silhouette are
   authoritative. Transparent pixels must remain neutral, relief is shallow,
   foliage may use back-lighting, and animation frames stay registered.
3. **Creatures.** UV atlases are processed without tiling. Atlas islands,
   painted eyes and markings must not move, opposite edges must not be treated
   as neighbours, and a rendered model turntable is required for acceptance.

The intake manifests under `pbr_packs/manifests/` are candidate lists, not a
claim that the images are already licensed, baked or approved. Package
versions and hashes are in `pbr_packs/COMMUNITY_LOCK.json`.

## Licence gate

For every selected source image, record the exact archive, owning mod, source
path, author, media licence and required attribution. An archive-wide licence
is sufficient only when it unambiguously covers all media. A mixed notice
requires a per-file mapping. A ContentDB label is corroborating metadata, not
a substitute for the notice inside the pinned archive. Ambiguous files are
excluded rather than assigned the most convenient nearby licence. Goanna's
policy is deliberately narrower than general legal redistributability:
GPL-, LGPL- and AGPL-licensed **media** are rejected. A package's software may
use one of those licences only when a separate notice unambiguously places the
selected image under an accepted media licence. `pbr_packs/MEDIA_POLICY.json`
is the machine-readable allow/deny list and `tools/check-pbr-licenses.py`
enforces it against both the source lock and reviewed per-file ledgers.

Where the package-level notice is mixed, the summary string in
`pbr_packs/MEDIA_AUDIT.json` does not qualify anything on its own. The gate
resolves that package from the exact `media_license` recorded against each
selected file in its intake manifest under `pbr_packs/manifests/`, and fails
the package if the mapping is missing, if any selected file has no exact
licence, or if any recorded licence is outside the accepted set. A rejected
package-level licence still fails before the mapping is consulted.

Not yet under the gate: the bundled Mineclonia pack predates the source lock,
so it has no pinned release, no archive hash and no audit row, and
`check-pbr-licenses.py` iterates the lock and therefore never sees it. Its
terms are clean on inspection, with `LEGAL.md` separating GPLv3 code from
media that is CC BY-SA 4.0 (Pixel Perfection and Pixel Perfection Legacy)
with CC0 menu images, but clean on inspection is not the same as checked.

The current audit groups are:

| Package group | State | Reason |
| --- | --- | --- |
| Advtrains, Glass Stained, Lanterns, Mesecons, Moreblocks, Morelights, Nether, Pipeworks, Stainedglass | archive-wide media terms found | Derivatives are permitted with the named attribution/share-alike terms. |
| Animalia, Dungeons Plus, Natural Biomes | single-project terms found | The included notice covers the project; Dungeons Plus has no qualifying node textures. |
| Cottages, Ebiomes, Ethereal, Everness, Fachwerk, Goblins, `mcl_decor`, Techage, X-Decor | per-file audit required | Their notices identify multiple authors, licences, imported works or submods. |
| Darkage | excluded | ContentDB declares CC0 media while the archive contains an MIT notice without a clear media scope; it is absent from every intake manifest. |
| VoxeLibre | per-file audit required | It is a game-scale source with multiple media notices; only the 72 currently uncovered candidates are relevant. |
| Asuna | excluded | Its own LICENSE opens "this game as a whole is released under GPLv3", because it aggregates GPL works. ContentDB's CC BY-SA 4.0 label is the corroborating metadata that cannot stand in for that. It does enumerate every included work with its licence file, so a work may still be admitted through its own upstream package. |
| Minetest Game | archive-wide plus per-mod attribution | Release 38214 is pinned; its LGPL code is irrelevant to the separately CC BY-SA 3.0 media. Its terrain tranche contains 87 solid-node surfaces. |
| Less Dirt | per-file mapping recorded | Release 13232 carries per-family CC BY-SA notices, so the archive-wide string is a summary. Its 42 selected files are each recorded CC BY-SA 3.0 at intake. |

## Automated acceptance gate

Run `tools/check-pbr-quality.py` against every completed tranche before copying
anything into `pbr_packs/`. It rejects malformed pairs, normal fields outside
the tangent hemisphere, directional bias, unbounded or flat height, excessive
smoothness for the material class, dark diffuse-authored art incorrectly made
metallic, broken transparent regions and excessive generated-albedo colour
drift. Strong wrap seams are reported for review.

The gate is intentionally followed by visual review:

- a source/albedo/normal/height/roughness contact sheet;
- representative Godot material-ball or cube renders under neutral, grazing
  and coloured light;
- a tiled plane for terrain, an alpha-card scene for billboards and a model
  turntable for creatures;
- reject, reclassify or rebake individual failures rather than weakening a
  threshold to make a batch pass.

`tools/test-pbr-quality.py` exercises the failure cases with synthetic maps.
The current pre-review manifests contain 808 community terrain candidates,
453 billboard/item/plant candidates, 139 creature candidates and 87 Minetest
Game terrain candidates. The original 33-image pilot was withdrawn after the
new gate rejected 31 maps,
mostly for unconstrained height. It is evidence for the gate, not a baseline
to grandfather into a release.

## Running a bake

The sources a bake reads are not in the repository. `tools/pbr_stage_sources.py`
rebuilds them from `pbr_packs/COMMUNITY_LOCK.json`, downloading each pinned
ContentDB release, checking it against the hash the lock records and extracting
it below a staging root. A hash that does not match is reported and skipped
rather than baked, because the licence audit above is written against the
archive the lock names.

`tools/run-pbr-overnight.sh` stages every package the queued tranches need and
then bakes them. Its staging root defaults to `~/.local/share/goanna-pbr-audit`
and can be moved with `GOANNA_AUDIT_ROOT`. It must not be put on `/tmp`: that
is tmpfs on the development box, and a reboot on 2026-09-07 took a night's
composed maps with it.

The generation itself survived that reboot, because ComfyUI writes every image
it produces to its own output directory on ordinary disk. `pbr_bake.py
--reuse-outputs` composes a texture from a previous run's saved detail pass and
Chord maps instead of generating it again, and generates only what the
directory does not cover, so an interrupted run is finished rather than
repeated. Checked on `br_carpet_0`: the reused `_n`, `_s` and `_albedo` are
byte identical to a fresh bake of the same stem, in 0.7 s against 31 s.
Nothing records which settings produced a saved image, so a reuse is only
valid for the same queue at the same settings; the overnight script therefore
reuses only each stage's own run folder.

## Popularity audit and update queue

A 2026-09-04 survey checks the top 50 listings per stream, then backfills to
20 packages that actually contain relevant assets. Download rank alone does
not admit a package: APIs, duplicate aggregates, low-yield packs and unclear
media are removed first.

- Terrain: Too Many Stones is the first clean addition (396 conservative
  candidates under an explicit MIT texture grant). Logistica follows after
  dynamic-registration selector support. Unified Dyes is excluded as GPL
  media; Protector, Melterns, Homedecor and Cblocks require exact ledgers or
  clarification.
- Billboards/items/plants: Farming Redo, Plantlife, More Trees, X Farming and
  Bonemeal are the main missing sources. Farming and X Farming require
  file-level attribution. DFCaverns, Bees, Digistuff, Nextgen Fungi,
  Multidecor and Beautiful Flowers remain held where archive evidence is
  mixed, missing or contradictory.
- Model skins: Animal World, Draconis, Dmobs, People, Living Nether and
  Marinara Mobs are the strongest clean additions. UV/model pairs are kept for
  turntable review even though only derived texture maps ship. GPL groups are
  excluded at file level; this applies to PaleoTest, the Mobs Water crocodile
  group, and four non-commercial Mobs Animal sheep skins.

The release format and periodic update procedure are described in
`docs/asset-bundles.md`. Minetest Game terrain bundle 1.0.0 is the calibration
release; later community sources receive separate immutable bundle IDs and
versions so users download only changed tranches.
