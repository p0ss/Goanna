# Dark glass against the game theme

Captures of the two interface styles (`docs/interface-style.md`) side by
side, taken on 19 September 2026 from the live client. They are for judging
the look; this page says what was captured and measured, not whether it
looks good.

## Conditions

- Goanna as committed in `889ab24` (branch
  `worktree-agent-a8f0caef91cf3b17e`), Godot 4.5.1, a 1600 by 900 window,
  and an NVIDIA RTX 3090 shared with other processes (machine learning jobs
  held it at 96 to 99 percent utilisation and 20 GiB of its memory
  throughout).
- Luanti 5.17.0 (the Flatpak) servers on fresh worlds: Mineclonia
  (`goanna_glass_mcl`) and Minetest Game (`goanna_glass_mtg`), with
  `goanna_server.conf` copied to set `creative_mode = false` and add the
  `server` privilege, so the survival inventory showed by default and
  `/gamemode creative` gave Mineclonia's creative inventory.
- A throwaway world mod built a snow field, a sand beach with a pool, a small
  forest and a stone room lit by one torch in the sky above the origin,
  placed a chest, a furnace and a crafting table, filled them, and gave the
  player a spread of dark, mid and light items. Its `/glass_open` command
  opened each container's form through the node's own code (for the furnace,
  its metadata form with `context` pointed at the node; for the crafting
  table, Mineclonia's own form without its reach check).
- The client ran with a scratch profile and reduced graphics (view range 8,
  no far field, no bounced light, smallest shadow map) because the GPU's
  memory was nearly full; the lighting in the backgrounds is therefore
  plainer than Goanna's default look.
- Each form was captured in dark glass, then switched to the game theme with
  the setting and captured again from the same pose, so the two frames of a
  pair differ only in the style. The main menu shots used
  `GOANNA_MENU_BACKDROP` with the world captures as the backdrop.
- The mobs, holes in the snow and floating snowballs in some frames are the
  live world (Mineclonia spawned mobs on the stage and something dug the
  snow); they are not part of the change.

## Comparison sheets

Each sheet has the game theme on the left and dark glass on the right, over
a bright day (snow and sky at noon), a forest and a cave lit by one torch.
Full frames are in `frames/`, named `<screen>_<background>_<style>.jpg`.

- [Mineclonia survival inventory](sheet_mcl_survival.jpg)
- [Mineclonia creative inventory](sheet_mcl_creative.jpg)
- [Mineclonia chest](sheet_mcl_chest.jpg)
- [Mineclonia furnace](sheet_mcl_furnace.jpg)
- [Mineclonia crafting table](sheet_mcl_table.jpg)
- [Minetest Game inventory](sheet_mtg_inventory.jpg)
- [Goanna main menu](sheet_menu_main.jpg)
- [Goanna main menu settings](sheet_menu_settings.jpg)
- [Goanna pause menu](sheet_pause.jpg)
- [Goanna in-game settings](sheet_settings.jpg)
- Chat open, bright day: [game theme](frames/chat_day_game.jpg),
  [dark glass](frames/chat_day_glass.jpg)

What to look for, as the rule in `docs/interface-style.md` intends:

- The game's window art (Mineclonia's light grey panel and slot squares,
  Minetest Game's dark panel and full screen dim, the themed button panes)
  is replaced by glass; the item art, the empty armour slot outlines, the
  player model and its black backing, the crafting and furnace arrows and
  flame, the recipe book and other image buttons, and the trash can are the
  game's own.
- Mineclonia's creative inventory tabs are the game's own button art and
  stay light grey in dark glass.
- Mineclonia's `#313131` labels ("Crafting", "Inventory", "Chest") are
  lifted to `#bababa` on glass.
- The hotbar is clear glass (not frosted) with the selected slot ringed.

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
| Snow at noon | 0.056 | 9.1:1 | 6.3:1 | 5.1:1 | 6.4:1 | 4.6:1 | 5.1:1 |
| Open sky at noon | 0.051 | 9.5:1 | 6.6:1 | 5.3:1 | 6.6:1 | 4.6:1 | 5.1:1 |
| Sand and water at noon | 0.052 | 9.4:1 | 6.5:1 | 5.3:1 | 6.6:1 | 4.6:1 | 5.1:1 |
| Forest at noon | 0.029 | 12.1:1 | 8.4:1 | 6.8:1 | 8.3:1 | 4.7:1 | 5.2:1 |
| Cave, one torch | 0.024 | 13.0:1 | 9.0:1 | 7.3:1 | 8.9:1 | 4.8:1 | 5.3:1 |
| Snow at midnight | 0.020 | 13.7:1 | 9.5:1 | 7.7:1 | 9.4:1 | 4.8:1 | 5.3:1 |

Over the 21 dark glass frames of the comparison sheets the brightest glass
was 0.053 and every figure stayed at or above the snow row. The shader's
bound is 0.07 (a 0.05 ceiling plus a 0.02 sheen at the top of a pane), so
none of these can fall below the worst case figures in
`docs/interface-style.md`. The contrast backgrounds are in `frames/`:
`contrast_world_*.jpg` (the world alone), `contrast_mcl_survival_*_glass.jpg`
and `contrast_mcl_survival_*_panes.jpg` (the glass alone, as measured).

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
| `mcl_trees:tree_oak` | 2.6 | 1.4 to 1.5 |
| `mcl_torches:torch` | 2.4 | 1.4 to 1.4 |
| `mcl_core:apple` | 2.4 | 1.3 to 1.5 |
| `mcl_core:cobble` | 2.1 | 1.1 to 1.2 |
| `mcl_tools:pick_iron` | 2.0 | 1.1 to 1.2 |
| `mcl_core:stone` | 2.0 | 1.1 to 1.1 |
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
theme for 10 of these 19 items, and more readable for 9. A slot's count is
more legible on glass (4.6:1 or better, against about 3.4:1 on Mineclonia's
tile). Minetest Game's own slots are darker than the glass tile, so there
the comparison goes the other way; it was not measured.

## Cost

`viewport_get_measured_render_time_gpu`, the mean of 240 frames, with the
game theme and dark glass alternated four times in the same pose:

| Case | Game theme | Dark glass | Difference |
| --- | --- | --- | --- |
| Mineclonia chest open | 2.24 ms | 2.32 ms | +0.08 ms |
| Minetest Game inventory open | 3.13 ms | 3.20 ms | +0.07 ms |
| Minetest Game inventory with an item tooltip up | 2.13 ms | 2.22 ms | +0.10 ms |
| No window open, hotbar only | 3.09 ms | 3.10 ms | +0.01 ms |
| Mineclonia chest open, earlier build, heavier GPU load | 11.41 ms | 11.77 ms | +0.36 ms |

The last row was measured with an earlier build in which the hotbar was also
frosted, at a time when the other processes on the GPU nearly doubled every
frame; hiding every glass pane there brought the frame back to the game
theme's (11.41 ms), so the difference is the screen copy and blur. The GPU
was never idle, so all of these are what the style costs next to other work;
an idle GPU should do better. The first four rows are with the committed
code.

`measurements.json` holds the raw numbers for all of the above.

## Not verified

- VoxeLibre, and any game other than Mineclonia and Minetest Game.
- The dark glass look on any GPU but this one, and any resolution but
  1600 by 900.
- Dropdown lists, the link dialogue, hypertext forms, tables and text lists
  in glass were checked by the formspec suite's structure checks and not
  photographed.
- The in-game settings screen's Interface style dropdown was not clicked.
  In game the switch was driven through the control channel, which calls
  the same `GlassStyle.set_mode` the dropdown does. The main menu's
  dropdown was driven by a script (headless, scratch profile): choosing
  Game theme saved `interface_style="game"`, dropped the glass Theme and
  rebuilt the screen with the choice shown, and choosing Dark glass put it
  back.
