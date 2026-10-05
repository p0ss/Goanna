# Goanna, unreleased

## Accessibility

- **Talk instead of typing.** Hold `T`, say your chat line and let go: it
  goes into the chat box unsent for you to check, and `Enter` sends it. A
  quick tap of `T` still opens chat for typing. Speech is turned into text
  on your computer by a Whisper model, downloaded (57 MB) the first time;
  nothing you say is recorded or sent anywhere. It makes more mistakes with
  young voices and strong accents; the Small model in Settings, Audio
  helps. Tried with synthesised speech, not yet with a microphone.

## Fixes

- **Read aloud no longer loses lines.** A line that arrived while another
  was being read, such as the reply to a command, could be dropped. Lines
  now wait their turn. A line that arrives while Read chat is off is no
  longer read out when it is turned back on.

- **One Escape closes chat.** It took two: the first only stopped the text
  box editing.
