# Goanna, unreleased

Changes on main since 0.16.0-alpha.

## Menu

- **Continue is the main screen's first button**, named with the world you
  played last and its game, and starts it again with the same settings.
  With no world yet it is New world. Everything else on the main screen is
  quiet, and Content, Local players, About and Quit sit in a quieter row.
- **Your worlds** is a table of world, game and last played, newest first,
  with the chosen world's game, mods, play mode and hosting beside it and
  Play in the footer. Change options and Delete world (which asks first)
  are there too. Start Game is gone; its options are on these screens.
- **New world** takes four steps (game, name and seed, options, hosting),
  each with a default, so Next, Next, Next and Create makes a world.
  Hosting is off unless you tick Open to LAN. The seed is new: empty means
  a new map each time.
- **Join a game** puts this network and the servers you joined before
  first. The public list is a searchable table of server, game, players
  and ping behind Browse public servers, and a typed address and the
  materials and shader choices are folded away.
- **Settings** keeps the graphics profile, the main sliders and switches,
  and accessibility on its front page. The shader pack and every render
  switch are under Advanced graphics; nothing was removed.
- **Content** is one table of games, mods and texture packs, with the
  worlds using each, filterable by kind.

## Joining

- **Scan local network** on Join a game lists the Luanti servers on your own
  network. Luanti servers do not announce themselves on a LAN, so Goanna
  asks each address on this computer's private /24 networks, ports 30000 to
  30005, with the packet a client opens a connection with, and closes each
  answer at once. It runs only when pressed. Pick a server to fill in the
  address.
- **A dropped game now says so.** When a server crashes, kicks you or shuts
  down mid game, the world is covered by "Disconnected from the server"
  with the server's message and a Back to the menu button. Before, the
  world stayed up with nobody answering: blocks broke locally and nothing
  else moved.
- **Back returns to Join a game** after a refused or dropped join, with the
  reason shown, and the password field focused after a wrong password.
  It used to open the main menu.

Not changed: a wrong password still costs the world's loading time before
the server's answer arrives, because the password is checked only once
the game scene has started connecting.

## Director

- **The director can move a stuck player**, when the operator sets
  `goanna_director_move_players = true`: to a point (landing on clear
  ground at or within two nodes of it) or beside another player, with the
  reason told to the player, at most once every five seconds, and never a
  player who opted out or to one. Undo moves them back. The join notice
  says when this is on. MCP tool: `director_move_player`.
- **The menu copies the game master command.** New world's Options step
  and a world's Change options have Copy
  Claude Code command and Copy MCP settings, filled in for the chosen
  world. Goanna still runs no game master itself: players are told a
  language model is acting as game master, so one runs only while a model
  app has started it.

## Hosting

- **A local server ends with its Goanna.** When Goanna quits, crashes or
  is killed, the Luanti server it started is sent SIGTERM within about a
  second, saves and shuts down, freeing its port; anything left after 30
  seconds is killed. Run on Linux with the Flathub Luanti and the bundled
  server; macOS takes the same path but has not been tried. On Windows a
  server whose Goanna crashed or was killed still keeps running.
