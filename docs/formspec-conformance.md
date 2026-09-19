# Formspec conformance

Goanna has an executable formspec conformance suite. It guards two related
boundaries:

- `tools/check-formspec-coverage.py` extracts Luanti's parser registry and
  requires every upstream element to be classified in
  `project/tests/formspec_coverage.json`.
- `project/tests/formspec_conformance.gd` builds representative forms in
  Godot and checks parsing, layout headers, field submission, inventory
  slots, list rings, partial fallbacks and known missing elements.

Run both layers from the repository root:

```sh
tools/test-formspec.sh
```

Set `GODOT_BIN` when Godot is not on `PATH`:

```sh
GODOT_BIN=/path/to/godot tools/test-formspec.sh
```

The suite can also produce a rendered fixture for visual comparison. This
mode needs a graphical display because Godot's headless display driver uses
a dummy renderer with no viewport texture. The directory must be an absolute
path:

```sh
GOANNA_FORMSPEC_SHOTS=/tmp/goanna-formspec tools/test-formspec.sh
```

## Current state

Every element Luanti registers now builds something: the manifest holds no
`missing` entries, and `_test_nothing_skipped` in the Godot suite fails if a
form leaves anything unrendered. What remains is a set of `partial` entries,
each with the omitted behaviour named in the manifest:

- `button_key` captures the next key or mouse button and sends it in Luanti
  5.17's `SYSTEM_SCANCODE_` and `MOUSE_BUTTON_` form, but only for the keys
  in its table (letters, digits, punctuation, function, editing, arrow,
  keypad and modifier keys); gamepad input is not captured and key names
  are English. Luanti's own settings menu is the only known user, and
  lua_api.md does not document the element.
- `hypertext` renders tags, styles, images, items, actions with their
  `hovercolor`, and the `<global>` page settings, but images and items do
  not float, and items are not rotated.
- `style` and `style_type` resolve and apply everything upstream does
  (states, the deprecated per-state properties, tints, images, borders,
  padding, `content_offset`, `font`, `font_size`, `sound`, and the version 11
  `halign` and `valign`) except `noclip`, `alpha`, and alignment on an
  editable `textarea[]`, which Godot's `TextEdit` cannot align. Goanna never
  clips an element to the form, so something upstream would cut off at the
  form's edge is still drawn. Fonts are the system's, not Luanti's Arimo
  and Cousine.
- `tablecolumns` ignores the per-column `padding` option.

## Compared with the vanilla client

On 19 September 2026 the everyday forms of Mineclonia, VoxeLibre
(`mineclone2`) and Minetest Game were shown side by side in Goanna and the
vanilla client, both connected to the same Luanti 5.17.0 server (the
Flatpak), at 1600 by 900, with Godot 4.5.1. A small server mod showed each
game's own form to both players: a node's `on_rightclick` or its metadata
formspec, an item's use callback, a villager's trade form, and the game's
own `on_player_receive_fields` handlers for pages such as the creative
inventory's tabs. The forms checked were the survival and creative
inventories, furnace, chest, crafting table, anvil, enchanting table,
villager trading, written book and skin editor in Mineclonia; the release
announcements in VoxeLibre; and the creative inventory, furnace, chest and
sign in Minetest Game. After the changes listed in `PLAN.md` for that date
they match in layout, colour, button artwork, slot and item drawing, and
text placement, with these differences left:

- The font. Goanna draws with Godot's default face at about the same size,
  which is wider than Luanti's Arimo, so a line that just fits upstream can
  wrap or be cut short in Goanna (VoxeLibre's "Wielded lights" card).
- Node item icons that are not cubes. Goanna composes a cube from the
  node's tiles where the vanilla client renders the node's own mesh (an
  anvil, a crafting table's side).
- Scrollbars take Luanti's colours, square thumb and arrow buttons, sized
  and placed as `CGUIScrollBar` places them (since 19 September 2026, from
  a side by side of Mineclonia's player settings form). Tab headers,
  dropdowns and checkboxes keep Godot's look rather than Luanti's skin.
- Textlist rows are a little taller than GUITable's.
- Goanna does not clip elements to the form, so anything a form places
  outside itself without `noclip` is still drawn.
- The vanilla client's tooltips were not captured, because the harness
  cannot move that client's pointer; Goanna's tooltip look follows
  `showTooltip` in the source.

## Reading the result

The coverage manifest uses three deliberately narrow labels:

- `supported` means the ordinary form is implemented and covered by the
  structural or behavioural fixtures. It does not promise pixel parity for
  every formspec version.
- `partial` means Goanna builds a usable fallback but omits named semantics.
  Every partial entry includes the omitted behaviour.
- `missing` means the element or directive has no effect. Missing build-time
  elements must also appear in the renderer's `skipped` report.

Luanti parses `formspec_version[]`, `size[]`, `position[]`, `anchor[]`,
`padding[]` and `no_prepend[]` before its element registry. The Godot suite
tests these as layout headers, while the source coverage count is limited to
the registry itself.

The game's own window theme, sent once as `TOCLIENT_FORMSPEC_PREPEND`, is
built in front of every server sent form that does not say `no_prepend[]`.
Upstream parses it with the old coordinate system whatever the form asked
for, and restores the formspec version afterwards, so a `formspec_version[6]`
form does not drag the prepend's positions into real coordinates. Goanna
keeps the prepend in its own element list and builds it first, under the same
rules; `_test_prepend` covers all three parts. Goanna's own pause menu and
settings screens are ordinary Godot Controls, not formspecs, so the prepend
never reaches them.

## Interface style

Everything above describes the game theme, which is one of the two interface
styles a player can choose. The other, dark glass and the default, replaces
the game's window chrome (the prepend's backgrounds and `bgcolor`,
`listcolors`, the prepend's button art and text colours, slot frame images)
with Goanna's glass panes and keeps the form's content art. The rule, and
why it is written the way it is, is in `docs/interface-style.md`. The
renderer is the same in both styles: layout, parsing, field submission and
inventory handling do not change, and `_test_glass_sends_the_same` checks
that a form sends the same fields in either. The suite builds its parity
fixtures in the game theme, and the `_test_glass_` checks build forms in
dark glass to check what is replaced and what is kept.

When Luanti adds or removes a registered element, the source check fails
until the manifest is updated. New support should update the renderer, the
status and an appropriate Godot fixture in the same change. Luanti's
`games/devtest/mods/testformspec` remains the useful manual integration set
for visual and interaction testing against a live server.
