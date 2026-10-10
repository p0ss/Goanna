# The Godot project

This is Goanna's Godot 4.5 project: the GDScript, scenes and shaders that
sit on top of the C++ GDExtension in `src/`. Open this folder in Godot, or
run it with `godot --path project`. The extension library lands in `bin/`
when you build; see
[building and running](../docs/develop/building.md).

The game starts at `menu/menu.tscn` (the main scene in `project.godot`),
which hands off to `game/main.tscn`. Everything in `studies/` is run by
hand and never loaded by the game.

## Folders

- `game/`: in-world play. `main.gd` and `main.tscn` are the game scene,
  driving the `GoannaClient` the extension provides. Beside them: the
  player's sounds (`audio.gd`), graphics presets and pass switches
  (`graphics_profiles.gd`, `render_features.gd`), the overseer camera
  (`overseer.gd`, `overseer_ui.gd`), and split screen local play
  (`local_play.tscn`, `player_slot.gd`, `local_launch.gd`,
  `player_context.gd`).
- `game/effects/`: the sky, weather and water round the player. The sky
  and cloud authorities (`sky_director.gd`, `cloud_layers.gd`), the colour
  grade (`look_grade.gd`), water and ice optics (`water_optics.gd`,
  `ice_transmission.gd`), and the weather, particle, splash and wake
  systems.
- `menu/`: the main menu, which starts a local game or joins a server.
- `net/`: running a Luanti server on this machine for local play
  (`local_server.gd`), and the process handle it is stopped by
  (`owned_process.gd`).
- `update/`: downloading and installing, each checked before it is used.
  Goanna's own signed updates (`updater.gd`) and the versioned material
  bundles (`asset_store.gd`, `asset_updater.gd`).
- `agents/`: the interfaces programs drive the client through. The
  developer control channel (`control_channel.gd`, `control_ui.gd`) and the
  player agent channel (`player_agent_channel.gd`). See
  [agent interfaces](../docs/agents/agent-interfaces.md).
- `input/`: game controllers, loaded as the `Gamepad` autoload.
- `ui/`: the in-game interface and its forms: `game_ui.tscn`, the formspec
  renderer, the glass panel style, the narrator and voice typing.
- `bench/`: the benchmark recorder the control channel installs. See
  [benchmarking graphics settings](../docs/develop/benchmark.md).
- `shaders/`: every world shader. The `.gdshaderinc` files are shared
  pieces the `.gdshader` files include.
- `studies/`: offline fixtures, probes and one-off bakes: material ramps
  and galleries, the lighting chart, sky and water studies. No server and
  no world. Run a scene through the GPU launcher, for example
  `tools/goanna-headless fixture res://studies/portal_study.tscn`; the
  comment at the top of each script says what it shows.
- `tests/`: headless test scripts, run with
  `godot --headless --path project --script res://tests/<name>.gd`. See
  [testing](../docs/develop/testing.md).
- `vendor/`: Lua mods the release carries for servers it starts:
  `goanna_server_mod/` and `terrain_diffusion/`.
- `texture_maps/`: per game tables mapping a game's texture names to a
  Minecraft resource pack's.
- `menu_backgrounds/`, `terrain_previews/`: images the menu shows.

## Files at the top

- `project.godot`: project settings, the autoload and the shader globals.
  Edit it by hand; the editor rewrites it (see
  [building and running](../docs/develop/building.md)).
- `export_presets.cfg`: the release export, which leaves out the control
  channel.
- `goanna.gdextension`: where Godot finds the extension library.
- `bootstrap_assets.json`: where the client finds the asset bundle
  catalogue, unless `GOANNA_ASSET_CATALOGUE_URL` says otherwise.
- `terrain_worlds.json`: the catalogue of downloadable terrain worlds.
- `update_key.pub.pem`: the public key self updates are checked against.
- `icon.svg`: drawn by `tools/dev/make-icon.py`.

## Conventions

GDScript follows the official style guide, as
[`CONTRIBUTING.md`](../CONTRIBUTING.md) says.

A script used from another script is reached by a `preload` of its
`res://` path, held in a constant named for what it is
(`const PlayerContext := preload("res://game/player_context.gd")`). Do not
add a `class_name` for this. Godot finds global class names through a cache
in `.godot/` that only an editor pass rewrites, so a new or moved
`class_name` fails to parse in every checkout that has not rerun
`godot --headless --editor --quit --path project` since. The render service
imports a checkout only on its first use, and the other tools never do.

To move a script, `git mv` it together with its `.uid` file, then fix every
`res://` path that names it: scenes, `preload` and `load` calls, `extends`
lines, `project.godot`, `export_presets.cfg`, and the harnesses under
`tools/`.
