# Menu layout review, 1 November 2026

Captures of Goanna's own menu after it was laid out to
`docs/systems/interface-layout.md` ("Menus" and "Checking a screen"), with
the six checklist questions answered for each screen.

## How they were taken

`tests/menu_screens_render.tscn`, run through `tools/goanna-headless fixture
--size 1280x720 --software` (lavapipe, no GPU: `gpu-free` reported the card
busy) with the official Godot 4.5.1 build, against `tests/menu_fixture.gd`:
a made up Luanti folder with three games (Mineclonia, VoxeLibre, Minetest
Game), the Kindred Holdfast modpack, two mods, a texture pack, three worlds
played at known times, two recent servers and a saved public list of 24
made up servers. No Luanti server was started and no network was used.
Each screen is captured at 1280 by 720 and again with
`content_scale_factor = 2` (the `-200` files), which is how 200 percent text
lays out. `shots.json` lists each shot's accent buttons as the scene saw
them. The JPEGs were converted from the PNGs the scene saved.

The fixture's Luanti shows as "Luanti (GOANNA_SERVER_CMD)" on Content and
New world: that is the name of the development override the fixture uses,
not what a player with a real install sees ("Luanti 5.17.0 (Flatpak, ...)").
The shader pack folder shows a scratch path for the same reason.

## Screens and the checklist

The questions: (1) the screen's task in five words; (2) exactly one accent
button; (3) every list over about eight rows a table in the main area;
(4) anything unavailable shown in the normal style; (5) any id, node name or
Lua value visible; (6) every empty region says why and what to do.

| Screen | Files | 1 Task | 2 Accent | 3 Tables | 4 Unavailable | 5 Ids | 6 Empty |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Main | `main`, `main-no-last` | Get back into my world | Continue, or New world with no last world | No lists | Nothing unavailable | None | Not applicable |
| Your worlds | `worlds` | Pick a world and play | Play (footer), greyed with a tooltip until a row is chosen | Worlds are a table, newest first | Play greyed until a row is chosen | Mods show folder names (`kindred_holdfast`), as Luanti names them | Table says "No worlds yet" and to choose New world |
| A world's options | `world-options` | Change this world, then play | Play | Mods list is folded checkboxes | World generator greyed: fixed when the world was made, said under the title | Mod folder names, as above | Not applicable |
| New world, step 1 | `new-1-game` | Choose the new world's game | Next | Games are radio buttons (a handful) | Nothing | None besides the fixture's override name | Not applicable |
| New world, step 2 | `new-2-name` | Name the world | Next | No lists | Nothing | None | Seed field says Random |
| New world, step 3 | `new-3-options` | Set the world's options | Next | Mods folded | Terrain Diffusion "generate new" greyed, as before, labelled "(setup required)" | Mod folder names | Not applicable |
| New world, step 4 | `new-4-hosting` | Choose whether to host | Create | No lists | Hosting fields hidden until Open to LAN | None | Not applicable |
| Join a game | `join` | Join a nearby or recent game | Connect | Network and recent lists are short trees, not over eight rows | Nothing | Addresses and ports, which the player types | Network list says to press Scan; recent list says servers joined appear there |
| Public servers | `public-servers` | Find a public server | Use this server, greyed until a row is chosen | The list is a table with search and sortable headings | Use this server greyed | A game the menu has no title for shows the id the list sends (`nodecore`) | Table says fetching, unavailable or no servers, and what to do |
| Settings | `settings` | Set the common settings | None: it saves as each control changes | No lists | Nothing | None | "Not recorded yet" notes, as before |
| Advanced graphics | `settings-advanced` | Fine tune graphics and shaders | None, as Settings | Render switches folded by group | Nothing | The shader pack folder's path, by design | Not applicable |
| Content | `content` | See what is installed | Install a game | One table, filterable by kind | Nothing | Mod and texture pack folder names, as Luanti names them | Table says nothing is installed and to choose Install a game |
| Local players | `local-players` | Set up split screen players | Save and back | Short rows | Nothing | None | Not applicable |

## What falls short

- At 200 percent in a 1280 by 720 window, the regions scroll and only a
  few rows or controls show at once (two or three table rows on Public
  servers, the main screen's first four buttons). Every accent stays in the
  footer, inside the window (`tests/menu_layout.gd` checks this).
- In Your worlds at 1280 by 720 the Game column cuts "Kindred Holdfast
  (preview)" short; the full title is in the detail beside it.
- The (i) icons are 24 px, not 40: each also opens while its control has
  the focus, so a controller or keyboard never needs to land on it, but a
  touch has a smaller target there.
- Mod and texture pack names are their folder names, because that is all
  Luanti gives them; the public list's games are titled only when the game
  is installed or is one Goanna offers.
- Not tried with real input: a controller or keyboard walking the steps,
  the tables and the folds was exercised only through the structural tests
  and Godot's own focus order; Continue was not run against a real server,
  so starting the last world from it is the same path as Start used, not a
  new observed run. The new seed field writes `fixed_map_seed` for a world
  with no map yet; no world was created with it.
