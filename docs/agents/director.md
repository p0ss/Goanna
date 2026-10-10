# The director

The director lets a language model run a Luanti world the way a game master runs
a table. It watches what players do, stages encounters, offers quests whose
conditions the game checks, speaks as creatures and characters, and keeps story
arcs and relationships going across sessions. The reference points are Left 4
Dead's AI director, which paces threats against each survivor's stress, and a DM
running a Neverwinter Nights module, who possesses creatures and talks to
players in character. It is not a way to drive a player avatar. Walking, digging
and crafting belong to the player agent interface in
`docs/agents/agent-interfaces.md`, and a model that has to walk to a village to
change it makes a poor game master.

One rule holds the design together: **the model proposes and the game decides.**
Every action is an intent that Lua validates against the game's own rules, the
operator's budgets and the world's protection before anything happens, and a
deterministic pacing layer decides when. The model is never in the per step
loop, and the game never waits for it.

Status: Phase 1, scoped to the first playtest, was built on 1 October 2026
and has been tested by a script, not yet by a model or by players. The
catalogue, rewards and structures followed on 5 October 2026 and game
rulesets on 6 October 2026. This page describes what is built. The
[director design](../design/director-design.md) of 19 September 2026 holds
the full model, the reasoning behind it and the decisions the maintainer
has settled since. The [director log](../history/director-log.md) records
what each test ran on, which server and game, and what it showed.
[Setting up a director](../host/director-setup.md) is the guide for server
owners.

## In brief

- **Server half:** a new capability of `goanna_server_mod`, off unless the
  operator enables it, and on for worlds Goanna launches.
- **MCP half:** `tools/goanna-director-mcp`, an MCP server with only
  `director_*` tools. The design put them in `tools/goanna-mcp`; see [MCP
  half](../design/director-design.md#mcp-half) for why they are separate.
- **Transports:** a seat (a headless Goanna client on its own account) relaying
  over a private mod channel, or the server mod calling the MCP service over
  Luanti's HTTP API. The same messages travel on both. The decided transport
  needs one amendment: director traffic cannot ride `goanna:v1` itself, because
  Luanti relays every message on a channel to every client on it. See
  [Transports](../design/director-design.md#transports).
- **Three layers:** an engine layer that works in any game, framework adapters
  detected at runtime (mob, armour and weather frameworks), and game rulesets
  that replace generic actions with better ones. Kythen's is proposed in detail.
- **Verified on real servers:** biome queries and where they go wrong,
  decorations and mob spawn tables per biome, the item catalogue, entities in an
  area with stable GUIDs, spawning, teleporting, naming, freezing and targeting
  mobs through mcl_mobs and mobs_redo, a removal hook that works in any game,
  weather through mcl_weather, the HTTP transport, and the real cost of the
  async environment.
- **Not verified:** anything that needs a connected player, the mod channel
  transport end to end, creatura, VoxeLibre's mcl_mobs, and any model.

## Phase 1 as built

Built on 1 October 2026 for the first playtest, and tested by a script that
plays the model's part (below). No language model has driven it yet, and no
tester has played it. Nothing has moved in `README.md`.

### Files

```
goanna_server_mod/init.lua            requests the HTTP API at load, when
                                      goanna_director is true, and hands it on
goanna_server_mod/director/
    init.lua        settings, conf file and token, session, the hook table
    logic.lua       ring buffer, budgets, rate limits, pacing, composition,
                    gear score, memory; no engine calls (unit tested)
    events.lua      engine callbacks, per player state, the one second tick
    summaries.lua   player and region summaries, status, capabilities
    intents.lua     the intent pipeline, queries, stop and undo
    commands.lua    the joiner notice, /director, the opt out
    audit.lua       the audit log
    http.lua        the HTTP transport
    adapters/mcl_mobs.lua   Mineclonia's mcl_mobs and mcl_armor
tools/goanna-director-mcp             the MCP service and HTTP endpoint
tools/test/test-director-logic.lua         unit tests for logic.lua (LuaJIT)
tools/test/test-director.py                the end to end test
```

The layout differs from the proposal in [Server
half](../design/director-design.md#server-half): pacing and memory are small
enough to live in `logic.lua` and `intents.lua`, there are no quests, and there
is no channel transport. `project/local_server.gd` lists the director's files in
`GOANNA_SERVER_MOD_FILES` (creating the subdirectories as it copies), writes
`goanna_director = true` and `secure.http_mods = goanna_server_mod` for every
world it launches, and the vendored copy in `project/vendor/goanna_server_mod`
is kept identical, which `project/tests/local_server_terrain_diffusion.gd`
checks.

### Transport

Since 5 October 2026 a world started from Goanna uses the file transport
(`director/filelink.lua`), and HTTP is the choice for a server on another
machine (`goanna_director_transport = http`). Goanna's bundled Linux server
is built without curl, so on a machine with no other Luanti the HTTP
transport could never work, and a player setting the director up had to
find `secure.http_mods` in a configuration file the launcher rewrites. The
file transport carries the same envelopes and messages through
`<world>/goanna_director/link/`: one file per message in `in/`, one batch
per server step in `out/`, and a heartbeat each way (`director.json`,
`server.json`). Each file is written whole and renamed. The inbox is read
on every server step, so a round trip, measured with the shell bridge
against the bundled server, took 0.08 to 0.2 seconds, including starting
the command each time. The catalogue, rewards and structures test
(51 checks by then) passed over it, against the Flatpak server.
Writes are a few small files a second at most, and none while nothing
happens. Kythen's villages, if each gets an agent, share one service and
one link, told apart by the envelope's `scope`.

The HTTP transport, as [HTTP](../design/director-design.md#http) proposed:

- `POST <url>/v1/push`, body `{"v": 1, "session": "...", "batch": [...]}`,
  where each element is an envelope (`v`, `kind`, `scope`, `session`, `t`,
  `body`). Kinds sent: `hello` (session, `last_seq`, capabilities, open
  encounters, cast characters, stop state), `events` (with `seq` and
  `body.events`, `body.gap`), `result` and `reply`. The endpoint answers
  `{"known_session": bool}`; false makes the server say hello again, which is
  how a restarted MCP service picks the session up.
- `GET <url>/v1/pull?scope=gm&after=N&wait=20&session=S&instance=I`, a long
  poll. The answer is `{"v": 1, "messages": [...], "auth": A, "instance": I}`
  where each message is `{"id", "req", "kind": "act" | "query", "type",
  "args", "based_on", "reason", "scope"}`, and `A` is the hex SHA-256 of
  `token:session:after`. The server ignores an answer whose proof is wrong,
  so a process that happens to hold the port cannot drive it. Message ids
  belong to one endpoint process (`instance`); a new instance starts them
  again.
- Both directions carry `Authorization: Bearer <token>`. The endpoint binds
  127.0.0.1 only.
- A result body is `{"id", "type", "status", "reason", ...}` with the statuses
  of [Envelope](../design/director-design.md#envelope). Reasons used so far:
  `schema`, `not_online`, `opted_out`, `stale`, `budget`, `entity_cap`,
  `no_fauna`, `unknown_mob`, `denied`, `budget_too_small`, `pacing`, `no_place`,
  `no_adapter`, `name_taken`, `name_in_use`, `hostile_npc`, `unknown_speaker`,
  `speaker_gone`, `out_of_earshot`, `no_listeners`, `rate`, `too_long`,
  `memory_text_off`, `unknown_action`, `stopped`.

The director counts as connected only once a pull answer carries a valid
proof. Players are told it is active from then, not before.

### MCP tools

`tools/goanna-director-mcp --world <world>` reads the url and token from the
world's `goanna_director.conf` and serves 17 tools, and since 6 October 2026
one more for each intent and query a game's ruleset registers ([Rulesets as
built](#rulesets-as-built)). They were reworked on 5
October 2026 for a model's sake: a menu of tools each with an exact schema
is easier to call correctly than a few tools whose arguments depend on one
another.

| Tool | Message |
| --- | --- |
| `director_status` | a short brief: connection, game, which features are on, budgets left, players' phases, characters and their orders, the catalogue fingerprint; `detail: true` gives the full `status` query and the hello |
| `director_events` | the events buffered since the model last asked, waiting up to `wait_s`, with results of queued intents that landed later |
| `director_player` | `player` query: the summary, with its region summary |
| `director_catalogue` | `catalogue` query, cached by fingerprint |
| `director_memory` | `memory` query |
| `director_stage_encounter` | `stage_encounter` |
| `director_cast_npc` | `cast_npc` |
| `director_move` | `order` with a goal: hold, watch, go_to, stay, patrol, follow |
| `director_attack` | `order` attack |
| `director_build` | `order` build |
| `director_interact` | `order` hold_item or offer_trade |
| `director_speak` | `speak` |
| `director_remember` | `remember` |
| `director_grant_reward` | `grant_reward` |
| `director_place_structure` | `place_structure` |
| `director_undo` | `undo` |
| `director_stop` | `stop` |

- **One vocabulary.** `npc` is the character who acts, `player` is whom it
  concerns, `target` is whom an act is aimed at, `at` is always a point
  `[x, y, z]`, and `near` with `distance` (`[min, max]`) always means "find
  a place near this player". A follow range is `range`. A character's
  `speak` to `all` means everyone within its earshot, as the narrator's
  means everyone.
- **Follow ups.** An act that is `accepted` or `queued` comes back with
  `follow_up`, naming the event its outcome will arrive as and the act id to
  match (`npc_order`, `structure_placed` or `structure_failed`,
  `encounter_started`, `encounter_ended`). A standing goal (hold, watch,
  stay, patrol, follow) says it reports only when it fails or is replaced.
- **Instructions.** The service's MCP `initialize` answer carries a short
  guide for the role: start with the brief, search the catalogue rather than
  guess names, read events before and after acting.
- **Roles.** `--role gm` (the default) offers every tool. `--role voice`
  offers status, events, player, memory, speak and remember, for an agent
  that only speaks for characters; `--role watcher` offers only the reading
  tools. The role is the menu, not the authority: every act still carries
  the `gm` scope and the server mod checks it, so per scope limits on the
  server side remain part of the sub-director work.
  `tools/goanna-director-cli --role voice` serves a role on a socket of
  its own.

An act carries `based_on`, the last event sequence returned to the model.

### What it does

- **Encounters.** `stage_encounter` takes `near`, `budget`, `theme` (a mob
  category, default `monster`) or `mobs` (names), `when`, `distance`,
  `hidden`, `leash_s` and `valid_for_s`. The budget is capped at the player's
  encounter ceiling, `goanna_director_encounter_base` plus the gear score
  times `goanna_director_encounter_per_gear`, and must fit what is left of
  the hourly points. Mobs come from the player's biome's fauna or the named
  list, minus the deny list, drawn by weight with a `PcgRandom` seeded from
  the world seed and session. Each is placed on loaded, clear, walkable,
  unprotected ground, out of the player's sight unless `hidden` is false,
  away from static spawn and from every opted out player; made persistent;
  given the director's targeting rule; and removed when the leash runs out,
  the player leaves, dies or opts out, or the encounter is undone. Outside a
  build up, `when: "now"` is refused and `next_build_up` is queued.
- **Characters.** `cast_npc` was not in the design. A character needs a body
  to speak from, and a fresh world has no villagers near the player, so the
  director may spawn a peaceful mob (default `mobs_mc:villager`) a few nodes
  from a player, named, and held in place, or name an existing mob by GUID.
  Monsters are refused, and so is a name any player account has.
- **Speech.** `speak` sends one chat line. A character's line reads
  `Grimbold (NPC): text` and goes only to players within
  `goanna_director_earshot` of its body; narration reads `[Narrator] text`
  and goes to one player or all. Escape sequences and newlines are stripped,
  so a line cannot recolour itself or pose as another speaker.
- **Memory.** Per character and player, for the session only: when they
  met, lines spoken, times addressed, a disposition, and facts. Facts come
  from events (`saw alice kill a zombie`, `was killed by alice`) or from
  `remember`, capped by `goanna_director_memory_lines` and
  `goanna_director_memory_chars`, oldest first out, each in the audit log.
  An `npc_addressed` event carries the character's memory of the speaker.
- **Pacing** is the layer in [Pacing](../design/director-design.md#pacing), per
  player, with the thresholds as settings and a short relax on joining
  (`goanna_director_join_grace`).
- **Holding a mob.** The probe froze a mob by shadowing `on_step`. That
  turned out to be unsafe: a villager killed while held that way crashed
  the server, because its murder report reads a cache only `on_step`
  creates. A held character now uses mcl_mobs' own `stupefied` state, which
  keeps physics, damage and death running and only stops the AI.

### Orders for characters

An order gives a cast character a goal it carries out by itself
(`goanna_server_mod/director/orders.lua`; the tools are `director_move`,
`director_attack`, `director_build` and `director_interact`), so the model
says what and the
character works out how: `hold`, `watch` a target, `go_to` a point or a
target and then `stay`, `stay` at a point and walk back when moved,
`patrol` up to twelve points with a pause at each, `follow` within a
distance range (a larger range hangs back), `attack`, `hold_item` and
`offer_trade`. Each ends with an `npc_order` event (arrived, lost, leash,
failed, replaced). Movement uses mcl_mobs' own pathfinder with the
character's AI still off, so it never wanders from an order; a held mob
walks waypoints but skips the path search itself, so the adapter advances
the search. `director_status` reports each character's position and order.

Attacking is for a mob that can fight: a villager has no attack and is
refused. A monster can only be a character when cast with `armed: true`,
which charges and paces it as an encounter on the player it is cast near
(ceiling, hourly points, build up). An attack on a player passes the same
checks again; the attacker's AI runs with the director's rule as its only
target source, so it fights whom it was ordered to and nobody else, and it
is held again when the target is gone, the player opts out or `leash_s`
ends. Trading sets a profession when asked (or farmer when it has none),
gives the villager a little experience so mobs_mc does not take the
profession back for want of a job site, and opens its trades on the
player's screen, at most three times a minute per player.

Tested on 5 October 2026 (Mineclonia, Luanti 5.17, a CPU rendered Goanna
client as the player): watch, hold_item, go_to with arrival reported and
stay after it, patrol visiting both points, follow (see the correction
below),
offer_trade opening the trading form on the player's screen, and a
villager refused as `cannot_attack`. An armed vindicator was refused as
`over_ceiling` (cost 14 against the player's 10), as it should be; an armed
husk (cost 5) was accepted, ordered to attack the player and took them
from 20 health to 17, stood down when its 20 s leash ended, then killed a
cast villager when ordered to, and was undone.

Correction, found later the same day: that run moved the player with
`/teleport tester x y z`, which Luanti refuses without saying so (it takes
`x,y,z` with commas), so the player never moved and "follow" was only shown
for a target already in range. The test in [Catalogue, rewards and
structures](#catalogue-rewards-and-structures) teleports correctly, checks
that the player really moved, and saw a cast villager follow the player over
about 12 nodes to within its range.

### Not verified

- Any language model driving it, and any playtest with people.
- Armour in the gear score: only the weapon half was exercised.
- `goanna_director_spawn_rules = natural`, `goanna_director_sees = coarse`,
  `goanna_director_chat = all`, and the exclusion zone around a player who
  opted out (the refusal for the opted out player was tested, the zone for
  others near them was not).
- A world launched from Goanna's menu with the director on. The deployment
  of the files is covered by the existing headless test; the two settings
  `local_server.gd` writes were read, not run.
- A server restart mid session, `stale` from a leave, and encounters ending
  by leash.
- Mobs other than skeletons and villagers, and any game but Mineclonia.

## Catalogue, rewards and structures

Designed on 5 October 2026, after the orders. A director that only stages
fights and speaks runs out of things to do. It also wants to know what the
world contains, to give a player a named or enchanted item, to put a house or
a ruin somewhere, and to have a character build one. This section is the
design. What has been built and tested is recorded under each heading as it
lands.

The rule throughout is the one in [Framework
adapters](../design/director-design.md#framework-adapters): the core works on
the engine alone, and an adapter adds what only a framework knows. Every new
part below has a core that runs in any game and degrades plainly where no
adapter matched, and a Mineclonia adapter that adds the game's own enchantments,
containers and structures. Adapters are chosen per kind (`mobs`, `items`,
`structures`), each by `detect()` testing the tables it needs, so a VoxeLibre or
Minetest Game adapter is a new file, not a change to the core.

### Catalogue

The model should not be sent every item at every turn: Mineclonia registers
about 3,000 items, 81 mobs and 50 structures. The catalogue is a query that
answers in pages, and a fingerprint that tells the model when what it already
knows is out of date.

- **Built from the engine.** Items, nodes and tools come from
  `core.registered_items`, with their mod, kind, description (first line,
  escapes stripped) and groups. Mods come from `core.get_modnames()` and the
  game from `core.get_game_info()`. Entities come from
  `core.registered_entities`. Items hidden from the creative inventory
  (`not_in_creative_inventory`) are left out unless asked for, because games
  use them for technical nodes.
- **Enriched by adapters.** The mob adapter marks which entities are
  creatures, with category and cost. The items adapter lists enchantments
  with their maximum level and whether they are a curse or treasure, and says
  which items can carry them. The structures adapter lists the game's own
  structures with their size.
- **Query.** `catalogue` takes `kind` (`item`, `node`, `tool`, `creature`,
  `enchantment`, `structure`, `mod`), `text` (matched against name and
  description), `group`, `mod`, `limit` (default 40, at most 200) and
  `cursor`. Each answer is one short record per entry, the total, and the
  next cursor.
- **Overview.** With no arguments it returns the game, the mods, the
  fingerprint and counts by kind and by mod, so the model knows where to
  look before it searches.
- **Fingerprint.** A hash of the game, its mods and every registered name.
  It is in the hello and in `status`. The MCP service caches answers by
  fingerprint, so a repeated question costs the server nothing until a mod
  changes.

### Rewards

`grant_reward` makes an item and puts it where a player can choose to take
it. It is never put into a player's inventory, because a player has to be
able to refuse a gift from a machine and an inventory can be full.

- **The item.** Any catalogue item and count, an optional name, up to four
  short lines of description, and, through the items adapter, enchantments
  with levels. The core sets the name and lines through item metadata, which
  every client shows. The Mineclonia adapter names an item the way its anvil
  does (the `name` field, then `tt.reload_itemstack_description`) and
  enchants it with `mcl_enchanting.enchant`, after `mcl_enchanting.can_enchant`
  accepts each enchantment. Text is cleaned like speech.
- **Delivery.** `drop` (the core: an item entity on the ground near the
  player, made persistent until taken), `container` (a container node placed
  on clear ground near the player and filled; the adapter names the node,
  `mcl_chests:chest_small` in Mineclonia), or `npc` (a cast character walks
  to the player and drops it in front of them, holding it on the way).
- **Budget.** Rewards have their own hourly points
  (`goanna_director_reward_points_per_hour`), separate from encounters, so
  a generous director cannot buy fights and a violent one cannot buy loot.
  The cost is the item's value times the count, plus each enchantment's
  level. Value comes from the adapter where the game has a notion of it, and
  otherwise from the engine: a tool by its damage and dig level, anything
  else one point per full stack. Each reward is also capped at
  `goanna_director_reward_max` points, and `goanna_director_reward_deny`
  lists items that are never granted.
- **Undo.** Removes the item or container if nobody has taken it, and
  restores the ground under a container. Once a player has picked it up it is
  theirs, and undo says so.

### Structures

`place_structure` puts a building in the world. It is the largest change a
director can make, so it is off unless the operator sets
`goanna_director_structures = true`.

- **Two sources.**
  - **The game's own** through the structures adapter: Mineclonia's
    `mcl_structures.place_structure` with the game's loot and setup. Only
    structures whose size the adapter can work out before placing are
    offered, which in Mineclonia means those built from schematic files
    (read with `core.read_schematic`); structures made by a function (the
    igloo, geodes) are not.
  - **Authored by the director** in the core: a palette of one character
    keys to catalogue nodes, and layers from the bottom up, each a list of
    rows along z, each a string along x. A space leaves the world's node, and
    `air` clears it. Placed with `core.place_schematic`. Nodes that hurt
    (`damage_per_second` above zero), explode (group `tnt`) or are hidden
    from the creative inventory are refused, so an authored schematic cannot
    be a trap.
- **Where.** At a position or near a player, on ground that is loaded,
  wholly unprotected (`core.is_area_protected`), clear of every player's body,
  away from static spawn and from players who opted out, and in no mapblock a
  player has dug or built in. The director records which mapblocks players
  change, in mod storage, from the moment it is first switched on in a world;
  changes from before then are not known to it, which is why protection is
  checked as well.
- **Budget.** `goanna_director_build_nodes_per_hour` counts nodes changed,
  and `goanna_director_structure_max_volume` caps one placement's bounding
  box.
- **Undo.** Before placing, the box (plus a margin, since the game's
  structures may lay a foundation) is read with a VoxelManip, with every
  node's metadata. Undo writes it back, except nodes a player has changed
  since, which stay as the player left them. Anything stored in a container
  the structure created is dropped on the ground rather than deleted, so a
  player loses nothing they put there. Creatures that appeared in the box
  are removed. Undo lasts for the server session, like every other undo
  record.

### Building

The `build` order has a cast character put up a schematic over time: the
same two sources and the same checks, budget and undo snapshot as
`place_structure`, all taken when the order is accepted. The character walks
to the site and places a few nodes a second
(`goanna_director_build_rate`), bottom layer first, holding the node it is
placing, and skips any position a player has changed since the order began.
It reports progress in `status` and ends with an `npc_order` event. A game
structure is built from its schematic alone, so it has no loot. A character
builds whatever its body is: a villager is a builder, but nothing here gives
it an inventory to take the nodes from, so the director's budget is what the
nodes cost.

## Rulesets as built

Built on 6 October 2026, so that a game or mod can add its own intents,
queries and characters without editing Goanna. The first consumer is
DorfCraft's fortress director (its `docs/director-integration.md`, "Proposed
Goanna changes", items 1 to 4); Kythen is the next. Items 5 to 8 of that list
(a memory hook, adopting cast characters, `make_item` and a voice scope) are
not built; see [Not built yet](#not-built-yet).

The code is `goanna_server_mod/director/rulesets.lua`, with the schema check
and name rules in `logic.lua`, and the tool generation in
`tools/goanna-director-mcp`.

### Registering a ruleset

A mod declares `optional_depends = goanna_server_mod` and registers at load
time, only when the table exists, so it loads unchanged on a server without
Goanna's mod or with the director off (`goanna_director` is then absent):

```lua
local api = rawget(_G, "goanna_director")
if api then
    local ok, why = api.register_ruleset("fortress", {
        description = "Fortresses: officers, workshops and their books.",
        capabilities = {},              -- any table, shown to the model as is
        points_per_hour = 20,           -- optional; caps what costs add up to
        intents = {
            work_order = {
                description = "Put an order in a workshop's queue.",
                -- The JSON Schema subset below. The same table is checked
                -- here and given to the model as the tool's input schema.
                schema = {type = "object", required = {"fortress", "item"},
                    properties = {fortress = {type = "string"},
                        item = {type = "string"},
                        count = {type = "integer", minimum = 1, maximum = 64}}},
                scope = function(scope, args, ctx) end,   -- ok, rule, detail
                subjects = function(args, ctx) end,       -- {player names}
                cost = 1,                    -- or function(args, ctx) -> n
                rules = function(args, ctx) end,          -- ok, rule, detail
                places = function(args, ctx) end,         -- {positions}
                paced = false,
                follow_up = "work_order_done",            -- an event name
                -- result table (status "accepted" for something that
                -- carries on, else "completed"), and an undo record; or
                -- false, rule, detail to refuse after all.
                apply = function(args, ctx) end,
                undo = function(record, ctx) end,         -- fields
            },
        },
        queries = {
            fortress = {
                description = "A fortress's summary.",
                schema = {type = "object", required = {"id"},
                    properties = {id = {type = "string"}}},
                answer = function(args, ctx) end,         -- any table
            },
        },
        undo = function(record, ctx) end,     -- for intents without their own
        on_stop = function(by, reason) end,   -- /director stop or director_stop
        addressed = function(player, message) end,   -- nil or {npc, data}
        speaker = function(name) end,   -- nil or {name, label, pos, remote}
        speak = function(speaker, text, listeners) end,   -- ok, rule, detail
        spoken = function(speaker, text, delivered) end,
    })
end
```

`register_ruleset` returns true, or false and why, and logs the reason as an
error. Nothing is registered unless the whole definition is sound. Ruleset,
intent and query names are 1 to 32 of `a-z`, `0-9` and `_`; a ruleset may not
be called `director`, and an intent or query may not take a name the director
or another ruleset already has. Registration after the server's first step
is refused, so the first hello already lists everything. `ctx` is
`{ruleset, act, scope, based_on, reason, queued}`; `act` is the id
`director_undo` takes. Every hook runs under `pcall`: an error refuses that
intent as `error`, answers that query with an error, or is ignored for chat,
and is logged as a warning. It never stops the director.

The schema subset: `type` (`object`, `string`, `number`, `integer`,
`boolean`, `array`), `properties`, `required`, `additionalProperties =
false`, `enum`, `minimum`, `maximum`, `maxLength`, `items`, `maxItems` and
`description`. Arguments outside the schema are passed through unless
`additionalProperties` is false. Luanti writes an empty Lua table as JSON
`null`, so the MCP service restores empty `properties` and `required`.

### The pipeline

A ruleset's intent runs through the same nine steps as the director's own,
and the result and audit line have the same shape. What each step asks of
the ruleset:

1. **Schema.** The director checks the arguments against `schema`; a
   failure is `schema` with a `detail` naming the argument.
2. **Scope.** Every scope but `gm` is still refused for every intent, the
   ruleset's included. `scope(scope, args, ctx)` may then refuse what `gm`
   asks about this subject, as `not_in_scope` with the ruleset's `rule`.
   `subjects(args, ctx)` names the players the intent concerns: one who
   opted out refuses it as `opted_out`, and one who joined, left or died
   since the model's `based_on` makes it `stale`, as for an encounter.
3. **Stop.** Everything is refused while the director is stopped.
4. **Budget.** `cost` (a number, or a function of the arguments) is
   charged to the ruleset's own hourly points, separate from encounters and
   rewards, and only when the intent is applied. The operator's
   `goanna_director_<ruleset>_points_per_hour` overrides the ruleset's
   `points_per_hour`; with neither, costs are reported and not capped.
5. **Rules.** `rules(args, ctx)` returns true, or false with the ruleset's
   own reason, which the model receives as reason `rules` with that `rule`
   and `detail`.
6. **Place.** Every position `places(args, ctx)` returns must be loaded,
   unprotected (`core.is_protected` for nobody), and clear of static spawn
   and of players who opted out (`not_loaded`, `protected`, `spawn`,
   `opted_out_player_near`).
7. **Pacing.** A `paced` intent waits in the director's queue until every
   online subject is in a build up, and comes back as a late result, or is
   refused as `pacing` when its arguments say `when = "now"`. It expires
   after `valid_for_s` (at most `goanna_director_queue_s`), and stop
   cancels it.
8. **Apply.** `apply(args, ctx)` does the work through the game's own entry
   points and returns its result fields and an undo record, which must be
   plain data, since it goes into the audit log. `director_undo` with the
   act's id calls the intent's `undo` (or the ruleset's) with that record.
9. **Audit.** One line per intent, with the arguments, the outcome, the
   result as effects, the subjects and the undo record.

Queries are checked against their schema and answered by `answer(args,
ctx)`; whatever they leave out for players who opted out is the ruleset's
to leave out (`goanna_director.opted_out` below).

`on_stop(by, reason)` is called when the operator or the model stops the
director, after the director has removed its own creatures, so a ruleset can
end what it started for the director (DorfCraft's sieges). Each ruleset's
intents, queries, descriptions, schemas, `capabilities`, points left and
whether each intent is paced or undoable are in the `capabilities` query and
in every hello, under `rulesets`.

### Characters the director did not cast

- **Chat addressed to them.** The chat callback asks each ruleset's
  `addressed(player, message)`, in the order they registered, after the
  director's cast characters and only for a public line from a player who
  has not opted out, while `goanna_director_chat` is not `none`. A ruleset
  claims the line by returning `{npc = "Urist", data = {...}}`, with a valid
  character name; the director emits `npc_addressed` with the ruleset's
  data plus `npc`, `ruleset` and the line (at most 280 characters), and the
  line is not reported again as `player_chat`. The line stays in public chat
  either way, as on any server.
- **Speech.** When `speak` names someone who is not the narrator and not a
  cast character, each ruleset's `speaker(name)` is asked. It returns the
  speaker's `name`, a `label` (at most 60 characters), the body's `pos` if
  it has one, and `remote`, the players who may hear it from afar (a set or
  a list). Players within `goanna_director_earshot` of `pos` read
  `Urist (NPC): text`; players in `remote` beyond it read
  `<label> (NPC): text`. The name must be a valid character name and no
  player's (`name_taken`), so a ruleset's speaker cannot pass for a player,
  and the `(NPC)` mark stays on both lines for the same reason. The text is
  cleaned of escapes and newlines and capped as before, and the speaker and
  listener rate limits apply to it by name. The ruleset's `speak(speaker,
  text, listeners)` sees the line before it goes out and may refuse it
  (reason `rules`, with its `rule`, such as DorfCraft's figures check);
  `spoken(speaker, text, delivered)` is told who received it. The
  director's own memory is not kept for a ruleset's speakers.

### Small reads

- `goanna_director.connected()`: true while a director is connected and not
  stopped.
- `goanna_director.opted_out(name)`: true or false for a player seen since
  the server started, nil for one who has not been. The director now keeps
  this for players who have left, too, so an event a ruleset emits about a
  player who opted out and then left is still dropped.
- `goanna_director.pacing(name)`: the player's phase and intensity, or nil
  when they are offline or opted out.
- `goanna_director.emit(event)` returns the event's sequence number, or nil
  when it was dropped because it names a player who opted out.

### MCP tools for rulesets

`tools/goanna-director-mcp` turns each ruleset intent and query in the hello
into a tool named `<ruleset>_<name>` (`fortress_work_order`), with the
ruleset's description and schema, and `reason` added as a required argument
of every intent. A game master gets all of them, `--role watcher` only the
queries, `--role voice` none. The fixed 17 tools are unchanged. A ruleset's
tools exist only once a server has said hello, which is usually after the
MCP client has listed the tools, so the service declares `listChanged` and
sends `notifications/tools/list_changed` when the set changes.
`tools/goanna-director-cli` calls a ruleset's tool by its own name.

### Where it departs from the design

- Hooks take `(args, ctx)`, with the scope in `ctx`, rather than `(scope,
  args)`. The design's single `validate` is split into `scope`, `subjects`,
  `cost`, `rules` and `places`, so that the director runs the opt out,
  budget, protection and pacing steps itself rather than trusting each
  ruleset to.
- The design's `speakers(scope)` list became `speaker(name)`, which can
  carry a position and players to reach from afar, as DorfCraft asked, and
  `spoken` was added so a ruleset can keep its own record of what was said.
- DorfCraft asked for the remote line to read
  `Urist, quartermaster of Deepdelve: text`. It reads
  `Urist, quartermaster of Deepdelve (NPC): text`, because without the mark
  a label could be any text, a player's name among them.
- A ruleset's refusal arrives as reason `rules` with the ruleset's word in
  `rule`, not as its own reason, so a model can always tell the game's rules
  from the director's limits. DorfCraft's `not_known` is `rule`.
- `addressed(player, message)` and `on_stop` were not in the design; they
  are as DorfCraft proposed.

### Not built yet

`replaces`, `knowledge`, `value` and the `events` hook of the design (`emit`
serves for events); `register_condition`; any scope but `gm`; a memory hook
so `remember` and `memory` reach a ruleset's characters;
`goanna_director.npc(name)` and `release(name)` for adopting cast
characters; `goanna_director.make_item(spec)`; and a `voice` scope with
server side limits. These are DorfCraft's items 5 to 8 and remain future
work.

## Open questions

1. **Transport order.** Build the spike on HTTP and the seat second, as
   recommended above, or keep the decided order and accept the Goanna client
   work and a second client in the spike?
2. **Private channel.** Is a derived channel name, with the token as the
   capability, acceptable, given that anyone who learns the name can listen
   until the token is changed?
3. **Hosted worlds.** Should `goanna_director` be on for every world Goanna
   launches, or only for single player launches, with a hosted world asking the
   host first?
4. **What the game master sees.** Exact positions and full inventories of every
   player (the operator can see them anyway), or coarser views by default?
5. **Public chat.** Decided 2026-10-01: all public chat, never direct
   messages or group chats.
6. **Rewards.** An allow list per game, a value heuristic, or the game's own
   numbers where they exist?
7. **Model cadence and cost.** How often a model is called, which model for a
   game master and which for voices, and who pays.
8. **Kythen.** Is Kythen willing to add controllers, the new command kinds, a
   per village priority override, institutional knowledge holders and a spirit
   speaker, and in which milestone?
9. **Memory text.** Should NPC memory hold short model written facts at all,
   given moderation and size, or only structured facts from events?
10. **Seat accounting.** Is a hidden seat that games still count as a player
    acceptable, or should the seat transport wait for a Luanti feature that does
    not exist, rather than a workaround in Goanna?
11. **First faction experiment.** Kythen lacks A10 diplomacy and institutional
    knowledge. Run the first multi-model experiment on Kythen anyway, or on a
    simpler game with teams of players as factions?
