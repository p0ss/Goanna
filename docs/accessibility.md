# Accessibility

What Goanna does for players who cannot see the screen, or see it poorly,
and what it does not do yet. It is early work, written without a blind
player testing it. Reports from players who use it are the most useful
thing anyone can send.

## Read aloud

Read aloud speaks what is on the screen through your system's voice. It
uses the same speech service as your screen reader, so the voice, its rate
and its language are the ones you have already chosen there.

Turn it on with `Ctrl+B` at any time, in the main menu, in the world or
with a form open (the same key as Minecraft's narrator). It says "Read
aloud on" or "Read aloud off", and remembers. It is also in Settings,
Audio, Read aloud. To start Goanna with it already on, launch it with
`GOANNA_READ_ALOUD=1` in the environment.

Settings, Audio, also has:

- Speech rate and Speech volume;
- Speech voice: the system default, which follows your screen reader or
  desktop, or one of the system's voices by name;
- Read chat, Read on screen text, Read what you point at, Read what you
  hold, Read health and Read menus as they open, each of which can be
  turned off. The control you move to is always read.

It reads:

- chat, as each line arrives;
- text the game puts on the screen, once it has stayed the same for half a
  second, so a line that changes all the time (coordinates) is not read;
- the infotext of whatever you are pointing at, such as a chest's owner;
- the item in your hand when it changes;
- your health when it changes;
- a form or menu when it opens: its text, its tabs and which one is
  selected, and how many buttons, checkboxes, text fields and inventory
  slots it has, and again when the game changes what it says;
- each screen of the main menu as it opens;
- the stack you pick up in a form, and when you put it down;
- the control under the mouse pointer or the keyboard focus: its words, or
  the label beside it, what kind of control it is and its state, for
  example "Buy bread, button", "Haggle, checkbox, checked", "Stone, 12" or
  "View distance, slider, 22". This interrupts whatever was being said,
  since only the newest one matters, and is read again when its state
  changes.

## Keyboard

Forms, Goanna's menus and the main menu can be worked without a mouse.
With nothing focused, `Tab` or an arrow key moves to the first control.
Then:

- `Tab` and `Shift+Tab` move through the controls in order, and the
  arrow keys move to the nearest control in that direction, which is the
  quickest way around a grid of inventory slots;
- `Enter` or `Space` presses a button, ticks a checkbox and opens a
  dropdown;
- on an inventory slot, `Enter` picks up or puts down, as a click does;
  `Shift+Enter` moves the stack to the other list, as a shift click does;
  `Ctrl+Enter` takes half or puts one down, as a right click does;
- on a row of tabs, `Left` and `Right` choose the tab beside;
- on text with links in it, such as the choices in a conversation, `Up`
  and `Down` choose a link and `Enter` follows it;
- `Escape` closes the form, and `I` closes the inventory.

When the game sends a form again, after a button or a tab, the focus stays
on the same control. Luanti's own client does not let the keyboard reach
inventory slots or links; Goanna adds that.

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

- The file picker that Locate Luanti opens, under Content, has not been
  tried with Read aloud or the keyboard.
- Moving and looking around the world is by keyboard and mouse as usual;
  there are no sound cues for edges, walls or water yet.
- There is no description of the world around you beyond what the game
  itself prints: no reading of the terrain ahead, of drops or of nearby
  creatures. A guide that does this is planned.
- Only the system voice is available. A built in neural voice is planned
  as an option, for players who do not have one set up.
