# Goanna, unreleased

## Accessibility

- **Talk instead of typing.** Hold `T`, say your chat line and let go: it
  goes into the chat box unsent for you to check, and `Enter` sends it. A
  quick tap of `T` still opens chat for typing. Speech is turned into text
  on your computer by a Whisper model, downloaded (57 MB) the first time;
  nothing you say is recorded or sent anywhere. It makes more mistakes with
  young voices and strong accents; the Small model in Settings, Audio
  helps.
- **Talk and chat on a controller.** Hold D-pad up to speak a chat line, or
  tap it to open chat; in the chat box, A sends and B cancels. Controllers
  had no way to chat before. Not yet tried on a real controller.

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

- **Read aloud no longer loses lines.** A line that arrived while another
  was being read, such as the reply to a command, could be dropped. Lines
  now wait their turn. A line that arrives while Read chat is off is no
  longer read out when it is turned back on.

- **One Escape closes chat.** It took two: the first only stopped the text
  box editing.
