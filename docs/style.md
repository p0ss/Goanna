# Goanna text style

These rules apply to everything written in this repository: README, plans,
documentation, code comments, commit messages, issue and pull request text,
and any user facing strings.

They exist so the project reads as one voice, and so that a reviewer can tell
at a glance whether a change follows house style. They are conventions, not
matters of correctness. Nobody should be blocked over a spelling.

## 1. Australian English

Australian spelling throughout, per the Macquarie Dictionary. The usual
cases:

| Use | Not |
| --- | --- |
| colour, behaviour, neighbour | color, behavior, neighbor |
| centre, metre, litre, fibre | center, meter, liter, fiber |
| organise, recognise, analyse, optimise, initialise | organize, recognize, analyze, optimize, initialize |
| grey | gray |
| catalogue, dialogue, analogue | catalog, dialog, analog |
| defence, offence, pretence | defense, offense, pretense |
| travelling, cancelled, modelled, labelled | traveling, canceled, modeled, labeled |
| licence (noun), license (verb) | license (noun) |
| practice (noun), practise (verb) | practice (verb) |
| enrol, fulfil, instalment | enroll, fulfill, installment |

`program` is correct in the computing sense. `-yse` beats `-yze`
(analyse, paralyse). `judgment` is preferred over `judgement` in the legal
sense only, which will not come up here.

### Exceptions that are not negotiable

Never "correct" the spelling of a thing that has a name. Identifiers, file
names, API surfaces and quoted text keep whatever spelling they were born
with:

- Godot and Luanti API names: `Color`, `sky_top_color`, `video::SColor`,
  `initialize`, `MeshInstance3D`.
- The root `LICENSE` file, and the SPDX tag `SPDX-License-Identifier`. These
  are machine read, and the American spelling is part of the format.
- Verbatim quotes from upstream code, docs, logs or people.
- Settings keys and protocol field names.

So: "the licence is LGPL-2.1-or-later, declared in `LICENSE`" is correct and
deliberate. Prose gets Australian spelling; identifiers get their real name.

## 2. No em dashes

Do not use `—` (em dash). Not in prose, not in comments, not in commit
messages. This is a hard rule and it is easy to check.

Rewrite instead. In order of preference:

- A comma, when the aside is mild.
  `Goanna carries Luanti's client logic, networking and world handling
  included, into Godot.`
- A full stop, when the aside is really a second sentence. This is usually
  the best fix and it shortens the writing.
  `Forward+ only. Vulkan is required.`
- A colon, when what follows explains or lists.
  `The scar tissue is exactly two directories: src/client and src/gui.`
- Brackets, when the aside is genuinely parenthetical.
  `The header only math types (vector3d, aabbox3d, matrix4) are kept.`

En dashes (`–`) are allowed only in numeric ranges, and even there
`5 to 9` reads better than `5–9`. Hyphens are ordinary punctuation and are
unaffected.

Two hyphens (`--`) as a stand in for an em dash is also out. It is the same
construction wearing a hat.

## 3. Punctuation and characters

- Straight quotes and apostrophes: `'` and `"`. No smart quotes.
- No ellipsis character `…`. Write three full stops if you need one, or
  rewrite.
- No non breaking spaces, no zero width characters.
- Single space after a full stop.
- Serial (Oxford) comma when it removes ambiguity, otherwise optional.
- Australian date format in prose (16 August 2026) and ISO dates
  (2026-08-16) in anything a machine may read: changelogs, commit messages,
  plan entries.
- Metric units. Seconds, metres, MiB.

## 4. Headings and structure

- Sentence case for headings. `Building from source`, not
  `Building From Source`.
- No trailing full stop on headings.
- Wrap prose at 80 columns in Markdown. Do not wrap tables, URLs or code.
- One blank line between blocks. No trailing whitespace.

## 5. Tone

Goanna is a client for somebody else's ecosystem, and its documentation is
read by people who maintain that ecosystem. Write accordingly.

- Plain and factual. State what the code does, in the present tense.
- Say what does not work. A README that lists the gaps is trusted; one that
  lists only the wins is not. Every claim about a feature should be true of
  the committed code, today.
- Never imply endorsement by, or affiliation with, the Luanti project.
- No marketing superlatives: revolutionary, blazing fast, next generation,
  seamless, game changing. If a number is worth quoting, quote the number
  and say how it was measured.
- Credit upstream by name. Luanti's client logic is the substance of this
  project and the documentation should read that way.
- Avoid "simply", "just", "obviously", "of course". They only ever tell a
  stuck reader that the problem is them.
- Prefer the active voice and short sentences.

## 6. Naming and terminology

Use the ecosystem's own vocabulary. Getting this wrong is the fastest way to
look like an outsider.

| Term | Meaning |
| --- | --- |
| Luanti | The engine and project. Use this name, not Minetest. |
| Minetest | Only in historical context, for example a pre 2024 release or an old URL. |
| node | One cube of world content. Not "block", not "voxel". In player facing text, gloss it once on first use ("the cubes a world is made of, which Luanti calls nodes") and then use "node" throughout. Do not switch to "block": it collides with "mapblock". |
| mapblock | A 16x16x16 volume of nodes, the unit the server sends. |
| game | A Luanti game, for example Mineclonia, VoxeLibre, minetest_game. |
| mod | A Luanti mod. Not "plugin", not "addon". |
| formspec | Luanti's UI description format. |
| client side modding, SSCSM | Server sent client side modding. Spell it out on first use. |
| drawtype | A node's render style, for example `NDT_NORMAL`, `NDT_LIQUID`. |
| Goanna | This project. Capital G. Not "the Goanna client" in running prose, just "Goanna". |

Godot terms keep Godot's capitalisation: `Node3D`, `MeshInstance3D`,
`RenderingServer`, Forward+, GDExtension, GDScript.

## 7. Code comments

Comments follow the same rules. Additionally:

- Every file transplanted from Luanti keeps its original SPDX and copyright
  block **first**, and adds a Goanna note immediately below it saying what
  was changed, why, and against which upstream version. Upstream's own
  comments are never restyled: `src/transplant/` is exempt from every rule
  in this document, including this one. See `docs/transplanting.md`.
- Comment the intent, not the syntax. If the reason a line exists is "the
  protocol requires it", say so, and name the packet.
- `TODO` is fine. `TODO(name)` is better. `XXX` and `HACK` should say what
  the hack is working around.

## 8. Commit messages

- Subject line in the imperative mood, under 72 characters, no full stop.
  `Add media transfer`, not `Added media transfer.` or `adding media`.
- Blank line, then a body that explains why, wrapped at 72 columns.
- Reference the spike or stage where relevant, for example `E0b stage 3`.
- Same style rules. Australian spelling, no em dashes.

## 9. Checking

A repository check lives at `tools/check-style.sh`. It greps for em dashes,
smart quotes and the common American spellings, skipping the submodules and
anything that has to keep its original spelling. Run it before pushing:

```sh
tools/check-style.sh
```

It is a lint, not a gate. It will occasionally flag a legitimate quotation.
Fix the prose or leave it, and say which in the pull request.
