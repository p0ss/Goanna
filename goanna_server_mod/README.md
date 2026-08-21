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
