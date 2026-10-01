# Goanna, unreleased

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
