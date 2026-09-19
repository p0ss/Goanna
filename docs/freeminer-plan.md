# Freeminer servers: findings and a plan

Research of 19 September 2026. No Goanna code was changed for it.

Freeminer is a long lived fork of Minetest, now of Luanti, maintained at
<https://github.com/freeminer/freeminer>. This file answers whether Goanna
can or should join Freeminer servers, what that would take, and where it
meets Goanna's boundaries.

The short answer: a current Freeminer server, built with its default
options, speaks Luanti's own protocol on its main port, and Goanna already
joins it as a Luanti client. It was run here against a locally built
Freeminer server with devtest and Mineclonia. What Freeminer adds on top
(its far view, 32-bit world coordinates, wind physics) is carried in
Freeminer's own messages or in a protocol version Goanna cannot speak, and
none of it is reachable without a second protocol path or building against
Freeminer's tree. The recommendation is to document the working case and do
nothing more yet. The section "What would change the recommendation" says
what would reopen it.

Goanna is not affiliated with or endorsed by the Freeminer project or the
Luanti project, and nothing here should be read as either.

## Sources

Read, not recalled:

- Freeminer `master` at `5d2c77028` (18 September 2026, "Merge
  remote-tracking branch 'origin/wip5.17.0' into wip5.17.0-32"), cloned
  outside this repository. Its merge base with Luanti's `5.17.0` tag is the
  tag commit itself, `c0e6812b`, and `AGENTS.md` in the tree says "The
  current merge tag is 5.17.0". The version string of the built server is
  `freeminer 5.17.0.0`.
- Luanti's `5.17.0` tag, fetched into the same clone, for every diff below.
- Freeminer issues #308 (2026, a Luanti 5.16.1 client refused by Freeminer
  servers), #291 (2022, no servers to join), #290 (2021) and #28 (2014, the
  proposal for a msgpack packet format).
- The server lists `http://servers.freeminer.org/list` and
  `https://servers.luanti.org/list`, fetched on 19 September 2026.
- The front page of <https://freeminer.org>, fetched the same day.

Old documentation, and treated as such:

- Freeminer's `README.md` still describes Travis builds, a getdeb PPA,
  `yaourt`, Irrlicht 1.8.2 and gcc 4.8. It predates the current tree by
  about ten years and says nothing about the protocol.
- Freeminer's `doc/protocol.txt` is Luanti's early draft ("Updated
  2011-06-18").
- The msgpack packet format described in issue #28 still exists in the
  tree but is not what a default build speaks (below).
- The front page advertises "1000000x better view range" and "10x faster
  and more reliable networking". Neither is measured anywhere I found; the
  second presumably refers to the ENet and SCTP transports, which Goanna
  would not use.

Freeminer's last GitHub release is 0.4.14.8, from May 2016. Since then the
project tracks Luanti releases on `master` without tagging its own. Of the
300 most recent commits on `master`, 291 are by one author, proller.

## What a Freeminer server speaks

### The build decides

Most of the answer is set at compile time, so it matters which options a
server was built with. The defaults, from `cmake/Modules/freeminer.cmake`,
`cmake/Modules/fm_network.cmake` and `src/CMakeLists.txt`:

| Option | Default | Effect |
| --- | --- | --- |
| `MINETEST_PROTO` | on | Luanti's packet format. Off selects Freeminer's msgpack format, which no Luanti client can read. The option's own description is "Use minetest protocol (Slow and buggy)". |
| `MINETEST_TRANSPORT` | on | Luanti's reliable UDP transport. |
| `USE_MULTI` | on | Serve several transports at once. |
| `ENABLE_ENET` | on | ENet transport. |
| `ENABLE_SCTP` | on | SCTP transport, only if the `usrsctp` source has been fetched by hand. |
| `ENABLE_WEBSOCKET` | on, except Android | WebSocket transport, needs Boost. |
| `USE_POS32` | `32` | 32-bit node and mapblock positions. |
| `USE_OPOS64` | `64` | 64-bit object positions. |

All five servers on the Freeminer list announce `"proto": "mt"`, which is
what these defaults announce.

### Transports and ports

`src/network/multi/connection.cpp` serves Luanti's UDP transport on the
configured port, SCTP on port + 100, ENet on port + 200 and WebSocket on the
configured port over TCP. A Freeminer client chooses one with its
`remote_proto` setting, and an empty setting means Luanti's. The Luanti
transport in `src/network/mtp/` differs from 5.17.0 only internally (peer
ids are capped at `0x3fff` so that the transports do not collide). A Luanti
client, and Goanna, see Luanti's transport.

### Protocol version

`src/network/networkprotocol.cpp`:

```cpp
const u16 PROTOCOL_VERSION_32BIT = 147;
#if USE_POS32
const u16 LATEST_PROTOCOL_VERSION = 148;
#else
const u16 LATEST_PROTOCOL_VERSION = 53;
#endif
```

`SERVER_PROTOCOL_VERSION_MIN` is still 37. The server keeps Luanti's
negotiation in `Server::handleCommand_Init`: it picks the client's maximum,
capped at its own. A Luanti 5.17.0 client offers 37 to 53 and gets 53; the
test below shows `Protocol version: min: 37, max: 53, chosen: 53`. Below
147 every position is written as Luanti's 16-bit form
(`NetworkPacket::readPos`, `writePos` and the `v3pos_t` operators in
`src/network/networkpacket.cpp`), and above it as 32-bit. A default
Freeminer server is therefore bilingual: protocol 53 for Luanti clients,
148 for its own.

The negotiation has a consequence that issue #308 shows in practice.
Because the server's maximum is 148, it never negotiates a Luanti client
down. A client built on a newer Luanti than the Freeminer server has merged
is granted its own maximum, and the server then writes packets in the older
layout it actually implements. In May 2026 a Luanti 5.16.1 client failed
against Freeminer servers with `String too long @ name=TOCLIENT_INVENTORY`
while 5.15.2 worked; the maintainer answered "Now freeminer updated to
5.16.0, should work with 5.16.0 luanti" and the reporter confirmed it. So a
Luanti client works on a Freeminer server when its Luanti version is the
same as or older than the server's merge, and fails when it is newer.

### What else a Luanti client receives

Under protocol 53 a default server still differs from Luanti's in ways a
client can see. All from diffs against `5.17.0`:

| Difference | Where | Effect on a Luanti client, and on Goanna |
| --- | --- | --- |
| `TOCLIENT_FREEMINER_INIT` (`0x08`) is sent to every client during `INIT2`, a msgpack map with the mapgen name and parameters, the seed, water level and mapgen flags, the game id and a weather flag. | `serverpackethandler.cpp:303`, `fm_server.cpp:557` | Luanti handles `0x08` with `handleCommand_Null`; Goanna's `GoannaSession::handle` drops unknown commands. Both ignore it. It was 6,756 bytes in the test. The seed alone is not new: Luanti's `TOCLIENT_AUTH_ACCEPT` already carries it. |
| Three extra commands to the server, `TOSERVER_INIT_FM` (`0x03`), `TOSERVER_GET_BLOCKS` (`0x04`) and `TOSERVER_DRAWCONTROL` (`0x05`), and two to the client, `TOCLIENT_BLOCKDATA_FM` (`0x12`) and `TOCLIENT_BLOCKDATAS_FM` (`0x13`). | `serveropcodes.cpp` | Sent only to clients that ask for far blocks. A Luanti client never does. |
| A mapblock may set flag bit 7 and append a msgpack list of light points inside its compressed data; the network trailer is version 3 and adds heat, humidity and wind. | `mapblock.cpp` | For network blocks Luanti's `deSerialize` reads through the node metadata and stops, and ignores flag bit 7; its `deSerializeNetworkSpecific` reads only the version byte. Goanna calls the same two functions. |
| `TOSERVER_GOTBLOCKS` is ignored (`#if NOTUSED`). | `serverpackethandler.cpp` | Nothing visible. Freeminer throttles sending its own way. |
| `TOCLIENT_MOVE_PLAYER`, `TOCLIENT_MOVEMENT` and `TOCLIENT_SPAWN_PARTICLE` are sent unreliably. | `serveropcodes.cpp` | A lost teleport or correction leaves the client where it was until the next one. |
| `LIQUID_FLOW_DOWN_MASK` is `0x40` instead of `0x08`, and `LEVELED_MASK` is `0x1F` instead of `0x7F`. | `mapnode.h` | Luanti's mesher reads liquids through `LIQUID_LEVEL_MASK`, which is unchanged. Leveled nodes are read with `0x7F`, so a Freeminer server that sets the upper bits would draw differently. Not observed. |
| Freeminer's own client adds wind acceleration to the local player (`getPlayerWindAcceleration`), from the wind the block trailer carries. The server's movement check is unchanged apart from types. | `client/localplayer.cpp`, `server/player_sao.cpp` | A Luanti client, Goanna included, is not pushed by wind where a Freeminer player is, and the server does not correct it. Not observed in play. |
| `max_block_send_distance` defaults to 30 mapblocks, against Luanti's 12. | `defaultsettings.cpp` | More near terrain arrives. |
| With `creative_mode = true`, new players get `default_privs_creative` (`interact, shout, fly, fast`) instead of `default_privs`. | `builtin/game/auth.lua:50` | A test setup trap: `default_privs` is ignored. |
| Positions beyond the 16-bit range are cast, not refused, when written for a protocol below 147 (`posToS16`, `util/numeric.h:465`). The generation limit of a 32-bit build is 2,147,483,008. | `util/numeric.h`, `constants.h` | A Luanti client on a 32-bit world beyond 32,767 nodes from the origin receives wrapped positions. One listed server is named "32bit client only!". Not tested. |

### Which clients join which servers

| Client | Server | Result | How known |
| --- | --- | --- | --- |
| Luanti 5.17.0 (the Flatpak) | Freeminer at `5d2c77028`, default protocol options | joins | run here |
| Goanna on Luanti 5.17.0 | same | joins | run here |
| Luanti 5.0 to 5.16 (protocol 37 to 52) | same | should join through Luanti's own version gates, which Freeminer keeps | code reading, not run |
| Luanti older than 5.0 | same | refused, below protocol 37 | code reading |
| Luanti newer than the server's merge | any Freeminer server | fails | issue #308 |
| Freeminer client | Luanti 5.17.0 | should join at protocol 53; a Luanti server ignores commands `0x03` to `0x05` through `handleCommand_Null`, so there is no far view | code reading, not run |
| Any Luanti client | Freeminer built with `MINETEST_PROTO` off | refused, different packet format | code reading |

## What was run

A server only build of Freeminer at `5d2c77028`, `RelWithDebInfo`, with the
default protocol options (`map32 obj64 threads multi: mt 37-148 enet` in its
start banner), on 127.0.0.1:30534 with throwaway worlds. The Earth mapgen,
WebSocket, LevelDB and dependency fetching were off; Lua was the bundled
Lua 5.1.5 because this machine has no LuaJIT headers. The build took about
20 minutes, of which about 5 were compiling at `-j6`. Two option switches do
not compile when turned off: `ENABLE_TIFF=0` breaks
`src/mapgen/earth/hgt.cpp` and `ENABLE_CURL=0` breaks
`src/server/serverlist.cpp`. Both were worked around with build settings,
not source edits.

Goanna was built from its `luanti-5.17` branch at `a5da4db` (Luanti 5.17.0,
protocol 53) and run in Godot 4.5.1 with a scratch `XDG_DATA_HOME`. `main`
still pins Luanti 5.16.1 at the time of writing. The games were Freeminer's
own copy of devtest (which adds a `circuit` mod to Luanti's) and Mineclonia
release 38561 from the local Luanti install.

| Run | World | Client | Result |
| --- | --- | --- | --- |
| 1 | devtest, new | Luanti 5.17.0 | Joined at protocol 53, received the Freeminer init, left cleanly after about 20 s. No client errors. |
| 2 | devtest, same | Goanna | Joined, 469 of 469 media files, 273 mapblocks received and meshed, player standing, pointed node reported, `goanna:v1` hello received by the server. Frames rendered correctly. |
| 3 | devtest, same, with `goanna_server_mod` and `goanna_far_rendering = true`, pregeneration on | Goanna | The grant arrived over `goanna:v1`, `render_stats().far_remote` read 567 and later 453, chat round trip worked. Ten Lua panics in emerge threads; the server survived, reporting 6 s of lag. |
| 4 | devtest, new, mod, pregeneration off | Goanna, 14 s | Clean. |
| 5 | devtest, new, mod, pregeneration on | Goanna, 10 s | Server exited with status 1 within a second of the first far requests. Nothing logged. |
| 6 | as 5, verbose log | Goanna | Two Lua panics, then SIGSEGV about 7 s after joining. |
| 7 | as 5, `num_emerge_threads = 1` | Goanna, 75 s | Clean, no panics, `far_remote` 630, 1,226 mapblocks received. |
| 8 | Mineclonia, new, no Goanna mod | Goanna | Joined and rendered; the server aborted with `double free or corruption (out)` after 456 error lines. |
| 9 | Mineclonia, new, no Goanna mod | Luanti 5.17.0 | Joined; the server aborted the same way (exit 134, 133 Lua panics) within about 50 s. |
| 10 | Mineclonia, new, `num_emerge_threads = 1` | Goanna, 75 s | Clean: 925 mapblocks, 53 entities, 5,488 item definitions, chat, inventory and HP. |

The crashes are Freeminer's, not Goanna's: run 9 reproduces them with the
stock Luanti client and no Goanna mod. Runs 3, 6, 8 and 9 logged Lua panics
in several emerge threads ("bad argument #-1 (function expected, got
nil)"); run 5 died without logging anything. Freeminer started eight emerge
threads on this 16 thread machine, where Luanti defaults to one, and runs 7
and 10, with one thread, were clean. The likely cause is Lua `on_generated`
callbacks, which Mineclonia registers in seven files and
`goanna_server_mod` in one, being run from several emerge threads at once.
That is a reading of the evidence, not a diagnosis, and it was one run per
case. It may also depend on this build using Lua 5.1.5 rather than LuaJIT.
The public servers reported uptimes of 29 to 32 hours, so their games or
builds evidently avoid it. It has not been reported to Freeminer from here.

In run 10 Mineclonia's grass looked blue grey where its savanna is usually
yellow green. It was not compared with the same seed on a Luanti server, so
whether that is Freeminer, Goanna or the biome is not known.

The teleport in run 3 failed because of the `default_privs_creative` trap
above, not because of Goanna.

## Licensing

Freeminer's own code is GPL-3.0-or-later. Its root `COPYING` is the GPLv3
text, added in commit `2ad6e78d3` of 8 March 2014, "Switch license to GPLv3
or later", which rewrote the notices of 322 of the 382 C++ files then under
`src/`. The tree today is a mixture:

- 111 files under `src/` (outside `src/external/`) carry Freeminer's
  GPL-3.0-or-later notice. They include every `fm_*` file, the multi, ENet,
  SCTP and WebSocket transports, the Earth mapgens and the threading
  helpers.
- 720 carry an LGPL notice. Two carry both: `src/emerge.cpp`, for example,
  has Luanti's `SPDX-License-Identifier: LGPL-2.1-or-later` line followed
  by Freeminer's GPLv3 block.
- `src/noise.cpp` carries only the GPLv3 block, where Luanti's `5.17.0`
  copy carries a BSD style notice. File headers are therefore not a
  reliable guide to what a given file may be used under; anyone reusing one
  would have to establish it from history.
- `LICENSE.txt` is Luanti's (LGPL-2.1-or-later code, CC BY-SA media) and
  `COPYING.LESSER` arrived with an upstream merge. GitHub reports the
  licence as `NOASSERTION`.
- Media: the engine's own textures are Luanti's, under the terms in
  `LICENSE.txt`. Freeminer adds some (for example
  `textures/base/pack/sun.png`) with no separate statement that I found. The
  `games/default` submodule was not checked out or read.
- msgpack-c, which any Freeminer extension would need, is under the Boost
  Software License 1.0, which is compatible with Goanna's terms.

What that means for Goanna, which is LGPL-2.1-or-later and whose built
binary is already LGPL-3.0-or-later (`THIRD-PARTY.md`):

- **Talking to a Freeminer server raises no licence question.** It is
  interoperation over a network, the same as with Luanti.
- **Compiling or linking any Freeminer file** makes the built GDExtension
  GPL-3.0-or-later. Goanna's "or later" terms permit that, and it is the
  same choice `docs/far-rendering.md` declines for Distant Horizons: it
  decides what every downstream game built on Goanna may do, so it is not
  to be made as a side effect of a feature. It would also put
  `luanti/lib/sha256`, under the old four clause OpenSSL licence, into a GPL
  binary, a combination the FSF lists as incompatible.
- **Compiling Luanti files from a Freeminer checkout instead of `luanti/`**
  is the same thing. Freeminer's changes to those files are part of a
  GPL-3.0-or-later work, whatever the file's header says.
- **Transplanting** a Freeminer file under `src/transplant/` is the same
  again, and `docs/transplanting.md` is written for Luanti files only.
- **Writing Goanna's own encoder and decoder for Freeminer's messages**,
  from a reading of the protocol, is ordinary interoperability work, as long
  as nothing is copied: not `fm_networkprotocol.h`, not its enums as text.

None of this is legal advice.

## What Goanna would need

### To join: nothing

Goanna already ignores `0x08` and the block trailers, reads positions at
protocol 53, and joined in every run. The only
work is to say so accurately and keep testing it, and to be clear about
what a Luanti client does not get on a Freeminer server.

Two small, optional additions:

- Recognise a Freeminer server by the arrival of command `0x08` and say so
  in the connection status, with a line on what is not supported. This
  reads a packet every client already receives and parses nothing in it.
- An advanced setting that offers a lower maximum protocol version, for the
  weeks after a Luanti release while Freeminer has not merged it (issue
  #308). This asks the server for less, not more. Goanna's session already
  branches on protocol 51 and 52 in places, but the transplanted code is
  compiled against one Luanti version and only some of its paths honour an
  older protocol, so each would need testing. Not worth building until
  somebody hits it.

### Freeminer's far view: a second protocol path

How it works, from `fm_server.cpp`, `fm_clientiface.cpp`,
`fm_world_merge.cpp`, `client/fm_farmesh.cpp`, `client/fm_client.cpp` and
`client/fm_far_container.cpp`:

- A world merge thread on the server builds coarser copies of generated
  terrain into databases `merge_1`, `merge_2` and so on, each step halving
  the resolution by picking a representative node from each 2 by 2 by 2
  group. The `world_merge` setting turns it off.
- The client tells the server its far range and quality with
  `TOSERVER_DRAWCONTROL`, then asks for far blocks by position and step
  with `TOSERVER_GET_BLOCKS`, a msgpack map. The server answers with
  `TOCLIENT_BLOCKDATAS_FM`: up to 100 serialised mapblocks per pass, each
  with its step, heat, humidity, wind and light points. Steps run to 21 in
  a 32-bit build (`FARMESH_STEP_MAX` is 22).
- The client's default far range is 5,000, 10,000 or 100,000 nodes by
  machine speed. Where no merged block exists it runs the server's mapgen
  locally, from the parameters in `TOCLIENT_FREEMINER_INIT`, to fill the
  gap.
- I found no privilege, distance or rate check on requested far blocks in
  `Server::handleCommand_GetBlocks` or `RemoteClient::SendFarBlocks`. Step
  0 is accepted and is served from the main map database, which by my
  reading would hand any client full resolution stored mapblocks from
  anywhere in the world. Freeminer's own client never asks for step 0
  (`FarMesh::makeFarBlock` returns early). This was not tested, on purpose.

Set against Goanna's far field (`docs/far-rendering.md`):

| | Freeminer far view | Goanna far field |
| --- | --- | --- |
| Data | the server's merged databases, built from generated terrain | the client's store of received mapblocks, plus summaries from `goanna_server_mod` |
| Request | `TOSERVER_GET_BLOCKS`, Freeminer's own msgpack command | `farsum?` and `farfine?` messages on the `goanna:v1` mod channel |
| Grant | none: any client that asks is answered; the operator can only switch `world_merge` off | off unless the operator sets `goanna_far_rendering` |
| Gaps | filled by running the mapgen on the client | left unknown; Goanna never generates terrain |

Goanna's own far field already works on a Freeminer server when the
operator installs `goanna_server_mod` (runs 3 and 7), through the ordinary
mod channel mechanism. That path needs no Freeminer specific code at all,
subject to the emerge thread crash above.

Using Freeminer's far view instead would need Goanna's own implementation
of `TOSERVER_INIT_FM`, `TOSERVER_DRAWCONTROL`, `TOSERVER_GET_BLOCKS` and
`TOCLIENT_BLOCKDATAS_FM` over msgpack, a mapping from Freeminer's steps onto
Goanna's coarse chain, and a decision in `docs/capabilities.md` about the
grant. It would not need the mapgen fallback, which Goanna's boundary
excludes outright. It would also be a combination no stock client sends:
Freeminer's client asks for far blocks at protocol 148, a Luanti client
never asks at all, and Goanna would be asking at 53.

### 32-bit worlds: a second engine

Protocol 148 means Freeminer's `pos_t`, `v3pos_t` and `v3opos_t` through
the map, mapblocks, meshing, collision, raycasting, entities and Goanna's
own store and far field. None of that can be compiled from `luanti/`. The
only route is to build Goanna against Freeminer's tree: a second pinned
submodule, a second transplant inventory, a GPL-3.0-or-later binary and a
second product to keep in step with a fork. Rejected. If 32-bit positions
ever land in Luanti, Goanna inherits them through its submodule like any
other upstream change.

### Games

The five servers on the Freeminer list (all on one host, `fm.setun.net`,
all version 5.17.0.0 with 32-bit maps) run the games `earth` (three, with
the `earth` and `voxel_earth` mapgens) and `sky` (two, with `indev` and
`math`). None runs Mineclonia, Minetest Game or devtest, and Goanna has
never been run against `earth` or `sky`. The same five are the only
Freeminer servers among the 424 on the Luanti list, which is dominated by
`minetest` (178, Minetest Game's id), `mineclonia` (62) and
`minetest_game` (25). Freeminer's default game is its own `default`, a
separate repository not read here.

Mineclonia and devtest do run on a Freeminer server (runs 2, 7 and 10), with
the emerge thread caveat. Minetest Game was not tried.

## Against Goanna's boundaries

**Unmodified servers, the ordinary protocol.** Joining a default Freeminer
server on its main port uses Luanti's protocol, unmodified, and asks the
server for nothing it was not built to give. Freeminer's own messages are
not the ordinary protocol. Using them for far view would be a second
protocol, however carefully it copied Freeminer's client.

**Nothing a vanilla player lacks.** As a Luanti protocol client, Goanna
receives what the stock Luanti client receives from a Freeminer server, and
less than Freeminer's own client. Three points need saying plainly:

- Every client receives the mapgen parameters in `0x08`. Goanna must never
  use them to generate terrain, which its existing rule already forbids.
- Every Luanti protocol client, the stock one included, escapes the wind
  that Freeminer's client applies to its own player. Goanna did not create
  that and cannot close it without reimplementing Freeminer's physics. It
  should be stated, not advertised.
- If Goanna ever used Freeminer's far view, it must ask for no more than
  Freeminer's own client asks for, and never step 0. On a Freeminer server
  the vanilla client is arguably Freeminer's own, which does ask for far
  blocks by default; but the server has no grant to read, and treating
  Freeminer's defaults as consent is exactly the kind of judgement
  `docs/capabilities.md` says Goanna must not make for itself. It would have
  to be decided there, before any code.

**Never fork or patch Luanti.** Phase 1 below needs neither. Building
against Freeminer's tree would be depending on a fork of Luanti, which
defeats the reason for the rule even though Goanna would not be the one
patching. The Freeminer build used for testing here was not modified.

**No claim of affiliation.** Freeminer is a separate project with its own
name and maintainer. Documentation may say that Goanna can join Freeminer
servers through their Luanti compatible protocol, with the versions it was
tested against. It must not use Freeminer's name or artwork to suggest more,
and the README's "not affiliated with or endorsed by Luanti" sentence should
name Freeminer too if Freeminer is mentioned at all.

## Plan

**Phase 0, this research.** Done, about half a day including the build and
ten runs.

**Phase 1, document and keep it working.** About one day, or one and a half
with the status line.

- Re-run the table above on whatever Goanna and Freeminer commits are
  current, adding Minetest Game, digging and placing, a formspec, and a
  side by side with the stock Luanti client on the same server, with the
  server log checked for movement corrections.
- Then, and only then, add a short entry to `docs/players.md` (and a line
  in `README.md` if wanted): Goanna joins Freeminer servers built with the
  default Luanti compatible protocol, when Goanna's Luanti version is not
  newer than the server's merge; Freeminer's far view, 32-bit worlds and
  wind are not supported; which versions were tested.
- Optionally, the `0x08` status line described above.
- Report the emerge thread crash to Freeminer with the stock client
  reproduction (run 9). It affects every client.

Risks: Freeminer can change the protocol 53 path without notice, since one
maintainer merges Luanti on their own schedule; a Goanna built on a newer
Luanti fails until they do. Mitigation: record the tested pair, and treat
Freeminer as a best effort target that is not part of the release gate.

**Phase 2, the version lag setting.** One to three days, only if Phase 1
finds people hitting issue #308. Test by building Freeminer at its last
commit before the 5.17.0 merge and joining it with a 5.17.0 Goanna, with
and without the setting.

**Phase 3, Freeminer far view as a far field source.** Three to six weeks.
Not recommended now. Needs the grant decision in `docs/capabilities.md`
first, then msgpack-c, Goanna's own messages, step mapping, a request
pattern that matches Freeminer's client, and a Freeminer server with merged
data to test against. Risks: an undocumented protocol with one maintainer
(the `net_proto_version_fm < 3` split in `SendFarBlocks` shows it moving);
a protocol 53 client asking for far blocks, which nobody else does; GPL
code arriving by copy rather than by reading.

**Phase 4, 32-bit worlds.** Months, and rejected for the reasons above.

## Recommendation

Do Phase 1 when someone next has a day for it, and nothing further.

Goanna already joins a default Freeminer server as a Luanti client, and
that costs nothing to keep. Everything that makes Freeminer different from
Luanti is either out of reach within Goanna's boundaries without a second
protocol (far view), or out of reach without a second engine (32-bit
worlds), or already denied to every Luanti client (wind). Meanwhile the
public Freeminer servers are five, on one host, running games Goanna has
never run, on 32-bit maps where a protocol 53 client may see wrapped
positions.

### What would change the recommendation

- Freeminer servers running Mineclonia, VoxeLibre or Minetest Game, with
  players, appearing on either server list.
- Freeminer documenting and versioning its far view messages, with a
  server setting an operator sets deliberately. That would make Phase 3 a
  capability with a real grant rather than a judgement call.
- 32-bit positions merged into Luanti.
- Freeminer players asking for Goanna.

## Not verified

- A Freeminer client. None was built, so its behaviour against a Luanti
  server, its far view and its wind are known from the code only.
- A server built with `MINETEST_PROTO` off, or with LuaJIT.
- The public servers. Goanna was not connected to them, so whether their
  spawn points lie beyond the 16-bit range is not known.
- Whether the server really serves step 0 far blocks. Not sent, on purpose.
- The leveled node mask difference and the wind difference, in play.
- Luanti clients older than 5.17.0 against a Freeminer server.
- Minetest Game on Freeminer, and the grass tint in run 10.
- The cause of the emerge thread crash.
- The licence of media Freeminer adds, and anything in `games/default`.

## Reproducing the test

A server only build that compiled on this machine (Fedora based, gcc 16,
CMake 4.4). Fetch `src/external/msgpack-c`, `src/external/enet`,
`src/external/jsoncpp` and `src/external/libtiff` as submodules first.
`CURL_INCLUDE_DIR` pointed at a copy of cURL's headers, since the host has
the library but not its development package.

```sh
cmake -S . -B build-server -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_CLIENT=0 -DBUILD_SERVER=1 -DBUILD_UNITTESTS=0 \
  -DBUILD_DOCUMENTATION=0 -DRUN_IN_PLACE=1 -DFETCH_DEPS=0 \
  -DFETCH_EARTH_DEPS=OFF -DENABLE_ARROW=OFF -DENABLE_VOXEL_EARTH=OFF \
  -DUSE_VOXEL_EARTH=OFF -DENABLE_OSMIUM=OFF -DENABLE_OSMIUM_TOOL=OFF \
  -DENABLE_ONNXRUNTIME=0 -DENABLE_TIFF=1 -Djpeg=OFF \
  -Djpeg-prefer-standard=ON -DCMAKE_DISABLE_FIND_PACKAGE_libjpeg-turbo=ON \
  -DENABLE_WEBSOCKET=0 -DENABLE_SCTP=0 -DENABLE_LEVELDB=0 \
  -DENABLE_CURL=1 -DCURL_INCLUDE_DIR=/path/to/curl-headers \
  -DCURL_LIBRARY=/usr/lib64/libcurl.so.4 -DENABLE_POSTGRESQL=0 \
  -DENABLE_CURSES=0 -DENABLE_TCMALLOC=0 -DENABLE_UNWIND=0 \
  -DENABLE_GETTEXT=0 -DENABLE_SYSTEM_GMP=0 -DENABLE_SYSTEM_JSONCPP=0 \
  -DENABLE_LUAJIT=0 -DENABLE_REDIS=0 -DENABLE_SPATIAL=0 \
  -DENABLE_PROMETHEUS=0 -DENABLE_OPENSSL=0 \
  -DSQLITE3_INCLUDE_DIR=/home/linuxbrew/.linuxbrew/include \
  -DSQLITE3_LIBRARY=/usr/lib64/libsqlite3.so.0
cmake --build build-server -j6
```

The server configuration that was used, with `num_emerge_threads = 1`
added for runs 7 and 10, `creative_mode` set only for the devtest runs, and
the `goanna_*` lines only where the table says so:

```ini
port = 30534
bind_address = 127.0.0.1
ipv6_server = false
server_announce = false
creative_mode = true
default_privs = interact, shout, fly, fast, teleport, give
enable_damage = false
enable_mod_channels = true
goanna_far_rendering = true
goanna_far_rendering_distance = 512
goanna_far_provider_distance = 512
goanna_far_pregenerate = true
```

```sh
build-server/freeminerserver --config fm_server.conf \
  --world /path/to/world --gameid devtest --port 30534

GOANNA_HOST=127.0.0.1 GOANNA_PORT=30534 GOANNA_NAME=probe \
  /path/to/Godot_v4.5.1-stable_linux.x86_64 --path project
```

For Mineclonia, set `LUANTI_GAME_PATH` to a directory that contains it
before starting the server. Leave `creative_mode` unset if the test needs
the privileges in `default_privs`.
