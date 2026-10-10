# Director log

What each director test ran, on which server, game and Godot version, and
what it showed, oldest first. The design is in the
[director design](../design/director-design.md) and the current state in
[the director](../agents/director.md).

## What was verified

Everything below ran on 19 September 2026 against the Luanti 5.17.0 Flatpak
(`org.luanti.luanti`, server only, no client) with the probe in
`tools/test/director-probe/`, each on a fresh world on port 30561, stopped by
the probe itself (`core.request_shutdown`) and checked gone by PID. No client
connected, so no player existed. The GPU was in a faulted state, which is why no
client was tried.

| Run | Game | Mapgen | What it showed |
| --- | --- | --- | --- |
| 1 | Mineclonia 38561 | v7 | the whole sequence; mcl_mobs targeting; the removal hook |
| 2 | Mineclonia 38561 | v7 | biome at water surface and seabed; decorations per biome; a zombie lost to a bad teleport |
| 3 | Mineclonia 38561 | its own level generator (`singlenode`, `mcl_singlenode_mapgen = true`) | engine biome disagrees in 9 of 9 columns; targeting |
| 4 | Mineclonia 38561 | singlenode with the bundled Terrain Diffusion and the `tdl-bay-1m-v2` tiles | engine biome disagrees in 9 of 9 columns; targeting |
| 5 | as run 4 | as run 4 | decorations explained by TDL's biome and not the engine's |
| 6 | Mineclonia 38561 | v7 with run 2's seed | run 2's lost zombie, diagnosed as a deactivation |
| 7 | Mineclonia 38561 | v7 | freezing an mcl_mobs zombie; a kill reported as a deactivation |
| 8 | Minetest Game 38214, Mobs Redo 38115 | v7 | mobs_redo spawn rules as ABMs; a raider that picked its own target |
| 9 | as run 8 | v7 | a raider in water held its target and did not move |
| 10 | as run 8 | v7 | `do_attack` targeting; freezing a mobs_redo raider |

Verified: `core.get_biome_data` and its y dependence and disagreement with Lua
mapgens; decorations indexed by biome; `mcl_mobs.registered_spawners` per biome
and `spawning_possible`; mobs_redo spawn ABMs; the item catalogue's size;
`objects_inside_radius`, `get_guid`, `objects_by_guid`; `add_entity`, `set_pos`,
`set_yaw`, nametags; the mcl_mobs targeting rule and mobs_redo `do_attack`;
freezing by shadowing `on_step`; the `on_deactivate` removal hook and its
deactivation case; mcl_mobs health against engine hp;
`mcl_weather.change_weather`; `forceload_block`; HTTP `POST` and `GET` from the
server; `handle_async`, `ipc_set` and mod storage costs.

Read in source, not run: mod channel relaying and limits (`src/server.cpp`,
`src/network/serverpackethandler.cpp`, `src/modchannels.cpp`), chat command
handling (`builtin/game/chat.lua`), `get_biome_data` (`l_mapgen.cpp`), mcl_beds
counting players, creatura, 3d_armor, mcl_armor, VoxeLibre.

Not verified at all: any player callback, player inventory or HUD, chat
delivery, the seat transport, Goanna under Godot's `--headless`, any quest, the
pacing layer, and any language model driving any of it. Phase 1's test on 1
October 2026 has since covered player callbacks, inventory reads, chat
delivery and the pacing layer, with connected players; see [What the first
test showed](#what-the-first-test-showed).

To run the probe again, copy it into a fresh world's `worldmods` and start a
server with a config file inside the world, so the sandbox can see it and the
player's own `minetest.conf` is left alone:

```sh
W=~/.var/app/org.luanti.luanti/.minetest/worlds/director_probe_example
mkdir -p "$W/worldmods"
cp -r tools/test/director-probe "$W/worldmods/director_probe"
printf 'mg_name = v7\nsecure.http_mods = director_probe\n' > "$W/probe.conf"
printf 'director_probe_url = http://127.0.0.1:30591\n' >> "$W/probe.conf"
python3 tools/test/director-probe/http_sink.py 30591 /tmp/sink.log &
flatpak run --command=luanti org.luanti.luanti --server --gameid mineclonia \
    --world "$W" --port 30561 --config "$W/probe.conf" --logfile "$W/server.log"
```

The server writes `$W/director_probe.json` and shuts itself down after about
half a minute. Stop the sink by its PID afterwards. For Minetest Game, use
`--gameid minetest` and copy Mobs Redo into `worldmods` as well.

## What the first test showed

`tools/test/test-director.py` on 1 October 2026: the Luanti 5.17.0 Flatpak
server, Mineclonia release 38561, mapgen v7, a fresh world; two Goanna
clients (Godot 4.5.1 stable, the client library built from the main
checkout at 01:18 that day) running headless in gamescope with software
rendering (lavapipe), as the players alice and bob; the MCP service driven
over stdio JSON-RPC by the script, as a model would. 61 checks passed:

- The mod created a 64 hex digit token, and the endpoint answered only with
  it. With no director connected a joining player was told nothing; when the
  MCP service started, the server reached it, alice got the notice, and her
  earlier join was in the event stream.
- `director_player` gave position, biome, gear and a ceiling of 5 bare
  handed, 10 with a diamond sword in the hotbar.
- Alice's biome (PaleGarden) has no monster fauna, so the theme was refused
  as `no_fauna`, and a named list was accepted: asked for 100, clamped to 10,
  two skeletons out of sight for 8 points. mcl_mobs took alice as their
  target and they closed from 10 to about 5 nodes.
- A second encounter past the hourly budget was refused as `budget`. With
  alice past the peak, `when: "now"` was refused as `pacing`, a small
  encounter was queued, and it landed, as a late result, at her next build
  up. Undo removed each encounter.
- A villager cast as Grimbold spoke to alice, and narration reached her;
  both read in her client as attributed. Her line `Grimbold, where is the
  old tower?` reached the model with his memory of her; a remembered line
  and disposition came back on her next address and through
  `director_memory`; a line over the cap was refused; ordinary chat was not
  read. A character named `alice` was refused.
- Alice killed Grimbold with her own client's punches. The model got
  `entity_died` with her as the killer, his memory kept `was killed by
  alice`, he could no longer speak, and the region counted the kill.
- Bob joined, was told, and opted out. His summary said only that;
  narration to him, an encounter near him and a memory of him were refused;
  narration to all reached alice and not his client; and his leaving was not
  reported.
- A restarted MCP service got a fresh hello and could query again.
- `director_stop` removed the character and refused everything until alice,
  the server's admin, typed `/director start`. `/director` and
  `/director log` answered in game. The audit log held every intent, and the
  server log had no director warnings or errors.

`tools/test/test-director-logic.lua` covers the ring, budgets, rate limits,
pacing cycle, composition, gear score, memory caps and text cleaning.

Seen in passing: a fresh player in that world sometimes took damage at
spawn (`set_hp`) and died before anything else happened. That is not the
director's, but it shows why an intent carries `based_on`: one run's first
encounter was refused as `stale` because the model had not yet read the
death.

## What was built and tested

Built and tested on 5 October 2026 against Mineclonia (Luanti 5.17 Flatpak
server, a CPU rendered Goanna client as the player, the director driven
through `tools/goanna-director-cli`): 46 checks, none failed.

- **Files.** `director/catalogue.lua`, `director/rewards.lua` and
  `director/structures.lua` are the cores; `adapters/mcl_items.lua` and
  `adapters/mcl_structures.lua` are Mineclonia's. `init.lua` now picks one
  adapter per kind (`mobs`, `items`, `structures`). The pure parts (search,
  item value, schematic parsing, build order) are in `logic.lua` with unit
  tests in `tools/test/test-director-logic.lua`.
- **Catalogue.** All three adapters matched. 3,184 nodes, 512 items, 207
  tools, 81 creatures, 203 other entities, 39 enchantments, 57 structures
  and 219 mods; a repeated question came from the MCP service's cache.
- **Rewards.** A diamond sword named "Thornbite", with Sharpness III and a
  line of description, cost 12 points (9 for a diamond tier sword, 3 for the
  enchantment) and was dropped by the player; the player picked it up and
  their inventory showed the name, Sharpness III and the line in the game's
  own tooltip. Undo then left it with them. Sharpness V with Unbreaking III
  was refused as over the cap, and Sharpness on bread as `cannot_enchant`.
  Bread in a chest appeared on the player's client, and undo removed the
  untouched chest. A villager carried apples from 10 nodes away and dropped
  them in front of the player.
- **Structures.** A lava schematic was refused, and so was a hut on the
  player's own position. An authored 5 by 5 hut appeared on the player's
  client and undo took it away. The game's desert well was placed through
  `mcl_structures.place_structure` (99 nodes changed) and undone, and so was
  the igloo's top as a plain schematic (153 nodes). A witch hut was refused
  as `not_flat` on hilly ground, which is the site check working.
- **Building.** A villager walked to the site and laid a 3 by 3 by 5 cobble
  tower (41 nodes, at the default four a second), reported `built`, and
  undo took it down.
- **Mineclonia's level generator.** With it on (the default in this
  release), `mcl_structures` does not register the temples, huts, shipwrecks
  and ruins, because the level generator places them inside map generation,
  where nothing can call it at run time. The adapter offers their schematic
  files instead, as plain buildings without loot (`loot: false` in the
  catalogue). A desert temple placed this way stands on the ground with its
  base showing, since map generation sinks it 12 nodes.

Not tested: a world with `goanna_director_structures` off (the refusal is
one line), a restart between placing and undoing (undo records last for the
session only, as with every other undo), `player_built` refusals from a
player's digging, and any game but Mineclonia. Goanna's launcher leaves
structures off and rewrites the server's settings on every launch, so there
is not yet a way to turn them on for a world started from Goanna's menu.

## What was tested

`tools/test/test-director.py --ruleset` on 6 October 2026: the Luanti 5.17.0
Flatpak server (`org.luanti.luanti`), Mineclonia release 38561, mapgen v7,
a fresh scratch world with a probe mod written by the test into its
`worldmods`; the file transport; one Goanna client (Godot 4.5.1 stable,
the client library as built in `project/bin` at 23:06 on 5 October) as the
player alice, started with `software` in headless gamescope (which device
gamescope itself chose was not checked); the MCP service driven over stdio
JSON-RPC by the script. 44 checks passed:

- With `goanna_director = false`, the probe found no `goanna_director`
  table and loaded. With it true, a ruleset named `director` and an intent
  named `speak` were refused, and the probe's ruleset was registered.
- The service listed `probe_mark`, `probe_ring` and `probe_tally` after the
  hello, sent `notifications/tools/list_changed`, kept the 17 fixed tools,
  and gave `probe_mark` the ruleset's schema with `reason` added. The brief
  named the ruleset.
- `probe_mark` set a node near alice, cost 3 of the ruleset's 5 points, and
  returned the sequence number `emit` gave its event, which arrived with
  that number. A second was refused as `budget`; a forbidden label as
  `rules` with the ruleset's `bad_label`; a missing or too long argument as
  `schema`; a point 25000 nodes away as `not_loaded`. A query with a bad
  argument was refused as `schema`. A paced intent ran at once while alice
  was in a build up. `director_undo` put the node back.
- `Warden, open the gate` from alice's client reached the model as
  `npc_addressed` with the ruleset's data; `wardens are boring` stayed
  ordinary chat. The model spoke as the Warden, whose body was 1000 nodes
  away, and alice's client showed `Warden of the Gate (NPC): ...` with the
  escape sequence in the text stripped; a line with a figure the probe's
  check refused came back as `rules` / `not_known`; a speaker named after a
  player was refused as `name_taken`; a burst of the Warden's lines was cut
  off by the speech rate limit (`rate`).
- `director_stop` called `on_stop`, `connected()` read false until
  `/director start`, and a ruleset intent was refused as `stopped` meanwhile.
  `pacing("alice")` read `build_up`, and `opted_out` read false for alice
  and nil for a name never seen.
- The audit log held the ruleset's intents with outcome, refusal and undo
  record, and the server log had no director warnings or errors beyond the
  two deliberate refusals.

With no ruleset registered, the Phase 1 test (`tools/test/test-director.py`,
same server and game) first ran with software rendered clients and passed its
first 36 checks before it was stopped on request, to keep clients in gamescope
off a machine where another session held the GPU. It was then run whole with
`--dummy`, which starts each player as Godot `--headless` (the dummy renderer,
no gamescope, no Vulkan device), on 6 October 2026: all 62 checks passed,
including the kill, the opt out, the service restart and stop. One earlier
`--dummy` run failed only the kill check, with alice's blows not landing on the
villager at 2.1 nodes; the next run killed it, so that check is sensitive to
aim, not to the renderer.

Not tried: a paced intent that had to wait in the queue (the player was in
a build up throughout, so only the path that applies at once ran); `stale`
and `opted_out` for a ruleset intent's subjects; a ruleset hook that raises
an error; two rulesets claiming the same chat line; the HTTP transport with
a ruleset (only the file transport ran); the voice and watcher roles' tool
lists, which were checked offline only; an MCP client other than the test
script receiving the list change notice; any language model; and DorfCraft
or Kythen themselves, neither of which has a ruleset yet.
