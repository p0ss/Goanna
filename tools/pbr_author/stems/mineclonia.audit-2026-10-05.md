# Mineclonia texture audit, 2026-10-05

Every PNG in the Mineclonia game's mods, checked against `stems/mineclonia.txt`
and `stems/mineclonia.mobs.txt`. The stem lists came from a block census of a
fresh world with no player, so built blocks, rarer blocks and everything a
player carries were missed.

How each texture is drawn was read from the game itself, not guessed from names:
a worldmod on a headless server (no client) dumped every registered item, node
and entity's tiles, overlay and special tiles, inventory and wield images and
entity textures, with the raw tile strings. A node's inventory image is
inventory only (Luanti draws the node, or its first tile, in the hand); a
craftitem's or tool's inventory image is the held and dropped item unless it has
its own wield image. Textures in no definition were looked up in the Lua: set at
runtime (clock and compass frames, candle overlays, worn armour, decorated pot
faces), HUD, formspec, particle, sky, or not referenced at all.

The client reads companions for a node face from the image before the first `^`
only, and for an item or entity composites a plain `^` stack with colour
modifiers but nothing with `[combine` or `[transform`; sprites take no
companions. Textures that only reach the screen through those routes were not
authored, since their maps would never be read or would sit rotated against the
art.

Later the same day the client learnt to compose companions for texture
expressions (docs/materials.md, "Companions of texture expressions"): an
overlay with its own maps on a node face, `[combine` parts and `[transform`
on node tiles and items alike. The three groups below that said otherwise
are marked as resolved; their textures can now be authored. Sprites still
take no companions.

Game: the Mineclonia installed in the Luanti flatpak on 2026-10-05, Luanti
5.17.0 server for the dump.

## Summary

| how it is drawn | outcome | count |
|---|---|---|
| HUD | dropped | 63 |
| blank | dropped | 1 |
| entity | authored | 9 |
| entity | not authored | 40 |
| entity | other agent | 11 |
| formspec | dropped | 131 |
| held | authored | 436 |
| held | not authored | 27 |
| held | other agent | 74 |
| inventory only | dropped | 9 |
| map marker | dropped | 1 |
| mob overlay | dropped | 2 |
| node tile | authored | 32 |
| node tile | not authored | 33 |
| node tile | other agent | 4 |
| param2 | dropped | 8 |
| particle | dropped | 141 |
| player skin | not authored | 26 |
| sign glyph | dropped | 441 |
| sky | dropped | 2 |
| unused | dropped | 128 |
| weather | dropped | 13 |
| worn | other agent | 220 |
| all unlisted textures | | 1852 |

Authored: 477 stems, each with a spec in `specs/mineclonia/`, built by
`extrude.py` and passing `extrude.check` and the release gate at 256 and 512 px.
They are not yet in `stems/mineclonia.txt` or `stems/mineclonia.classes.json`:
the list below is the stem list's lines, each with the class to freeze.

## Authored

- `3d_armor_stand_item` (mcl_armor_stand): held/dropped item; class wood.
- `axolotl_bucket` (mcl_buckets): held/dropped item; class metal.
- `bucket` (mcl_buckets): held/dropped item; class metal.
- `bucket_lava` (mcl_buckets): held/dropped item; class metal.
- `bucket_powder_snow` (mcl_powder_snow): held/dropped item; class metal.
- `bucket_river_water` (mcl_buckets): held/dropped item; class metal.
- `bucket_water` (mcl_buckets): held/dropped item; class metal.
- `cake` (mcl_cake): held/dropped item; class soil.
- `cod_bucket` (mcl_fishing): held/dropped item; class metal.
- `default_apple` (mcl_core): held/dropped item; class soil.
- `default_book` (mcl_books): held/dropped item; class wood.
- `default_clay_brick` (mcl_core): held/dropped item; class stone.
- `default_clay_lump` (mcl_core): held/dropped item; class soil.
- `default_coal_lump` (mcl_core): held/dropped item; class stone.
- `default_diamond` (mcl_core): held/dropped item; class stone.
- `default_flint` (mcl_core): held/dropped item; class stone.
- `default_gold_ingot` (mcl_core): held/dropped item; class metal.
- `default_gunpowder` (mcl_mobitems): held/dropped item; class sand.
- `default_paper` (mcl_core): held/dropped item; class wood.
- `default_steel_ingot` (mcl_core): held/dropped item; class metal.
- `default_stick` (mcl_core): held/dropped item; class wood.
- `default_torch_on_floor` (mcl_torches): held/dropped item; class wood.
- `doors_item_steel` (mcl_doors): held/dropped item; class metal.
- `doors_item_wood` (mcl_doors): held/dropped item; class wood.
- `extra_mobs_glow_ink_sac` (mcl_mobitems): held/dropped item; class soil.
- `farming_bread` (mcl_farming): held/dropped item; class soil.
- `farming_carrot` (mcl_farming): held/dropped item; class soil.
- `farming_carrot_gold` (mcl_farming): held/dropped item; class metal.
- `farming_cookie` (mcl_farming): held/dropped item; class soil.
- `farming_melon` (mcl_farming): held/dropped item; class soil.
- `farming_mushroom_stew` (mcl_mushrooms): held/dropped item; class wood.
- `farming_potato` (mcl_farming): held/dropped item; class soil.
- `farming_potato_baked` (mcl_farming): held/dropped item; class soil.
- `farming_potato_poison` (mcl_farming): held/dropped item; class soil.
- `farming_tool_diamondhoe` (mcl_farming): held/dropped item; class stone.
- `farming_tool_goldhoe` (mcl_farming): held/dropped item; class metal.
- `farming_tool_netheritehoe` (mcl_farming): held/dropped item; class metal.
- `farming_tool_steelhoe` (mcl_farming): held/dropped item; class metal.
- `farming_tool_stonehoe` (mcl_farming): held/dropped item; class stone.
- `farming_tool_woodhoe` (mcl_farming): held/dropped item; class wood.
- `farming_wheat_harvested` (mcl_farming): held/dropped item; class leaves.
- `jeija_commandblock_off` (mcl_commandblock): node tile (normal); class metal.
- `mcl_amethyst_amethyst_shard` (mcl_amethyst): held/dropped item; class stone.
- `mcl_armor_inv_boots_chain` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_boots_copper` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_boots_diamond` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_boots_gold` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_boots_iron` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_boots_leather` (mcl_armor): held/dropped item; class wood.
- `mcl_armor_inv_boots_netherite` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_chestplate_chain` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_chestplate_copper` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_chestplate_diamond` (mcl_armor): held/dropped item; class
  metal.
- `mcl_armor_inv_chestplate_gold` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_chestplate_iron` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_chestplate_leather` (mcl_armor): held/dropped item; class wood.
- `mcl_armor_inv_chestplate_netherite` (mcl_armor): held/dropped item; class
  metal.
- `mcl_armor_inv_elytra` (mcl_armor): held/dropped item; class wood.
- `mcl_armor_inv_helmet_chain` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_helmet_copper` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_helmet_diamond` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_helmet_gold` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_helmet_iron` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_helmet_leather` (mcl_armor): held/dropped item; class wood.
- `mcl_armor_inv_helmet_netherite` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_leggings_chain` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_leggings_copper` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_leggings_diamond` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_leggings_gold` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_leggings_iron` (mcl_armor): held/dropped item; class metal.
- `mcl_armor_inv_leggings_leather` (mcl_armor): held/dropped item; class wood.
- `mcl_armor_inv_leggings_netherite` (mcl_armor): held/dropped item; class
  metal.
- `mcl_bamboo_bamboo_inv` (mcl_bamboo): held/dropped item; class leaves.
- `mcl_bamboo_door_wield` (mcl_bamboo): held/dropped item; class wood.
- `mcl_beds_bed_black_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_blue_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_brown_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_cyan_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_green_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_grey_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_light_blue_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_lime_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_magenta_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_orange_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_pink_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_purple_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_red_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_silver_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_white_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_beds_bed_yellow_inv` (mcl_beds): held/dropped item; class wood.
- `mcl_bone_meal_bone_meal` (mcl_bone_meal): held/dropped item; class sand.
- `mcl_books_book_writable` (mcl_books): held/dropped item; class wood.
- `mcl_books_book_written` (mcl_books): held/dropped item; class wood.
- `mcl_brewing_stand_inv` (mcl_brewing): held/dropped item; class stone.
- `mcl_candles_item` (mcl_candles): held/dropped item; class wood.
- `mcl_candles_item_black` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_blue` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_brown` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_cyan` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_green` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_grey` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_light_blue` (mcl_candles): held (wield_overlay set in item
  meta); class wood.
- `mcl_candles_item_lime` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_magenta` (mcl_candles): held (wield_overlay set in item
  meta); class wood.
- `mcl_candles_item_orange` (mcl_candles): held (wield_overlay set in item
  meta); class wood.
- `mcl_candles_item_pink` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_purple` (mcl_candles): held (wield_overlay set in item
  meta); class wood.
- `mcl_candles_item_red` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_silver` (mcl_candles): held (wield_overlay set in item
  meta); class wood.
- `mcl_candles_item_white` (mcl_candles): held (wield_overlay set in item meta);
  class wood.
- `mcl_candles_item_yellow` (mcl_candles): held (wield_overlay set in item
  meta); class wood.
- `mcl_cauldrons_cauldron` (mcl_cauldrons): held/dropped item; class metal.
- `mcl_charges_wind_charge` (mcl_charges): held/dropped item; class glass.
- `mcl_cherry_blossom_door_inv` (mcl_cherry_blossom): held/dropped item; class
  wood.
- `mcl_clock_clock_00` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_01` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_02` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_03` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_04` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_05` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_06` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_07` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_08` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_09` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_10` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_11` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_12` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_13` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_14` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_15` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_16` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_17` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_18` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_19` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_20` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_21` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_22` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_23` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_24` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_25` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_26` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_27` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_28` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_29` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_30` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_31` (mcl_clock): held/dropped item; class metal.
- `mcl_clock_clock_32` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_33` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_34` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_35` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_36` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_37` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_38` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_39` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_40` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_41` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_42` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_43` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_44` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_45` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_46` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_47` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_48` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_49` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_50` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_51` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_52` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_53` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_54` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_55` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_56` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_57` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_58` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_59` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_60` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_61` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_62` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_clock_clock_63` (mcl_clock): held (frame set in item meta); class metal.
- `mcl_cocoas_cocoa_beans` (mcl_cocoas): held/dropped item; class soil.
- `mcl_comparators_item` (mcl_comparators): held/dropped item; class stone.
- `mcl_compass_compass_00` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_01` (mcl_compass): held/dropped item; class metal.
- `mcl_compass_compass_02` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_03` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_04` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_05` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_06` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_07` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_08` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_09` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_10` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_11` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_12` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_13` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_14` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_15` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_16` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_17` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_18` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_19` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_20` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_21` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_22` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_23` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_24` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_25` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_26` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_27` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_28` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_29` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_30` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_compass_31` (mcl_compass): held (frame set in item meta); class
  metal.
- `mcl_compass_recovery_compass_00` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_01` (mcl_compass): held/dropped item; class
  stone.
- `mcl_compass_recovery_compass_02` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_03` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_04` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_05` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_06` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_07` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_08` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_09` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_10` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_11` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_12` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_13` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_14` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_15` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_16` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_17` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_18` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_19` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_20` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_21` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_22` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_23` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_24` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_25` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_26` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_27` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_28` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_29` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_30` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_compass_recovery_compass_31` (mcl_compass): held (frame set in item
  meta); class stone.
- `mcl_copper_door` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_door_exposed` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_door_oxidized` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_door_weathered` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_ingot` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_lantern_exposed_inv` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_lantern_inv` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_lantern_oxidized_inv` (mcl_copper): held/dropped item; class
  metal.
- `mcl_copper_lantern_weathered_inv` (mcl_copper): held/dropped item; class
  metal.
- `mcl_copper_nugget` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_raw` (mcl_copper): held/dropped item; class stone.
- `mcl_copper_tool_axe` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_tool_hoe` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_tool_pick` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_tool_shovel` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_tool_sword` (mcl_copper): held/dropped item; class metal.
- `mcl_copper_torch` (mcl_copper): held/dropped item; class wood.
- `mcl_core_apple_golden` (mcl_core): held/dropped item; class metal.
- `mcl_core_bowl` (mcl_core): held/dropped item; class wood.
- `mcl_core_charcoal` (mcl_core): held/dropped item; class stone.
- `mcl_core_emerald` (mcl_core): held/dropped item; class stone.
- `mcl_core_gold_nugget` (mcl_core): held/dropped item; class metal.
- `mcl_core_iron_nugget` (mcl_core): held/dropped item; class metal.
- `mcl_core_lapis` (mcl_core): held/dropped item; class stone.
- `mcl_core_reeds` (mcl_core): held/dropped item; class leaves.
- `mcl_core_sugar` (mcl_core): held/dropped item; class sand.
- `mcl_crimson_crimson_door` (mcl_crimson): held/dropped item; class wood.
- `mcl_crimson_warped_door` (mcl_crimson): held/dropped item; class wood.
- `mcl_doors_door_acacia` (mcl_doors): held/dropped item; class wood.
- `mcl_doors_door_birch` (mcl_doors): held/dropped item; class wood.
- `mcl_doors_door_dark_oak` (mcl_doors): held/dropped item; class wood.
- `mcl_doors_door_jungle` (mcl_doors): held/dropped item; class wood.
- `mcl_doors_door_spruce` (mcl_doors): held/dropped item; class wood.
- `mcl_dye` (mcl_dyes): held/dropped item; class sand.
- `mcl_enchanting_book_enchanted` (mcl_enchanting): held/dropped item; class
  wood.
- `mcl_end_chorus_fruit` (mcl_end): held/dropped item; class soil.
- `mcl_end_chorus_fruit_popped` (mcl_end): held/dropped item; class soil.
- `mcl_end_crystal_item` (mcl_end): held/dropped item; class glass.
- `mcl_end_ender_eye` (mcl_end): entity + held; class stone.
- `mcl_experience_bottle` (mcl_experience): entity + held; class glass.
- `mcl_farming_beetroot` (mcl_farming): held/dropped item; class soil.
- `mcl_farming_beetroot_seeds` (mcl_farming): held/dropped item; class soil.
- `mcl_farming_beetroot_soup` (mcl_farming): held/dropped item; class wood.
- `mcl_farming_melon_seeds` (mcl_farming): held/dropped item; class soil.
- `mcl_farming_pumpkin_pie` (mcl_farming): held/dropped item; class soil.
- `mcl_farming_pumpkin_seeds` (mcl_farming): held/dropped item; class soil.
- `mcl_farming_sweet_berry` (mcl_farming): held/dropped item; class soil.
- `mcl_farming_wheat_seeds` (mcl_farming): held/dropped item; class soil.
- `mcl_fire_fire_charge` (mcl_fire): entity + held; class stone.
- `mcl_fire_flint_and_steel` (mcl_fire): held/dropped item; class metal.
- `mcl_fireworks_rocket` (mcl_fireworks): held/dropped item; class wood.
- `mcl_fishing_clownfish_raw` (mcl_fishing): held/dropped item; class soil.
- `mcl_fishing_fish_cooked` (mcl_fishing): held/dropped item; class soil.
- `mcl_fishing_fish_raw` (mcl_fishing): held/dropped item; class soil.
- `mcl_fishing_pufferfish_raw` (mcl_fishing): held/dropped item; class soil.
- `mcl_fishing_salmon_cooked` (mcl_fishing): held/dropped item; class soil.
- `mcl_fishing_salmon_raw` (mcl_fishing): held/dropped item; class soil.
- `mcl_flowerpots_flowerpot_inventory` (mcl_flowerpots): held/dropped item;
  class stone.
- `mcl_flowers_double_plant_fern_inv` (mcl_flowers): held/dropped item; class
  leaves.
- `mcl_flowers_double_plant_grass_inv` (mcl_flowers): held/dropped item; class
  leaves.
- `mcl_flowers_fern_inv` (mcl_flowers): held/dropped item; class leaves.
- `mcl_flowers_firefly_bush_inv` (mcl_flowers): held/dropped item; class leaves.
- `mcl_flowers_tallgrass_inv` (mcl_flowers): held/dropped item; class leaves.
- `mcl_honey_honey_bottle` (mcl_honey): held/dropped item; class glass.
- `mcl_honey_honeycomb` (mcl_honey): held/dropped item; class soil.
- `mcl_hoppers_item` (mcl_hoppers): held/dropped item; class metal.
- `mcl_jukebox_record_13` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_blocks` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_chirp` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_far` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_mall` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_mellohi` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_strad` (mcl_jukebox): held/dropped item; class stone.
- `mcl_jukebox_record_wait` (mcl_jukebox): held/dropped item; class stone.
- `mcl_lanterns_lantern_inv` (mcl_lanterns): held/dropped item; class metal.
- `mcl_lanterns_soul_lantern_inv` (mcl_lanterns): held/dropped item; class
  metal.
- `mcl_lush_caves_glow_berries` (mcl_lush_caves): held/dropped item; class soil.
- `mcl_mangrove_doors` (mcl_mangrove): held/dropped item; class wood.
- `mcl_maps_map_empty` (mcl_maps): held/dropped item; class wood.
- `mcl_maps_map_filled` (mcl_maps): held/dropped item; class wood.
- `mcl_maps_map_filled_markings` (mcl_maps): held/dropped item; class wood.
- `mcl_mobitems_beef_cooked` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_beef_raw` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_blaze_powder` (mcl_mobitems): held/dropped item; class sand.
- `mcl_mobitems_blaze_rod` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_bone` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_breeze_rod` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_bucket_milk` (mcl_mobitems): held/dropped item; class metal.
- `mcl_mobitems_chicken_cooked` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_chicken_raw` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_copper_horse_armor` (mcl_mobitems): held/dropped item; class
  metal.
- `mcl_mobitems_diamond_horse_armor` (mcl_mobitems): held/dropped item; class
  metal.
- `mcl_mobitems_feather` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_ghast_tear` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_gold_horse_armor` (mcl_mobitems): held/dropped item; class
  metal.
- `mcl_mobitems_heart_of_the_sea` (mcl_mobitems): held/dropped item; class
  stone.
- `mcl_mobitems_ink_sac` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_iron_horse_armor` (mcl_mobitems): held/dropped item; class
  metal.
- `mcl_mobitems_leather` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_leather_horse_armor` (mcl_mobitems): held/dropped item; class
  wood.
- `mcl_mobitems_magma_cream` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_mutton_cooked` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_mutton_raw` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_nametag` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_nautilus_shell` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_nether_star` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_porkchop_cooked` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_porkchop_raw` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_rabbit_cooked` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_rabbit_foot` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_rabbit_hide` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_rabbit_raw` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_rabbit_stew` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_rotten_flesh` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_saddle` (mcl_mobitems): held/dropped item; class wood.
- `mcl_mobitems_shulker_shell` (mcl_mobitems): held/dropped item; class stone.
- `mcl_mobitems_slimeball` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_spider_eye` (mcl_mobitems): held/dropped item; class soil.
- `mcl_mobitems_string` (mcl_mobitems): held/dropped item; class wood.
- `mcl_nether_glowstone_dust` (mcl_nether): held/dropped item; class sand.
- `mcl_nether_nether_wart` (mcl_nether): held/dropped item; class soil.
- `mcl_nether_netherbrick` (mcl_nether): held/dropped item; class stone.
- `mcl_nether_netherite_ingot` (mcl_nether): held/dropped item; class metal.
- `mcl_nether_netherite_scrap` (mcl_nether): held/dropped item; class stone.
- `mcl_nether_netherite_upgrade_template` (mcl_nether): held/dropped item; class
  stone.
- `mcl_nether_quartz` (mcl_nether): held/dropped item; class stone.
- `mcl_ocean_brain_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_brain_coral_fan` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_bubble_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_bubble_coral_fan` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_dead_brain_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_dead_brain_coral_fan` (mcl_ocean): node tile (plantlike_rooted);
  class leaves.
- `mcl_ocean_dead_bubble_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_dead_bubble_coral_fan` (mcl_ocean): node tile (plantlike_rooted);
  class leaves.
- `mcl_ocean_dead_fire_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_dead_fire_coral_fan` (mcl_ocean): node tile (plantlike_rooted);
  class leaves.
- `mcl_ocean_dead_horn_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_dead_horn_coral_fan` (mcl_ocean): node tile (plantlike_rooted);
  class leaves.
- `mcl_ocean_dead_tube_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_dead_tube_coral_fan` (mcl_ocean): node tile (plantlike_rooted);
  class leaves.
- `mcl_ocean_dried_kelp` (mcl_ocean): held/dropped item; class soil.
- `mcl_ocean_fire_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_fire_coral_fan` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_horn_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_horn_coral_fan` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_kelp_item` (mcl_ocean): held/dropped item; class leaves.
- `mcl_ocean_kelp_plant` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_prismarine_crystals` (mcl_ocean): held/dropped item; class stone.
- `mcl_ocean_prismarine_shard` (mcl_ocean): held/dropped item; class stone.
- `mcl_ocean_sea_pickle_1_anim` (mcl_ocean): node tile (plantlike_rooted) +
  held; class leaves.
- `mcl_ocean_sea_pickle_1_off` (mcl_ocean): node tile (plantlike_rooted) + held;
  class leaves.
- `mcl_ocean_sea_pickle_2_anim` (mcl_ocean): node tile (plantlike_rooted) +
  held; class leaves.
- `mcl_ocean_sea_pickle_2_off` (mcl_ocean): node tile (plantlike_rooted) + held;
  class leaves.
- `mcl_ocean_sea_pickle_3_anim` (mcl_ocean): node tile (plantlike_rooted) +
  held; class leaves.
- `mcl_ocean_sea_pickle_3_off` (mcl_ocean): node tile (plantlike_rooted) + held;
  class leaves.
- `mcl_ocean_sea_pickle_4_anim` (mcl_ocean): node tile (plantlike_rooted) +
  held; class leaves.
- `mcl_ocean_sea_pickle_4_off` (mcl_ocean): node tile (plantlike_rooted) + held;
  class leaves.
- `mcl_ocean_sea_pickle_item` (mcl_ocean): held/dropped item; class leaves.
- `mcl_ocean_seagrass` (mcl_ocean): node tile (plantlike_rooted); class leaves.
- `mcl_ocean_seagrass_item` (mcl_ocean): held/dropped item; class leaves.
- `mcl_ocean_tube_coral` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_ocean_tube_coral_fan` (mcl_ocean): node tile (plantlike_rooted); class
  leaves.
- `mcl_pale_oak_door_item` (mcl_pale_oak): held/dropped item; class wood.
- `mcl_pale_oak_resin_brick` (mcl_pale_oak): held/dropped item; class stone.
- `mcl_pale_oak_resin_clump` (mcl_pale_oak): held/dropped item; class soil.
- `mcl_potions_dragon_breath` (mcl_potions): held/dropped item; class glass.
- `mcl_potions_lingering_bottle` (mcl_potions): entity + held; class glass.
- `mcl_potions_melon_speckled` (mcl_potions): held/dropped item; class soil.
- `mcl_potions_ominous_potion` (mcl_potions): held/dropped item; class glass.
- `mcl_potions_potion_bottle` (mcl_potions): held/dropped item; class glass.
- `mcl_potions_potion_overlay` (mcl_potions): held/dropped item; class glass.
- `mcl_potions_spider_eye_fermented` (mcl_potions): held/dropped item; class
  soil.
- `mcl_potions_splash_bottle` (mcl_potions): entity + held; class glass.
- `mcl_potions_splash_overlay` (mcl_potions): entity + held; class glass.
- `mcl_pottery_sherds_angler` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_archer` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_arms_up` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_blade` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_brewer` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_burn` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_danger` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_explorer` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_flow` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_friend` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_guster` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_heart` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_heartbreak` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_howl` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_miner` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_mourner` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_plenty` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_prize` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_scrape` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_sheaf` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_shelter` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_skull` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_pottery_sherds_snort` (mcl_pottery_sherds): held/dropped item; class
  stone.
- `mcl_raw_ores_raw_gold` (mcl_raw_ores): held/dropped item; class stone.
- `mcl_raw_ores_raw_iron` (mcl_raw_ores): held/dropped item; class stone.
- `mcl_sculk_echo_shard` (mcl_sculk): held/dropped item; class stone.
- `mcl_signs_default_sign_greyscale` (mcl_signs): held/dropped item; class wood.
- `mcl_signs_hanging_sign_acacia_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_bamboo_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_birch_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_cherry_blossom_item` (mcl_signs): held/dropped item;
  class wood.
- `mcl_signs_hanging_sign_crimson_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_dark_oak_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_jungle_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_mangrove_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_oak_item` (mcl_signs): held/dropped item; class wood.
- `mcl_signs_hanging_sign_pale_oak_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_spruce_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_signs_hanging_sign_warped_item` (mcl_signs): held/dropped item; class
  wood.
- `mcl_spyglass` (mcl_spyglass): held/dropped item; class metal.
- `mcl_sus_nodes_brush` (mcl_sus_nodes): held/dropped item; class wood.
- `mcl_throwing_egg` (mcl_throwing): entity + held; class stone.
- `mcl_throwing_ender_pearl` (mcl_throwing): entity + held; class stone.
- `mcl_throwing_snowball` (mcl_throwing): entity + held; class snow.
- `mcl_totems_totem` (mcl_totems): held/dropped item; class metal.
- `mcl_totems_totem_wieldview` (mcl_totems): held/dropped item; class metal.
- `mcl_vaults_ominous_trial_key` (mcl_vaults): held/dropped item; class metal.
- `mcl_vaults_trial_key` (mcl_vaults): held/dropped item; class metal.
- `mesecons_delayer_item` (mcl_repeaters): held/dropped item; class stone.
- `mesecons_walllever_lever_inv` (mcl_lever): held/dropped item; class wood.
- `pufferfish_bucket` (mcl_fishing): held/dropped item; class metal.
- `redstone_redstone_dust` (mcl_redstone): held/dropped item; class sand.
- `respawn_anchor_top_on` (mcl_beds): node tile (normal); class stone.
- `salmon_bucket` (mcl_fishing): held/dropped item; class metal.
- `soul_torch_on_floor` (mcl_blackstone): held/dropped item; class wood.
- `spawn_egg` (mobs_mc): held/dropped item; class stone.
- `spawn_egg_overlay` (mobs_mc): held/dropped item; class stone.
- `sus_stew` (mcl_sus_stew): held/dropped item; class wood.
- `tropical_fish_bucket` (mcl_fishing): held/dropped item; class metal.

## Seen in the world, not authored

### A mask takes its skin part's companions (26)

A mask takes its skin part's companions.

- `mcl_skins_bottom_1_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_bottom_2_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_bottom_3_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_bottom_4_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_bottom_5_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_hair_10_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_hair_11_mask` (mcl_skins): player skin mask (the client gives it
  the part's companions).
- `mcl_skins_hair_1_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_2_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_3_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_4_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_5_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_6_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_7_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_8_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_hair_9_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_10_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_1_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_2_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_3_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_4_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_5_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_6_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_7_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_8_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).
- `mcl_skins_top_9_mask` (mcl_skins): player skin mask (the client gives it the
  part's companions).

### Admin or debug item (21)

Admin or debug item.

- `doc_identifier_identifier` (doc_identifier): held/dropped item.
- `doc_identifier_identifier_liquid` (doc_identifier): held/dropped item.
- `mcl_core_light_0` (mcl_core): held/dropped item.
- `mcl_core_light_1` (mcl_core): held/dropped item.
- `mcl_core_light_10` (mcl_core): held/dropped item.
- `mcl_core_light_11` (mcl_core): held/dropped item.
- `mcl_core_light_12` (mcl_core): held/dropped item.
- `mcl_core_light_13` (mcl_core): held/dropped item.
- `mcl_core_light_14` (mcl_core): held/dropped item.
- `mcl_core_light_2` (mcl_core): held/dropped item.
- `mcl_core_light_3` (mcl_core): held/dropped item.
- `mcl_core_light_4` (mcl_core): held/dropped item.
- `mcl_core_light_5` (mcl_core): held/dropped item.
- `mcl_core_light_6` (mcl_core): held/dropped item.
- `mcl_core_light_7` (mcl_core): held/dropped item.
- `mcl_core_light_8` (mcl_core): held/dropped item.
- `mcl_core_light_9` (mcl_core): held/dropped item.
- `mcl_core_void` (mcl_core): held/dropped item.
- `mcl_levelgen_schematic_border_checkers` (mcl_levelgen): entity.
- `mcl_levelgen_structure_void` (mcl_levelgen): held/dropped item.
- `mcl_unknown` (mobs_mc): held/dropped item.

### Colour mask (4)

Colour mask, takes the companions of the layer it masks.

- `mcl_dye_mask` (mcl_dyes): held/dropped item.
- `mcl_fences_fence_gate_mask` (mcl_fences): held/dropped item.
- `mcl_fences_fence_mask` (mcl_fences): held/dropped item.
- `mesecons_button_wield_mask` (mcl_buttons): held/dropped item.

### Drawn only after a ^ on a node face (7)

Drawn only after a ^ on a node face, where the client reads the base image's
companions.

Resolved 2026-10-05: an overlay with its own `_n` or `_s` now gets them where
it is drawn, composed over the base image's (GoannaTextureSource::
tileCompanion), and the redstone cross's line rotated by `[transformR90` gets
its maps turned with it. Author these by their own names, at the art's grid
(the composite takes the finer of the base's and the overlay's scales).

Authored 2026-10-05 (`seen_gaps.py`, "overlays"), tiles for
`stems/mineclonia.txt`: the nylium sides stand over the netherrack (the
warped side draws its own netherrack under the fringe, on netherrack's
rule), the comparator's front torch is unlit in compare mode and lit and
glowing in subtract mode as the "off" and "on" faces draw theirs, the slab
rows of the sides and ends take the base's materials, and the cross's
second line takes the first line's rule. Judged offline only.

- `crimson_nylium_side` (mcl_crimson): node tile (normal).
- `mcl_comparators_comp` (mcl_comparators): node tile (nodebox).
- `mcl_comparators_ends_sub` (mcl_comparators): node tile (nodebox).
- `mcl_comparators_sides_sub` (mcl_comparators): node tile (nodebox).
- `mcl_comparators_sub` (mcl_comparators): node tile (nodebox).
- `redstone_redstone_dust_line1` (mcl_redstone): node tile (nodebox).
- `warped_nylium_side` (mcl_crimson): node tile (normal).

### Flame on a burning entity (1)

Flame on a burning entity.

- `mcl_burning_entity_flame_animated` (mcl_fire): entity.

### Flame (3)

Flame, emissive cut-out animation.

- `fire_basic_flame_animated` (mcl_fire): node tile (firelike).
- `mcl_candles_flames` (mcl_candles): node tile (mesh).
- `soul_fire_basic_flame_animated` (mcl_blackstone): node tile (firelike).

### Held through [transform (3)

Held through [transform, which the client does not apply to companions.

Resolved 2026-10-05: the client transforms the companions as the art is
transformed, and turns the `_n` tangent with it (the table is in
docs/materials.md). Author these unrotated, as the inventory image draws them.

Authored 2026-10-05 (`seen_gaps.py`, "held"), tiles on the fishing rod's
materials, with the carrot's and the warped fungus's own. Judged offline
only.

- `mcl_mobitems_carrot_on_a_stick` (mcl_mobitems): held/dropped item.
- `mcl_mobitems_warped_fungus_on_a_stick` (mcl_mobitems): held/dropped item.
- `screwdriver` (screwdriver): held/dropped item.

### Laid into the chiseled bookshelf by [combine (6)

Laid into the chiseled bookshelf by [combine, which the client does not
composite.

Resolved 2026-10-05: each part's companions are placed at its offset in the
`[combine` canvas. Ship only the `_n` and `_s` of these and of
`mcl_books_chiseled_bookshelf_empty`: Luanti blits a `[combine` part at its
own size, so an albedo at map size shows only its top left corner in the 16
texel canvas (the pack as shipped does this to the empty shelf).

Authored 2026-10-05 (`seen_gaps.py`, "books"): leather spines a little
behind the shelf's frame, built by atlas.py with one face each at 16 map
pixels per texel, the empty shelf's density (extrude.py would make a 4
texel part 64 per texel, and the composed front would follow it to 1024
pixels). Maps only. In a node array the client sizes the layer by the
albedo, the 16 texel canvas, so these maps and the empty shelf's reach the
screen at 16 pixels until the client sizes a layer by its companions.
Judged offline only.

- `mcl_books_book_0` (mcl_books): node tile (normal).
- `mcl_books_book_1` (mcl_books): node tile (normal).
- `mcl_books_book_2` (mcl_books): node tile (normal).
- `mcl_books_book_3` (mcl_books): node tile (normal).
- `mcl_books_book_4` (mcl_books): node tile (normal).
- `mcl_books_book_5` (mcl_books): node tile (normal).

### Liquid (6)

Liquid, drawn by the lava shader; liquid, drawn by the water shader.

- `default_lava_flowing_animated` (mcl_core): node tile (flowingliquid) + held.
- `default_lava_source_animated` (mcl_core): node tile (liquid,nodebox).
- `default_river_water_flowing_animated` (mclx_core): node tile (flowingliquid).
- `default_river_water_source_animated` (mclx_core): node tile
  (allfaces_optional,liquid,nodebox).
- `default_water_flowing_animated` (mcl_core): node tile (flowingliquid) + held.
- `default_water_source_animated` (mcl_core): node tile
  (allfaces_optional,liquid,nodebox).

### Map item preview of the player model (2)

Map item preview of the player model.

- `character` (mcl_player): node tile (mesh).
- `mcl_skins_base_1_mask` (mcl_skins): node tile (mesh).

### Mesh entity (9)

Mesh entity, a model atlas for atlas.py and the mobs list.

Authored 2026-10-05 (`seen_gaps.py`, "entities"): the wind charge on
wind_charge.obj, the carved pumpkin and jack o'lantern on pumpkin_head.obj
(the head armour entity), the evoker's fangs, the llama's spit and the
plain villager on the villager base's spec. The conduit, the enchanting
table's book and the End crystal are end_objects.py's. Judged offline
only.

- `mcl_charges_wind_charge_entity` (mcl_charges): entity.
- `mcl_conduit_conduit` (mcl_conduits): entity.
- `mcl_enchanting_book_entity` (mcl_enchanting): entity.
- `mcl_end_crystal` (mcl_end): entity.
- `mcl_farming_pumpkin_face` (mcl_farming): entity.
- `mcl_farming_pumpkin_face_light` (mcl_farming): entity.
- `mobs_mc_evoker_fangs` (mobs_mc): entity.
- `mobs_mc_llama_spit` (mobs_mc): entity.
- `mobs_mc_villager` (mobs_mc): entity (mob skin on mobs_mc_villager.b3d).

### Portal (2)

Portal, starfield sheet; portal, translucent animated sheet.

- `mcl_portals_end_portal` (mcl_portals): node tile (nodebox,normal).
- `mcl_portals_portal` (mcl_portals): node tile (nodebox).

### Sprite or projectile nobody holds (6)

Sprite or projectile nobody holds.

- `mcl_end_crystal_beam` (mcl_end): entity.
- `mcl_experience_orb` (mcl_experience): entity.
- `mobs_mc_dragon_fireball` (mobs_mc): entity.
- `mobs_mc_shulkerbullet` (mobs_mc): entity.
- `mobs_mc_wither_projectile` (mobs_mc): entity.
- `mobs_mc_wither_projectile_strong` (mobs_mc): entity.

### The art draws no texel (6)

The art draws no texel.

- `mcl_sus_nodes_suspicious_overlay` (mcl_sus_nodes): node tile (normal).
- `mcl_sus_nodes_suspicious_overlay_1` (mcl_sus_nodes): node tile (normal).
- `mcl_sus_nodes_suspicious_overlay_2` (mcl_sus_nodes): node tile (normal).
- `mcl_sus_nodes_suspicious_overlay_3` (mcl_sus_nodes): node tile (normal).
- `xpanes_top_glass_magenta` (mcl_panes): node tile (nodebox).
- `xpanes_top_glass_pink` (mcl_panes): node tile (nodebox).

### Tinted shading overlay on grass sides (1)

Tinted shading overlay on grass sides.

- `mcl_dirt_grass_shadow` (mcl_core): node tile (normal).

### Upright sprite (23)

Upright sprite, which the client draws without companions.

- `mcl_pottery_sherds_pattern_angler` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_archer` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_arms_up` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_blade` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_brewer` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_burn` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_danger` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_explorer` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_flow` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_friend` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_guster` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_heart` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_heartbreak` (mcl_pottery_sherds): entity
  (decorated pot face, set_properties).
- `mcl_pottery_sherds_pattern_howl` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_miner` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_mourner` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_plenty` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_prize` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_scrape` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_sheaf` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_shelter` (mcl_pottery_sherds): entity (decorated
  pot face, set_properties).
- `mcl_pottery_sherds_pattern_skull` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).
- `mcl_pottery_sherds_pattern_snort` (mcl_pottery_sherds): entity (decorated pot
  face, set_properties).

### Another agent's families (309)

Another agent's families (boats, minecarts, worn armour, chests, bells, shields,
tridents, bows and arrows, item frames, paintings, banners, campfires, fishing
rods, the dragon head).

- `bolt_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `bolt_boots` (mcl_armor): worn or entity texture set at runtime.
- `bolt_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `bolt_helmet` (mcl_armor): worn or entity texture set at runtime.
- `bolt_leggings` (mcl_armor): worn or entity texture set at runtime.
- `boots_trim` (mcl_armor): worn or entity texture set at runtime.
- `chestplate_trim` (mcl_armor): worn or entity texture set at runtime.
- `coast_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `coast_boots` (mcl_armor): worn or entity texture set at runtime.
- `coast_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `coast_helmet` (mcl_armor): worn or entity texture set at runtime.
- `coast_leggings` (mcl_armor): worn or entity texture set at runtime.
- `dune_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `dune_boots` (mcl_armor): worn or entity texture set at runtime.
- `dune_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `dune_helmet` (mcl_armor): worn or entity texture set at runtime.
- `dune_leggings` (mcl_armor): worn or entity texture set at runtime.
- `eye_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `eye_boots` (mcl_armor): worn or entity texture set at runtime.
- `eye_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `eye_helmet` (mcl_armor): worn or entity texture set at runtime.
- `eye_leggings` (mcl_armor): worn or entity texture set at runtime.
- `flow_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `flow_boots` (mcl_armor): worn or entity texture set at runtime.
- `flow_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `flow_helmet` (mcl_armor): worn or entity texture set at runtime.
- `flow_leggings` (mcl_armor): worn or entity texture set at runtime.
- `helmet_trim` (mcl_armor): worn or entity texture set at runtime.
- `leggings_trim` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_chain` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_copper` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_diamond` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_gold` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_iron` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_leather` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_boots_leather_desat` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_boots_netherite` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_broken_elytra` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_chestplate_chain` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_chestplate_copper` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_chestplate_diamond` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_chestplate_gold` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_chestplate_iron` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_chestplate_leather` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_chestplate_leather_desat` (mcl_armor): worn or entity texture set
  at runtime.
- `mcl_armor_chestplate_netherite` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_elytra` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_chain` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_copper` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_diamond` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_gold` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_iron` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_leather` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_helmet_leather_desat` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_helmet_netherite` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_inv_boots_leather_desat` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_inv_chestplate_leather_desat` (mcl_armor): worn or entity texture
  set at runtime.
- `mcl_armor_inv_helmet_leather_desat` (mcl_armor): worn or entity texture set
  at runtime.
- `mcl_armor_inv_leggings_leather_desat` (mcl_armor): worn or entity texture set
  at runtime.
- `mcl_armor_leggings_chain` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_leggings_copper` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_leggings_diamond` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_leggings_gold` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_leggings_iron` (mcl_armor): worn or entity texture set at runtime.
- `mcl_armor_leggings_leather` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_leggings_leather_desat` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_armor_leggings_netherite` (mcl_armor): worn or entity texture set at
  runtime.
- `mcl_banners_banner_base` (mcl_banners): entity.
- `mcl_banners_base` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_base_inverted` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_border` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_bricks` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_circle` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_creeper` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_cross` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_curly_border` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_diagonal_left` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_diagonal_right` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_diagonal_up_left` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_diagonal_up_right` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_flow` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_flower` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_globe` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_gradient` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_gradient_up` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_guster` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_half_horizontal` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_half_horizontal_bottom` (mcl_banners): worn or entity texture set
  at runtime.
- `mcl_banners_half_vertical` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_half_vertical_right` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_item_base_48` (mcl_banners): held/dropped item.
- `mcl_banners_item_overlay_48` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_bricks` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_creeper` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_curly_border` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_flow` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_flower` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_globe` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_guster` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_piglin` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_skull` (mcl_banners): held/dropped item.
- `mcl_banners_pattern_thing` (mcl_banners): held/dropped item.
- `mcl_banners_piglin` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_rhombus` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_skull` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_small_stripes` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_square_bottom_left` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_square_bottom_right` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_square_top_left` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_square_top_right` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_straight_cross` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_bottom` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_center` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_downleft` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_downright` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_left` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_middle` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_right` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_stripe_top` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_thing` (mcl_banners): worn or entity texture set at runtime.
- `mcl_banners_triangle_bottom` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_triangle_top` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_triangles_bottom` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_banners_triangles_top` (mcl_banners): worn or entity texture set at
  runtime.
- `mcl_bells_bell` (mcl_bells): held/dropped item.
- `mcl_bells_bell_uv_bell` (mcl_bells): entity.
- `mcl_boats_acacia_boat` (mcl_boats): held/dropped item.
- `mcl_boats_acacia_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_bamboo_boat` (mcl_boats): held/dropped item.
- `mcl_boats_bamboo_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_birch_boat` (mcl_boats): held/dropped item.
- `mcl_boats_birch_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_cherry_blossom_boat` (mcl_boats): held/dropped item.
- `mcl_boats_cherry_blossom_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_dark_oak_boat` (mcl_boats): held/dropped item.
- `mcl_boats_dark_oak_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_jungle_boat` (mcl_boats): held/dropped item.
- `mcl_boats_jungle_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_mangrove_boat` (mcl_boats): held/dropped item.
- `mcl_boats_mangrove_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_oak_boat` (mcl_boats): held/dropped item.
- `mcl_boats_oak_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_obsidian_boat` (mcl_boats): worn or entity texture set at runtime.
- `mcl_boats_pale_oak_boat` (mcl_boats): held/dropped item.
- `mcl_boats_pale_oak_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_spruce_boat` (mcl_boats): held/dropped item.
- `mcl_boats_spruce_chest_boat` (mcl_boats): held/dropped item.
- `mcl_boats_texture_acacia_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_bamboo_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_birch_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_cherry_blossom_boat` (mcl_boats): worn or entity texture
  set at runtime.
- `mcl_boats_texture_dark_oak_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_jungle_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_mangrove_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_oak_boat` (mcl_boats): entity.
- `mcl_boats_texture_obsidian_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_pale_oak_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_boats_texture_spruce_boat` (mcl_boats): worn or entity texture set at
  runtime.
- `mcl_bows_arrow` (mcl_bows): entity.
- `mcl_bows_arrow_back` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_arrow_front` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_arrow_inv` (mcl_bows): held/dropped item.
- `mcl_bows_arrow_overlay` (mcl_bows): entity.
- `mcl_bows_bow` (mcl_bows): held/dropped item.
- `mcl_bows_bow_0` (mcl_bows): held/dropped item.
- `mcl_bows_bow_1` (mcl_bows): held/dropped item.
- `mcl_bows_bow_2` (mcl_bows): held/dropped item.
- `mcl_bows_crossbow` (mcl_bows): held/dropped item.
- `mcl_bows_crossbow_0` (mcl_bows): held/dropped item.
- `mcl_bows_crossbow_1` (mcl_bows): held/dropped item.
- `mcl_bows_crossbow_2` (mcl_bows): held/dropped item.
- `mcl_bows_crossbow_3` (mcl_bows): held/dropped item.
- `mcl_bows_firework_blue` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_firework_green` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_firework_red` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_firework_white` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_firework_yellow` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_rocket` (mcl_bows): worn or entity texture set at runtime.
- `mcl_bows_rocket_particle` (mcl_bows): worn or entity texture set at runtime.
- `mcl_campfires_campfire_inv` (mcl_campfires): held/dropped item.
- `mcl_campfires_campfire_log_lit` (mcl_campfires): node tile (mesh).
- `mcl_campfires_log` (mcl_campfires): node tile (mesh).
- `mcl_campfires_particle_1` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_10` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_11` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_12` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_2` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_3` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_4` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_5` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_6` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_7` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_8` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_particle_9` (mcl_campfires): worn or entity texture set at
  runtime.
- `mcl_campfires_soul_campfire_inv` (mcl_campfires): held/dropped item.
- `mcl_campfires_soul_campfire_log_lit` (mcl_campfires): node tile (mesh).
- `mcl_chests_ender_present` (mcl_chests): worn or entity texture set at
  runtime.
- `mcl_chests_noise` (mcl_chests): worn or entity texture set at runtime.
- `mcl_chests_noise_double` (mcl_chests): worn or entity texture set at runtime.
- `mcl_chests_normal_double` (mcl_chests): worn or entity texture set at
  runtime.
- `mcl_chests_normal_double_present` (mcl_chests): worn or entity texture set at
  runtime.
- `mcl_chests_normal_present` (mcl_chests): worn or entity texture set at
  runtime.
- `mcl_chests_trapped_double` (mcl_chests): worn or entity texture set at
  runtime.
- `mcl_chests_trapped_double_present` (mcl_chests): worn or entity texture set
  at runtime.
- `mcl_chests_trapped_present` (mcl_chests): worn or entity texture set at
  runtime.
- `mcl_copper_chestplate_copper` (mcl_copper): worn or entity texture set at
  runtime.
- `mcl_copper_helmet_copper` (mcl_copper): worn or entity texture set at
  runtime.
- `mcl_copper_leggings_copper` (mcl_copper): worn or entity texture set at
  runtime.
- `mcl_fishing_bobber` (mcl_fishing): entity.
- `mcl_fishing_fishing_rod` (mcl_fishing): held/dropped item.
- `mcl_heads_dragon` (mcl_heads): node tile (mesh). Authored 2026-10-05
  (`seen_gaps.py`, "dragon") by atlas.py on mcl_heads_dragon_floor.obj, on
  the ender dragon's materials.
- `mcl_inventory_empty_armor_slot_shield` (mcl_inventory): worn or entity
  texture set at runtime.
- `mcl_itemframes_glow_item_frame` (mcl_itemframes): held/dropped item.
- `mcl_itemframes_invisible_glow_item_frame` (mcl_itemframes): held/dropped
  item.
- `mcl_itemframes_invisible_item_frame` (mcl_itemframes): held/dropped item.
- `mcl_itemframes_item_frame` (mcl_itemframes): held/dropped item.
- `mcl_loom_itemslot_bg_banner` (mcl_loom): worn or entity texture set at
  runtime.
- `mcl_minecarts_minecart` (mcl_minecarts): entity.
- `mcl_minecarts_minecart_chest` (mcl_minecarts): held/dropped item.
- `mcl_minecarts_minecart_command_block` (mcl_minecarts): held/dropped item.
- `mcl_minecarts_minecart_furnace` (mcl_minecarts): held/dropped item.
- `mcl_minecarts_minecart_hopper` (mcl_minecarts): held/dropped item.
- `mcl_minecarts_minecart_normal` (mcl_minecarts): held/dropped item.
- `mcl_minecarts_minecart_tnt` (mcl_minecarts): held/dropped item.
- `mcl_paintings_frame` (mcl_paintings): entity.
- `mcl_paintings_painting` (mcl_paintings): held/dropped item.
- `mcl_paintings_painting_ancient_octopus` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_balding_man` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_battle_axe` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_blue_banner` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_butcher_knives` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_cooking_utensils` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_decorative_swords` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_dense_jungle_forest` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_desert_castle` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_elf_utopia` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_endless_dunes` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_froggy_pond` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_gloom_mountain` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_green_banner` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_green_bottles` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_moonshine_tundra` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_mountain_tower` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_notes` (mcl_paintings): worn or entity texture set at
  runtime.
- `mcl_paintings_painting_poster` (mcl_paintings): worn or entity texture set at
  runtime.
- `mcl_paintings_painting_quest_board` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_sarmatian_decoration` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_snowy_mountain` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_support_truss` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_viking_shield` (mcl_paintings): worn or entity texture
  set at runtime.
- `mcl_paintings_painting_volendam_costume` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_paintings_painting_waterfall_bridge` (mcl_paintings): worn or entity
  texture set at runtime.
- `mcl_potions_arrow_inv` (mcl_potions): held/dropped item.
- `mcl_shield_48` (mcl_shields): held/dropped item.
- `mcl_shield_base_nopattern` (mcl_shields): entity.
- `mcl_shield_hud` (mcl_shields): worn or entity texture set at runtime.
- `mcl_shield_pattern_base` (mcl_shields): worn or entity texture set at
  runtime.
- `mcl_tridents_trident_entity` (mcl_tridents): entity + held.
- `mcl_tridents_trident_entity_clip` (mcl_tridents): entity.
- `rib_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `rib_boots` (mcl_armor): worn or entity texture set at runtime.
- `rib_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `rib_helmet` (mcl_armor): worn or entity texture set at runtime.
- `rib_leggings` (mcl_armor): worn or entity texture set at runtime.
- `sentry_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `sentry_boots` (mcl_armor): worn or entity texture set at runtime.
- `sentry_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `sentry_helmet` (mcl_armor): worn or entity texture set at runtime.
- `sentry_leggings` (mcl_armor): worn or entity texture set at runtime.
- `silence_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `silence_boots` (mcl_armor): worn or entity texture set at runtime.
- `silence_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `silence_helmet` (mcl_armor): worn or entity texture set at runtime.
- `silence_leggings` (mcl_armor): worn or entity texture set at runtime.
- `snout_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `snout_boots` (mcl_armor): worn or entity texture set at runtime.
- `snout_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `snout_helmet` (mcl_armor): worn or entity texture set at runtime.
- `snout_leggings` (mcl_armor): worn or entity texture set at runtime.
- `spire_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `spire_boots` (mcl_armor): worn or entity texture set at runtime.
- `spire_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `spire_helmet` (mcl_armor): worn or entity texture set at runtime.
- `spire_leggings` (mcl_armor): worn or entity texture set at runtime.
- `tide_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `tide_boots` (mcl_armor): worn or entity texture set at runtime.
- `tide_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `tide_helmet` (mcl_armor): worn or entity texture set at runtime.
- `tide_leggings` (mcl_armor): worn or entity texture set at runtime.
- `vex_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `vex_boots` (mcl_armor): worn or entity texture set at runtime.
- `vex_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `vex_helmet` (mcl_armor): worn or entity texture set at runtime.
- `vex_leggings` (mcl_armor): worn or entity texture set at runtime.
- `ward_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `ward_boots` (mcl_armor): worn or entity texture set at runtime.
- `ward_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `ward_helmet` (mcl_armor): worn or entity texture set at runtime.
- `ward_leggings` (mcl_armor): worn or entity texture set at runtime.
- `wayfinder_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `wayfinder_boots` (mcl_armor): worn or entity texture set at runtime.
- `wayfinder_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `wayfinder_helmet` (mcl_armor): worn or entity texture set at runtime.
- `wayfinder_leggings` (mcl_armor): worn or entity texture set at runtime.
- `wild_armor_trim_smithing_template` (mcl_armor): held/dropped item.
- `wild_boots` (mcl_armor): worn or entity texture set at runtime.
- `wild_chestplate` (mcl_armor): worn or entity texture set at runtime.
- `wild_helmet` (mcl_armor): worn or entity texture set at runtime.
- `wild_leggings` (mcl_armor): worn or entity texture set at runtime.

## Dropped: not drawn in the world

### HUD (63)

`awards_bg_default`, `awards_unknown`, `bubble`, `crack_anylength`,
`credits_bg`, `crosshair`, `freezing_1`, `freezing_2`, `freezing_3`,
`frozen_heart`, `hbarmor_bar`, `hbarmor_bgicon`, `hbarmor_icon`,
`hbhunger_bar_health_poison`, `hbhunger_bgicon`, `hbhunger_icon_health_poison`,
`hbhunger_icon_regen_poison`, `hudbars_bar_background`, `hudbars_bar_breath`,
`hudbars_bar_health`, `hudbars_bgicon_breath`, `hudbars_bgicon_health`,
`hudbars_icon_breath`, `hudbars_icon_health`, `hudbars_icon_regenerate`,
`mcl_base_textures_background`, `mcl_base_textures_background9`, `mcl_bossbars`,
`mcl_bossbars_empty`, `mcl_brewing_bubble_sprite`, `mcl_brewing_bubbles`,
`mcl_brewing_bubbles_active`, `mcl_burning_hud_flame_animated`,
`mcl_experience_bar`, `mcl_experience_bar_background`,
`mcl_farming_pumpkin_hud`, `mcl_hunger_bar_exhaustion`,
`mcl_hunger_bar_foodpoison`, `mcl_hunger_bar_saturation`,
`mcl_hunger_bgicon_exhaustion`, `mcl_hunger_bgicon_saturation`,
`mcl_hunger_icon_exhaustion`, `mcl_hunger_icon_foodpoison`,
`mcl_hunger_icon_saturation`, `mcl_inventory_hotbar`,
`mcl_inventory_hotbar_selected`, `mcl_maps_map_background`,
`mcl_maps_player_arrow`, `mcl_mobitems_heart_of_the_sea_split`,
`mcl_mobs_hud_vehicle_container`, `mcl_mobs_hud_vehicle_full`,
`mcl_mobs_hud_vehicle_half`, `mcl_offhand_slot`, `mcl_potions_blindness_hud`,
`mcl_potions_glow_waypoint`, `mcl_potions_icon_absorb`,
`mcl_potions_icon_regen_wither`, `mcl_potions_icon_wither`,
`mcl_spyglass_scope`, `mcl_wear_bar`, `mineclonia_icon`, `mineclonia_logo`,
`object_crosshair`.

### Blank placeholder (1)

`mobs_mc_empty`.

### Formspec or help (125)

`awards_progress_gray`, `awards_progress_green`, `beacon_achievement_icon`,
`craftguide_arrow`, `craftguide_book`, `craftguide_clear_icon`,
`craftguide_furnace`, `craftguide_next_icon`, `craftguide_prev_icon`,
`craftguide_search_icon`, `craftguide_shapeless`, `craftguide_zoomin_icon`,
`craftguide_zoomout_icon`, `crafting_creative_active`,
`crafting_creative_active_down`, `crafting_creative_bg`,
`crafting_creative_bg_dark`, `crafting_creative_inactive`,
`crafting_creative_inactive_down`, `crafting_creative_marker`,
`crafting_creative_next`, `crafting_creative_prev`, `crafting_creative_trash`,
`crafting_formspec_arrow`, `crafting_formspec_bg`, `custom_beacon_symbol_1`,
`custom_beacon_symbol_2`, `custom_beacon_symbol_3`, `custom_beacon_symbol_4`,
`default_furnace_fire_bg`, `default_furnace_fire_fg`, `doc_basics_build`,
`doc_basics_craft_grid`, `doc_basics_hotbar`, `doc_basics_inventory_detail`,
`doc_basics_items_dropped`, `doc_basics_light_test`, `doc_basics_light_torch`,
`doc_basics_liquids_nonrenewable`, `doc_basics_liquids_range`,
`doc_basics_liquids_renewable_1`, `doc_basics_liquids_renewable_2`,
`doc_basics_liquids_types`, `doc_basics_minimap_map`,
`doc_basics_minimap_radar`, `doc_basics_minimap_round`, `doc_basics_nodes`,
`doc_basics_players_sam`, `doc_basics_pointing`, `doc_basics_tools`,
`doc_basics_tools_mining`, `doc_button_icon_lores`, `gui_crafting_arrow`,
`gui_furnace_arrow_bg`, `gui_furnace_arrow_fg`, `mcl_achievements_button`,
`mcl_anvils_inventory_arrow`, `mcl_anvils_inventory_cross`,
`mcl_anvils_inventory_hammer`, `mcl_base_textures_button9`,
`mcl_base_textures_button9_pressed`, `mcl_biome_dispatch_transition_bkg`,
`mcl_book_book_empty_slot`, `mcl_books_book_bg`, `mcl_books_button9`,
`mcl_books_button9_pressed`, `mcl_brewing_bottle_bg`, `mcl_brewing_burner`,
`mcl_brewing_burner_active`, `mcl_brewing_fuel_bg`, `mcl_brewing_inventory`,
`mcl_craftguide_fuel`, `mcl_crafting_guide_craft`,
`mcl_crafting_table_inv_fill`, `mcl_enchanting_book_closed`,
`mcl_enchanting_book_open`, `mcl_enchanting_button`,
`mcl_enchanting_button_background`, `mcl_enchanting_button_hovered`,
`mcl_enchanting_button_off`, `mcl_enchanting_glyph_1`,
`mcl_enchanting_glyph_10`, `mcl_enchanting_glyph_11`, `mcl_enchanting_glyph_12`,
`mcl_enchanting_glyph_13`, `mcl_enchanting_glyph_14`, `mcl_enchanting_glyph_15`,
`mcl_enchanting_glyph_16`, `mcl_enchanting_glyph_17`, `mcl_enchanting_glyph_18`,
`mcl_enchanting_glyph_2`, `mcl_enchanting_glyph_3`, `mcl_enchanting_glyph_4`,
`mcl_enchanting_glyph_5`, `mcl_enchanting_glyph_6`, `mcl_enchanting_glyph_7`,
`mcl_enchanting_glyph_8`, `mcl_enchanting_glyph_9`,
`mcl_enchanting_lapis_background`, `mcl_enchanting_number_1`,
`mcl_enchanting_number_1_off`, `mcl_enchanting_number_2`,
`mcl_enchanting_number_2_off`, `mcl_enchanting_number_3`,
`mcl_enchanting_number_3_off`, `mcl_formspec_itemslot`,
`mcl_inventory_background9`, `mcl_inventory_bar`, `mcl_inventory_bar_fill`,
`mcl_inventory_button9`, `mcl_inventory_button9_pressed`,
`mcl_inventory_empty_armor_slot_boots`,
`mcl_inventory_empty_armor_slot_chestplate`,
`mcl_inventory_empty_armor_slot_helmet`,
`mcl_inventory_empty_armor_slot_leggings`, `mcl_loom_itemslot_bg_dye`,
`mcl_loom_itemslot_bg_pattern`, `mcl_player_settings`,
`mcl_raids_hero_of_the_village_icon`, `mcl_smithing_table_inventory`,
`mcl_smithing_table_inventory_hammer`, `mcl_smithing_table_inventory_trim_bg`,
`mcl_stacksize_button`, `mobs_mc_trading_formspec_bg`,
`mobs_mc_trading_formspec_disabled`.

### Formspec or help (skin editor) (6)

`mcl_skins_arrow`, `mcl_skins_button`, `mcl_skins_icons`,
`mcl_skins_select_overlay`, `mcl_skins_slim_arms`, `mcl_skins_thick_arms`.

### Inventory only (9)

`fire_basic_flame`, `mcl_copper_chain_exposed_inv`, `mcl_copper_chain_inv`,
`mcl_copper_chain_oxidized_inv`, `mcl_copper_chain_weathered_inv`,
`mcl_lanterns_chain_inv`, `mcl_tridents_trident_item`, `soul_fire_basic_flame`,
`twisting_vines`.

### Map marker (1)

`mcl_maps_player_dot`.

### Mob overlay set at runtime (charged creeper) (1)

`mobs_mc_creeper_charge`.

### Mob overlay set at runtime (enderman's block) (1)

`mobs_mc_enderman_cactus_background`.

### Param2 colour palette, never drawn as an image (8)

`beacon_beam_palette`, `mcl_candles_palette`, `mcl_core_palette_grass`,
`mcl_core_palette_grass_levelgen`, `mcl_core_palette_leaves`,
`mcl_dyes_palette`, `mcl_flowers_dry_vegetation_palette`,
`mcl_redstone_palette_power`.

### Particle (141)

`hbhunger_bar`, `hbhunger_icon`, `heart`, `mcl_charges_wind_burst_1`,
`mcl_cherry_blossom_particle`, `mcl_cherry_blossom_particle_1`,
`mcl_cherry_blossom_particle_2`, `mcl_cherry_blossom_particle_3`,
`mcl_copper_anti_oxidation_particle`, `mcl_core_crying_obsidian_tear`,
`mcl_core_mycelium_particle`, `mcl_end_chorus_flower_1`,
`mcl_end_chorus_flower_10`, `mcl_end_chorus_flower_2`,
`mcl_end_chorus_flower_3`, `mcl_end_chorus_flower_4`, `mcl_end_chorus_flower_5`,
`mcl_end_chorus_flower_6`, `mcl_end_chorus_flower_7`, `mcl_end_chorus_flower_8`,
`mcl_end_chorus_flower_9`, `mcl_lush_caves_big_dripleaf_side`,
`mcl_lush_caves_big_dripleaf_stem`, `mcl_lush_caves_big_dripleaf_tip`,
`mcl_lush_caves_big_dripleaf_top`, `mcl_lush_caves_dripleaf_stem`,
`mcl_lush_caves_small_dripleaf_side`,
`mcl_lush_caves_small_dripleaf_stem_bottom`,
`mcl_lush_caves_small_dripleaf_stem_top`, `mcl_lush_caves_small_dripleaf_top`,
`mcl_lush_caves_spore_blossom_particle`, `mcl_particles_angry_villager`,
`mcl_particles_bonemeal`, `mcl_particles_bubble`, `mcl_particles_crit`,
`mcl_particles_dragon_breath_1`, `mcl_particles_dragon_breath_2`,
`mcl_particles_dragon_breath_3`, `mcl_particles_droplet_bottle`,
`mcl_particles_effect`, `mcl_particles_fire_flame`,
`mcl_particles_instant_effect`, `mcl_particles_lava`, `mcl_particles_mob_death`,
`mcl_particles_nether_dust1`, `mcl_particles_nether_dust2`,
`mcl_particles_nether_dust3`, `mcl_particles_nether_portal`,
`mcl_particles_nether_portal_t`, `mcl_particles_note`, `mcl_particles_smoke`,
`mcl_particles_smoke_anim`, `mcl_particles_soul_fire_flame`,
`mcl_particles_sponge1`, `mcl_particles_sponge2`, `mcl_particles_sponge3`,
`mcl_particles_sponge4`, `mcl_particles_sponge5`, `mcl_particles_squid_ink`,
`mcl_particles_squid_ink_1`, `mcl_particles_squid_ink_2`,
`mcl_particles_teleport`, `mcl_particles_totem1`, `mcl_particles_totem2`,
`mcl_particles_totem3`, `mcl_particles_totem4`, `mcl_portals_particle1`,
`mcl_portals_particle2`, `mcl_portals_particle3`, `mcl_portals_particle4`,
`mcl_portals_particle5`, `mcl_potions_effect_absorbtion`,
`mcl_potions_effect_absorption`, `mcl_potions_effect_bad_luck`,
`mcl_potions_effect_bad_omen`, `mcl_potions_effect_blindness`,
`mcl_potions_effect_conduit_power`, `mcl_potions_effect_darkness`,
`mcl_potions_effect_dolphin_grace`, `mcl_potions_effect_fatigue`,
`mcl_potions_effect_fire_proof`, `mcl_potions_effect_food_poisoning`,
`mcl_potions_effect_glowing`, `mcl_potions_effect_haste`,
`mcl_potions_effect_health_boost`, `mcl_potions_effect_hero_of_village`,
`mcl_potions_effect_infested`, `mcl_potions_effect_invisible`,
`mcl_potions_effect_leaping`, `mcl_potions_effect_levitation`,
`mcl_potions_effect_luck`, `mcl_potions_effect_nausea`,
`mcl_potions_effect_night_vision`, `mcl_potions_effect_oozing`,
`mcl_potions_effect_poisoned`, `mcl_potions_effect_regenerating`,
`mcl_potions_effect_regeneration`, `mcl_potions_effect_resistance`,
`mcl_potions_effect_saturation`, `mcl_potions_effect_slow`,
`mcl_potions_effect_slow_falling`, `mcl_potions_effect_strong`,
`mcl_potions_effect_swift`, `mcl_potions_effect_trial_omen`,
`mcl_potions_effect_water_breathing`, `mcl_potions_effect_weak`,
`mcl_potions_effect_weaving`, `mcl_potions_effect_withering`,
`mcl_pottery_sherds_pot_1`, `mcl_pottery_sherds_pot_10`,
`mcl_pottery_sherds_pot_2`, `mcl_pottery_sherds_pot_3`,
`mcl_pottery_sherds_pot_4`, `mcl_pottery_sherds_pot_5`,
`mcl_pottery_sherds_pot_6`, `mcl_pottery_sherds_pot_7`,
`mcl_pottery_sherds_pot_8`, `mcl_pottery_sherds_pot_9`, `mcl_tnt_blink`,
`mobs_blood`, `mobs_mc_arrow_particle`, `mobs_mc_wolf_icon_roam`,
`mobs_mc_wolf_icon_sit`, `mobs_mc_wolf_splash_0`, `mobs_mc_wolf_splash_1`,
`mobs_mc_wolf_splash_2`, `mobs_mc_wolf_splash_3`, `smoke_puff`,
`testpathfinder_waypoint`, `testpathfinder_waypoint_end`,
`testpathfinder_waypoint_start`, `trialspawner_blue_bar_particles.1`,
`trialspawner_blue_bar_particles.2`, `trialspawner_blue_dot_particle`,
`trialspawner_orange_bar_particles.1`, `trialspawner_orange_bar_particles.2`,
`weather_pack_snow_snowflake1`, `weather_pack_snow_snowflake2`,
`weather_pack_snow_snowflake3`, `weather_pack_snow_snowflake4`,
`weather_pack_snow_snowflake5`.

### Sign glyph (441)

Every glyph and character image in `mcl_signs/textures` (names starting with
`_`), 441 files.

### Sky (2)

`mcl_moon_moon_phases`, `mcl_playerplus_end_sky`.

### Unused (no reference in the Lua) (70)

`crimson_stem_stripped_side`, `crimson_stem_stripped_top`,
`extra_mobs_glow_squid_glint1`, `extra_mobs_glow_squid_glint2`,
`extra_mobs_glow_squid_glint3`, `extra_mobs_glow_squid_glint4`,
`farming_pumpkin_side_small`, `jeija_commandblock_on`, `mcl_anvils_inventory`,
`mcl_bamboo_bamboo_sign`, `mcl_bamboo_bamboo_sign_wield`,
`mcl_bamboo_door_bottom_alt`, `mcl_bamboo_door_top_alt`, `mcl_bamboo_endcap`,
`mcl_bamboo_flower_pot`, `mcl_blackstone_gilded_side`,
`mcl_books_chiseled_bookshelf_full`, `mcl_charges_wind_burst_2`,
`mcl_cherry_blossom_door_bottom_bottompart`,
`mcl_cherry_blossom_door_top_toppart`, `mcl_cherry_blossom_pink_petals_inv`,
`mcl_copper_inv_boots_copper`, `mcl_copper_inv_chestplate_copper`,
`mcl_copper_inv_helmet_copper`, `mcl_copper_inv_leggings_copper`,
`mcl_copper_top`, `mcl_copper_top_exposed`, `mcl_copper_top_oxidized`,
`mcl_core_crying_obsidian_tear2`, `mcl_core_crying_obsidian_tear3`,
`mcl_crimson_crimson_fence_side`, `mcl_crimson_crimson_fence_top`,
`mcl_crimson_warped_fence_side`, `mcl_crimson_warped_fence_top`,
`mcl_doors_door_crimson_side_lower`, `mcl_doors_door_warped_side_lower`,
`mcl_end_endframe_eye`, `mcl_end_endframe_side`, `mcl_end_endframe_top`,
`mcl_fences_fence_gate_acacia`, `mcl_fences_fence_gate_birch`,
`mcl_fences_fence_gate_jungle`, `mcl_fences_fence_gate_oak`,
`mcl_fences_fence_gate_red_nether_brick`, `mcl_fences_fence_gate_spruce`,
`mcl_flowers_double_plant_sunflower_top`, `mcl_honey_block_bottom`,
`mcl_honey_block_top`, `mcl_jukebox_record_11`, `mcl_jukebox_record_cat`,
`mcl_jukebox_record_stal`, `mcl_jukebox_record_ward`,
`mcl_levelgen_structure_block_side`, `mcl_levelgen_structure_block_top`,
`mcl_lush_caves_cave_vines_plant`, `mcl_lush_caves_cave_vines_plant_lit`,
`mcl_lush_caves_moss`, `mcl_lush_caves_moss_carpet_side`,
`mcl_mobitems_leather_horse_armor_desat`, `mcl_potions_effect_wind_charged`,
`mcl_pottery_sherds`, `mcl_stairs_turntexture`, `mcl_vaults_vault_top_unlock`,
`mobs_mc_TEMP_wither_projectile`, `mobs_mc_helmet_mask`, `nether_wart_block`,
`stripped_crimson_stem`, `stripped_warped_stem`, `warped_stem_stripped_side`,
`warped_stem_stripped_top`.

### Unused (only with mcl_old_spawn_icons, off by default) (52)

`mobs_chicken_egg`, `mobs_mc_spawn_icon_bat`, `mobs_mc_spawn_icon_blaze`,
`mobs_mc_spawn_icon_cat`, `mobs_mc_spawn_icon_cave_spider`,
`mobs_mc_spawn_icon_chicken`, `mobs_mc_spawn_icon_cod`,
`mobs_mc_spawn_icon_cow`, `mobs_mc_spawn_icon_creeper`,
`mobs_mc_spawn_icon_donkey`, `mobs_mc_spawn_icon_dragon`,
`mobs_mc_spawn_icon_enderman`, `mobs_mc_spawn_icon_endermite`,
`mobs_mc_spawn_icon_evoker`, `mobs_mc_spawn_icon_ghast`,
`mobs_mc_spawn_icon_guardian`, `mobs_mc_spawn_icon_guardian_elder`,
`mobs_mc_spawn_icon_horse`, `mobs_mc_spawn_icon_horse_skeleton`,
`mobs_mc_spawn_icon_horse_zombie`, `mobs_mc_spawn_icon_husk`,
`mobs_mc_spawn_icon_illusioner`, `mobs_mc_spawn_icon_iron_golem`,
`mobs_mc_spawn_icon_killer_bunny`, `mobs_mc_spawn_icon_llama`,
`mobs_mc_spawn_icon_magmacube`, `mobs_mc_spawn_icon_mooshroom`,
`mobs_mc_spawn_icon_mule`, `mobs_mc_spawn_icon_parrot`,
`mobs_mc_spawn_icon_pig`, `mobs_mc_spawn_icon_polarbear`,
`mobs_mc_spawn_icon_rabbit`, `mobs_mc_spawn_icon_salmon`,
`mobs_mc_spawn_icon_sheep`, `mobs_mc_spawn_icon_shulker`,
`mobs_mc_spawn_icon_silverfish`, `mobs_mc_spawn_icon_skeleton`,
`mobs_mc_spawn_icon_slime`, `mobs_mc_spawn_icon_snowman`,
`mobs_mc_spawn_icon_spider`, `mobs_mc_spawn_icon_squid`,
`mobs_mc_spawn_icon_stray`, `mobs_mc_spawn_icon_vex`,
`mobs_mc_spawn_icon_villager`, `mobs_mc_spawn_icon_vindicator`,
`mobs_mc_spawn_icon_witch`, `mobs_mc_spawn_icon_wither`,
`mobs_mc_spawn_icon_witherskeleton`, `mobs_mc_spawn_icon_wolf`,
`mobs_mc_spawn_icon_zombie`, `mobs_mc_spawn_icon_zombie_pigman`,
`mobs_mc_spawn_icon_zombie_villager`.

### Unused (registration commented out) (6)

`mcl_sculk_sensor_bottom`, `mcl_sculk_sensor_side`, `mcl_sculk_sensor_top`,
`mcl_sculk_shrieker_bottom`, `mcl_sculk_shrieker_side`,
`mcl_sculk_shrieker_top`.

### Weather (13)

`lightning_lightning_1`, `lightning_lightning_2`, `lightning_lightning_3`,
`mcl_copper_top_weathered`, `weather_pack_rain_raindrop_1`,
`weather_pack_rain_raindrop_2`, `weather_pack_rain_raindrop_3`,
`weather_pack_snow_snowflake10`, `weather_pack_snow_snowflake11`,
`weather_pack_snow_snowflake6`, `weather_pack_snow_snowflake7`,
`weather_pack_snow_snowflake8`, `weather_pack_snow_snowflake9`.
