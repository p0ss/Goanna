# Notes for AI agents working in this repository

Read `CONTRIBUTING.md` and `docs/transplanting.md` before changing anything.
This file is the short version of the rules that are easy to break by
accident.

## Text style, applies to everything you write

- **Australian English.** colour, behaviour, organise, recognise, centre,
  licence (noun) and license (verb), grey, catalogue, defence. The full
  table is in `docs/style.md`.
- **Never an em dash.** Not in prose, not in comments, not in commit
  messages, not in pull request text. Use a comma, a full stop, a colon or
  brackets. `--` standing in for one is the same offence.
- No smart quotes, no ellipsis character, no non breaking spaces.
- Sentence case headings. Wrap Markdown prose at 80 columns.
- Plain and factual. No marketing language. Say what does not work.
- Identifiers keep their real spelling: Godot's `Color`, `initialize`,
  `SPDX-License-Identifier`, the `LICENSE` file. Never "correct" a name.

Run `tools/check-style.sh` before you finish. It must exit clean.

## Never restyle transplanted code

`src/transplant/` holds Luanti's own source, copied because it could not be
compiled unmodified. It must stay as close to upstream as possible, because
every cosmetic difference becomes a merge conflict at the next Luanti
release.

Do not reformat it, do not rename anything in it, do not apply the text
style above to its comments, do not "fix" its spelling. It is excluded from
`tools/check-style.sh` for exactly this reason.

If you must change a transplanted file, change the minimum, and update both
its header note and the inventory table in `docs/transplanting.md` in the
same commit.

## Before copying anything from Luanti

1. Try compiling it from the `luanti/` submodule instead, by adding it to
   `cmake/luanti_core.cmake`. This is almost always the right answer.
2. If it will not compile, try giving Goanna a stand-in with the name
   upstream expects, rather than editing upstream code.
   `src/goanna_luanti_client.h` and `src/goanna_image_hooks.h` are the
   pattern.
3. Only then copy it, following `docs/transplanting.md` exactly: upstream
   header first, Goanna note below it, minimal change, inventory row.

Copied code without its upstream copyright header is a licence violation,
not a style problem. This has been got wrong here before. Check.

## Claims must be true of the committed code

`README.md` has a "Working" and a "Not working yet" list, and `PLAN.md` has
a dated log. Both are read by people deciding whether to trust this project.

Do not move an item from "not working" to "working" because the code exists,
only because it has been run against a real server and observed to work. Say
which server, which game and which Godot version when you record a result.

## Boundaries that are not negotiable

- Goanna connects to unmodified servers, over the ordinary protocol, and
  asks for nothing a vanilla client does not ask for. Never add a feature
  that gives a Goanna player information or reach a vanilla player lacks.
- Never fork or patch Luanti. `luanti/` is a pinned submodule.
- Never claim affiliation with or endorsement by the Luanti project.

## Practical notes

- The session runs on its own thread. Do not touch Godot objects from it.
  Anything crossing threads goes through the existing mutexes in
  `GoannaSession`.
- The build output must land in `project/bin/`, where the `.gdextension`
  expects it.
- Commit messages: imperative, under 72 characters, no full stop, then a
  body explaining why. Sign off with `git commit -s`.
