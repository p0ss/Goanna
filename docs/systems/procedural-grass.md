# Procedural grass

Enable **Settings → Graphics → Procedural grass** from the main menu or in a
running game. It is off by default and saved as `settings.procedural_grass` in
`user://goanna.cfg`. Lowest and Low disable it; Medium, High and Ultra
enable it with graded
budgets. See [graphics tiers](graphics-tiers.md).

Changing the option in a game adds or removes the grass surface on existing
near and distant terrain meshes. New terrain uploads use the same setting.
Turning it off removes those surfaces, including their draw cost. The setting
does not alter server nodes or the existing grass plants supplied by a game.

Density, draw distance, bending distance and actor count have independent
settings. Lower density widens the blade grid and shortens candidate
searches. Grass fades back to the original ground over the final fifth of
its draw range; fully distant proxies collapse before rasterisation. Zero
bending distance or actors disables interaction work.

Grass edge smoothing can keep existing AA, add FXAA, or add 2x/4x MSAA and
FXAA. Changing quality or disabling grass restores its original AA
baseline. A stronger existing MSAA setting is preserved. The diagnostic
`render_grass_aa` gate can suppress grass-owned AA independently.

`GOANNA_GRASS=1` remains a development startup default. A saved choice takes
precedence. The isolated review launcher can test ordinary settings behaviour
without the environment default:

```sh
python3 tools/test/grass-review/run.py --keep --grass saved
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

Close-up tracing searches longer ray intervals, bounds candidate roots by
wind/actor reach, and rejects empty space before evaluating individual blades.
Height varies both within and across clumps, continuously across block
boundaries. Travelling wind fronts follow cloud motion and strengthen with
precipitation. The player's collision footprint parts the grass even with the
first-person body hidden. Distant blades blend to a canopy before the configured
distance cutoff. See the earlier [measurements and validation
limits](../perf/procedural-grass-wind-2026-09-25.md).

The live feature regression checks first-person interaction, body visibility,
movement and rain-driven wind:

```sh
python3 tools/test/grass-review/features.py --port 30867
```

An isolated pool regression captures above-water and underwater views and checks
the actual grass geometry while flooding, draining, toggling, and entering LOD:

```sh
python3 tools/test/grass-review/run.py --keep --scratch /tmp/goanna-grass-water \
  --port 30868 --server-port 30569 --out build/grass-review/water
python3 tools/test/grass-review/water.py --port 30868 --out build/grass-review/water
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
