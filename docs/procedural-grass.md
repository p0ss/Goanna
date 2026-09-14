# Procedural grass

Enable **Settings → Graphics → Procedural grass** from the main menu or in a
running game. It is off by default and saved as `settings.procedural_grass` in
`user://goanna.cfg`. Graphics profiles leave this preference alone.

Changing the option in a game adds or removes the grass surface on existing
near and distant terrain meshes. New terrain uploads use the same setting.
Turning it off removes those surfaces, including their draw cost. The setting
does not alter server nodes or the existing grass plants supplied by a game.

While enabled, grass uses at least 4× MSAA plus FXAA for smooth procedural
edges. Disabling it restores the antialiasing settings that were active before
it was enabled; an existing 8× MSAA setting is preserved.

`GOANNA_GRASS=1` remains a development startup default. A saved choice takes
precedence. The isolated review launcher can test ordinary settings behaviour
without the environment default:

```sh
python3 tools/grass-review/run.py --keep --grass saved
```

The prototype uses world-positioned blades on grass-bearing top textures of
normal soil nodes. It preserves blade length when bending around nearby
players and physical entities. Distant blades blend into a continuous canopy.
Submerged soil does not grow procedural meadow grass. Mesh publication checks
the liquid above each root, splitting merged quads along wet/dry boundaries.
Near meshes use live nodes; cached LOD meshes use retained liquid envelopes.
Flooding or draining a patch updates its grass with the terrain mesh, and
toggling the graphics option preserves the published wet/dry mask. This removes
the underwater meadow volumes that previously sorted incorrectly against water;
it does not change the game's underwater plants or the general transparent pass.

Close-up tracing bounds the visible grass volume to its actual wind/actor
reach, limits the root search by blade height and actor influence, and rejects
ray segments outside a blade's enclosing cylinder before solving intersections.
Blade density, length, wind, edge compositing, and the distance transition are
retained. See [close-up measurements](perf/procedural-grass-close-2026-09-14.md).

An isolated pool regression captures above-water and underwater views and checks
the actual grass geometry while flooding, draining, toggling, and entering LOD:

```sh
python3 tools/grass-review/run.py --keep --scratch /tmp/goanna-grass-water \
  --port 30868 --server-port 30569 --out build/grass-review/water
python3 tools/grass-review/water.py --port 30868 --out build/grass-review/water
```

The toggle regression checks default-off behaviour in both menu and client,
repeated on/off changes on existing near and LOD meshes, retention of base
terrain, and restoration of antialiasing:

```sh
XDG_DATA_HOME=/tmp/goanna-grass-setting-check/data \
XDG_CONFIG_HOME=/tmp/goanna-grass-setting-check/config \
../Godot_v4.5.1-stable_linux.x86_64 --headless --path project \
  --script res://tests/procedural_grass.gd
```
