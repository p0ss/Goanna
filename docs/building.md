# Building and running Goanna

Goanna is a GDExtension. You build a shared library from this repository,
drop it into the Godot project that lives in `project/`, and run that project
against a Luanti server.

Everything below has been done on Linux with GCC. Windows and macOS are not
yet supported, not because of anything fundamental, but because nobody has
tried. Reports are welcome.

Goanna is pre-alpha. Expect it to connect, show you terrain and let you walk
around, and expect it to do very little else. See the README for the honest
list.

## What you need

| | Version | Notes |
| --- | --- | --- |
| Godot | 4.5.x, standard build | The release binary. You do not need Godot's source and you do not rebuild the engine. |
| GPU | Vulkan capable, mid range discrete or better | Forward+ only. There is no Compatibility or Mobile fallback, on purpose. |
| CMake | 3.22 or newer | |
| Ninja or Make | any | Ninja is what the author uses. |
| C++ compiler | C++17 | GCC 12 or newer, or Clang 15 or newer. Verified on GCC 16. |
| Python | 3.4 or newer | Not optional. godot-cpp runs it to generate the bindings. |
| zlib | development headers | `find_package(ZLIB REQUIRED)`. |
| Zstandard | library and headers, static preferred | The build fails with `zstd not found` if it is missing. |
| git | any | The submodules are not optional. |
| A Luanti server | 5.16.x | See "Connecting to a server" below. |

Debian and Ubuntu:

```sh
sudo apt install build-essential cmake ninja-build git python3 zlib1g-dev libzstd-dev
```

Fedora:

```sh
sudo dnf install gcc-c++ cmake ninja-build git python3 zlib-devel libzstd-devel
```

Arch:

```sh
sudo pacman -S base-devel cmake ninja git python zlib zstd
```

## Building

```sh
git clone --recurse-submodules --shallow-submodules \
    https://github.com/p0ss/Goanna.git goanna
cd goanna
```

The submodules are large. Full history is around 170 MB;
`--shallow-submodules` cuts that to about 55 MB, which is plenty to build
from. If you already cloned without them,
`git submodule update --init --depth 1` does the same job.

`luanti` is pinned to release 5.16.1 and `godot-cpp` tracks the 4.5 branch.
Both are used unmodified. Goanna does not patch either one, and if it ever
needs to, that is a bug in Goanna. See `docs/transplanting.md`.

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build
```

Pass the build type explicitly. `CMakeLists.txt` sets no default, so
omitting it gives you a build with no optimisation at all, which will make
the meshing and collision code look far slower than it is.

The first build compiles godot-cpp as well as Goanna, and takes a while. On
an eight core machine, budget five to fifteen minutes, and expect the
`build/` tree to reach about 1.4 GB.

The output goes straight into the Godot project, which is where the
`.gdextension` file expects it:

```
project/bin/libgoanna.linux.template_debug.x86_64.so
```

If you would rather build with Make, drop `-G Ninja`.

### If zstd is not found

`cmake/luanti_core.cmake` looks for a static `libzstd.a` first and falls back
to whatever `zstd` the linker can find. If your zstd is somewhere unusual,
point CMake at it:

```sh
cmake -S . -B build -G Ninja \
  -DZSTD_STATIC_LIB=/path/to/libzstd.a \
  -DZSTD_INCLUDE_DIR=/path/to/include
```

or, if both live under one prefix, `-DZSTD_ROOT=/that/prefix`.

### A note on the build target

`CMakeLists.txt` forces godot-cpp's `template_debug` target, and hardcodes
the library name to match. That is a spike-stage shortcut, and it has two
consequences worth knowing:

- `-DGODOTCPP_TARGET=template_release` is silently ignored, because the
  variable is set with `FORCE`.
- An exported release build of the Godot project will not find its library,
  because `project/goanna.gdextension` names a `template_release` file that
  nothing produces. Running from the editor, or with the Godot binary
  directly as below, is the supported path for now.

`CMAKE_BUILD_TYPE` and `GODOTCPP_TARGET` are separate things. The first
controls optimisation of Goanna's own code, the second controls which
godot-cpp variant is linked. Setting `RelWithDebInfo` above does not turn
off Godot's debug checks.

### One time: let Godot register the extension

A freshly built library is not enough. Godot only writes
`project/.godot/extension_list.cfg`, which is what actually loads a
GDExtension at run time, during an **editor** filesystem scan. That
directory is gitignored, so a fresh clone never has one, and a plain run
will fail with `Could not find type "GoannaClient"` and then hang.

Do this once, after the first build:

```sh
/path/to/Godot_v4.5.1-stable_linux.x86_64 --headless --editor --quit --path project
```

Opening `project/` in the graphical editor once has the same effect.

**Known issue:** with the extension loaded, the editor segfaults on
shutdown (signal 11). The `extension_list.cfg` file is written before the
crash, so the step above still does its job and you can carry on. A plain
run, without `--editor`, exits cleanly. The cause is most likely static
destructor ordering in `luanti_core` when Godot unloads the library, and it
is not yet fixed.

**Check your diff afterwards.** Opening the project in the editor, including
with `--headless --import`, rewrites `project/project.godot`. It adds a
boilerplate header, and it silently drops any setting whose value happens to
match Godot's own default. That has already cost this repository its
explicit `[rendering] renderer/rendering_method="forward_plus"` line once.
Forward+ is the default, so nothing broke, but that line is the one place
the project asserts in machine readable form the thing the README spends a
paragraph on. Run `git diff project/project.godot` after any editor pass and
revert it unless you meant it.

## Windows

Untested. The build system knows about Windows and there is a CI job for it,
but no Windows binary has been produced on real hardware yet, and nobody has
played it. If you try this, a report either way is genuinely useful.

The route is MSVC with vcpkg, not MinGW. Upstream Luanti abandoned GCC MinGW
because thread-local storage is broken there, and Luanti's core leans on TLS,
so that is not a road worth walking again.

You need Visual Studio, 2022 or newer, with the C++ workload, CMake, Git and
Python, and [vcpkg](https://vcpkg.io/) for zlib and zstd, which a stock
Windows machine does not have. The manifest at `vcpkg.json` lists them.

```
git clone --recurse-submodules --shallow-submodules https://github.com/p0ss/Goanna.git goanna
cd goanna
cmake -S . -B build -A x64 ^
  -DCMAKE_TOOLCHAIN_FILE=C:/path/to/vcpkg/scripts/buildsystems/vcpkg.cmake ^
  -DVCPKG_TARGET_TRIPLET=x64-windows
cmake --build build --config RelWithDebInfo
```

No `-G` on purpose. CMake picks the newest Visual Studio it finds when the
generator is left unspecified, which is one less thing to go stale as new
Visual Studio versions ship. Pass `-G "Visual Studio 18 2026"`, or whatever
generator name matches your install, if you need a specific version.

Keep the `x64-windows` triplet. It uses the dynamic CRT, which is what
godot-cpp defaults to; a static triplet gives a CRT mismatch at link time,
and the error message will not tell you that is what happened.

The library lands at
`project/bin/libgoanna.windows.template_debug.x86_64.dll`, which is the name
`project/goanna.gdextension` expects.

Expect the first attempts to fail inside `src/transplant/client/*.cpp` rather
than in the CMake plumbing. MSVC is stricter than GCC about two-phase name
lookup in templates, and that code is Luanti's, carried across unchanged. If
it gets unpleasant, `-T ClangCL` is a reasonable escape hatch, and upstream
Luanti supports that toolset too.

## Running

Goanna talks to a Luanti server, always. It has no built in server and is
not going to grow one, because the whole point is that it is a client for
the ordinary ecosystem.

"Start a local game" in the menu is that principle applied rather than an
exception to it. Goanna finds Luanti on your machine, launches an ordinary
unmodified server on localhost, and joins it over the ordinary protocol,
exactly as if you had started the server yourself in another terminal. It
looks for `luantiserver` or `minetestserver` on `PATH`, then `luanti` or
`minetest --server`, then the `org.luanti.luanti` flatpak. Set
`GOANNA_SERVER_CMD` to override the command. It enumerates the games you
have installed, creates the world, waits for the port to open, and connects.
Quitting or disconnecting shuts that server down.

So there is no singleplayer code path, no embedded engine and no private
protocol. There is a server, it is Luanti's, and Goanna just started it for
you.

### Running a server yourself

Any ordinary Luanti 5.16.x server works, and you will want your own for
anything beyond a quick look. Goanna connects over the ordinary protocol and
asks for nothing special. The quickest option is Luanti's own Development
Test game, which is small, ugly and exercises the basics:

```sh
luantiserver --gameid devtest --worldname goanna_test --port 30000
```

Depending on how Luanti was packaged, the server may instead be the main
binary in server mode:

```sh
luanti --server --gameid devtest --worldname goanna_test --port 30000
```

If you installed Luanti as a flatpak, the server is inside it:

```sh
flatpak run --command=luantiserver org.luanti.luanti \
  --gameid devtest --worldname goanna_test --port 30000
```

Note that the flatpak has no access to your home directory, so its worlds
live under `~/.var/app/org.luanti.luanti/.minetest/worlds/`.

A server running a full game such as minetest_game or Mineclonia will also
accept the connection, and Goanna will show you something, but expect
missing and wrong geometry. Only the simplest drawtypes are meshed today.

### Point Goanna at it

Run the project and a menu (`project/menu.gd`) asks for the server address,
port, player name and password. It remembers the address, port and name in
Godot's user data directory (`user://goanna.cfg`, which on Linux is
`~/.local/share/godot/app_userdata/Goanna/goanna.cfg`) and never the
password.

The menu steps aside when the details are already in the environment, which
is what scripts and the automated runs below use. Set `GOANNA_HOST` or
`GOANNA_NAME` and Goanna connects straight away; set `GOANNA_MENU=1` to get
the menu anyway, prefilled from whatever else is set. The variables are read
in `project/main.gd`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `GOANNA_HOST` | `127.0.0.1` | Server address |
| `GOANNA_PORT` | `30000` | Server port |
| `GOANNA_NAME` | `goanna` | Player name |
| `GOANNA_PASS` | empty | Password. On a server that allows registration, the first connection registers this name with this password. |

Two warnings about `GOANNA_PASS`. Leaving it empty registers the name with
an **empty password**, which is fine for a local devtest world and not fine
for anything else. And putting it on the command line writes it to your
shell history and exposes it in `/proc/<pid>/environ`. Export it, or use a
password you do not mind leaking, for anything public.

Run the project with the Godot binary, skipping the menu:

```sh
GOANNA_HOST=127.0.0.1 GOANNA_PORT=30000 \
GOANNA_NAME=goanna GOANNA_PASS=hunter2 \
/path/to/Godot_v4.5.1-stable_linux.x86_64 --path project
```

Or open `project/` in the Godot editor and press F5, having set the
variables in your shell before launching the editor.

Note that `project/` is not self-contained. `GoannaClient` resolves Luanti's
share path to `res://../luanti` at run time, so it reads the base texture
pack out of the submodule checkout. The Godot project cannot be moved or
copied away from the repository, and an export will not find those textures.
That is a known gap, not a design.

Progress is printed to the console once a second: connection state, media
files received, mapblocks received and meshed, materials built, and the
player's position and ground state. If something is wrong, that line is the
first place to look.

### Controls

| Key | Action |
| --- | --- |
| W A S D | Walk |
| Mouse | Look |
| Left mouse | Dig the pointed node, held down |
| Right mouse | Place the wielded item |
| 1 to 8 | Choose the wielded item |
| Mouse wheel | Cycle the wielded item |
| I | Open and close the inventory |
| T | Open chat |
| / | Open chat with a command already started |
| Escape | Pause menu: continue, disconnect to the menu, or quit |
| Space | Jump, or ascend while flying |
| Shift | Sneak, or descend while flying |
| E | Aux1, which is fast movement if the server grants it |
| F | Toggle between walking and a free flying camera |
| Ctrl | Move faster, while flying |

Walking uses Luanti's own `LocalPlayer` and collision code, so speeds,
gravity, step height and sneak behaviour are the server's, not an
approximation.

Flying is a debug camera. It is not the game's `fly` privilege, it does not
ask the server for anything, and it moves the player position the server
sees, exactly as walking does.

## Automated runs

`project/main.gd` has a few environment variables used for smoke tests and
for producing the screenshots in `docs/`. They are development aids, not
features.

| Variable | Effect |
| --- | --- |
| `GOANNA_CONTROL=<port>` | Open a loopback command channel on that port (`1` means 30800), so the running client can be teleported, posed, questioned and photographed instead of relaunched for each question. `docs/control-channel.md` has the commands and the rule about not reporting a live tweak as a result. |
| `GOANNA_SMOKE=<seconds>` | Connect, run for that many seconds, disconnect and quit. Useful in CI or after a change to the session code. |
| `GOANNA_SHOT=<directory>` | Fly to three fixed viewpoints, save a PNG at each, then quit. |
| `GOANNA_WALKTEST=1` | Drive the movement controls from a script rather than the keyboard. With `GOANNA_SHOT`, saves two frames mid walk. |
| `GOANNA_VIEW="name:x,y,z:pitch,yaw;..."` | With `GOANNA_SHOT`, replaces the three fixed viewpoints. Positions are relative to the spawn eye position, or absolute with a leading `@`. |
| `GOANNA_SUN`, `GOANNA_WHITE`, `GOANNA_EXPOSURE`, `GOANNA_SKY_FILL`, `GOANNA_SDFGI`, `GOANNA_SSAO` | Seed the Lighting tab's values: sun energy, ACES white point, base exposure, sky fill strength, bounced light, corner shading. `project/lighting_chart.tscn` reads the same names, so a value judged there transfers. |
| `GOANNA_TOD=<0..1>` | Override the time of day, and drop any day night ratio the server is overriding (Mineclonia does in weather), so the frame is that hour. |
| `GOANNA_TEXTURE_MAP=<csv>` | A game_texture,pack_path CSV (`project/texture_maps/`), the same as the settings entry: lets a Minecraft resource pack dress the game, and gives the classifier its block column. |
| `GOANNA_DEBUG_PBR=1` | Print the classifier's counts and, per array texture, how many layers are authored, classed or inferred, and how many are left neutral. |
| `GOANNA_PERF=1` | Print one telemetry line a second: frame time, mesh and upload cost, draw calls, objects, video memory, and the far tier counts. |
| `GOANNA_LOD=<blocks>` | Draw blocks beyond this many mapblocks as coarse tiers (`docs/far-rendering.md`); the same as the detail distance slider. `GOANNA_LOD_CELL=<nodes>` sets the first tier's cell size, a power of two from 2 to 16. |
| `GOANNA_STORE=<dir>`, `GOANNA_NO_STORE=1` | Relocate or turn off the local block store (`docs/far-rendering.md` rung 5), which otherwise lives under `user://goanna_store`, one directory per server. `GOANNA_STORE_CAP_MB` sets its cap (512). `GOANNA_FAR_DISTANCE=<nodes>` caps how far stored blocks are drawn when the server grants far rendering. |
| `GOANNA_DEBUG_LOD=1` | Print every far tier region build: tier, cell, members, faces, quads and the surfaces it produced. |
| `GOANNA_SHADERPACK=<directory>` | Load an Iris or OptiFine shader pack (unpacked) and run its `deferred`, `composite` and `final` programs as a compositor effect. Only the screen space chain; see `docs/iris-compat.md`. |
| `GOANNA_SHADERPACK_RAW=1` | With a pack: hand it Godot's linear HDR colour and keep Godot's tonemap, instead of the Minecraft style gamma space bridge. |
| `GOANNA_SHADERPACK_DUMP=<directory>` | With a pack: write each program's translated Vulkan GLSL there, for reading compile errors. |
| `GOANNA_VISUAL_TEST=lighting_walk` | With `GOANNA_SHOT`, request a named deterministic fixture, capture its fixed camera path and write the capture metadata. Requires `goanna_visual_test_mod` in a dedicated singlenode world. |
| `GOANNA_MENU_SHOT=<file.png>` | Render the connection menu once, save it, quit. |
| `GOANNA_UI_SHOT=<directory>` | Save the HUD, inventory, chat and pause menu at fixed times. |
| `GOANNA_UI_TEST=move` | Open the inventory and move the stack in main slot 0 to slot 10, then split it to slot 11, printing the list each time. Exercises inventory_action through the UI. |
| `GOANNA_MENU_TEST="host:port:name:pass"` | Fill the menu and press Connect, to exercise the menu to game hand-over. Combine with `GOANNA_MENU=1` if a skip variable such as `GOANNA_SMOKE` is also set. |

A minimal check that everything still works, end to end:

```sh
GOANNA_SMOKE=20 /path/to/godot --path project
```

### Deterministic visual fixtures

Do not use a survival spawn or the material gallery for renderer comparisons.
Terrain, time, weather, nearby lights and previously built tests all change the
result, so a repeat run is not the same experiment.

`goanna_visual_test_mod/` is a worldmod for a fresh test world using the
`singlenode` mapgen. Copy or link it to the world's `worldmods/` directory and
enable `goanna_visual_test` in `world.mt`. The mod refuses to build in any
other mapgen, so an accidental install cannot clear part of a survival world.

Run the lighting path against that server with:

```sh
GOANNA_HOST=127.0.0.1 GOANNA_NAME=goanna \
GOANNA_SHOT=/tmp/goanna-lighting \
GOANNA_VISUAL_TEST=lighting_walk \
/path/to/godot --path project
```

The fixture fixes midday, removes clouds, disables the camera headlight and
captures 17 positions half a node apart with one pitch and yaw. The output
directory also receives `lighting_walk.json`, recording the positions and
lighting settings used. Analyse adjacent changes with:

```sh
tools/shotcheck.py --walk-series \
  /tmp/goanna-lighting/lighting_walk_*.png
```

Pass `--max-step N` once a measured acceptance threshold has been chosen. The
checker reports the result without inventing a pass threshold by default.

The `ao`, `materials` and `ice` fixture sites are 1024 nodes from one another
and from `lighting_walk`. Their automated captures should be added at those
sites rather than extending one shared gallery.

The formspec renderer has a separate headless conformance suite. It checks
the local Luanti parser registry as well as Godot-side layout and interaction
fixtures:

```sh
tools/test-formspec.sh
```

See [formspec conformance](formspec-conformance.md) for classifications,
reference screenshots and instructions for extending the suite.

## Troubleshooting

**`zstd not found` during CMake configure.** Install the Zstandard
development package, or pass `-DZSTD_STATIC_LIB` and `-DZSTD_INCLUDE_DIR` as
above.

**CMake cannot find Python.** godot-cpp requires Python 3.4 or newer to
generate its bindings. It is in the dependency list above and is easy to
miss on a minimal container image.

**Godot starts, reports `Could not find type "GoannaClient"`, then hangs.**
Almost always this is the missing `project/.godot/extension_list.cfg`, not a
missing library. Run the one time editor step above. If the file exists,
check that `project/bin/libgoanna.linux.template_debug.x86_64.so` is there
and that Godot is 4.5 or newer.

**The editor crashes when you close it.** Known, see the note above. It
happens on extension unload and does not affect a plain run.

**Undefined symbol errors when loading the extension.** The link uses
`--no-undefined`, so this should be caught at build time rather than load
time. If it happens anyway, say so in an issue with the full message and
your compiler version.

**It connects, then sits at "media".** The server is still sending media
files. Devtest sends around 440 and takes about a second on a local server.
A large game over the internet takes considerably longer, and the count in
the console line tells you whether it is progressing.

**The server rejects the password.** Goanna registers a new name on first
connect if the server allows it, and uses SRP to log in afterwards. If the
name already exists with a different password, pick another `GOANNA_NAME`.

**A surface is blank, white or missing.** Goanna supports Luanti's drawtypes
and array-texture grouping, but an unusual texture modifier, material or model
can still expose a conversion bug. Run with `GOANNA_DEBUG_CONTENT=1` and report
the node name, game and relevant log lines.
