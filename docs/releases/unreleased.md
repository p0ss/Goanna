# Goanna, unreleased

Changes on main since 0.16.0-alpha.

## Joining

- **Scan local network** on Join Game lists the Luanti servers on your own
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
- **Back returns to Join Game** after a refused or dropped join, with the
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
- **Start Game copies the game master command.** The World page has Copy
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
