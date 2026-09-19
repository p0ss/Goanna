# Interface style

Goanna draws its own screens and every server sent form in one of two
styles, chosen under Settings, Appearance, Interface style:

- **Dark glass**, the default. Goanna's main menu, pause menu, settings,
  chat, the hotbar and every game form sit on dark translucent panes that
  blur and darken the world behind them, with a thin highlight along the top
  edge, a slight bend of the view at the edges and a soft shadow underneath.
  Buttons, fields, dropdowns, check boxes, tabs, scrollbars, lists, slots
  and tooltips share one look.
- **Game theme**. Server forms are drawn in the game's own window art, the
  way `docs/formspec-conformance.md` describes and the vanilla client draws
  them. Goanna's own screens look as they did before the glass existed.

The change applies at once, in the main menu and in game, with no restart.
An open form is rebuilt in the new style and keeps what the player has typed,
ticked, chosen, selected and scrolled to, without sending anything. The setting is stored as `interface_style` (`glass` or
`game`) in the `settings` section of `goanna.cfg`; the control channel's
`set interface_style 1` and `0` switch it too.

The style is presentation only. A form sends the server exactly the fields it
sends in the game theme (`_test_glass_sends_the_same` in the formspec suite
checks this), and nothing is shown that the form did not show.

## Where it lives

| File | What it is |
| --- | --- |
| `project/ui/ui_glass.gdshaderinc` | The glass, as a canvas item shader. |
| `project/ui/ui_glass.gdshader` | Frosted glass: reads and blurs the screen. |
| `project/ui/ui_glass_clear.gdshader` | The same glass without the screen read, for the hotbar. |
| `project/ui/glass_surface.gd` | One pane. Every pane shares one of the two materials. |
| `project/ui/glass_style.gd` | The setting, the palette, the shared Godot `Theme` and the contrast arithmetic. |
| `project/ui/formspec.gd` | The chrome and content rule below. |

A pane passes its corner radius, tint strength and shadow strength in its
vertex colour and works out its own size from the rate UV changes across it,
so there is no material per pane. Controls get their look from one `Theme`
set on the root of each screen rather than from code per control.

## Chrome and content in a form

In dark glass the game's window chrome is replaced and its content is kept.
The rule is written so that anything it is unsure of stays as the game drew
it.

The game's window theme is whatever the server sent as the formspec prepend
(`player:set_formspec_prepend`). Goanna notes every element of it whether or
not the form uses the prepend, because a form may write the theme out again
itself: Mineclonia's creative inventory says `no_prepend[]` and then repeats
the theme's `listcolors`, styles and `bgcolor`, with the theme's
`background9` at a rectangle of its own.

| Element | Dark glass |
| --- | --- |
| `background[]`, `background9[]` from the prepend, or in the form with a texture the prepend's backgrounds use, or with plain window art of the form's own | Replaced by a glass pane of the same rectangle. |
| `bgcolor[]` from the prepend, or the same element repeated in the form | Ignored: the glass is the window, and the full screen colour becomes a light dim. |
| `bgcolor[]` of the form's own | A transparent one (no panel) is honoured; a coloured one gets the glass pane; its full screen colour is kept. |
| `listcolors[]`, from anywhere | Ignored: slots and tooltips are drawn in the glass look. |
| `style[]`, `style_type[]` from the prepend, or repeated in the form | The window art properties are dropped (`bgcolor`, `bgimg` and their state variants, `bgimg_middle`, `border`, `textcolor`, `padding`, and a box's `colors`, `bordercolors`, `borderwidths`). Size, spacing, font, sound and alignment are kept. |
| `style[]`, `style_type[]` of the form's own | Kept. A button coloured with `bgcolor` becomes a tinted glass button; a `bgimg` that is plain window art becomes a glass button (Mineclonia's creative tabs); any other `bgimg` is kept. |
| Buttons, image buttons and item image buttons with no art of their own | Glass buttons. An image button keeps its image; `drawborder=false` still draws no pane. |
| Fields, text areas, dropdowns, check boxes, tab headers, scrollbars, text lists, tables | The glass `Theme`. Colours a form sets itself (`tableoptions`, a text list item's `#RRGGBB`) are kept. |
| Tooltips and hypertips | Glass panes, unless a hypertip is styled with its own `bgcolor` or `bgimg`. |
| `image[]` behind a slot, framing it closely, whose texture frames at least two slots in the form | A slot frame: hidden, and the slot draws its own glass tile. |
| `image[]` of plain window art behind a slot, button, model or field it holds (a large output slot, a tab, the player preview's backing) | A glass tile of the same rectangle. |
| Dark line art in or behind a slot (empty armour, shield, banner, dye and template outlines) | Kept, and drawn light. |
| `box[]` of neutral grey, at least half a slot each way | A sunken glass tile. |
| Every other `image[]`, `animated_image[]`, `item_image[]`, `model[]`, `box[]`, hypertext images, item images, and backgrounds with a texture of the form's own | Kept exactly. |

Plain window art is a texture that is a panel, button or tab face rather
than a picture: at least 24 pixels each way (node textures, item icons and
bars are smaller), nine tenths opaque, grey (nineteen pixels in twenty with
channels no more than 16 apart), and flat (one colour, to four bits a
channel, covering nine twentieths of it). Run over every texture Mineclonia
ships, the test picks out its slot, panel, tab, button and model backing art,
and also two help page pictures of crafting grids, which is why an `image[]`
of window art is only replaced when it frames something the player uses: a
picture that frames nothing is kept.

A slot frame must meet all three tests: it is built before the list, so it
lies behind the slot (for a form older than version 3, after the old draw
order has put it there); it contains the slot and is at most an eighth of a
slot larger on each side; and the same texture frames at least two slots.
This catches Mineclonia's `mcl_formspec_itemslot.png` under every slot and
Minetest Game's `gui_hb_bg.png` under its hotbar row. It keeps Mineclonia's
empty armour slot outlines (drawn over the slot, after the list), its trash
can (the only slot framed with that texture) and anything much bigger than a
slot, such as a furnace's large output slot, which becomes a glass tile of
its own size instead.

A list with any framed slot is drawn in a slightly lighter tile than a list
with none, so Minetest Game's hotbar row stays set apart from the rows below
it, as `gui_hb_bg.png` sets it apart. A slot over a picture the form keeps is
drawn as a see-through tile, so the trash can shows as it does in the game
theme.

Mineclonia marks the chosen tab by drawing it in lighter art than the rest.
Among replaced window art of the same size, a piece at least 0.1 lighter (in
relative luminance) than every other is drawn selected: an accent fill and
ring. A group with no such piece, or where more than half the pieces are
that light, has none. Replaced art that stands outside the form's glass, as
the creative tabs stand above and below its window, gets a pane of the same
glass behind it. The tab's icon, a separate item button, is the game's own
and is kept.

A form that paints its own window keeps the game theme whole: when a
`background[]` or `background9[]` with the form's own texture, not plain
window art, covers nine tenths of the form or more and is at least half
opaque, as a Mineclonia book is, the form is drawn exactly as in the game
theme, text colours and all, because its text and controls were made for
that art. The brewing stand's background also covers its form, but it is
line art (tubes, a twentieth opaque) drawn over the game's panel, so that
form is glass.

Text colours are made legible (see below) only where the text sits on glass.
Text on a form's own button art, a hypertext page with its own background
colour, a table with its own background, or a bespoke form keeps the colour
the game chose for that surface.

## Legibility

The glass has a luminance ceiling. The blurred world is pulled towards the
tint in linear light and then through `g / (1 + L(g) / ceiling)`, so the
glass tends towards `ceiling` (0.05 relative luminance) and never reaches
it, however bright the world. A sheen of 0.02 at the top of each pane brings
the worst case to 0.07. That bound is the brightest surface text on glass
can have behind it, and the palette is chosen against it:

| Text | Colour | Worst case contrast |
| --- | --- | --- |
| Interface text | `#f3f5f9` | 8.0:1 |
| Quiet text, descriptions | `#c8ced8` | 5.5:1 |
| Button text on a hovered button | `#f3f5f9` | 5.7:1 |
| A slot's count on the lighter, framed tile | white | 4.6:1 |
| A slot's count on a hovered slot | white | 5.0:1 |

A colour a game chose for text on its own light theme would vanish on dark
glass (Mineclonia writes its labels in `#313131`). On glass every text colour
that falls short of 4.5:1 against the worst case is lifted towards white in
linear light, just far enough (`GlassStyle.ink`): `#313131` becomes
`#bababa`, pure blue a light blue, pure red a light red. The hue survives, so
a colour that carries meaning still carries it.

Inventory slots are mid grey tiles, not a tint of the glass. With a tint, a
dark item (coal, obsidian, black wool) disappeared into a dark slot at
night. The tile is nearly opaque, so it looks the same whatever the world
behind, and its brightness sits between the darkest and lightest items, so
both keep some contrast against it; the numbers are below.

Measured on 19 September 2026 from Goanna 1600 by 900 captures of the
Mineclonia survival inventory and the settings screen, with Luanti 5.17.0
(Flatpak), Mineclonia and Godot 4.5.1, the form's content hidden so only
the glass remained, and everything within 6 pixels of a pane's rounded edge
(the rim hairline) left out. Each row is the lower of the two screens:

| Background | Brightest glass | Interface text | Quiet text | `#313131` label, lifted | Hovered button | Count, slot | Count, hovered slot |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Snow at noon | 0.056 | 9.1:1 | 6.3:1 | 5.1:1 | 6.4:1 | 4.6:1 | 5.1:1 |
| Open sky at noon | 0.051 | 9.5:1 | 6.6:1 | 5.3:1 | 6.6:1 | 4.6:1 | 5.1:1 |
| Sand and water at noon | 0.052 | 9.4:1 | 6.5:1 | 5.3:1 | 6.6:1 | 4.6:1 | 5.1:1 |
| Forest at noon | 0.029 | 12.1:1 | 8.4:1 | 6.8:1 | 8.3:1 | 4.7:1 | 5.2:1 |
| Cave, one torch | 0.024 | 13.0:1 | 9.0:1 | 7.3:1 | 8.9:1 | 4.8:1 | 5.3:1 |
| Snow at midnight | 0.020 | 13.7:1 | 9.5:1 | 7.7:1 | 9.4:1 | 4.8:1 | 5.3:1 |

Slot contents are a trade rather than a gain. Against Mineclonia's light
grey slot, dark and mid tone items (black wool, coal, dirt, logs, stone)
stand out less on the glass tile and light ones (snow, quartz, white wool,
ingots) stand out more; by the mean luminance of the item against the tile,
10 of 19 items measured are less distinct and 9 more.
`docs/perf/ui-glass-2026-09-19/index.md` has the table and the frames.

## Cost

The glass costs one copy of the screen, with its blurred mipmap chain, per
frame in which a frosted pane is on screen. Nothing else in the style is
measurable. The hotbar, which is on screen for the whole game, uses the clear
variant that does not read the screen, so play with no window open costs
nothing extra. A tooltip copies the screen a second time, under itself only,
so that its frost is the form beneath it.

Measured on the same day at 1600 by 900 on an RTX 3090 that other
processes kept 96 to 99 percent busy, with
`viewport_get_measured_render_time_gpu` over 240 frames and the two styles
alternated four times: a Mineclonia chest
open costs 0.08 ms more in dark glass (2.24 against 2.32 ms), Minetest
Game's inventory 0.07 ms, the inventory with an item tooltip up 0.10 ms,
and play with no window open 0.01 ms, which is within the noise. At a time
when the other processes nearly doubled every frame, the chest cost 0.36 ms
more, and hiding the panes brought it back to the game theme's figure, so
that is the screen copy and blur under load.

## What does not work

- Dark and mid tone items stand out less on the glass slot tile than on
  Mineclonia's light grey slot (see Legibility). The tile's brightness is a
  choice between them and light items, and it is one number in
  `glass_style.gd`.
- The window art test and the "lighter tab is selected" rule are
  heuristics, measured against Mineclonia's and Minetest Game's art only. A
  game whose selected tab is darker than the rest, or whose tabs differ in
  lightness for another reason, gets no marker or a wrong one.
- Books, and any other form that paints its own page, keep the game theme
  whole, so they are not dark in dark glass.
- Text a form draws over a picture of its own, rather than on the panel,
  is still lifted as if it sat on glass, which would make it harder to read
  on a light picture. No form checked does this.
- Popups (a dropdown's list, the link dialogue) are nearly opaque dark panels,
  not frosted: Godot draws them in their own window with no screen behind
  them to read.
- The slot frame rule is a heuristic. A game that draws a different frame
  texture under each slot, or a single slot's hint image behind its slot,
  will have the frame kept and a see-through glass tile drawn over it.
- A form's own coloured `bgcolor[]` is treated as a window colour and
  replaced by glass. A form that used a panel colour to mean something would
  lose that colour.
- Goanna's own screens have no game theme of their own, so "Game theme"
  there means the look Goanna had before the glass.
