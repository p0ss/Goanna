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
ungenerated block is reported as unknown and stays a hole in the client's
view, so nothing is invented and no worldgen happens on a request. What comes
back per mapblock is 21 bytes, protocol version 2: whether it blocks light,
whether it is lit, a 4 by 4 grid of surface heights over the block's
footprint (one byte each, so a slope reads as a slope rather than a stepped
box), the commonest node on top and at the sides, and its light levels. A
block is still under a hundredth of the size it would be sent at full
resolution, and an 8 by 8 by 8 block area, the size a request covers, is
about 10.5 KB raw and 14 KB once base64 encoded for the channel.

Two bounds an operator owns. Requests outside `goanna_far_rendering_distance`
of the asking player are refused silently, so the grant is the reach. And the
work is paced by `goanna_far_summary_blocks_per_step`, ninety six mapblocks
per server step by default, which keeps an area to about half a second of
wall clock; lower it on a busy server.

That number is the rate the whole far view fills at, for every client on the
server together, and it is worth knowing what it buys. The queue runs one job
at a time and a job is 512 mapblocks, so 96 a step is roughly two areas a
second. A 1024 node grant is 128 by 128 mapblocks around a player, one
horizontal layer of which is 16384 blocks: nearly three minutes at that rate,
and it was eight and a half at the old default of 32. `goanna_far_summary_lag`
is what makes raising it safe. Above that many seconds of reported server lag
the queue pauses, keeping the part finished area rather than abandoning it, so
no client is left waiting on a reply that never comes.

One limitation worth stating plainly, because it is Luanti's rather than
ours: a mod channel has no unicast. `send_all` is the only way to answer, so
every Goanna client on the channel sees every reply and filters by the
requester name in it. Granting far rendering therefore grants coarse
summaries of terrain near any player who asks, to every Goanna client on the
server. The distance check is against the asking player and the grant is
server wide, so this widens what is seen by other players' whereabouts, not
by any distance beyond what was granted.

### Pregeneration

A summary describes terrain that exists, and a server generates only within
the range its client asks for, so a new world has a 192 node horizon
whatever distance was granted. `goanna_far_pregenerate` lets this mod
generate outward from each connected player, one 128 node area at a time,
nearest first and the player's own vertical layer before the ones above and
below it, with `goanna_far_pregenerate_interval` seconds between areas, out
to the far rendering distance, and summarise each finished area for the
clients near it unasked. It spends mapgen time and map memory on terrain no
one has visited, so it is off unless the operator turns it on. The server a
Goanna client launches for itself turns it on.

An area is emerged `goanna_far_pregenerate_slice` mapblocks on a side at a
time rather than all at once, and the next slice starts when the last one
reports back. This is the part that keeps pregeneration out of a player's
way, and it is not optional politeness: Lua's `core.emerge_area` carries
`BLOCK_EMERGE_FORCE_QUEUE`, so none of the per client queue limits apply to
it, and each emerge thread's queue is a plain FIFO. Emerging a whole area
put 512 mapblocks in front of whatever the player was waiting for.
`goanna_far_pregenerate_lag` is the coarser guard: above that many seconds
of server step time, pregeneration waits for the server to catch up.
`docs/far-rendering.md` has the before and after timings.

A client's own `farsum?` goes ahead of every summary offered from
pregeneration, and only asked requests count towards the queue limit that
refuses one. A player waiting on the view in front of them is not made to
wait behind terrain nobody asked about.

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
