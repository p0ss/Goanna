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

- `model` draws a labelled placeholder. A real preview needs a mesh from the
  client media cache, which the UI cannot reach yet.
- `button_key` draws an ordinary button. Goanna has no key binding capture.
- `hypertext` renders tags, styles, images, items and actions, but not
  `hovercolor` or vertical alignment.
- `style` and `style_type` apply colours, background images, borders, font
  size and list slot geometry, but not the font family or sounds.
- `tablecolumns` ignores the per-column `padding` option.
- `tooltip` ignores custom tooltip colours.

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

When Luanti adds or removes a registered element, the source check fails
until the manifest is updated. New support should update the renderer, the
status and an appropriate Godot fixture in the same change. Luanti's
`games/devtest/mods/testformspec` remains the useful manual integration set
for visual and interaction testing against a live server.
