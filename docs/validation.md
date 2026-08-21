# Validating the capabilities we authorise

Goanna hands players abilities a vanilla client does not have, each one
authorised by the server through `goanna_server_mod/`. Authorising an ability
and then not checking it is how a server ends up trusting its clients, which
no server should do. This is what we check, what we cannot check, and what
belongs upstream rather than here.

## It is not anticheat, and the difference matters

Our source will be open, so anyone can take the client, strip whatever checks
it contains and keep the abilities. That is true of every client for every
game and it is not worth fighting.

So nothing here is a client side check. Client side checks are user interface:
they stop accidents and mistakes, and they are worth having for that, but they
are not security and must never be treated as such. **A check that matters
runs on the server**, and the server is not ours.

That reframes the whole exercise. We are not writing anticheat. We are writing
**server side validation of a movement model the server itself authorised**,
which is a different and much more tractable thing: the server knows exactly
which model it granted and with what parameters, so it can check against that
model rather than against a guess.

Done properly this is *stricter* than the status quo, not looser. The status
quo for an authorised capability is `anticheat_flags` with the `movement` bit
cleared, which is no checking at all.

## Two kinds of cheat, two different defences

Worth separating, because conflating them produces effort spent where it
cannot pay.

**Action cheats** are things a player does: moving too fast, flying, reaching
too far, digging too quickly. The server observes the outcome, so it can
validate them. This is where a validator earns its keep.

**Information cheats** are things a player knows: x-ray, seeing entities
through walls, reading terrain beyond the fog. The client performs no
observable action, so the server cannot *prove* them from the packets alone,
and the strongest defence remains **not sending the data**.

But "cannot prove" is not "cannot detect", and treating the two as the same
thing gives up ground for no reason. See the section below.

Goanna's capabilities split cleanly along that line, and it retroactively
justifies a decision made earlier:

- Source style movement is an action capability. It needs a validator.
- Far rendering is an information capability. It needs none, and that is not
  an oversight: it draws only mapblocks the server already chose to send this
  client. There is nothing to validate because the server already made the
  decision, at the moment it sent them. Had it been designed to fetch or
  infer terrain instead, no validator could have made it safe.

That is the test for any future capability: if it can only be defended by
withholding data, then withholding data is the design, and permission is not
enough.

## Attestation, and why it is worth having anyway

The tempting conclusion from "any check can be patched out" is that checks are
pointless. That is wrong three times over.

**Effort gradients are the whole of security.** Nothing here is unbreakable
and nothing anywhere else is either. The question is never whether a
determined modder wins, it is what the cheapest attack costs. Moving that from
"set a config flag" to "patch a C++ client, rebuild it, keep the patch working
across releases and defeat an integrity check" removes almost everyone. The
people who remain were never going to be stopped by anything.

**Rules have to exist before they can be broken.** This is the part that has
nothing to do with technology. On a server with no stated rule, someone
rendering terrain they were not sent is not violating anything: there was no
expectation to violate. Once a server declares, through the options it grants,
what a client may do, exceeding it becomes a breach of a rule the operator set
rather than a grey area. That is worth doing even where the check behind it is
weak, and it costs nothing but writing the rule down.

**Detection feeds moderation, which is the real enforcement layer.** Servers
ban people. Every commercial anti-cheat is bypassable and works anyway,
because it produces evidence an administrator acts on. A client that does not
answer the attestation channel, answers inconsistently, claims a capability it
was never granted, or reports a build that does not match any release, has
given an admin something to act on. None of that is proof, and it does not
need to be.

So a Goanna client should report, and the server should record. Cheap signals
worth having, roughly in order of cost to defeat:

- no response on `goanna:v1` from a client that identified itself as Goanna
- a capability exercised that the server never granted, which the server can
  see for action capabilities and can at least ask about for the rest
- a self reported build identifier, checked against known releases
- self reported render settings: view distance in use, whether far rendering
  is active and how far

### The line that must not be crossed

Attestation produces **evidence, never proof**, and the failure mode is a
server operator who forgets that. "Goanna reports it is not doing x-ray,
therefore nobody is doing x-ray" is worse than having no attestation at all,
because it converts an unknown into a false certainty.

Two rules follow, and they are not negotiable:

- Attestation is an input to moderation. It is never an authorisation gate,
  and it never decides what the server sends.
- Where withholding data is possible, withhold it **as well**. Never relax a
  protection because attestation is watching, because that is precisely the
  trade an attacker is buying when they patch the client.

## What a validator has to do

Replace, not remove. Clearing `AC_MOVEMENT` disables movement validation for
every client on the server, so a mod that clears it owes the server a check at
least as strict for players who were granted nothing.

Per player, it needs:

- the capability set granted to that player, which the mod already knows
- the last position the server considers authoritative, and when
- the maximum displacement the *granted model* permits over that interval,
  which for source movement means the acceleration curve and air speed cap the
  mod advertised, not a flat speed limit
- a correction, and a log, when the observed displacement exceeds it

The interesting part is that this can be tighter than vanilla for an
authorised player, because it knows the model's actual parameters, where
vanilla only knows a speed.

## A mod is enough, and the upstream case is separate

`PlayerSAO::checkMovementCheat()` in `luanti/src/server/player_sao.cpp` is
C++, gated on `anticheat_flags & AC_MOVEMENT`, with no Lua hook. So a mod
clears that flag and validates in `register_globalstep`, correcting with
`set_pos`.

That is sufficient, and an earlier draft of this file was wrong to call it a
poor substitute. Two reasons:

- **The granularity is comparable.** Vanilla checks on position packets, which
  arrive perhaps ten to twenty times a second. `register_globalstep` runs
  every server step, near enough the same rate.
- **A displacement check integrates.** It does not need to catch the instant a
  player moved wrongly, only to notice that the distance between two
  observations exceeds what the model allows. A teleport between polls still
  arrives at a position the model could not have reached. There is no hiding
  in the gap, because the gap is exactly what is being measured.

The cost is a few position reads and some arithmetic per player per step,
which is nothing at any player count a Luanti server reaches.

One consequence to design for rather than discover: clearing `AC_MOVEMENT` is
server wide, so the mod's validator must cover **every** player, not only the
ones granted a capability. Strict by default, lenient only where a grant says
so. A validator that only watches Goanna players has left the hole open for
everyone else.

An upstream hook would still be better, and the case for it stands on its own
without Goanna needing it:

> `anticheat_flags` is all or nothing. Every mod that changes how players
> move, jetpacks, grappling hooks, vehicles, gliders, has to disable movement
> validation for the entire server to do it. A hook letting a mod supply its
> own movement model, or validate a movement it recognises, would let those
> mods keep the server's protections instead of trading them away.

That is a gap in Luanti that exists without Goanna and affects mods that have
nothing to do with us, visible since luanti-org/luanti#3822 in 2016. Worth
proposing for its own sake: it would keep the check in C++, keep it per
packet, and remove the need to clear a server wide flag to change one player's
movement. But it is an improvement to a working arrangement, not a
prerequisite for one.

### What "propose it upstream" actually requires

Luanti has an AI policy, `doc/developing/ai_policy.md`, and it bears directly
on how anything from this repository can reach them.

Substantial AI generated code is "strongly discouraged and may result in
immediate closure of the PR". AI generated prose is not to be used "when
communicating with other humans, including when writing documentation", which
covers the pull request description as much as the patch. Significant AI use
must be disclosed. Exploring a codebase, using a model as a search engine, and
local review or debugging are all explicitly fine.

Goanna's own working practice is a matter for Goanna. The constraint is at the
boundary: **nothing written here transfers to a Luanti pull request as is.**
Not the patch, not the issue text, not the paragraphs above. A contributor who
wants that hook has to understand the problem, write the patch and the
description themselves, own it, and disclose what assistance they had.

That is not an obstacle to the idea, and the analysis here is legitimately
useful as input to a person doing that work. But "belongs upstream" is a
statement about where the fix should live, not a plan for getting it there,
and this file should not be read as though the second follows from the first.

## The interim position

Until such a hook exists:

- Capabilities needing no relaxed protection ship normally. Far rendering is
  the example and is unaffected by any of this.
- Capabilities needing a protection relaxed do not ship as a plain setting.
  They need a submod carrying a replacement validator, and the submod is the
  larger half of the work. That validator is ordinary Lua, not blocked on
  anything.
- Where the replacement is meaningfully weaker than what it replaces, say so
  in the setting's own description rather than presenting it as an ordinary
  toggle. A server operator should be able to see the trade they are making.

## What this does not attempt

Proving a client is unmodified. That cannot be done, and a server that needs
certainty gets it from validation, which does not care which client sent the
packet. Attestation raises the cost of lying and hands an administrator
something to act on; it does not establish trust, and the moment it is treated
as though it does, it has become worse than nothing.
