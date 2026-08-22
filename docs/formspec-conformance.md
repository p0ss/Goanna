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

## Reading the result

The coverage manifest uses three deliberately narrow labels:

- `supported` means the ordinary form is implemented and covered by the
  structural or behavioural fixtures. It does not promise pixel parity for
  every formspec version.
- `partial` means Goanna builds a usable fallback but omits named semantics.
  Every partial entry includes the omitted behaviour.
- `missing` means the element or directive has no effect. Missing build-time
  elements must also appear in the renderer's `skipped` report.

Luanti parses `formspec_version[]`, `size[]`, `position[]`, `anchor[]` and
`padding[]` before its element registry. The Godot suite tests these as
layout headers, while the source coverage count is limited to the registry
itself.

When Luanti adds or removes a registered element, the source check fails
until the manifest is updated. New support should update the renderer, the
status and an appropriate Godot fixture in the same change. Luanti's
`games/devtest/mods/testformspec` remains the useful manual integration set
for visual and interaction testing against a live server.
