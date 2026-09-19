# The director layer

Status: a design, written on 19 September 2026. Nothing in it is built. The only
code is the throwaway probe in `tools/director-probe/`, which exists to check
the engine and framework calls the design depends on. [What was
verified](#what-was-verified) at the end says what ran, on which server and
game, and what did not.

The director lets a language model run a Luanti world the way a game master runs
a table. It watches what players do, stages encounters, offers quests whose
conditions the game checks, speaks as creatures and characters, and keeps story
arcs and relationships going across sessions. The reference points are Left 4
Dead's AI director, which paces threats against each survivor's stress, and a DM
running a Neverwinter Nights module, who possesses creatures and talks to
players in character. It is not a way to drive a player avatar. Walking, digging
and crafting belong to the player agent interface in `docs/agent-interfaces.md`,
and a model that has to walk to a village to change it makes a poor game master.

One rule holds the design together: **the model proposes and the game decides.**
Every action is an intent that Lua validates against the game's own rules, the
operator's budgets and the world's protection before anything happens, and a
deterministic pacing layer decides when. The model is never in the per step
loop, and the game never waits for it.

## In brief

- **Server half:** a new capability of `goanna_server_mod`, off unless the
  operator enables it, and on for worlds Goanna launches.
- **MCP half:** `director_*` tools in `tools/goanna-mcp`, built on the
  multi-instance rewrite.
- **Transports:** a seat (a headless Goanna client on its own account) relaying
  over a private mod channel, or the server mod calling the MCP service over
  Luanti's HTTP API. The same messages travel on both. The decided transport
  needs one amendment: director traffic cannot ride `goanna:v1` itself, because
  Luanti relays every message on a channel to every client on it. See
  [Transports](#transports).
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

## What it is for

Three sketches set the bar.

- **A game master in creative Mineclonia, with only the engine layer.** It
  notices that a player has been mining alone for twenty minutes, waits until
  they surface at dusk, and puts three skeletons at the forest edge, sized to
  the armour the player is wearing. Later a villager mentions a ruined tower to
  the north and offers a quest to find it, and the player gets a map when they
  reach it.
- **The same game with adapters, over weeks.** The director keeps a player's arc
  ("spared the witch at the swamp") across sessions and restarts. The witch's
  memory of that player survives both, and changes what she says the next time
  they meet.
- **Kythen.** A director per culture sets village priorities and faction goals
  through Kythen's own command queue, speaks as villagers through Kythen's
  language system and as a mythological figure, and shapes creature populations
  only through ecology levers. Several models, one per faction, each see only
  what their own people know.

A GM with only the engine layer can already do most of the first sketch: see
players and their gear, know the biome and what grows there, spawn and name any
registered entity, freeze it or move it, speak through it, give items, and run
quests on inventory, place and kill conditions. The layers above make it better,
not possible.

## Where it lives

### Server half

A director module inside `goanna_server_mod`, in the manner of `damage.lua` and
`fine.lua`: loaded from `init.lua` with the channel and the settings, and doing
nothing unless `goanna_director` is true. The server has to act, not only
permit, so by the rule in `goanna_server_mod/README.md` it is a submod and not a
setting. Proposed layout:

```
goanna_server_mod/director/
    init.lua        settings, privilege, chat commands, wiring
    events.lua      engine callbacks into a ring buffer
    summaries.lua   player, region and faction summaries
    queries.lua     query handlers
    intents.lua     validation and application of actions
    pacing.lua      per player intensity and phases
    quests.lua      conditions, progress, persistence
    memory.lua      NPC memory and story arcs
    audit.lua       audit log, budgets, undo records
    wire.lua        framing shared by both transports
    channel.lua     private mod channel transport
    http.lua        HTTP transport
    adapters/       mcl_mobs, mobs_redo, creatura, mcl_armor, 3d_armor,
                    mcl_weather, mcl_levelgen
```

Two consequences for Goanna itself:

- `project/local_server.gd` copies the mod file by file from
  `GOANNA_SERVER_MOD_FILES`. A subdirectory needs the tree copy it already has
  (`_copy_resource_tree`).
- `core.request_http_api()` "only works at init time and must be called from the
  mod's main scope" (`lua_api.md`). It is called in `init.lua` at load, kept in
  a local, and passed to `director/http.lua`. It is never a global, because any
  mod could then make requests with the operator's grant.

Enabling follows `goanna_far_rendering` and `goanna_shared_dig_damage`:
`goanna_director` is false in `settingtypes.txt`, and `local_server.gd` writes
it true for a world Goanna launches, because there the player is the operator.
Enabling makes the capability available. Nothing happens until a director
connects.

Nothing secret goes in a `goanna_*` setting, because `options()` in `init.lua`
broadcasts every one to any Goanna client that says hello. The transport secret,
the HTTP endpoint and the seat assignments live in
`<world>/goanna_director.conf`, read with the `Settings` class. The mod creates
it with a random token (`SecureRandom`) on first start. Budgets and limits are
ordinary `goanna_director_*` settings and are broadcast on purpose: players may
read them.

### MCP half

`director_*` tools in `tools/goanna-mcp`, on top of the multi-instance rewrite
on branch `worktree-agent-a26bf3c56cac7885b`, which was reviewed but not merged
when this was written. That rewrite gives each headless client an instance id
and its own control port, which is what the seat transport drives. The director
tools are not the game development interface. They carry no `run`, no `eval` and
no camera. They speak for the server, with the authority the operator gave the
director.

## Boundaries and fairness

`CLAUDE.md` and `docs/capabilities.md` set Goanna's boundaries: it connects to
unmodified servers, asks for nothing a vanilla client does not, never gives a
Goanna player information or reach a vanilla player lacks, never patches Luanti,
and never claims affiliation with the Luanti project. How the director fits:

- **The operator opts in.** It exists only in `goanna_server_mod`, which an
  operator installs, and only when they set `goanna_director`. A server without
  it is untouched. Goanna never runs a director against someone else's server on
  its own initiative.
- **It gives Goanna players nothing.** Everything the director does reaches
  players through ordinary engine channels that a vanilla client renders
  identically: entities, chat, HUD elements, formspecs, sounds and weather. No
  director data goes over `goanna:v1`. Observations travel only on a private
  channel the seat joins, or over HTTP. A Goanna player and a vanilla player in
  the same world meet the same encounters, hear the same speech and get the same
  quests, so the sorting question in `docs/capabilities.md` ("could a player
  make a better decision because of this, that a vanilla player could not?") is
  answered no.
- **In multiplayer the director is its own account, never the model behind a
  player's own client.** The mod enforces it: director messages are accepted
  only from an account that holds the `goanna_director` privilege and does not
  hold `interact`, so a seat cannot also dig, place or fight, and a player's own
  account cannot act as a seat without giving up playing.
- **Players are told.** On join, a chat line says a director is active, which
  scopes are running and where to read more. `/director` shows what it is, its
  budgets, and what it has done near you recently. Director speech is always
  attributed to a named speaker or marked as narration.
- **Public chat only.** The director reads public chat, as the operator can. It
  never sees private messages: builtin's chat command handler
  (`builtin/game/chat.lua`) is registered before any mod and returns true for
  every `/` command, and `register_on_chat_message` callbacks run with
  `RUN_CALLBACKS_MODE_OR_SC` (`src/script/cpp_api/s_server.cpp`), so `/msg`
  never reaches a mod's callback.
- **Nothing in Luanti changes.** The server half is Lua and the MCP half is
  Python. The one Goanna client change, for the seat transport, is joining a
  second mod channel, which is a public Luanti mechanism.
- **Frameworks are adapted, not endorsed.** Adapters read public tables of
  mcl_mobs, mobs_redo and others. None of their authors is involved, and the
  documentation should not suggest otherwise.

## Roles

| Role | Scope | Sees | Can | Cannot |
| --- | --- | --- | --- | --- |
| Game master | `gm` | Every player's summary, position, inventory and gear; all entities; regions; quests, arcs and memory; the whole event stream including public chat | Stage encounters, offer and close quests, speak as any entity or as narrator, spawn rewards, adjust spawning and weather, move, freeze and target mobs, write memory and arcs | Place or dig arbitrary nodes (only reward containers, within budget), take from player inventories, act in protected areas, exceed budgets, act while stopped |
| Faction director | `faction:<id>` | Its members' own state, events its members witnessed, entities and players within their perception, reports members made | Set faction goals, allocate its own people, speak as its members, propose terms to other factions, commit its own forces through the game's rules | Create items or creatures, see other factions' state, command non-members |
| Voice | `voice:<id>` | Speech addressed to its entity, its entity's memory of each player, what its entity perceives (players and creatures within 16 nodes, time, weather), briefs the director wrote for it | Speak, emote, remember, offer quests from templates the director approved, ask the director for help | Spawn, give, move beyond its own entity, or see anything its entity could not |

Voices are for scale and latency. A small model can answer a greeting in a few
seconds while the game master spends a minute on the story. A voice with no
model attached falls back to lines the director wrote in its brief, so the game
never waits.

`docs/agent-interfaces.md` reserves two authority scopes, actor and director.
This document splits its director into two: `faction`, which is that reserved
scope (symbolic knowledge, priorities, no creation), and a new `gm` scope that
the operator grants and that may create within budgets. `voice` is an actor-like
scope bound to a non-player entity rather than a player. The non-goals in that
file still hold. Goanna ships no model runtime, personality system or memory
database. What the server keeps is facts that the rules check and that must
outlive a model session: quests, arcs, and what an NPC knows about a player.
Prompts, personality and prose stay with the agent host.

## The engine layer

What works in any game, with the API names at 5.17.0. "Verified" means it was
run on a real server on 19 September 2026 (see [What was
verified](#what-was-verified)); "documented" means checked against
`luanti/doc/lua_api.md` only.

| Capability | API | Status |
| --- | --- | --- |
| Biome at a position | `core.get_biome_data(pos)` (`biome`, `heat`, `humidity`), `core.get_biome_name(id)`, `core.registered_biomes` | Verified, with caveats below |
| Plants that occur there | `core.registered_decorations` indexed by their `biomes` field; `core.read_schematic` for schematic decorations | Verified for single node plants |
| Creatures that occur there | none: spawn rules belong to mob frameworks | Adapter |
| The game's items | `core.registered_items`, `registered_nodes`, `registered_craftitems`, `registered_tools`, `core.get_translated_string` | Verified |
| Players and their gear | `core.get_connected_players()`, `ObjectRef:get_pos`, `get_hp`, `get_breath`, `get_wielded_item`, `get_inventory():get_lists()`, `core.get_player_information`, `core.get_player_privs` | Documented only: no player could connect |
| Mapblock contents | the far summary store in `goanna_server_mod/init.lua` | Existing code, see [Mapblocks and regions](#mapblocks-and-regions) |
| Entities in an area | `core.objects_inside_radius`, `core.objects_in_area` (iterators), `ObjectRef:get_luaentity`, `ObjectRef:get_guid` (5.13), `core.objects_by_guid` | Verified |
| Spawn an entity | `core.add_entity(pos, name, staticdata)` | Verified |
| Move, turn, puppet | `ObjectRef:set_pos`, `move_to`, `set_velocity`, `add_velocity`, `set_yaw`, `set_properties`; `core.find_path`; shadowing `on_step` on one instance | Verified: set_pos, set_yaw, freeze |
| Give a mob a target | none in the engine | Adapter, or puppet |
| Speak as a mob | `ObjectRef:set_nametag_attributes`, `core.chat_send_player`, `ObjectRef:hud_add`, `core.show_formspec`, `core.sound_play` | Nametag verified; delivery to a player not verified |
| Spawn rewards | `core.add_item(pos, stack)`, `InvRef:add_item`, `core.set_node` plus node meta inventory | `add_item` verified |
| Deaths and removals | wrap `on_deactivate(self, removal)` of every entry in `core.registered_entities` at `core.register_on_mods_loaded` | Verified |
| Player events | `core.register_on_joinplayer`, `leaveplayer`, `dieplayer`, `player_hpchange`, `punchplayer`, `craft`, `dignode`, `placenode`, `chat_message`, `item_eat`, `item_pickup`, `protection_violation` | Documented only |
| World events | `core.register_on_generated`, `register_on_mapblocks_changed` | Already used by the far summary store |
| Time and sky | `core.set_timeofday`, `core.get_timeofday`, `core.get_day_count`, `ObjectRef:set_sky`, `set_clouds` | Documented only |
| Protection | `core.is_protected(pos, name)` | Documented only |
| Keep an area running | `core.forceload_block(pos, transient, limit)` | Verified |

### What the probes showed

**Biome at a position is cheap, but it is the engine's opinion, not the map's.**
1089 calls over a 2 km square cost 0.7 to 1.0 µs each, in every run. The engine
computes the answer from its own heat and humidity noise and never reads the map
(`l_get_biome_data` in `src/script/lua_api/l_mapgen.cpp` is
`NO_MAP_LOCK_REQUIRED`), so it answers for ungenerated places too. Three things
follow, all observed:

- It depends on y. Asked at a water surface it gave the land or beach biome
  (`Taiga_beach`); asked at the seabed under the same column it gave the ocean
  biome the mapgen used (`Taiga_ocean`). A column's biome has to be asked at its
  ground.
- On an engine mapgen it agrees with the ground. On Mineclonia v7 and Minetest
  Game v7, 21 of 22 bare land columns (not under water or a tree) were topped
  with their biome's `node_top`. The exception was a Mesa column whose surface
  was orange hardened clay, which Mineclonia's Mesa biomes use as filler and
  stone; why it was exposed there was not established.
- On a Lua mapgen it is wrong. On Mineclonia with its own level generator
  (`mg_name = singlenode`, `mcl_singlenode_mapgen = true`), all 9 columns
  disagreed with `mcl_biome_dispatch.get_biome_name`: `DripstoneCave` where the
  game had generated `ColdOcean`, `Forest_beach` where it had generated
  `Plains`. On a Terrain Diffusion world, all 9 disagreed with the biome TDL had
  placed: `MesaBryce` and `Mesa` where TDL placed `Savanna`. The director
  therefore asks a registered biome provider first (see [Lua hook
  API](#lua-hook-api)) and falls back to the engine only when none is
  registered.

**Decorations explain what grows, when the biome is right.** Indexing
`core.registered_decorations` by biome accounted for every single node plant
found standing in 17 by 17 patches around the land columns, on Mineclonia and
Minetest Game, apart from patches that crossed a biome edge. What it missed were
plants placed by schematic decorations (double height ferns, lilac, peony, rose
bush, papyrus), whose node names sit inside the schematic rather than in the
`decoration` field; `core.read_schematic` lists them. With the wrong biome it
fails completely: on the Terrain Diffusion world, against the engine's `Mesa`
the index explained almost nothing; against TDL's own `Savanna` it explained
every single node plant. Mineclonia registers 507 decorations (13 with no biome
filter), Minetest Game 57.

**The item catalogue does not fit in a message.** Mineclonia registers 3907
items (1563 visible in creative), which is 1.08 MB as compact JSON and 31 ms to
encode. Minetest Game's 550 items are 61 KB and 1.9 ms. A mod channel message is
at most 65535 bytes (`STRING_MAX_LEN`, checked in
`Server::broadcastModChannelMessage`), so item queries are filtered and paged,
and the MCP side caches the catalogue under a hash of the registry.

**GUIDs identify entities across time.** `ObjectRef:get_guid()` returned strings
like `@hJChDfVcO8KH166S0vdPiA`, and `core.objects_by_guid` found the object by
it while it was active. An `ObjectRef` goes invalid when its entity is
deactivated, so the director tracks everything by GUID and never holds a
reference across steps.

**Deactivation is not death, and the flag is not proof.** The generic removal
hook (wrapping `on_deactivate` on all 286 Mineclonia entity definitions and all
7 in Minetest Game with Mobs Redo) fired with `removal = true` for nearly every
kill, for mcl_mobs and mobs_redo alike, and for dropped items and burning
effects. Two runs showed its limits. In one, a zombie the probe had teleported
over a ravine (the probe's mistake: it fell back to the centre's height where a
column had no ground) fell out of the forceloaded blocks, took fatal fall
damage, and was deactivated with `removal = false` because its new block was not
active. `core.objects_by_guid` no longer held it, and as far as the world knows
it never died. In another, on a server lagging by up to 2.8 s, a cow the probe
had just killed was reported with `removal = false` rather than `true`; why was
not established. So the director reports deactivation and death as different
events, confirms a death by the framework's own health where an adapter has it
and by a later GUID lookup where it does not, and validates every position it
moves anything to.

**Framework AI keeps running unless it is paused.** `set_pos` takes effect at
once (3 to 14 µs) and `set_yaw` reads back, but a framework recomputes velocity
and direction on every step from its own state, so a teleported mob carries on
with whatever its AI was doing: zombies set on a cow chased it from wherever
they had been put. Shadowing `on_step` on the one instance
(`luaentity.on_step = function() end`) freezes it without touching the prototype
or any other mob. A mobs_redo raider and an mcl_mobs zombie, each in the middle
of an attack, stayed at exactly the same position for 2 s while frozen, and
resumed the attack when the field was cleared. This is the engine layer's way to
puppet any entity: freeze, drive it with `set_pos` or `move_to`, release.

**The engine's hit points are not the mob's health.** mcl_mobs keeps its own
`self.health`. A zombie burning in daylight went from 20 to 3 health while
`get_hp()` stayed at 20, and the server log recorded its hits on a cow as
`damage=0`. Health comes from the adapter.

### What the engine layer cannot do

- Know which creatures belong where. Spawn rules live in mob frameworks.
- Give a mob an intention that survives its own AI, except by freezing that AI
  and driving the body.
- Report a mob's real health, or who killed it, where a framework manages damage
  itself.
- Know what an item is worth, which items a game considers rewards, or which are
  admin only, beyond `not_in_creative_inventory`.
- Know about factions, villages or culture.
- Know the biome on a Lua mapgen without a provider.

## Framework adapters

The engine has no mob system, so spawn rules and mob behaviour live in
frameworks, and so do armour and weather. An adapter is a Lua table registered
with `goanna_director.register_adapter` (signatures in [Lua hook
API](#lua-hook-api)). Each has a `detect()` that tests for the tables and
functions it needs, not for a game's name, and runs at
`register_on_mods_loaded`, after every framework has registered. Several may
match; the highest `priority` wins per kind.

### mcl_mobs, Mineclonia

Detected by `mcl_mobs.register_spawner` and
`mcl_mobs.mob_class._targeting_rules`. Read against Mineclonia release 38561 and
run on it.

- **Fauna.** After load, `mcl_mobs.registered_spawners` maps a biome name to
  categories, each a list of spawners with `name`, `weight`, `pack_min` and
  `pack_max`. The probe read 214 biomes, 81 registered mobs and 7 categories
  with their caps (`monster` 70, `creature` 10, `ambient` 15 and four water ones
  at 5). `mcl_mobs.describe_spawning(name)` gives the conditions in words.
- **Spawn validation.** `mcl_mobs.spawning_possible(pos, mob)` applies the
  framework's own position, light and clearance tests, and
  `mcl_mobs.spawn_abnormally(pos, mob)` spawns through them. At the seven
  positions tried, all in daylight, it returned false for both a zombie and a
  cow. Light explains the zombie; why the cow was refused was not established.
- **Persistence.** A mob that is neither `persistent` nor named is removed on
  its first step when no player is within `instant_despawn_range`
  (`check_despawn` in `spawning.lua`). Every director-spawned mob is made
  persistent, recorded, and cleaned up by the director.
- **Targets.** `mob_class:run_targeting_rules` rebuilds `_active_target` every
  step from the mob's `_targeting_rules`, so writing `_active_target` does
  nothing. The adapter copies the instance's rule list with its own rule first,
  built with `mcl_mobs.build_target_rule`, returning whatever the director
  assigned. Verified in five runs: a zombie took a cow as its target and closed
  from about 10 m to 2 or 3 m within 6 s, and in two of them killed it before
  the probe did. Removing the rule should hand the mob back to its own rules;
  that was not tested. `API.md` in that release still documents
  `mob:do_attack(object)`, which no longer exists.
- **State stays off the entity.** mcl_mobs serialises the luaentity's fields
  into staticdata (`get_staticdata_table`). The probe's rule list (functions)
  produced "Support for dumping functions in `core.serialize` is deprecated"
  when that zombie was deactivated. The adapter keeps director state in a side
  table keyed by GUID, and adds only a rule that looks it up.
- **Health and speech.** `self.health`, and `mob:set_nametag(name)` (verified).
- **Weather.** `mcl_weather.change_weather(name, end_time, changer)` changed
  `mcl_weather.state` from `none` to `rain` (verified).
- **Armour.** mcl_armor keeps a player's armour in the `armor` list of the
  player inventory, and armour points come from item groups. Not run.

### mcl_mobs, VoxeLibre

VoxeLibre (release 38585 is installed here) forked from the same code, and the
two have diverged: Mineclonia's `mcl_mobs.spawn_setup` now logs a deprecation
error and spawns nothing, and its targeting is rule based. VoxeLibre needs its
own adapter, detected by the older `spawn_setup` spawn definition table. Not
examined beyond that in this pass.

### mobs_redo

Many games use TenPlus1's Mobs Redo. None bundled here does, so the probe ran
release 38115 in Minetest Game with two test mobs of its own.

- **Fauna.** Spawn rules are ABMs labelled `"<mob> spawning"` in
  `core.registered_abms`, with `nodenames`, `neighbors`, `interval`, `chance`,
  `min_y` and `max_y`, plus `mobs.spawning_mobs[name].aoc` (verified). There is
  no biome field: the adapter infers a biome's fauna by matching spawn nodes
  against each biome's `node_top`.
- **Targets.** `mob:do_attack(obj, true)` sets `self.attack` and
  `state = "attack"` (verified). On dry ground the raider closed from 7.5 to 2 m
  in 4 s and damaged the sheep; standing in water it held its target but did not
  move. `mob:go_to(pos)` spawns a `mobs:_pos` marker entity and attacks it,
  which is how the framework walks a mob to a place.
- **Freeze.** Shadowing `on_step` held the raider still mid-attack for 2 s;
  clearing it resumed the attack (verified).
- **Speech.** `mob:update_tag(name)` (verified).
- **Spawning more.** `mobs:add_mob(pos, def)` respects `mob_active_limit`. Not
  run.

### creatura

Used by Asuna's animalia. Read, not run. `creatura.registered_mob_spawns[mob]`
holds `biomes`, heights, light, time and group sizes. Behaviour is a utility
system: the adapter registers a director utility with
`creatura.register_utility` and starts it with
`mob:try_initiate_utility(name, score, ...)` at a score above the mob's own, and
`mob:move_to(goal, method, speed)` drives movement. Whether a mob's own utility
stack displaces a director utility has to be tested.

### Armour and weather

- **3d_armor** (Asuna): armour sits in a detached inventory named
  `<player>_armor`, and `armor.def[name].level` is the protection figure.
- **mcl_armor**: see above.
- **mcl_weather**: verified above.
- **Minetest Game's `weather`** changes cloud density only. There is no rain to
  control.

### Biome providers

- **mcl_levelgen:** `mcl_biome_dispatch.get_biome_name(pos)` returns the level
  generator's biome when it is enabled and the engine's otherwise. Verified
  equal to the engine on v7 and different on the level generator.
- **Terrain Diffusion:** `tdl_column.at(x, z)` returns the ground height, the
  top and side nodes, the water level and the palette entry whose `name` is the
  game biome TDL placed (verified). TDL should register it itself, from
  `tdl_far.lua`, next to its far surface provider.

### With no adapter

The director still lists items, reads biomes and decorations, sees and spawns
entities, speaks through nametags and chat, and puppets any entity by freezing
its AI. It has no ecological sense of which creature belongs where, it cannot
give a mob a goal its own AI will pursue, and it reports a kill only as a
removal with the last recorded puncher (from a wrapped `on_punch`). The status
reply says which adapters matched, so the model knows what it is working with.

## Game rulesets

A ruleset is a game's own better version of the generic tools. It adds queries,
adds intents, replaces generic intents with its own, and filters what each scope
may know. It is registered with `goanna_director.register_ruleset` and
advertised in the capabilities, so a model is told what the world supports
instead of guessing from the game name, as `docs/agent-interfaces.md` asks.

Mineclonia needs none for the spike. Kythen needs one, proposed in full under
[Kythen](#kythen).

## The data model

### Envelope

Every message on either transport is one JSON object:

```json
{
  "v": 1,
  "kind": "events",
  "scope": "gm",
  "session": "b3f1c2",
  "seq": 1042,
  "t": {"game": 18234, "day": 7, "tod": 0.43},
  "body": {}
}
```

- `v`: protocol version. A different version is refused with a logged warning,
  as the far summary protocol does.
- `kind`: `hello`, `welcome`, `events`, `query`, `reply`, `act`, `result`,
  `summary`, `status`, `error`, `bye`.
- `scope`: `gm`, `faction:<id>` or `voice:<id>`.
- `session`: chosen by the server at `welcome`, changing on restart, so a
  director knows its sequence numbers restarted.
- `seq`: on messages from the server, the observation sequence for that scope,
  monotonic within a session.
- `id` and `re`: a request's id, and the reply's reference to it.
- `based_on`: on an `act`, the last `seq` the model had seen. An intent whose
  target has changed since is refused as `stale`.
- `t`: `core.get_gametime()`, `core.get_day_count()` and `core.get_timeofday()`
  when the state was sampled.

Result statuses: `accepted`, `refused`, `stale`, `queued`, `completed`,
`interrupted`, `expired`, `undone`. A refusal carries a machine readable
`reason` (`budget`, `protected`, `no_ground`, `not_in_scope`, `rules`,
`unknown_item`, `stopped` and so on) and the rule's own words where a game
supplied them.

These fields are the ones `docs/agent-interfaces.md` asks every request and
observation to carry: version, session and subject, sequence, sample time, scope
and capabilities, the sequence an action was based on, and a structured result.

### Events

The stream is what happened, batched once a second per scope and filtered by
what the scope may know. One event:

```json
{"seq": 1043, "type": "player_hurt", "t": 18235.2,
 "who": ["player:alice"], "by": ["entity:@hJChDfVcO8KH166S0vdPiA"],
 "where": {"region": "r:3:-2", "pos": [412, 17, -230], "biome": "Forest"},
 "data": {"amount": 4, "hp": 12, "cause": "punch", "mob": "mobs_mc:zombie"}}
```

Subjects are `player:<name>`, `entity:<guid>`, `npc:<game id>` for entities a
ruleset names, `faction:<id>`, `quest:<id>` and `region:<id>`.

| Type | Source | Notes |
| --- | --- | --- |
| `player_join`, `player_leave` | `register_on_joinplayer`, `leaveplayer` | first join marked |
| `player_hurt`, `player_death`, `player_respawn` | `register_on_player_hpchange`, `dieplayer`, `respawnplayer` | hurt coalesced to one event per player per second |
| `player_chat` | `register_on_chat_message` | public chat only |
| `player_crafted`, `player_ate`, `player_picked_up` | `register_on_craft`, `item_eat`, `item_pickup` | coalesced per player and item per minute |
| `player_built`, `player_dug` | `register_on_placenode`, `dignode` | counted into region summaries, sent as an event only for notable nodes (containers, beds, doors, anything a ruleset flags) |
| `protection_violation` | `register_on_protection_violation` | |
| `entity_died`, `entity_deactivated`, `entity_removed` | wrapped `on_deactivate`, adapter kill events | killer from the adapter, or the last puncher |
| `npc_addressed` | right click on an entity with a voice, or chat naming one within 16 nodes | the voice's trigger |
| `quest_progress`, `quest_completed`, `quest_failed`, `quest_expired` | quests | |
| `encounter_started`, `encounter_ended` | intents | with the spawned GUIDs and the outcome |
| `pacing` | pacing layer | phase changes per player |
| `region_explored` | `register_on_generated` near a player | first generation of a region |
| game events | ruleset `events` hook | e.g. Kythen's `settlement_generated` |

The server keeps the last 4096 events per scope in memory. A director that falls
behind gets a `gap` marker and is expected to re-read summaries rather than
replay.

### Queries

| Query | Arguments | Answer |
| --- | --- | --- |
| `capabilities` | | engine version, game id, adapters matched, ruleset, scopes, intents, conditions, budgets |
| `biome` | `pos` or `region` | biome name and source (`provider:<name>` or `engine`), heat and humidity where the engine has them, the y it was asked at, the biome's `node_top`, flora (decoration node names), fauna (adapter spawners with weights and pack sizes) |
| `items` | `filter` (`group`, `prefix`, `type`, `creative_only`), `page`, `page_size` | name, description, type, groups, and a value where the ruleset supplies one; with the registry hash |
| `players` | | a summary per connected player |
| `player` | `name`, `detail` (`summary`, `inventory`, `equipment`, `history`) | see [Summaries](#summaries) |
| `entities` | `pos` and `radius`, or `region`; `filter` | GUID, name, position, health (adapter) or hp, framework, category, state, target, owner, nametag, director owned or not |
| `area` | `min`, `max` | mapblock summaries from the store, or `unknown` where nothing is generated. Never generates anything |
| `region` | `id` or `pos` | the region summary |
| `quests`, `arcs` | `player`, `state` | |
| `memory` | `npc`, `player` | the NPC's record of that player |
| `status` | | budgets left, live director entities, queued intents, pacing phase per player, stop state |

Every answer is filtered by the scope. A faction asking for a player it has
never seen gets `unknown`, not a refusal that confirms the player exists.

### Mapblocks and regions

The far summary store already keeps what the director needs at the finest level,
and keeps it incrementally. Per mapblock it holds a 92 byte version 7 record:
completeness flags, a 4 by 4 by 4 field of coarse contents indexed into the
area's name list, liquid surface heights, the block's day and night light, and a
liquid mask. Records live in areas of 8 by 8 by 8 mapblocks, persisted in mod
storage, filled from `register_on_generated` and refreshed from
`register_on_mapblocks_changed`, and paced by
`goanna_far_summary_blocks_per_step`. The store runs whether or not far
rendering is granted, since `register_on_generated` is registered
unconditionally. The director reuses it through a small exported reader
(`load_area` is a local in `init.lua` today), and never reads the map with a
`VoxelManip` to answer a question.

A model does not read 92 byte records, so the director keeps a derived layer,
the region: one store area's 128 by 128 node footprint through all heights, with
the id `r:<ax>:<az>`. A region summary:

```json
{"id": "r:3:-2", "x": [384, 511], "z": [-256, -129], "generated": 0.8,
 "surface": {"min": 4, "mean": 17, "max": 61}, "water": 0.12,
 "top": {"mcl_core:dirt_with_grass": 0.61, "mcl_core:sand": 0.2},
 "biomes": {"Forest": 0.7, "Forest_beach": 0.3},
 "built": {"placed_day": 340, "dug_day": 1210, "containers": 2, "beds": 1},
 "deaths_day": 1, "kills_day": {"monster": 6, "creature": 2},
 "mobs": {"monster": 3, "creature": 5, "director": 0},
 "protected": 0.25, "visited": {"alice": 18200}, "danger": 0.3,
 "places": [{"name": "the old tower", "pos": [450, 30, -200]}]}
```

Surface, water and materials come from the store's records. Biomes come from 16
samples through the provider (under 20 µs at the measured rate). Counters are
updated from events as they arrive. Mob counts are sampled every 30 s with
`core.objects_in_area`, only for regions with a player in them. Protection is
sampled with `core.is_protected` at 16 points when the region is first
summarised. `places` holds names the director gave with `mark_place`, and
structures a ruleset reports. `danger` is the pacing layer's recent intensity
for players in the region.

### Summaries

Summaries are maintained as events arrive, so a summary is a lookup, not a scan.
A player summary:

```json
{"name": "alice", "online": true, "region": "r:3:-2", "pos": [412, 17, -230],
 "biome": "Forest", "depth": "surface", "light": 12,
 "hp": 12, "hp_max": 20, "breath": 10,
 "gear": {"armour": 9, "weapon": "mcl_tools:sword_iron", "score": 0.45},
 "last_10_min": {"hurt": 14, "kills": {"monster": 3}, "deaths": 0,
                 "travelled": 380, "underground_s": 410, "dark_s": 300},
 "session_s": 2710, "alone": true, "pacing": {"phase": "build_up",
 "intensity": 0.22}, "quests": ["q:12"], "arcs": ["arc:witch"]}
```

`gear.score` is the adapter's armour points and best weapon damage, normalised
by the game's best, so a model can size an encounter without knowing the game's
numbers. A faction summary is whatever its ruleset reports, plus the engine's
view of its members if the faction is a group of accounts. Summaries are pushed
when they change past a threshold (a phase change, a death, 25 per cent of
health), not every second.

## Actions

An action is an intent at the level a game master thinks in, never a keystroke.
Every intent goes through the same pipeline, in Lua, in this order:

1. **Schema.** Arguments present and of the right type.
2. **Scope.** The scope may issue this intent, about this subject.
3. **Stop.** The director is not stopped by the operator.
4. **Budget.** The cost fits what is left for the hour and the day.
5. **Rules.** The adapter or ruleset agrees: the mob can spawn there, the item
   exists and is allowed, the village can take that priority.
6. **Place.** Every position is loaded, generated, standable, and not protected.
7. **Pacing.** If the intent is paced, it waits for the right phase; the result
   says `queued`.
8. **Apply,** recording an undo entry.
9. **Audit,** with the outcome.

An intent:

```json
{"id": "a17", "type": "stage_encounter", "based_on": 1042,
 "args": {"near": "player:alice", "budget": 12, "theme": ["undead"],
          "when": "next_build_up", "distance": [20, 40], "hidden": true,
          "leash_s": 180, "reward": "loot:small"},
 "reason": "alice has been mining alone for twenty minutes"}
```

`reason` is stored in the audit log and never executed.

| Intent | Arguments | What the game checks |
| --- | --- | --- |
| `stage_encounter` | `near`, `budget`, `theme` (tags or mob names), `when` (`now`, `next_build_up`, `at_night`), `distance`, `hidden`, `leash_s`, `reward` | Mobs drawn from the fauna of the player's biome that match the theme, or named ones the adapter can spawn, until their summed cost reaches the budget. Positions standable, not protected, out of the player's line of sight if `hidden` (`core.line_of_sight`), within the active area. Mobs made persistent, targeted at the player through the adapter, and removed when the leash runs out or the encounter ends |
| `offer_quest` | `giver`, `to`, `title`, `text`, `conditions`, `reward`, `expires_s` | Conditions from the registered set only. Reward within budget. Giver within 16 nodes of the player |
| `speak` | `as` (an entity, a voice or `narrator`), `to` (a player, a radius or all), `text`, `style` (`chat`, `hud`, `bubble`, `form`) | Scope may voice that speaker. At most 280 characters, rate limited per speaker and per listener. Listener within earshot unless narrator |
| `remember` | `npc`, `player`, `fact`, `disposition` | Scope may voice that NPC. Fact at most 200 characters; at most 16 facts per pair, oldest dropped |
| `spawn_reward` | `for`, `item` or `loot`, `count`, `how` (`give`, `drop_near`, `chest_near`) | Item registered, not on the operator's deny list, not `not_in_creative_inventory` unless allowed, within the value budget per player per day. A chest only on unprotected ground, removed when emptied |
| `adjust_spawning` | `region` or `biome`, `category`, `factor` (0 to 2), `duration_s` | Adapter support. Kythen maps it to ecology levers only |
| `set_weather` | `kind`, `duration_s` | Adapter support; restored at the end |
| `set_time` | `tod` | `gm` only, rarely, with its own budget |
| `move_entity` | `guid`, `to`, `mode` (`path`, `walk`, `teleport`) | Director owned or in scope; target standable and not protected; `teleport` only out of sight of players |
| `set_target` | `guid`, `target` | Adapter support; never at a player in a protected area or one who has opted out |
| `freeze`, `release` | `guid`, `duration_s` | Director owned or in scope; released automatically |
| `mark_place` | `pos`, `name`, `note` | Name at most 60 characters |
| `set_faction_goal` | `faction`, `goal` | Ruleset only |
| `end_encounter`, `undo` | `id` | Own actions only |
| `arc` | `id`, `players`, `beat`, `note` | Stored; nothing happens in the world |

### Quest conditions

The mod checks conditions. The model only chooses them.

| Condition | Arguments | Checked by |
| --- | --- | --- |
| `collect` | `item` or `group`, `count` | inventory when the player turns in, or at completion time |
| `deliver` | `item`, `count`, `to` | right click on the NPC with the items, which are taken |
| `kill` | `mob` or `category`, `count`, `region` | kill events attributed to the player |
| `reach` | `pos` and `radius`, `region`, or `biome` | position sampled once a second |
| `craft` | `item`, `count` | `register_on_craft` |
| `build` | `node` or `group`, `count`, `region` | `register_on_placenode` |
| `survive` | `seconds`, `region` | time without dying |
| `talk` | `npc` | `npc_addressed` |
| `escort` | `guid`, `to` | position of both; adapter keeps the escort following |

A ruleset adds its own with `goanna_director.register_condition`. Quests are
shown to players through the same channels a vanilla client renders: a chat line
and a HUD entry (`hud_add`), with the text in a formspec on `/quests`.

## Pacing

The pacing layer is Left 4 Dead's director in Lua (Michael Booth, "The AI
Systems of Left 4 Dead", AIIDE 2009): a per player intensity that rises with
harm and threat and decays when things are quiet, and a cycle of build up, peak,
fade and relax. It is deterministic: a function of events and time, with
placement randomness from a `PcgRandom` seeded by the world seed and the
director session, so a session can be replayed from its audit log. It runs every
server step within its share of the budget, and it never calls the model.

Per player intensity `I` in 0 to 1:

- rises by damage taken over maximum health, by 0.02 a second for each hostile
  within 16 nodes, and by 0.05 for each hostile the player kills;
- is set to 1 on death, which forces a long relax;
- decays as `I = I * exp(-dt / 20 s)` once 5 s have passed with no damage and no
  hostile near.

Phases:

| Phase | Enters when | Director may |
| --- | --- | --- |
| `build_up` | relax ends | release queued threats, within the build up's share of the budget |
| `peak` | `I` above 0.7 | nothing new; hold for 5 s |
| `fade` | peak held | nothing new, until `I` falls below 0.3 |
| `relax` | fade ends, or after a death | no threats for 45 s (120 s after a death); quests, speech and rewards are delivered here |

The model tunes and never ticks. It sets per player or per world a `theme` (what
kind of threat and story), a `tempo` (relax length 20 to 180 s, peak threshold
0.5 to 0.9), and budgets (difficulty points per hour, reward value per day). It
queues intents with `when: "next_build_up"`, and the pacing layer releases them.
A model call takes seconds and sometimes fails; a queued intent carries
`valid_until` and `based_on`, and expires or goes stale rather than landing on a
situation that has changed. With no model connected, the pacing layer tracks
intensity and releases nothing, and the game plays as it always does.

Encounter cost comes from the adapter: by default a mob's maximum health over 10
plus its damage, which a ruleset may replace. A Mineclonia zombie (20 health, 3
damage in `mobs_mc/zombie.lua`) costs 5 and a skeleton (20 and 2) costs 4, so a
budget of 12 buys three skeletons.

## Multiple factions

Each faction has its own scope, its own seat or HTTP endpoint, and its own event
stream. Three rules make it a fair experiment:

- **Fog of war.** A faction sees what its members know. An event records its
  witnesses as it is logged: every faction with a member within perception range
  of it (32 nodes by default, members held in a spatial hash updated each
  second), or the faction a ruleset's `knowledge` hook names. The stream and
  every query answer are filtered through that. A ruleset can add reports, so
  news travels at the speed a messenger would carry it.
- **A slow turn cycle.** Faction intents are collected and resolved at a turn
  boundary, every 120 s of real time by default, not as they arrive. Each
  faction submits at most a set number of intents per turn. Latency then decides
  nothing: a fast model gets no advantage over a slow one.
- **Arbitration by the rules.** At the boundary, intents are validated and
  applied in a deterministic order: by class (defensive before offensive), then
  round robin over factions starting from a position that rotates each turn.
  Conflicts, two factions wanting the same place or goods, are settled by the
  ruleset's rules (Kythen's A4 conflict), never by a model. The results go back
  to each faction as that faction would learn them.

A `gm` scope may run alongside factions and sees everything; factions never see
the game master.

## Persistence

Everything the director must remember lives in the mod's storage, so it survives
server restarts and model sessions, and a new session reads it back.

| Key | Holds |
| --- | --- |
| `dir1:meta` | protocol version, session counter, stop state |
| `dir1:quest:<id>` | a quest: giver, player, conditions, progress, reward, expiry |
| `dir1:arc:<id>` | an arc: players, beats, notes |
| `dir1:mem:<npc>:<player>` | first met, last seen, times spoken, disposition from -100 to 100, up to 16 dated facts, quests given and completed, promises |
| `dir1:enc:<id>` | a live encounter: GUIDs, leash, target, outcome |
| `dir1:own:<guid>` | a director owned entity: encounter, spawn time, cleanup rule |
| `dir1:budget:<scope>:<day>` | what was spent |
| `dir1:place:<id>` | named places |
| `dir1:region:<id>` | region counters |

One key per record, written when it changes, at most once a second, within the
step budget. Never one blob. NPCs are keyed by a ruleset's stable id where there
is one (Kythen's `actor_id`) and by GUID otherwise; a GUID persists across
reloads (`lua_api.md`, `get_guid`). An NPC's memory outlives the NPC.

On `hello`, the server answers with the session, the last sequence, and the open
quests, arcs and encounters, which is everything a fresh model session needs to
pick the story up.

## Performance budget

A Kythen session found its server step stalling for 737 to 885 ms because a
checkpoint encoded its whole state (27.3 MB) at once, and the same state was
deep copied and serialised again on every flush
(`docs/architecture/off-thread/persistence.md` and `partition-design.md` in
Kythen). The director's rule is the one Kythen arrived at: never encode
everything; keep summaries incremental and send deltas.

- **A share of each step.** Director work gets at most 2 ms of a step on
  average, with a hard stop at 4 ms, using the queue and coroutine pattern of
  `surface.lua` and `fine.lua`. It pauses while `core.get_server_max_lag()` is
  above a limit, as the far summaries do.
- **O(1) in callbacks.** An engine callback appends a small table to a ring
  buffer and updates counters. It never encodes and never scans.
- **Encode per batch.** Events are encoded once a second per scope, at most
  60000 bytes a message. Region summaries are cached and re-encoded only when
  dirty.
- **No map reads to answer.** Area answers come from the store. Nothing is
  emerged to answer a question: emerging 9 columns of 17 by 17 by 176 nodes took
  10 to 12 s on Mineclonia, 2.5 to 2.7 s on Minetest Game and 1.4 to 1.5 s on
  Terrain Diffusion.
- **The async environment, where it pays.** `core.handle_async` runs a function
  on a worker thread, but its arguments are serialised on the server thread.
  Measured over ten runs: handing a 20000 entry table (1.7 MB as JSON) to
  `handle_async` cost 19 to 25 ms of server thread time, against 48 to 89 ms to
  encode it directly, and `core.ipc_set` of the same table cost 22 to 28 ms. The
  worker took 57 to 87 ms and the round trip 120 to 206 ms, once 2.6 s. So async
  work helps only when the computation is much larger than its input, and it
  cannot rescue a whole state encode. Candidates: path planning over a copied
  grid (Kythen already runs A* in async), encounter placement scoring, and
  compressing large replies.
- **Mod storage writes are usually cheap; encoding is not.** Setting a 1.7 MB
  string cost 0.15 to 0.33 ms in nine runs and 108 ms in one, which was not
  explained. The steady cost is in producing the string, and the outlier is a
  reason to keep records small.
- **Biomes are cheap.** At 0.7 to 1.0 µs a call, tagging every event with its
  biome costs nothing measurable.

## Operator controls

- **Budgets,** as `goanna_director_*` settings: encounter points per hour, live
  director entities (24 in all, 8 per player), reward value per player per day,
  speech lines per minute per speaker, time changes per day. Kythen and other
  rulesets add their own.
- **A deny list** of items and entities the director may never create, and an
  allow list mode for strict servers.
- **Exclusion zones:** a radius around static spawn and every bed, and anything
  `core.is_protected` reports for the seat's account.
- **Per player opt out:** `/director optout` stops the director targeting or
  rewarding that player, and is announced to them.
- **Stop:** `/director stop` (`server` privilege) removes every director owned
  entity, cancels queued intents, closes open encounters, and refuses everything
  until `/director start`.
- **Undo:** every action records how to reverse it. Spawned entities are
  removed; weather and spawning factors restore; reward chests are removed if
  unopened. Items already in a player's inventory are not taken back, and the
  audit log says so.
- **Audit log:** one line of JSON per intent and per effect in
  `<world>/goanna_director/audit-<date>.jsonl`, appended by a paced writer: real
  and game time, scope, seat account, intent, arguments, outcome, effects
  (GUIDs, items, positions) and the undo record. `/director log [player]` shows
  the recent entries in game.

## Transports

### Why not `goanna:v1`

The decided design sent director messages over the existing `goanna:v1` channel
through a client. That cannot work as it stands, for a reason in Luanti's
server, not in Goanna:

- A message a client sends on a channel is relayed to every other peer on that
  channel and to server mods (`Server::broadcastModChannelMessage` in
  `src/server.cpp`), and there is no filtering or rate limit
  (`// @TODO: filter, rate limit` in `handleCommand_ModChannelMsg`).
- A server mod can only `send_all`; there is no unicast (`lua_api.md`,
  `ModChannel`).
- Every Goanna client joins `goanna:v1` after `CLIENT_READY`
  (`GoannaSession::joinGoannaChannel`).

So every Goanna player's client would receive the director's observations of
everyone, and its commands. That is exactly the information a vanilla player
lacks. Director traffic needs a channel only the seat joins.

### Seat and private channel

- The seat is a Goanna client on its own account, with `goanna_director` and
  without `interact`, run headless through `tools/goanna-headless` or
  `goanna_session`.
- The channel name is derived, never sent: `goanna:d:` followed by the first 32
  hex digits of `core.sha256(token .. ":" .. account .. ":" .. scope)`. The
  server joins it at start for each configured seat; the MCP service knows the
  token (from `<world>/goanna_director.conf` locally, or from the operator) and
  tells its seat instance which channel to join through the control channel.
  Luanti lets a client join any channel name, creating it if needed
  (`ModChannelMgr::joinChannel`), and a server mod cannot list who joined, so
  the name is the capability. Changing the token changes every channel.
- The server checks the sender of every message on the channel against the
  seat's account and scope.
- Messages over 60000 bytes are split into parts, as `surface.lua` already
  splits surface tiles.
- Goanna client changes: join extra channels by name, queue their messages
  (`onModChannelMsg` ignores every channel but `goanna:v1` today), and two
  control channel commands, `director_send` and `director_take`. Small, and all
  in `GoannaSession` behind its existing mutexes.

A seat is a player object, and games see it as one. It takes a slot in
`max_users`, the server streams map to it, blocks around it are active, and
anything that iterates `core.get_connected_players()` counts it: Mineclonia's
beds count players in the overworld before skipping the night
(`mcl_beds/functions.lua`), and mcl_mobs spawns around every connected player.
The mod hides the seat (no visual, not pointable, no collision, no nametag),
parks it, and asks for the smallest view range, but a game that counts players
still counts it. Whether a Goanna client can run a seat under Godot's dummy
`--headless` renderer, with no GPU at all, is not verified;
`docs/control-channel.md` on the MCP branch notes that the UI commands work
there and screenshots do not.

### HTTP

- The operator adds `goanna_server_mod` to `secure.http_mods`.
  `core.request_http_api()` then returns the HTTP table at load.
- The server mod is the HTTP client. It `POST`s batches of envelopes to
  `<url>/v1/push`, and keeps one long poll per scope open on
  `<url>/v1/pull?scope=gm&after=<n>&wait=20` for queries and intents. Requests
  carry `Authorization: Bearer <token>`. `HTTPApiTable.fetch` is asynchronous,
  so the step never waits.
- The MCP service runs a loopback HTTP endpoint per scope. For several factions,
  each LLM's MCP process has its own endpoint, configured per scope in
  `goanna_director.conf`. The token travels in a header, so an endpoint off the
  machine needs TLS.
- Verified from the Luanti 5.17.0 Flatpak server to a local endpoint: a `POST`
  answered 204 and a `GET` answered 200 with a JSON body, each in 50 to 90 ms,
  with `secure.http_mods` set for the probe mod.

No seat, no player object, no Goanna client change, and no traffic to any
player. It needs the operator to grant network access to the mod, which some
will not do on a public server.

### Recommendation

Build the spike on HTTP, and the seat transport second. For a world Goanna
launches, `local_server.gd` can grant `secure.http_mods` as it already grants
far rendering, so HTTP costs nothing there and needs no C++ and no second
client. The seat is the answer for a remote operator who will not allow HTTP,
and for them the private channel amendment above is required either way. This
reverses the order that was decided, which is why it is the first open question.

## MCP tools

On top of the multi-instance `tools/goanna-mcp`. Every tool takes `server` (a
world or a host and port), which picks the director connection; seat connections
also take the seat's `instance`.

| Tool | Does |
| --- | --- |
| `director_connect` | Attach to a server's director with a transport, scope and token (read from the world for a local one). Returns `welcome`: session, capabilities, open quests, arcs and encounters |
| `director_events` | The next batch of events after a sequence, waiting up to `wait_s` |
| `director_query` | Any query from [Queries](#queries) |
| `director_act` | One or more intents; returns a result per intent |
| `director_pacing` | Theme, tempo and budgets, per player or for the world |
| `director_status` | Budgets, live entities, queued intents, phases, stop state |
| `director_undo` | Reverse an action or an encounter |

The spike exposes five narrower tools instead, because a model uses a small,
specific schema better than a general one: `director_events`, `director_player`
(the player summary), `director_stage_encounter`, `director_speak` and
`director_offer_quest`, with `director_connect` implied by arguments. They are
thin wrappers over the same messages.

## Lua hook API

`goanna_server_mod` defines one global table, `goanna_director`, when the
capability is enabled, as it defines `goanna_register_far_surface` today. Games
and adapters call it at load time. A game declares
`optional_depends = goanna_server_mod`, as Terrain Diffusion's `mod.conf` does,
and checks that the table exists, so it loads unchanged on a server without
Goanna's mod or with the director off.

```lua
-- Adapters. kind is "mobs", "armour", "weather" or "biome".
goanna_director.register_adapter(name, {
    kind = "mobs",
    priority = 10,
    detect = function() return rawget(_G, "mobs") ~= nil end,

    -- mobs
    is_mob = function(obj, luaentity) end,        -- bool
    -- {framework, category, health, health_max, state, target, owner, tamed}
    describe = function(obj, luaentity) end,
    -- {{mob, category, weight, pack_min, pack_max}, ...}
    fauna = function(biome) end,
    cost = function(mob) end,                     -- number
    can_spawn = function(pos, mob) end,           -- ok, reason
    spawn = function(pos, mob, opts) end,         -- ObjectRef or nil, reason
    set_persistent = function(obj, persistent) end,
    set_target = function(obj, target) end,       -- ok, reason
    clear_target = function(obj) end,
    go_to = function(obj, pos, opts) end,         -- ok, reason
    name = function(obj, text) end,
    spawn_factor = function(category, factor, area) end,    -- ok, reason
    -- callback(victim, killer, mob)
    on_kill = function(callback) end,

    -- armour
    equipment = function(player) end,             -- {points, pieces}

    -- weather
    set_weather = function(kind, duration) end,   -- ok, restore
    weather = function() end,                     -- kind

    -- biome
    -- name, {source, heat, humidity}
    biome_at = function(pos) end,
})

-- Shorthand for a mapgen, as goanna_register_far_surface is.
goanna_director.register_biome_provider(name, function(pos) end)

-- Game rulesets.
goanna_director.register_ruleset(name, {
    scopes = function() end,                      -- {"faction:<id>", ...}
    capabilities = {},                            -- advertised to the model
    queries = {
        village = function(scope, args) end,      -- table
    },
    intents = {
        set_village_priority = {
            schema = {},
            -- ok, reason, cost
            validate = function(scope, args) end,
            -- result, undo
            apply = function(scope, args, ctx) end,
        },
    },
    replaces = {"adjust_spawning"},               -- generic intents replaced
    knowledge = function(scope, event) end,       -- bool, for fog of war
    speakers = function(scope) end,               -- who this scope may voice
    speak = function(scope, speaker, listener, text) end,
    value = function(stack) end,                  -- number, for rewards
    events = function(emit) end,                  -- subscribe; emit(event)
})

-- Extra quest conditions.
goanna_director.register_condition(name, {
    events = {"player_crafted"},
    progress = function(quest, player, event) end,    -- progress, done
})

-- A game reports its own events into the stream.
goanna_director.emit(event)

-- State kept per director owned entity, off the luaentity.
goanna_director.owned(guid)                       -- table or nil
```

Everything a ruleset's `apply` does must go through the game's own entry points,
so that a game with replay or determinism keeps it.

## Kythen

Read from the Kythen repository (read only) on 19 September 2026. Kythen already
expects this: `docs/briefs/legends-objectives.md` lists "one model directing
multiple civilisations as a game master, a model governing a culture or village,
models controlling individual villagers" among the arrangements it must support,
and `docs/architecture/ecosystem-simulation.md` designs controllers that "may
direct the whole world as game master, one culture, one village". None of it is
reachable in play yet.

### What exists to build on

- **Controllers and commands.** `W:command(c)` in `core/world.lua` accepts a
  command from a registered controller, checks its `authority` and
  `version == 1`, queues it by time, and `W:apply` executes it at the barrier
  and records it with `W:record('command', ...)`, marking research interventions
  as exogenous. Research authority takes `shock`, `access` and `deposit`; actor
  authority takes `cancel`, `trade`, `take_route` and `claim_transfer`. The live
  world is adopted without controllers (`world.adopt` in
  `engine/wire/ecosystem.lua`), so none of this can be used in play today.
- **Reports and events.** `kythen.adapter.report{kind=...}` reaches `W:report`
  in `core/wiring.lua`; `W.events:subscribe(kind, id, fn)` in
  `core/event_dispatcher.lua` takes `"*"`.
- **Stable ids.** Villages are `<region>:<site id>`. People have `actor_id` of
  the form `actor:<seed>:<village id>:<serial>`, stored in the `kythen:villager`
  entity's staticdata. Factions look like `norse:faction:the_thing_district`.
- **The behaviour tiers.** `a8.VOCAB` in `core/behaviour.lua` names T2 council
  verbs (`prioritise_build`, `allocate_labour`, `muster`, `trade_offer`,
  `set_posture`, `request_aid`, `evacuate`, `demand`, `accede`) and T3 culture
  verbs (`declare`, `ally`, `embargo`, `demand_tribute`, `send_expedition`,
  `set_goal`, `submit`). No runtime decomposition runs above T0; T2 and T3 are
  hand written in `W:_t2` and `W:_t3`.
- **Faction data nobody reads.** `faction.json` declares `behaviour` tiers and
  `goals`, such as `norse:goal:get_the_hay_in` driving `set_goal` and
  `allocate_labour`. No Lua reads them yet.
- **Allocation.** `allocate` in `core/settlement.lua` assigns jobs in a fixed
  class order (subsistence, craft, service, ritual, administrative, martial),
  which `docs/systems/trade.md` says is deliberately not authorable. Inputs per
  job come from `W:_a2_jobs(village)`. There is no per village override.
- **Building.** `settlement.queue_build(world, id, plan, cost)` exists.
- **Ecology.** `core/ecology.lua` keeps stocks, capacity and regeneration per
  region (`patch:<id>`), with `shock`, `establish` and `commit`. Creatures are
  spawned from it: `engine/creatures/populate.lua` asks
  `live_country.spawn_budget`, which is available stock not yet embodied.
  Hostiles are authored per site and embodied by `embody_hostile_site`.
- **Speech.** `W:_answer` turns an addressed villager into a `speak` intent,
  `exec.speak` in `engine/adapter/intents.lua` executes it, and
  `engine/interface/speech.lua` shows it in chat and on the HUD.
  `C:speech(line, listener)` in `core/conversation.lua` renders a structured
  line through the listener's comprehension; a plain string is returned as is,
  bypassing it.
- **Knowledge.** Only players hold knowledge (`L:learn(player, claim, spec)` in
  `core/legends.lua`). Institutions and factions know nothing.
- **Persistence and threads.** State flushes to mod storage every 10 s; the
  ecosystem checkpoint encodes in 4 ms slices and writes through
  `core.handle_async`; A* path search already runs in the async environment. The
  draft region partition design keeps the command queue and controllers on the
  main thread.

### Proposed hook surface

Kythen registers a ruleset from a new file of its own (for example
`engine/wire/director.lua`), only when `goanna_director` exists. Everything
below goes through commands or reports, never direct table writes, because
Kythen's determinism and replay depend on commands being recorded ("Never edit
arbitrary internal tables invisibly", `ecosystem-simulation.md`), and because
the partition design will make direct writes wrong.

**Scopes.** `gm`; `culture:<id>` (for example `culture:norse`);
`faction:<faction id>`; `village:<village id>`; `voice:<actor_id>`. When the
director is enabled, each configured scope is registered as a `world.lua`
controller with `issuer = "goanna:<scope>"`, a new `director` authority, and the
villages or factions it controls, so `W:apply` can check `outside_control_scope`
exactly as it does for actors.

**New command kinds** (Kythen side changes, each recorded by
`W:record('command', ...)`):

| Command | Maps to | Limits |
| --- | --- | --- |
| `village_priority {village, job, weight, until}` | a per village override read by `W:_a2_jobs`, adjusting `priority` within the job's class | class order unchanged, weight bounded, expires |
| `queue_build {village, plan}` | `settlement.queue_build` | village's own stock pays |
| `set_goal {faction, goal}` | choose among `faction.json` `goals`; the first consumer of `goals` and `behaviour.t3` | goal must be declared |
| `set_posture {village, posture}`, `trade_offer`, `request_aid`, `evacuate` | T2 verbs through the existing executors | where an executor exists |
| `declare`, `ally`, `embargo`, `demand_tribute`, `send_expedition` | A4 `set_relation`, `open_demand`, A9 `launch` | only as far as A10 diplomacy exists; refused as `rules` until then |
| `ecology {region, stock, kind, severity \| amount \| capacity_factor, until}` | the existing research `shock`, `access`, `deposit`, plus a bounded capacity bias | the only way a Kythen director changes wildlife numbers |
| `encounter {site, near, when}` | A9 `start_encounter` with the site's authored hostiles | authored composition only |

**Replaced generic intents.** `adjust_spawning` becomes `ecology`, so a Kythen
director can make wolves more common only by making their prey or habitat
richer, and `populate.lua` spawns the bodies. `stage_encounter` becomes
`encounter`, drawing on authored hostile sites. `spawn_reward` pays from a
village's stock or a culture's ledger rather than from nothing.

**Queries.** `village {id}`: population, households, `food_days`, `threat`,
`projects[1]`, stock, jobs filled, and work orders through
`query("a2", "work_orders", {village = id})`. `faction {id}`: relations,
strength, warbands, expeditions. `culture {id}`: `have`, ledgers.
`ecology {region}`: `stocks`, `yield`, `resilience`, `trajectory`.
`standing {player, scope}`: A6 standing and comprehension.

**Speech.** Director speech for a villager goes through A5 as a structured line
(`culture`, `speaker`, `listener`, `topic`, `facts`) plus the model's free text,
rendered through `C:speech` so that a listener who does not know the language
hears what their comprehension allows. Kythen needs to stop returning plain
strings unfiltered. A mythological figure is a new speaker kind (for example
`{kind = "spirit", culture, name}`), `gm` only, with its own presentation.

**Knowledge.** For faction directors, Kythen adds institutional knowledge
holders: a village or faction learns a claim when a member witnesses it or a
messenger reports it, through the same `L:learn` path players use. Until that
exists, a Kythen faction director sees only its own villages' state and events
inside their land, and the engine's perception rule does the rest.

**Memory.** NPC memory is keyed by `actor_id`. A villager's disposition toward a
player is kept consistent with A6 standing: the director may add facts, and
standing stays Kythen's.

**Persistence.** Overrides and goals are simulation state, so they live in
Kythen's own checkpoint alongside the command log, not in the director's
storage.

## Phased plan

Estimates are working days for one developer, including tests and documentation,
and are guesses.

1. **Spike: Mineclonia on a world Goanna launches (about 12 days).**
   - Director core: settings, privilege, `/director` commands, event ring
     buffer, player and region summaries, capabilities, audit log, budgets, stop
     and undo (4 days).
   - mcl_mobs (Mineclonia) adapter: fauna, spawn validation, persistence,
     targeting rule, freeze, kill events, cleanup (2 days).
   - Quests with `collect`, `kill`, `reach` and `talk`, shown in chat and on the
     HUD, persisted (2 days).
   - `speak` and NPC memory (1 day).
   - Pacing v0 (1 day).
   - HTTP transport, `local_server.gd` wiring, and the five MCP tools (2 days).
   - Then a playtest with a real model on a real Mineclonia world, written up
     with the server, game and Godot versions, before anything moves in
     `README.md`.
2. **Adapters and the seat (about 12 days).** mobs_redo and creatura (3),
   VoxeLibre's mcl_mobs (2), armour and weather (1), biome providers for
   mcl_levelgen and Terrain Diffusion (1), the seat transport with the private
   channel, Goanna client changes and seat hiding (4), chunked messages and
   protocol tests (1).
3. **Kythen provider (about 12 to 18 days, mostly in Kythen).** Controllers and
   the new command kinds (5), the village priority override (2), speech through
   A5 and the spirit speaker (3), ecology intent and encounter mapping (3),
   ruleset registration, queries and events (2), then play. It depends on
   Kythen's schedule for A10 diplomacy and the partition refactor.
4. **Several factions (about 10 to 15 days).** Witness sets and the knowledge
   filter (3), the turn cycle and arbitration (3), per scope endpoints (2),
   Kythen institutional knowledge holders (4 to 6, in Kythen), and a fairness
   test with scripted factions before any models (2).

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
5. **Public chat.** Should the director read it by default, or only lines
   addressed to an NPC?
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

## What was verified

Everything below ran on 19 September 2026 against the Luanti 5.17.0 Flatpak
(`org.luanti.luanti`, server only, no client) with the probe in
`tools/director-probe/`, each on a fresh world on port 30561, stopped by the
probe itself (`core.request_shutdown`) and checked gone by PID. No client
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
pacing layer, and any language model driving any of it.

To run the probe again, copy it into a fresh world's `worldmods` and start a
server with a config file inside the world, so the sandbox can see it and the
player's own `minetest.conf` is left alone:

```sh
W=~/.var/app/org.luanti.luanti/.minetest/worlds/director_probe_example
mkdir -p "$W/worldmods"
cp -r tools/director-probe "$W/worldmods/director_probe"
printf 'mg_name = v7\nsecure.http_mods = director_probe\n' > "$W/probe.conf"
printf 'director_probe_url = http://127.0.0.1:30591\n' >> "$W/probe.conf"
python3 tools/director-probe/http_sink.py 30591 /tmp/sink.log &
flatpak run --command=luanti org.luanti.luanti --server --gameid mineclonia \
    --world "$W" --port 30561 --config "$W/probe.conf" --logfile "$W/server.log"
```

The server writes `$W/director_probe.json` and shuts itself down after about
half a minute. Stop the sink by its PID afterwards. For Minetest Game, use
`--gameid minetest` and copy Mobs Redo into `worldmods` as well.
