# Interface layout

Rules for how Goanna lays out its own screens and the game views it draws
for a server (the overseer first), written 1 November 2026 after the first
DorfCraft co-op playtest. The maintainer's verdict on that playtest:
screens "squeeze so much into every screen", with "fifty things competing
for equal attention".

How things look (the dark glass, the palette, legibility) is
`interface-style.md`. What a game server sends, and what it calls things,
is the game's side; for DorfCraft that is its `docs/interface-rules.md`,
which defines the table shape these screens draw. A screen is done when it
meets both.

## Regions

A full-screen game view such as the overseer has at most five regions:

| Region | Holds | Rule |
| --- | --- | --- |
| Header | Where you are (place, view, live or paused), the view's tools (Select, Map focus), Back and Leave | One line of context, no more |
| Rail | The view's sections, grouped under small headings (overseer: Plan, Fortress) | Hidden sections absent; locked ones greyed with the reason on hover or focus |
| Main area | The map, or a table, or a page; one at a time | Tables cover the map, they do not sit beside it |
| Context panel | The selection's detail and its verbs | Shown only when something is selected or a tool needs settings |
| Footer | Level or position, and a View menu for overlays | No row of equal toggles |

Anything that does not fit one of these goes on its own screen rather than
into a corner of this one.

## Hierarchy

- **One primary action per screen**, in the accent fill. Other buttons are
  quiet (glass, no fill). A screen with two accent buttons is wrong.
- **Four text levels only:** title, section heading, body, quiet. No
  bold-for-emphasis inside body text.
- **Spacing does the grouping.** Related controls sit 8 px apart, groups
  24 px apart. No boxes inside boxes.
- **Targets** at least 40 px high at 100 percent, so controller focus and
  touch both work. At 200 percent text, regions scroll; controls never
  shrink below their text.

## Tables

One table widget for every list a game sends, drawing the server's table
shape (columns, rows, opening sort, filters, empty state, note):

- It fills the main area. The header row stays put while rows scroll.
- Click a column heading to sort; again to reverse. The sorted column shows
  its direction.
- A search box above the table filters rows by every text cell as you type.
  The server's filters sit beside it as dropdowns.
- Number columns are right aligned; a row's glyph (rune) leads it.
- A locked row is greyed and its reason shows on hover or focus. It is
  never clickable as if available.
- Choosing a row opens its detail in the context panel. A row with a
  position offers Show on map, which returns to the map centred on it.
- Empty: the server's `why` as a heading and `what` as the one action,
  centred in the main area. Never a blank region.
- Keyboard and controller: arrows move the row, Enter opens it, typing
  goes to the search box.

## Unavailable things

Greyed (quiet text colour, no hover lift) with the reason on hover or
focus when the player could get to it; absent when they cannot. Pressing a
greyed control shows the reason in place and does nothing else. The words
"(unavailable)" never appear in a label.

## Names and glyphs

Goanna shows the titles the server sends and never derives one from an id.
An id with no title is a server bug: show "Unnamed" and log it, rather than
the id. An action's glyph comes from the server's `icon` and means the same
everywhere (`overseer.md`, Noun-first selection).

## Checking a screen

Before calling a screen done, take a headless capture at 1280 by 720 and at
200 percent text, and check:

1. Can you say the screen's one task in five words?
2. Is there exactly one accent button?
3. Is every list over about eight rows a table in the main area?
4. Is anything unavailable shown in the normal style?
5. Is any id, node name or Lua value visible anywhere, tooltips included?
6. Does every empty region say why and what to do?
