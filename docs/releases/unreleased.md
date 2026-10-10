# Goanna, unreleased

Changes on main since 0.13.0-alpha.

## Fixes

- **Typing on a Steam Deck.** A text box reached with the D-pad, such as
  Join Game's address, ignored the Deck's on-screen keyboard, so a Deck
  could not join a server. It now takes typing as soon as it has the
  focus.
- **Prompts for the device you are using.** Messages name the control on
  what you last used, a controller's button or a key, and a failed
  connection offers a Back to the menu button instead of telling you to
  press Escape. A server that never answers is no longer reported as
  refusing you.

## Servers

- **Distant terrain fills faster and costs the server less.** On Luanti
  5.9 and later, the server mod now does the heavy part of summarising
  distant terrain on Luanti's async worker threads rather than in the
  server step that every mod and player shares. On an explored Mineclonia
  world with one player, summaries took about half of the server step and
  now take about an eighth, and the far view fills about a quarter faster
  (60,000 blocks per 30 seconds against 48,000). The full detail blocks
  sent for nearby terrain are encoded on the workers too.
  `goanna_far_summary_async = false` keeps the old behaviour. Not yet
  tested with several players or games other than Mineclonia.
