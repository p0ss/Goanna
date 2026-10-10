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
