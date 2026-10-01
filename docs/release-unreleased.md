# Goanna, unreleased

## Updates

- **Goanna updates itself.** When a new release is out, the menu offers
  Update and restart. It checks the release is signed by Goanna's
  maintainer before installing it, and keeps your worlds and settings.
  Coming from 0.10.0 needs one last download by hand.

## Your character

- **More ways to move.** Landing from a fall crouches your character, deeper
  the harder you land, with the feet staying on the ground; falling puts
  the arms out; stepping up a block lifts the leading knee; ladders and
  vines are climbed hand over hand; and in third person your character
  leans into starts, back on stops and into turns.
- **Swimming without sprinting.** Moving through deep water upright now
  swims the breaststroke instead of treading water. Sprinting with your
  head under still swims the crawl.
- **Back into first person with the wheel.** Alt with the wheel brings the
  third person camera in and, past the closest, back into first person;
  out from first person steps behind.
- **Arms in first person.** Your arms no longer swing a held item up into
  the view as you walk.

## Water

- **Under water looks like water.** The murk is lit cyan near the surface,
  darker with depth and through the evening, instead of nearly black.
  Looking up, you see the sky through the window overhead and, beyond it,
  the water below reflected in the surface. The bed loses its colour to the
  water the same way seen from in it as from above, neither brighter nor
  murkier once you dive in, and the waves show on the underside again.
- **Third person in water.** With your head under and the camera above the
  water, the view no longer turns water blue.
- **Waves round your body.** Wading, swimming or jumping in, the water
  rises and rings right at your body's edge instead of a node away, and
  splashes are thrown as streaks of water rather than white blobs. Seen
  from above, ripples are lit on the sun's side, and the water froths into
  bubbles where you push through it or jump in.
- **Crown splashes.** Jumping or falling into the water hard throws up a
  crown of water round you, its rim breaking into fingers and drops,
  higher on the side you were moving towards; punching the water throws a
  small one the way you hit.
- **No more strobing near the shore.** The sea no longer flickers as if in
  fast forward when you stand a few blocks from the water's edge.

## Fixes

- **Missing particles are back.** Effects a game attaches to a creature,
  such as a glow squid's glints, were not shown at all, and nor were most
  effects within about 100 blocks of the world's centre. They now show,
  each on the creature or place it belongs to.
- **Old materials are cleared away.** Installing a newer materials pack
  now removes the version it replaces, which was kept beside it before.
  On a long running install that frees a few hundred megabytes.

## Experimental

- **Let a program play as you.** With `GOANNA_PLAYER_AGENT` set, a local
  program (an AI agent, say) can see what your character sees and walk,
  look, dig, place, use items, chat and sort your inventory through the
  same controls you use, with no powers you do not have. It needs a key the
  game writes to your own files each time it starts. See
  `docs/agent-interfaces.md`.
- **An AI game master for your world.** A world started from Goanna can
  connect to a game master run by an AI agent you choose, through
  `tools/goanna-director-mcp`. In Mineclonia it can stage encounters sized
  to each player's gear and pace them, and speak as characters who remember
  what you said to them. Anyone who joins is told it is running and can
  turn it off for themselves with `/director optout`. It does nothing until
  you connect one. See `docs/director.md`.
