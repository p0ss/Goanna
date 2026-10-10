# Local multiplayer

Several people can play on one machine, each with their own view of the
screen and their own player on the server. This is splitscreen, and it is
experimental. Tests cover player ownership, input, menus,
shader parsing and real server connections. A rendered benchmark exercised
one, two, four and six players on an RTX 3090 with Godot 4.5.1 and a Luanti
5.17.0 Mineclonia server. Four players averaged 80 FPS in an inward-facing
circle and 34 FPS while streaming separate areas at 1080p on Low; six
averaged 51 and 22 FPS. These are specific workloads, not hardware guarantees.
See the [benchmark report](../perf/local-multiplayer-2026-09-27/report.md).
A real-controller play session and broader visual review remain outstanding.

## Setting it up

Choose **Local players** in the main menu, add the players, assign controls
and save. Then use **Start Game** or **Join Game** as usual. Player 1 uses
the name and password from the launch screen. Other players have separate
names and, when needed, server passwords. Names and control assignments are
remembered; passwords are held only in memory.

One player can own the keyboard and mouse. Each other player owns a
controller. An unassigned player displays a prompt to press Start on an
unused controller. Unplugging a controller releases held actions and returns
that slot to the prompt. Reconnecting does not assume the controller keeps
the same device ID.

Two players can split horizontally or vertically. More players use a grid.
The slot collection and layout have no four-player limit. A final incomplete
row leaves unused cells. Very small player rectangles still need a visual
and usability review, particularly for server forms.

Local play starts on its own Low graphics profile. The local setup screen
can select Medium, High or Ultra. Other settings come from the shared main
menu settings; in-game settings changes are deferred to that menu during
splitscreen. A single-player launch retains the existing game scene.

How it works inside, and how it is tested, is in
[local multiplayer architecture](../systems/local-multiplayer.md).
