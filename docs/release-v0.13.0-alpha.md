# Goanna v0.13.0-alpha

You can say a chat line instead of typing it, textures built from several
images draw with each part's relief, and the AI game master can now
give named and enchanted items, put buildings in the world and have its
characters build them.

## Chat

- **Voice typing.** Hold T, speak and let go: the words appear in the chat
  box unsent, read aloud says them back if it is on, and Enter sends them.
  A quick tap of T opens chat to type, as before. Speech is turned into
  text on your own computer by Whisper; nothing is sent anywhere. The
  speech model (57 MB, or 181 MB for the larger one in Settings, Audio)
  downloads the first time you use it. The microphone is open only while
  T is held. It has been tried with synthesised speech, not yet with a
  real microphone.
- **Older processors.** Voice typing needs a processor with AVX2, which
  most PCs from 2013 on and the Steam Deck have. On one without it, holding
  T does nothing more than open chat.
- **Escape closes chat with one press.** It took two.

## Materials

- **Overlaid and combined textures get their own relief.** A texture made
  by laying images over each other, combining parts or turning one, such
  as Crimson and Warped nylium's sides or the chiseled bookshelf's front,
  now draws each part with that part's authored maps, in the right place
  and the right way round. Before, the whole face took the first image's
  maps, or none.
- **Not in this release: the newer Mineclonia maps.** Maps authored since
  0.12.0 (the blocks the first census missed, armour, boats, minecarts,
  held objects, and metal tools whose wooden handles were drawn as metal)
  are not yet in a published pack. Mineclonia's pack is still 1.3.1, and
  the newer maps will arrive later as a pack update, without a new
  Goanna download.

## Experimental

- **The game master knows what the world holds.** It searches a catalogue
  of the game's items, creatures, enchantments and structures instead of
  guessing names.
- **Rewards.** It can make an item, with a name, a few lines of
  description and, in Mineclonia, enchantments, and leave it near a player,
  in a chest, or have a character carry it over. A reward is never put in
  your inventory; you choose whether to pick it up. Rewards have their own
  budget, separate from fights.
- **Buildings.** It can put up a building it designs or one of the game's
  own, and order a character to build one node by node while you watch.
  It never builds on protected ground, where players have dug or built, or
  on anyone, and undoing a building puts the ground back. Buildings are off
  unless the server's operator turns them on
  (`goanna_director_structures`), and a world started from Goanna's menu
  has no way to turn them on yet. In Mineclonia, the temples, huts and
  shipwrecks come without their loot.
- **Easier for a model to use.** The game master's tools were reworked so
  a model calls them correctly more often: one tool per kind of order, the
  same words for the same things throughout, and a short brief when it
  connects. A model that only voices characters can be given just those
  tools. See `docs/director.md`.
