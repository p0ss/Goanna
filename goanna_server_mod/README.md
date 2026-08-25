# Goanna server mod

Optional. A server without it is rendered exactly as any vanilla client
renders it. This only ever adds.

Goanna can do things Luanti's own client cannot, and some of them would give a
player reach or information a vanilla player lacks. The client does not decide
that for itself. This mod is how a server operator authorises it, which is why
absence is the safe state rather than a broken one: every option is a grant,
so granting nothing is the conservative default.

## It does not know what any option means

The obvious design is a list of capabilities in `init.lua`, one line added per
client feature. That was the first version and it was wrong: it forces this
mod to be released in lockstep with the client, and leaves a server running an
older copy unable to authorise anything newer, purely for bookkeeping.

Instead it relays every setting named `goanna_*` as it finds them, without
understanding any of them. A client that knows a key uses it, one that does
not ignores it, and a key no client knows yet costs nothing. Adding a
permission is an edit to `minetest.conf`, not a new release of this mod.

```
goanna_far_rendering = true
goanna_far_rendering_distance = 512
```

becomes `far_rendering=true` and `far_rendering_distance=512` on the wire. The
prefix exists to find them in the server's config, not to be repeated.

Two consequences. Unknown keys must be ignored silently at both ends, which is
what makes this safe to extend. And **nothing secret goes in a `goanna_*`
setting**, because every one of them is broadcast to any client that asks.

## Settings, or a submod?

Both exist, and which one a capability needs is decided by a single question:

> **Does the server have to do anything, or only permit it?**

**Only permit it: a setting is enough.** The work is entirely in the client;
the server's role is to say yes. Far rendering is the clean example. The
client keeps its own store and draws its own distant terrain; the server is
not involved beyond consenting. No code runs on the server at all, so no
submod exists to write.

**The server has to act: it needs a submod.** The capability requires server
side behaviour, and behaviour means code:

- relaxing a check, as source style movement needs `anticheat_flags` changed
  or the server rejects the movement it produces
- sending data the server does not otherwise send
- registering callbacks, validating differently, keeping state

A submod does its own work and calls `goanna_announce(key, value)` to appear
in the advertisement alongside the plain settings. It depends on this mod and
this mod knows nothing about it.

The distinction matters because it decides where a capability's complexity
lives. If a proposal only needs a flag, it must not grow a submod. If it needs
the server to behave differently, a flag alone will produce a feature that
looks enabled and silently does nothing, which is worse than it being off.

## The handshake

`goanna:v1`, a Luanti mod channel. The client joins after `CLIENT_READY` and
sends `hello`; this mod replies with `key=value` lines, one per line. A server
mod cannot see who joined a channel, only messages arriving on it, which is
why the client speaks first.

`send_all` goes to everyone on the channel. That is deliberate: the options
are a property of the server, not of the player.

## Far terrain summaries

This mod does one thing beyond relaying settings, and it is the half of far
rendering a client cannot do alone: it answers a request for a coarse summary
of an area of the map. That is how a Goanna client draws places its own player
has never been.

It reads terrain the server has already generated and never generates any. An
ungenerated block is reported as unknown, so no terrain volume is invented
and no worldgen happens on a request (unless the mapgen has registered a far
surface, below). The client temporarily closes the boundary faces of adjacent
known voxels until more data arrives, rather than exposing the inside of the
coarse volume. What comes back per mapblock is 83 bytes, protocol version 6:
flags for available and complete data, a 4 by 4 by 4 field of coarse content indices, packed
liquid surface heights, and the block's maximum day and night light. Index 0
is known air and 255 is unknown, so vertical occupancy is retained: a
sufficiently large cave, overhang or gap below a floating island remains air
instead of being reconstructed as solid ground under one height. A block is
still well under a tenth of the size it would be sent at full resolution, and
an 8 by 8 by 8 block area, the size a request covers, is about 42 KB raw and
57 KB once base64 encoded for the channel.

A partially emerged mapblock is useful progress but is not complete. Its
known cells are sent, while the client stages the reply and retries until the
whole summary area can be published atomically. Version 5 conflated those
states, allowing an early partial read to preserve unknown strips through a
mountain indefinitely.

The light remains block-wide because 64 packed per-voxel lights would take an
area reply beyond Luanti's 16-bit mod-channel string limit. Occupancy is the
topology-critical part of this protocol; a later chunked reply can raise the
lighting resolution without changing the mip or meshing model.

### The store

A block is summarised once and kept. Since 2026-08-23 the mod holds a store
of records, in areas of 8 by 8 by 8 mapblocks (the unit a client asks for),
persisted in mod storage under keys that carry the protocol version, and a
request for an area the store knows is answered in the same server step by
lookup. Before that every request read every block of its area through a
`VoxelManip` when it was asked, one job at a time for every client on the
server, and that rate, not the network, was what made a horizon arrive as a
mosaic over minutes and be recomputed from nothing for every client that
joined.

The store fills without being asked: every freshly generated block is
summarised within a few steps of `register_on_generated`, while it is still
in memory; a block someone digs, builds on or floods is summarised again a
few seconds after `register_on_mapblocks_changed` reports it; and when the
queues are idle, the nearest unsettled area to any player is read in the
background (`goanna_far_summary_backfill`), which is how a world that
existed before the store did gets read once rather than on the first
client's clock. An area is settled once every block in it is known or has
been looked at and found ungenerated, and is not read again: generation and
node changes are the only things that change it and both are reported.

Two bounds an operator owns. Requests outside `goanna_far_rendering_distance`
of the asking player are refused silently, so the grant is the reach. And
every read of the map is paced by `goanna_far_summary_blocks_per_step`,
ninety six mapblocks per server step by default, with asked jobs ahead of
generated blocks, changed blocks and backfill in that order.
`goanna_far_summary_lag` pauses all of it while the server's reported lag is
above that many seconds, keeping part finished work rather than abandoning
it. `goanna_far_summary_cache_areas` bounds how many areas stay in memory;
past it, areas untouched for ten minutes are written out and let go.

What the store does not do yet is tell a client that a block it already has
changed. A client never asks twice for an area that came back complete, so
far terrain another player alters stays as it was until the client walks
there or rejoins.

One limitation worth stating plainly, because it is Luanti's rather than
ours: a mod channel has no unicast. `send_all` is the only way to answer, so
every Goanna client on the channel sees every reply and filters by the
requester name in it. Granting far rendering therefore grants coarse
summaries of terrain near any player who asks, to every Goanna client on the
server. The distance check is against the asking player and the grant is
server wide, so this widens what is seen by other players' whereabouts, not
by any distance beyond what was granted.

### A far surface from the mapgen

A mapgen that can say where its ground is for any (x, z) without generating
anything can register that with this mod, and then a client sees the whole
grant on a world nobody has walked:

```lua
goanna_register_far_surface(function(x, z)
    -- surface_y, top_name, water_y or nil, side_name
    return y, "mcl_core:dirt_with_grass", nil, "mcl_core:dirt"
end, {water = "mcl_core:water_source"})
```

When the store finds a block ungenerated and a provider is registered, it asks
for one sample per 4 node cell of the area's footprint and serves the record
made from that as known. Such a record is remembered as the provider's, and
when the block is really generated the real summary replaces it and the area
is offered again to the clients near it. The terrain diffusion mapgen
registers one (`tdl_far.lua` in that repository); the engine mapgens have no
such function, and pregeneration is the answer there. Nothing here writes to
the world, the operator grants it with the rest of far rendering, and the
client asks for the same summaries as before.

### Pregeneration

A summary describes terrain that exists, and a server generates only within
the range its client asks for, so a new world has a 192 node horizon
whatever distance was granted. `goanna_far_pregenerate` lets this mod
generate outward from each connected player with a small pipeline of 128
node areas, nearest first and the player's own vertical layer before the
ones above and below it, with `goanna_far_pregenerate_interval` seconds
between starting streams, out
to the far rendering distance, and summarise each finished area for the
clients near it unasked. Beyond the layer either side of the player's, an
area is generated only when the area nearer the player's layer is done and
its summary says the terrain carries on that way (ground at its ceiling, or
air along its floor), so a valley under a mountain is followed down and the
sky over a plain is left alone. It spends mapgen time and map memory on terrain no
one has visited, so it is off unless the operator turns it on. The server a
Goanna client launches for itself turns it on.

Each area is emerged `goanna_far_pregenerate_slice` mapblocks on a side at a
time rather than all at once, and its next slice starts when the last one
reports back. `goanna_far_pregenerate_concurrency` controls how many of
these independent streams are active (two by default; the bundled local
server uses three). This is the part that keeps pregeneration out of a player's
way, and it is not optional politeness: Lua's `core.emerge_area` carries
`BLOCK_EMERGE_FORCE_QUEUE`, so none of the per client queue limits apply to
it, and each emerge thread's queue is a plain FIFO. Emerging a whole area
put 512 mapblocks in front of whatever the player was waiting for.
`goanna_far_pregenerate_lag` is the coarser guard: above that many seconds
of server step time, pregeneration waits for the server to catch up.
`docs/far-rendering.md` has the before and after timings.

A completed pregeneration area goes ahead of speculative `farsum?` scans,
and half of the per-step summary budget is reserved for indexing newly
generated blocks. This prevents requests for empty areas from starving the
output side of mapgen. Duplicate jobs for the same player and area are
collapsed, and only asked requests count towards the queue limit that
refuses one.

## Settings

See `settingtypes.txt`. Everything is off by default.

`goanna_source_movement` is the one with a trap, and it is worse than it
looks. It needs `anticheat_flags = digging,interaction` as well, or the server
rejects the movement and the option appears to do nothing. This mod logs a
warning at startup when that is the case, rather than letting it present as a
client bug.

But clearing that bit disables movement validation for **every** client, not
for Goanna clients doing the sanctioned thing: the flags are three bits wide
and there is no finer grain. Every exploit in luanti-org/luanti#3822 becomes
available to anyone. So a source movement submod owes the server a replacement
validator, one that understands the model it authorises and still rejects
teleports and flight. Until that exists, treat this setting as suitable only
for a server whose operator has decided movement validation does not matter to
them, and say so plainly rather than presenting it as a feature toggle.
