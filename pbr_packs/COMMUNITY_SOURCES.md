# Community PBR source register

This is the intake register for community mods whose textures are candidates
for Goanna's bundled PBR packs. A package may enter the pack only after its
download is pinned, the licence files inside that exact archive are audited,
and every selected texture has an author and licence recorded in the target
pack's `ATTRIBUTION.md`. ContentDB's package-level media field is useful for
discovery, but is not sufficient evidence on its own.

Pinned release IDs, repositories, declared media licences and archive hashes
are machine-readable in `COMMUNITY_LOCK.json`. Candidate images are separated
into terrain, billboard and creature manifests under `manifests/`; the review
and rejection rules are documented in `docs/pbr-community-review.md`.

`audited; rebake pending` means the archive's notices have been checked but no
art is bundled until a tranche-specific bake passes the quality gate.
`pending audit` also means no art from that package is bundled.

| Package | Status |
| --- | --- |
| [Cave Realms](https://content.luanti.org/packages/HeroOfTheWinds/caverealms/) | audited; terrain rebake pending |
| [Castle Lighting](https://content.luanti.org/packages/FaceDeer/castle_lighting/) | audited; terrain/billboard rebake pending |
| [Castle Masonry](https://content.luanti.org/packages/FaceDeer/castle_masonry/) | audited; terrain rebake pending |
| [Pipeworks](https://content.luanti.org/packages/mt-mods/pipeworks/) | pending audit |
| [Nether](https://content.luanti.org/packages/PilzAdam/nether/) | pending audit |
| [Ethereal](https://content.luanti.org/packages/TenPlus1/ethereal/) | pending audit |
| [Everness](https://content.luanti.org/packages/SaKeL/everness/) | pending audit |
| [Ebiomes](https://content.luanti.org/packages/CowboyLv/ebiomes/) | pending audit |
| [Dungeons Plus](https://content.luanti.org/packages/EmptyStar/dungeonsplus/) | pending audit |
| [Natural Biomes](https://content.luanti.org/packages/Liil/naturalbiomes/) | pending audit |
| [X-Decor-libre](https://content.luanti.org/packages/Wuzzy/xdecor/) | pending audit |
| [Mesecons](https://content.luanti.org/packages/Jeija/mesecons/) | media override audited: textures CC BY-SA 3.0; tranche review pending |
| [More Blocks](https://content.luanti.org/packages/Calinou/moreblocks/) | pending audit |
| [Cottages](https://content.luanti.org/packages/Sokomine/cottages/) | pending audit |
| [Morelights](https://content.luanti.org/packages/random_geek/morelights/) | pending audit |
| [Stained Glass](https://content.luanti.org/packages/v-rob/glass_stained/) | pending audit |
| [Fachwerk](https://content.luanti.org/packages/jbb/fachwerk/) | pending audit |
| [Lanterns](https://content.luanti.org/packages/gergelypolonkai/lanterns/) | pending audit |
| [Stained Glass](https://content.luanti.org/packages/alerikaisattera/stainedglass/) | pending audit |
| [Darkage](https://content.luanti.org/packages/addi/darkage/) | excluded: archive/ContentDB media-licence mismatch |
| [Animalia](https://content.luanti.org/packages/ElCeejo/animalia/) | pending audit |
| [Advtrains](https://content.luanti.org/packages/orwell/advtrains/) | pending audit |
| [Goblins](https://content.luanti.org/packages/FreeLikeGNU/goblins/) | pending audit |
| [MineClone 2 Decorations](https://content.luanti.org/packages/EmoryNB/mcl_decor/) | pending audit; likely belongs in the Mineclonia pack |
| [Techage Modpack](https://content.luanti.org/packages/joe7575/techage_modpack/) | pending audit |
| [VoxeLibre](https://content.luanti.org/packages/Wuzzy/mineclone2/) | pinned; per-file audit of 72 uncovered terrain candidates pending |
| [Asuna](https://content.luanti.org/packages/EmptyStar/asuna/) | pinned; provenance-filtered per-mod audit pending |
| [Minetest Game](https://content.luanti.org/packages/Luanti/minetest_game/) | pinned; 87-texture terrain re-bake pending |
| [Backrooms Test](https://content.luanti.org/packages/Sumianvoice/backroomtest/) | release 36294 audited CC-BY-4.0; terrain/billboard/item/model manifests ready |
| [Age of Mending](https://content.luanti.org/packages/Sumianvoice/pmb_core/) | release 38636 audited CC-BY-4.0; terrain/billboard/item/model manifests ready |
| [Hand Painted Pack](https://content.luanti.org/packages/drummyfish/drummyfish/) | release 834 audited CC0; texture-pack intake manifest ready |
| [Hand Painted Expanded](https://content.luanti.org/packages/shaft/hand_painted_expanded/) | release 35538 audited CC0; texture-pack intake manifest ready |
| [Soothing 32](https://content.luanti.org/packages/Zughy/soothing32/) | release 30230 audited CC-BY-SA-4.0; texture-pack intake manifest ready |
| [Baunilha](https://content.luanti.org/packages/Mirtilo/baunilha/) | release 37613 audited CC-BY-SA-4.0; texture-pack intake manifest ready |
| [RPG16](https://content.luanti.org/packages/Hugues%20Ross/rpg16/) | release 20357 audited CC-BY-SA-4.0; texture-pack intake manifest ready |
| [Less Dirt](https://content.luanti.org/packages/DrFrankenstone/lessdirt/) | release 13232 audited per-file CC-BY-SA; intake manifest ready |
| [Pixel Imperfection](https://content.luanti.org/packages/bramaudi/pixel_imperfection/) | release 35281 audited CC-BY-SA-4.0; texture-pack intake manifest ready |
| [Polygonia](https://content.luanti.org/packages/Lokrates/polygonia/) | pending: archive lacks its declared licence file |
| [Craft & Ruin](https://content.luanti.org/packages/GamingAssociation39/craft_and_ruin/) | excluded: GPL-3.0-only media |
| [Realism 512](https://content.luanti.org/packages/Horka/realism_512/) | excluded: EUPL-1.2 media |

The Your Land inventory used to prioritise this work is
<https://your-land.de/additional/yl_mods.txt>. Inclusion in that inventory is
not itself a licence or evidence that a texture is visible enough to benefit
from PBR processing.
