# Accessibility

What Goanna does for players who cannot see the screen, or see it poorly,
and what it does not do yet. It is early work, written without a blind
player testing it. Reports from players who use it are the most useful
thing anyone can send.

## Read aloud

Read aloud speaks what is on the screen through your system's voice. It
uses the same speech service as your screen reader, so the voice, its rate
and its language are the ones you have already chosen there.

Turn it on with `Ctrl+B` at any time, in the world or with a form open
(the same key as Minecraft's narrator). It says "Read aloud on" or "Read
aloud off". It is also in Settings, Audio, Read aloud, with Speech rate and
Speech volume beside it. To start a game with it already on, launch Goanna
with `GOANNA_READ_ALOUD=1` in the environment.

It reads:

- chat, as each line arrives;
- text the game puts on the screen, once it has stayed the same for half a
  second, so a line that changes all the time (coordinates) is not read;
- the infotext of whatever you are pointing at, such as a chest's owner;
- the item in your hand when it changes;
- your health when it changes;
- a form or menu when it opens: its text, its tabs and which one is
  selected, and how many buttons, checkboxes, text fields and inventory
  slots it has;
- the control under the mouse pointer or the keyboard focus in a form:
  its words, what kind of control it is and its state, for example "Buy
  bread, button" or "Haggle, checkbox, checked". This interrupts whatever
  was being said, since only the newest one matters.

On Linux it needs speech-dispatcher and a voice, such as espeak-ng. Most
desktops with a screen reader have them. Without them Read aloud stays
silent and Goanna's log says why.

## Sound

Every sound the game plays is placed where it comes from: footsteps and
calls of other players and mobs, digging, and sounds the game attaches to a
creature move with it. Sounds fade with distance the way they do in the
vanilla Luanti client, and are panned fully left and right. Goanna cannot
yet make a sound seem above, below or behind you on headphones; the
vanilla client can, through OpenAL Soft's HRTF.

## Not done yet

- The main menu, where you choose a world or a server, is not read aloud.
  Starting a game still needs sight, or a launcher set up by someone else.
- Forms cannot yet be worked from the keyboard alone. Read aloud says what
  is under the pointer, but moving between a form's controls with the
  keyboard is not built.
- There is no description of the world around you beyond what the game
  itself prints: no reading of the terrain ahead, of drops or of nearby
  creatures. A guide that does this is planned.
- Only the system voice is available. A built in neural voice is planned
  as an option, for players who do not have one set up.
