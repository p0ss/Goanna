# Dark glass against the game theme

Captures of the two interface styles (`docs/interface-style.md`) side by
side, taken on 19 September 2026 from the live client. They are for judging
the look; this page says what was captured and measured, not whether it
looks good.

There were two rounds. The first, with `889ab24`, used reduced graphics. The
second, after the fixes that followed the first review, used `4d48e0b` with
Goanna's default graphics and replaced most of the first round's frames and
all of its numbers. The Minetest Game and main menu sheets could not be
recaptured (see "Not done"), so they are still the first round's.

## Conditions

Second round (`4d48e0b`):

- Godot 4.5.1, a 1600 by 900 window inside a headless gamescope (no window
  on the desktop, no input from it), and an NVIDIA RTX 3090. At 17:38:35 the
  GPU faulted (Xid 51) and refused every new Vulkan context from then on;
  the client used here had started 28 seconds earlier and kept rendering
  normally, so every capture below comes from that one client. A game on the
  same GPU held it at about 40 percent utilisation throughout, so no
  measurement here is on an idle GPU.
- A fresh profile holding only what Goanna writes on its first run, which is
  its default graphics: view range 12, far field 512, bounced light, screen
  space light and shadows at their defaults, and the player's body shown in
  first person (the arm in the snow, beach and chat frames).
- Luanti 5.17.0 (the Flatpak) server on a fresh Mineclonia world
  (`goanna_glass_sweep_mcl`), survival by default.
- A throwaway world mod (`goanna_glass_sweep`, kept with the session, not
  committed) built a snow field, a sand beach with a pool, a forest and a
  stone room lit by one torch in the sky above the origin, gave the player a
  spread of dark, mid and light items, and opened each form through the
  game's own code: a node's `on_rightclick` or its metadata form, an item's
  use callback, a villager's `on_rightclick`.
- Each screen was captured in dark glass, then switched to the game theme
  with the setting and captured again from the same pose.
- The mobs, holes in the snow and stray blocks are the live world (mobs
  spawned on the stage and the sweep placed nodes on it); they are not part
  of the change.

First round (`889ab24`): the same machine with the GPU not faulted but held
at 96 to 99 percent by machine learning jobs, a scratch profile with reduced
graphics (view range 8, no far field, no bounced light, smallest shadow
map), Mineclonia and Minetest Game worlds (`goanna_glass_mcl`,
`goanna_glass_mtg`) and an earlier version of the same world mod.

## Comparison sheets

Each sheet has the game theme on the left and dark glass on the right, over
a bright day (snow and sky at noon), a forest and a cave lit by one torch.
Full frames are in `frames/`, named `<screen>_<background>_<style>.jpg`.

Second round:

- [Mineclonia survival inventory](sheet_mcl_survival.jpg)
- [Mineclonia creative inventory](sheet_mcl_creative.jpg)
- [Mineclonia chest](sheet_mcl_chest.jpg)
- [Mineclonia furnace](sheet_mcl_furnace.jpg)
- [Mineclonia crafting table](sheet_mcl_table.jpg)
- [Goanna pause menu](sheet_pause.jpg)
- [Goanna in-game settings](sheet_settings.jpg)
- Chat open over the bright day, Mineclonia:
  [game theme](frames/chat_day_game.jpg),
  [dark glass](frames/chat_day_glass.jpg)

First round only, not recaptured:

- [Minetest Game inventory](sheet_mtg_inventory.jpg)
- [Goanna main menu](sheet_menu_main.jpg)
- [Goanna main menu settings](sheet_menu_settings.jpg)

These three show the first round's code: panes with the larger radius and a
rim only along the top, not the one pane every surface now shares.

What to look for, as the rule in `docs/interface-style.md` intends:

- The game's window art (Mineclonia's light grey panel, slot squares and
  creative tabs, the themed button panes) is replaced by glass; the item
  art, the empty armour slot outlines, the player model, the crafting and
  furnace arrows and flame, the recipe book and other image buttons, and the
  trash can are the game's own.
- The creative tabs are glass panes holding the game's own tab icons, with
  the selected tab ringed in the accent colour.
- Mineclonia's `#313131` labels ("Crafting", "Inventory", "Chest") are
  lifted to `#bababa` on glass.
- Forms, menus, chat, tooltips and the hotbar frame are one pane: the same
  12 pixel radius, rim and outline. The hotbar is clear glass (not frosted)
  with the selected slot ringed.

## Form sweep

Every Mineclonia form the sweep could reach, opened through the game's own
code with `4d48e0b` and captured in both styles. `sweep/<form>.jpg` has the
game theme on the left and dark glass on the right, cropped to the form.

| Form | Form name | Result in dark glass |
| --- | --- | --- |
| Survival inventory | (inventory) | Glass |
| Crafting guide | `mcl_craftguide` | Glass |
| Help | `doc:main` | Glass |
| Achievements | `awards:awards` | Glass |
| Player settings | `mcl_player:settings_formspec` | Glass; back arrow returns to the inventory |
| Skin editor | `mcl_skins:skins` | Glass; the selected category keeps the game's green |
| Chest | `mcl_chests:chest_*` | Glass |
| Furnace | `mcl_furnaces:furnace` | Glass |
| Blast furnace | `mcl_blast_furnace:blast_furnace` | Glass |
| Smoker | `mcl_smoker:smoker` | Glass |
| Crafting table | (inventory, `main`) | Glass |
| Enchanting table | `mcl_enchanting:table` | Glass; the parchment of offers is the game's |
| Anvil | `mcl_anvils:anvil` | Glass |
| Loom | `mcl_loom:loom` | Glass |
| Stonecutter | `mcl_stonecutter:stonecutter` | Glass |
| Smithing table | `mcl_smithing_table:table` | Glass |
| Grindstone | `mcl_grindstone:grindstone` | Glass |
| Brewing stand | `mcl_brewing:stand_000` | Glass; items now drawn over the stand art |
| Beacon | `mcl_beacons:beacon` | Glass; the power buttons are the game's |
| Hopper | `mcl_hoppers:hopper` | Glass |
| Dispenser | `mcl_dispensers:dispenser` | Glass |
| Dropper | `mcl_dispensers:dropper` | Glass |
| Barrel | `mcl_barrels:barrel_*` | Glass |
| Shulker box | `mcl_chests:*_shulker_box_small` | Glass |
| Ender chest | `mcl_chests:ender_chest_*` | Glass |
| Villager trading | `mobs_mc:trading_formspec` | Half at `4d48e0b`: the three trade slots stayed light grey; glass since `4a84bb4` |
| Written book | `mcl_books:written_book` | The game's own book, by the bespoke rule |
| Book and quill | `mcl_books:writable_book` | The game's own book, by the bespoke rule |
| Sign | | Not captured: the sweep could not open it |
| Creative, 12 item tabs | (inventory) | Glass tabs, selected tab ringed |
| Creative, rail tab | (inventory) | Half at `4d48e0b`: a row of empty slot art stayed light grey; glass since `4a84bb4` |
| Creative, survival tab | (inventory) | Glass |

The two halves were the same gap: slot art the game draws where no slot
exists (a tab with fewer items than its grid, the trade slots, which have no
list until a trade is chosen) was left as the game's art, because only art
under a real slot was recognised as a slot frame. `4a84bb4` draws such art
as an empty glass slot. It was checked live by reloading `formspec.gd` from
`4a84bb4` into the running client (the rest of the client was `4d48e0b`),
since no new client could be started: `sweep/villager_4a84bb4.jpg` and
`sweep/creative_rail_4a84bb4.jpg`, taken at night because the server's
clock had moved on.

The Minetest Game forms were not swept (see "Not done").

## Before and after

In `before_after/`:

- Player settings: `player_settings_5cfd7b9*` is the export built from
  `5cfd7b9`, before the glass style existed, where the back arrow left the
  form showing (and changed the player's settings on the server);
  `player_settings_fixed_*` is the code committed as `4d49d7c` in both
  styles, before and after pressing the arrow, which shows the inventory
  (the sweep's `player_settings` frames show the same form with `4d48e0b`). `player_settings_vanilla_luanti.jpg` is the vanilla Luanti
  5.17.0 client showing the same form. The vanilla client was not clicked:
  the two `player_settings_vanilla_after_*` frames are it after the server
  ran Mineclonia's own handler on the field set the vanilla client sends for
  the arrow (it returns to the inventory) and on the set Goanna used to send
  (it shows the settings form again).
- Crafting guide and survival inventory: `*_4d48e0b_*` are this round's
  frames. The only "before" for the crafting guide is the reviewer's
  screenshot, which came from the main checkout, not this branch; this
  branch drew it in glass in both rounds. `survival_inventory_889ab24_glass`
  is the first round's frame.

## Contrast

Measured with `measure.py` (kept with the session, not committed) on
captures in which the form's content was hidden and only the glass drawn,
so the pixels are the glass exactly as it lies behind text. Everything within
6 pixels of a pane's rounded edge (the rim hairline) is left out. The worst
background is the brightest glass pixel; contrast is WCAG 2's, for the
colours `glass_style.gd` draws. Each row is the lower of the Mineclonia
survival inventory and the in-game settings screen over that background.

| Background | Brightest glass | Interface text | Quiet text | `#313131` label, lifted | Hovered button | Count, slot | Count, hovered slot |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Snow at noon | 0.056 | 9.1:1 | 6.2:1 | 5.1:1 | 6.4:1 | 4.6:1 | 5.1:1 |
| Open sky at noon | 0.051 | 9.5:1 | 6.6:1 | 5.3:1 | 6.6:1 | 4.6:1 | 5.1:1 |
| Sand and water at noon | 0.054 | 9.3:1 | 6.4:1 | 5.2:1 | 6.5:1 | 4.6:1 | 5.1:1 |
| Forest at noon | 0.030 | 12.1:1 | 8.3:1 | 6.8:1 | 8.3:1 | 4.7:1 | 5.2:1 |
| Cave, one torch | 0.020 | 13.8:1 | 9.5:1 | 7.7:1 | 9.4:1 | 4.8:1 | 5.3:1 |
| Snow at midnight | 0.019 | 13.8:1 | 9.6:1 | 7.8:1 | 9.5:1 | 4.8:1 | 5.3:1 |

Over the 21 dark glass frames of the second round's sheets the brightest
glass was 0.054 and every figure stayed at or above the snow row. For the
creative inventory only the window's pane was measured: the tab panes were
hidden with the tabs in those captures, so their rectangles held the world,
not glass. The shader's bound is 0.07 (a 0.05 ceiling plus a 0.02 sheen at
the top of a pane), so none of these can fall below the worst case figures
in `docs/interface-style.md`. The contrast backgrounds are in `frames/`:
`contrast_world_*.jpg` (the world alone), `contrast_mcl_survival_*_glass.jpg`
and `contrast_mcl_survival_*_panes.jpg` (the glass alone, as measured). In
the snow and beach frames the player's arm covers the lower right of the
window; the rest of the window lies over snow or sand.

## Slot contents

The glass slot tile is darker than Mineclonia's (median relative luminance
0.16 to 0.17 against 0.34). For each item in the survival inventory, the
mean luminance of the item's pixels was compared with the tile around it,
in the game theme and in dark glass over the three backgrounds:

| Item | Game theme | Dark glass |
| --- | --- | --- |
| `mcl_wool:black` | 5.6 | 3.0 to 3.2 |
| `mcl_core:coal_lump` | 4.7 | 2.5 to 2.7 |
| `mcl_redstone:redstone` | 4.2 | 2.3 to 2.4 |
| `mcl_core:dirt` | 3.0 | 1.6 to 1.7 |
| `mcl_books:book` | 2.7 | 1.5 to 1.6 |
| `mcl_trees:tree_oak` | 2.6 | 1.4 to 1.5 |
| `mcl_torches:torch` | 2.4 | 1.4 to 1.4 |
| `mcl_core:apple` | 2.4 | 1.3 to 1.5 |
| `mcl_core:cobble` | 2.1 | 1.1 to 1.2 |
| `mcl_tools:pick_iron` | 2.0 | 1.1 to 1.2 |
| `mcl_core:stone` | 2.0 | 1.1 to 1.1 |
| `mcl_core:lapis` | 1.7 | 1.0 to 1.1 |
| `mcl_core:snowblock` | 1.5 | 2.6 to 2.8 |
| `mcl_core:diamond` | 1.3 | 2.2 to 2.4 |
| `mcl_wool:white` | 1.2 | 2.1 to 2.2 |
| `mcl_farming:bread` | 1.2 | 2.0 to 2.2 |
| `mcl_core:iron_ingot` | 1.1 | 1.6 to 1.7 |
| `mcl_core:gold_ingot` | 1.1 | 1.6 to 1.9 |
| `mcl_core:sand` | 1.1 | 1.6 to 1.8 |
| `mcl_tools:sword_diamond` | 1.1 | 1.7 to 1.8 |
| `mcl_nether:quartz` | 1.0 | 1.7 to 1.8 |

This is a crude measure: it ignores the dark outlines most item art has,
which is what separates an item from a tile of similar brightness. What it
does show is a trade, not an improvement: on the glass tile dark and mid
tone items stand out less than on Mineclonia's light grey, and light items
more. Slot contents are therefore not as readable as in Mineclonia's game
theme for 12 of these 21 items, and more readable for 9. A slot's count is
more legible on glass (4.6:1 or better, against about 3.4:1 on Mineclonia's
tile). Minetest Game's own slots are darker than the glass tile, so there
the comparison goes the other way; it was not measured.

## Cost

`viewport_get_measured_render_time_gpu`, the mean of 240 frames, with the
game theme and dark glass alternated four times in the same pose over the
bright day, default graphics:

| Case | Game theme | Dark glass | Difference |
| --- | --- | --- | --- |
| Mineclonia chest open | 6.38 ms | 6.45 ms | +0.07 ms |
| Mineclonia survival inventory open | 6.28 ms | 6.40 ms | +0.11 ms |
| Survival inventory with an item tooltip up | 6.32 ms | 6.41 ms | +0.09 ms |
| Pause menu open | 6.34 ms | 6.43 ms | +0.08 ms |
| No window open, hotbar only | 6.36 ms | 6.36 ms | +0.00 ms |

The chest's first game theme round (4.54 ms, the other load dropping for a
moment) is left out of its mean. The GPU was not idle (see "Conditions"),
and it had faulted before these were taken, so these are what the style
costs next to other work on a GPU in that state. An idle GPU was not
available and was not measured. In the first round, under heavier load and
reduced graphics, the differences were +0.07 to +0.10 ms with a window open,
and +0.36 ms for the chest with an earlier build under the heaviest load.

`measurements.json` holds the raw numbers for all of the above, and the first
round's under `first_round_889ab24`.

## Not done

- Minetest Game: neither the sweep of its forms nor a recapture of its
  inventory. Both needed a new client after the GPU fault.
- The main menu and its settings screen were not recaptured: they need a
  new client.
- The sign's text form was not opened: the sweep mod's command for it was
  added after the server had loaded the mod.
- The vanilla client was never clicked. Its frames are from forms the
  server showed it and fields the server replayed.
- A measurement on an idle GPU.
- VoxeLibre, and any game other than Mineclonia and Minetest Game.
- The dark glass look on any GPU but this one, and any resolution but
  1600 by 900.
- Dropdown lists, the link dialogue, hypertext forms, tables and text lists
  in glass were checked by the formspec suite's structure checks and not
  photographed, apart from those the sweep's forms contain.
- The in-game settings screen's Interface style dropdown was not clicked.
  In game the switch was driven through the control channel, which calls
  the same `GlassStyle.set_mode` the dropdown does. In the first round the
  main menu's dropdown was driven by a script (headless, scratch profile):
  choosing Game theme saved `interface_style="game"`, dropped the glass
  Theme and rebuilt the screen with the choice shown, and choosing Dark
  glass put it back.
