# Contributing to Goanna

Goanna is pre-alpha. It connects to a real Luanti server, authenticates,
receives media and mapblocks, meshes them and lets you walk around. It does
not yet do most of what a client does. See `README.md` for an honest list of
what works and `PLAN.md` for where it is going.

At this stage the most useful contributions are small and concrete: build
reports from machines that are not the author's, bugs found against real
servers, and review of the transplant discipline described below. Large
features are better raised as an issue first, because the shape of the code
is still moving weekly.

## Relationship to Luanti

Goanna is an independent project. It is not affiliated with, endorsed by or
supported by the Luanti project or its developers.

Goanna is a client for the existing ecosystem, and takes that seriously:

- It connects to ordinary, unmodified Luanti servers, over the ordinary
  protocol.
- It asks for nothing a vanilla client does not ask for, and shows the
  player nothing the protocol did not send. Anything that would give a
  Goanna player an advantage over a vanilla player is out of scope
  permanently. "Alt client" has meant cheat client in this community, and
  Goanna is not going to blur that line.
- The vanilla client is the reference. Where Goanna and the vanilla client
  differ in behaviour, the vanilla client is right and Goanna has a bug.
- Bugs in the engine, the protocol or a game belong upstream, reported to
  the relevant project. Do not report them here, and do not carry local
  patches against Luanti. See `docs/transplanting.md`.

## Licensing and provenance

- Goanna is LGPL-2.1-or-later, matching Luanti's client code, which it
  carries. New files get an SPDX tag.
- godot-cpp is MIT and is used as a submodule, unmodified.
- Code copied from Luanti keeps its upstream copyright and SPDX header,
  gains a note saying what was changed, and is listed in the inventory in
  `docs/transplanting.md`. Read that document before copying anything.
- There is no CLA and no copyright assignment. Contributors keep their
  copyright.
- Sign off your commits under the Developer Certificate of Origin
  (`git commit -s`). It is a statement that you have the right to contribute
  the code, which for a project made largely of other people's code is worth
  being explicit about.

Do not paste code from a project whose licence is incompatible with
LGPL-2.1-or-later, and say in the pull request where non-trivial code came
from if it came from anywhere.

## Transplanting Luanti code

This is the core discipline of the project and it has its own document:
**`docs/transplanting.md`**. In short:

1. Compile it from the `luanti/` submodule if you possibly can.
2. If you cannot, copy it into `src/transplant/`, keep the upstream header,
   add a note saying what changed, change as little as the compiler allows,
   and add it to the inventory table.
3. Prefer giving Goanna a stand-in with the name upstream expects over
   editing upstream code.

Do not reformat or restyle transplanted code. Every cosmetic change is a
merge conflict at the next Luanti release.

## Code style

**Transplanted code** keeps Luanti's style, exactly. Tabs, brace placement,
naming, comment wording. It is upstream's file.

**Goanna's own code**, under `src/` outside `src/transplant/`:

- C++17, four space indentation, 100 column soft limit.
- `namespace goanna` for Goanna types. The one deliberate exception is
  `src/goanna_luanti_client.h`, which defines a global `Client` on purpose so
  that unmodified upstream headers resolve.
- `#pragma once`.
- Godot types via `godot_cpp/...` includes, Luanti types via their own
  headers. Do not add `using namespace godot;` to a header.
- A file starts with a comment saying what it is for. `src/goanna_map.h` and
  `src/goanna_textures.h` are the pattern.
- The session thread and Godot's main thread are separate. Anything crossing
  between them goes through the existing mutexes in `GoannaSession`. Do not
  touch Godot objects from the session thread.

**GDScript** in `project/` follows the official GDScript style guide: tabs,
`snake_case`, typed variables where practical.

## Text style

Australian English, no em dashes, plain factual tone. The full rules are in
**`docs/style.md`** and they apply to documentation, comments, commit
messages and pull request text alike.

Check before you push:

```sh
tools/check-style.sh
```

It is a lint, not a gate. If it flags a legitimate quotation, say so in the
pull request.

## Commits and pull requests

- Imperative subject line under 72 characters, no full stop. Blank line,
  then why.
- Sign off with `git commit -s`.
- Keep transplants in their own commits, separate from Goanna code that uses
  them, so a reviewer can diff a transplant against upstream cleanly.
- Say how you tested. "Connected to devtest 5.16.1, walked around for a
  minute, no console errors" is a real test report at this stage and is
  worth writing down. Say which server, which game and which Godot version.
- Screenshots are welcome and should say whether they are from the live
  client or from an offline study. Do not present one as the other.

## Building

See `docs/building.md`. If it does not work on your machine, that is a bug
in the document as much as in the code, and a report is genuinely useful
right now.
