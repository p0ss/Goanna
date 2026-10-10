# Contributing to Goanna

Goanna is pre-alpha. It connects to a real Luanti server, authenticates,
receives media and mapblocks, meshes them and lets you walk around. It does
not yet do most of what a client does. See `README.md` for an honest list of
what works and `docs/design/roadmap.md` for where it is going.

At this stage the most useful contributions are small and concrete: build
reports from machines that are not the author's, bugs found against real
servers, and review of the transplant discipline described below. Large
features are better raised as an issue first, because the shape of the code
is still moving weekly.

Coding agents start from `AGENTS.md`, which lists the hard rules and links
back to the sections below.

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
  patches against Luanti. See `docs/develop/transplanting.md`.

## Licensing and provenance

- Goanna is LGPL-2.1-or-later, matching Luanti's client code, which it
  carries. New files get an SPDX tag. The one exception is texture packs:
  maps under `pbr_packs/` are derived from game media and carry its licence,
  noted per file in the pack's `ATTRIBUTION.md`.
- godot-cpp is MIT and is used as a submodule, unmodified.
- Code copied from Luanti keeps its upstream copyright and SPDX header,
  gains a note saying what was changed, and is listed in the inventory in
  `docs/develop/transplanting.md`. Read that document before copying anything.
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
**`docs/develop/transplanting.md`**. In short:

1. Compile it from the `luanti/` submodule if you possibly can, by adding
   it to `cmake/luanti_core.cmake`.
2. If it will not compile, give Goanna a stand-in with the name upstream
   expects rather than editing upstream code. `src/goanna_luanti_client.h`
   and `src/goanna_image_hooks.h` are the pattern.
3. Only then copy it into `src/transplant/`: keep the upstream header
   first, add a note below it saying what changed, change as little as the
   compiler allows, and add it to the inventory table.

Copied code without its upstream copyright header is a licence violation,
not a style problem.

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
**`docs/develop/style.md`** and they apply to documentation, comments, commit
messages and pull request text alike.

Run the check before every commit:

```sh
tools/check-style.sh
```

It is a gate: commit only when it exits clean. If it flags a legitimate
quotation, reword around it, or add the exception to the script in a
commit of its own that says why.

## Commits and pull requests

This section is the one statement of the commit format; `AGENTS.md` and
`docs/develop/style.md` point here.

- Subject line in the imperative mood, under 72 characters, no full stop.
  `Add media transfer`, not `Added media transfer.` or `adding media`.
- Blank line, then a body that explains why, wrapped at 72 columns. Name
  the spike or stage where relevant, for example `E0b stage 3`.
- The text style applies: Australian spelling, no em dashes.
- Sign off with `git commit -s`.
- `tools/git-hooks/commit-msg` checks all of the above. Run
  `tools/install-git-hooks.sh` once per checkout to turn it on.
- Keep transplants in their own commits, separate from Goanna code that uses
  them, so a reviewer can diff a transplant against upstream cleanly.
- Screenshots are welcome and should say whether they are from the live
  client or from an offline study. Do not present one as the other.

### Claims and test reports

`README.md` describes what Goanna draws and does, and says what is untested;
`docs/play/index.md` lists current limitations;
`docs/history/development-log.md` keeps a dated log of what was done and what
was verified. People read all three to decide whether to trust the project, so
every claim in them must be true of the committed code.

- Describe a feature as working only after it has been run against a real
  server and observed to work, not because the code exists. A study, a
  fixture or a unit test is evidence of its own kind; say which it was.
- Say which server, which game and which Godot version, for example
  "Connected to devtest 5.16.1, walked around for a minute, no console
  errors, Godot 4.5.1". At this stage that is a real test report.
- Say what was not tried. Synthetic input is not a controller; lavapipe is
  not the GPU.

## Working in a shared checkout

Several people and agents may work in one checkout at once, all on main.
The working tree, the index and the branch tip are all shared, and each has
already put someone's unfinished work into a commit whose message said
nothing about it.

- **The index is shared.** Another session can `git add` between two of
  your commands, and your next plain `git commit` takes its staged work.
  Immediately before every commit, read `git diff --cached --name-only` and
  `git diff --cached`, and unstage anything that is not yours with
  `git restore --staged`.
- **Stage only your own hunks.** A pathspec commit (`git commit FILE`)
  and `git add FILE` both take the whole current state of the file,
  including hunks someone else has not finished. Compare `git diff --stat
  FILE` with what you changed; if another session also edited the file,
  stage your hunks alone, with `git add -p` or, where interactive commands
  are not available, by writing your hunks to a patch and running
  `git apply --cached`. Never `git add -A`, `git commit -a` or a directory
  pathspec.
- **Do not stash in the shared tree.** `git stash`, with or without
  `--keep-index`, takes every unstaged change, other sessions' included,
  and the tree changes under them.
- **The tip moves.** Read `git log --oneline -3` before and after you
  commit. A file that `git status` shows as clean may mean somebody else
  committed your change, not that you never made it.
- **The working tree ships.** A build links whatever is in the tree,
  including other sessions' uncommitted work. For anything measured, record
  the commit and whether the tree was dirty. After staging by hunk, build
  the commit itself (in a worktree) to prove you got every hunk.
- If you sweep up someone else's work and nothing has been pushed, tell
  the owner before rewriting any history: they may prefer to keep it with
  a line in the message saying so.

## Landing work

- Finished work lands on main, in a linear history: rebase it onto main
  and fast-forward. No merge commits, and no review branches left lying
  around; the owner reviews what is on main.
- Do not push. Pushing is the owner's.
- A `git worktree` of your own is a good way to keep unfinished work out
  of the shared tree. When the work is done, check it touches none of the
  files dirty in the shared checkout, rebase it onto main, fast-forward
  main to it, then remove the worktree and its branch. Worktrees are full
  checkouts, and once a client is built in one it holds gigabytes.

## Documentation

The documentation is a site built from `docs/` by Material for MkDocs and
published to GitHub Pages; `mkdocs.yml` holds its navigation. Put a page
in the section for its reader (play, host, develop, agents) or its kind
(systems for how something works now, design for plans, history for dated
logs and investigations), and add it to the `nav` in `mkdocs.yml`. A dated
entry goes in a log under `docs/history/`, not in a systems page. Build it
with `mkdocs build --strict` before committing; `tools/README.md`, "docs",
says how.

## Building

See `docs/develop/building.md`. If it does not work on your machine, that is a
bug in the document as much as in the code, and a report is genuinely useful
right now.
