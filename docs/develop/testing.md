# Testing

Goanna is tested at three levels: native C++ tests that need no Godot,
headless Godot scripts that need no GPU, and rendered runs against a real
server. Rendered runs go through `tools/goanna-headless` or the render
service, never as a window on someone's desktop; the rules are in
[agent interfaces](../agents/agent-interfaces.md#rules-for-test-clients).

For what a change costs in frame time, see
[benchmarking graphics settings](benchmark.md) and the
[rendering baseline](baseline.md). For whether a release is ready, see the
[launch target](launch-target.md).

## Native and headless checks

Native tests are built in `build/`. They are not part of the default build,
so `cmake --build build` never rebuilds them and a `./build/<test>` run can
execute a binary days older than its sources. Build and run all of them
with:

```sh
cmake --build build --target check
```

To run one, build it by name in the same command, for example
`cmake --build build --target goanna_lod_test && ./build/goanna_lod_test`.
A new test source must be added to `GOANNA_NATIVE_TESTS` in
`CMakeLists.txt`; configuring fails until it is.

`goanna_animation_test` feeds the animation messages a Luanti 5.17 server
sends, and the shorter ones an older server sends, through the transplanted
active object and checks the joints the tracks pose: by priority, by name
and by number, blended, and back at rest once stopped.

`goanna_object_collision_test` runs the transplanted `LocalPlayer::move` on
a stone floor among objects made from the init and `AO_CMD_*` messages a
server sends: a physical object with `collide_with_objects` stops the
player at its face, can be stood on and, when lower than the step height,
stepped onto; one that is not physical, or physical without
`collide_with_objects`, is walked through; a moved object collides at the
position the server sent, not where it is still drawn; the local player's
own object and attached objects never block; and 1000 blocks around the
player cost well under a millisecond a second of walking.

`goanna_step_ease_test` walks the same transplanted `LocalPlayer::move` at
4 nodes a second, with a step height of 1.05 nodes, onto a whole block, a
half slab and a stair of two blocks, at 60 and 20 frames a second. The
physics still rises in one frame; the height shown
(`goanna_step_ease.h`) rises no more than the stock camera's decay allows
in a frame, is never above the player, is within 5% of the top after 0.08
to 0.22 s, and is not eased on the flat, in a jump or in a fall. No frame
moves the player further forwards than the walk. With
`GOANNA_STEP_EASE_TRACE=<file>` it writes every frame as CSV.

`goanna_item_icon_test` builds node definitions with no server, runs them
through upstream's node visuals and item mesh, and checks the inventory icons
Goanna draws from them: a mesh node on a texture atlas keeps its outline with
no holes, where the old folded cube had 476 in the same test, and a cube,
a slab and an alpha blended cube come out with vanilla's orientation,
lighting and draw order.

Godot integration checks can be run headlessly with the project's Godot
binary, for example:

```sh
Godot --headless --path project \
  --script res://tests/local_server_terrain_diffusion.gd
```

Local server discovery (including system game paths outside the desktop
session's `PATH`) can be checked with:

```sh
godot --headless --path project --script res://tests/local_server_discovery.gd
```

The Luanti server the Linux release carries is built in a container from
the pinned `luanti/` submodule, into `dist/luanti-server/`, which
`tools/release/package-release.sh linux` requires:

```sh
tools/release/build-luanti-server.sh
```

Get ready to play from nothing (no Luanti, no Flatpak) to a server
listening on a new Mineclonia world is checked in clean Ubuntu, Debian,
Fedora and Arch containers, with network access for the game download:

```sh
GODOT_BIN=/path/to/godot tools/test/test-fresh-install.sh
```

On a machine whose default podman storage is broken, set `PODMAN` to the
command with `--root` and `--runroot` (both scripts say how).

The Appearance grade's twilight and night bypass, its curve endpoints and
monotonicity, its texture cache and its vividness are checked with:

```sh
godot --headless --path project --script res://tests/look_grade.gd
```

The shader pack gbuffers translator's handling of GLSL that Godot's
shading language refuses (implicit conversions in constructors, constant
initialisers, names shared by the two stages and the rest listed in
`docs/design/iris-compat.md`) is checked case by case, each one translated
and compiled by Godot's own front end; `GOANNA_GLSL_CASE=name` runs one and
prints its translation:

```sh
godot --headless --path project --script res://tests/iris_gbuffers_glsl.gd
```

An asset bundle's archive hash, payload hashes and composed profile are
checked by installing one into a scratch root. It names the bundle and the
hash it must match, so it also demonstrates that a superseded hash is
refused:

```sh
GOANNA_TEST_ASSET_BUNDLE=dist/assets/org.goanna.minetest-game.terrain-1.1.0.zip \
GOANNA_TEST_ASSET_SHA256=$(python3 -c "import json;print([b for b in \
  json.load(open('asset_bundles/catalogue.json'))['bundles'] \
  if b['id']=='org.goanna.minetest-game.terrain'][0]['sha256'])") \
godot --headless --path project --script res://tests/asset_store_install.gd
```

That needs a published bundle to hand. With nothing to hand, a small bundle
built by `tools/pbr/pbr_bundle.py` from textures the test writes, with stems
that are prefixes of one another, is installed into an empty store the way
a downloaded one is, and the composed textures directory is checked file by
file. It needs `python3` with Pillow:

```sh
godot --headless --path project --script res://tests/asset_bundle_install.gd
```

The catalogue wiring, that `catalogue_url` is absolute and that every bundle
URL is absolute so nothing has to resolve against the catalogue's own
location, is checked with:

```sh
godot --headless --path project --script res://tests/asset_catalogue.gd
```

Which bundles a media announcement queues, including that a name two games
both use (Mineclonia and Minetest Game share about thirty `default_*` stems)
queues neither of them, is checked with a stub client, so it needs no server:

```sh
godot --headless --path project --script res://tests/asset_updater.gd
```

Controller input, from synthetic joypad events through to the keys handed
to the client and the cursor's pushed mouse events, is checked with:

```sh
godot --headless --path project --script res://tests/gamepad.gd
```

The keyboard bindings are checked with no server: Luanti's default keys and
key format, saving and reading `[keymap]` in `goanna.cfg`, a key another
control has being refused, a changed key taking effect in the game's own
input handler (the drop key, whole stack and one item with sneak), the
control channel's action names and the controller's stand in keys following
the bindings, and the Key bindings table at 1280 by 720 and 640 by 360 and
in the pause menu's settings. It rewrites `goanna.cfg`, so it needs a
scratch profile:

```sh
XDG_DATA_HOME=$(mktemp -d) godot --headless --path project --script res://tests/key_bindings.gd
```

The terrain world catalogue that the world picker is built from, including
that every world has a usable hash, size, tile window and bundled preview, is
checked with:

```sh
godot --headless --path project --script res://tests/terrain_catalogue.gd
```

Point it at a downloaded world as well to check the published archive
unpacks to the tile window its catalogue entry claims, which is the step
between a verified download and a world that loads:

```sh
GOANNA_TEST_TERRAIN_ARCHIVE=/path/to/tdl-default-1m-v4.zip \
GOANNA_TEST_TERRAIN_ID=tdl-default-1m-v4 \
godot --headless --path project --script res://tests/terrain_catalogue.gd
```

The shader pack folder and setting (`project/game/shader_packs.gd`): which
entries count as packs, unpacking a zip once and again when it changes, the
options a pack offers and saving each pack's overrides, is checked in a
scratch folder of its own with:

```sh
godot --headless --path project --script res://tests/shader_packs.gd
```

Use `git diff --check` and the style checker before submitting.
Deterministic visual fixtures and capture conventions are described in
[building and running](building.md#deterministic-visual-fixtures) and
[shader pack testing](shaderpack-testing.md).
