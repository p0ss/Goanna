# Rules for coding agents

This file is the one place the rules for agents working in this repository
are stated, for every agent (Claude, Codex and others). Each rule is short
and links to the document that holds its detail. Read those documents
before you work in their area; if a rule here and its detail ever seem to
differ, fix the detail, do not pick one.

1. **Text style.** Australian English, never an em dash (nor `--` as one),
   no smart quotes or ellipsis characters, sentence case headings, Markdown
   wrapped at 80 columns. `tools/check-style.sh` is a gate: it must exit
   clean before you commit. Detail: `docs/develop/style.md`.
2. **Never restyle `src/transplant/`.** It is Luanti's own code; do not
   reformat, rename or respell anything in it. To use Luanti code, first
   compile it from the submodule, else give Goanna a stand-in with the name
   upstream expects, and only then copy it, upstream header first, with an
   inventory row. Detail: `docs/develop/transplanting.md`.
3. **Claims need a real run.** Describe something as working only after it
   has run against a real server and been observed to work, and say which
   server, game and Godot version. Detail: `CONTRIBUTING.md`, "Claims and
   test reports".
4. **Boundaries.** Goanna talks to unmodified servers over the ordinary
   protocol and gives a player nothing a vanilla client would not. Never
   fork or patch Luanti (`luanti/` is a pinned submodule). Never claim
   affiliation with or endorsement by the Luanti project. Detail:
   `CONTRIBUTING.md`, "Relationship to Luanti".
5. **The GPU goes through the tools.** Rendered frames and GPU timings go
   through the render service (`tools/goanna-render`), any other GPU client
   through `tools/goanna-headless`; they take the GPU lock and check the
   card themselves. One GPU client at a time. When `goanna-headless
   gpu-free` says busy, do not render. Never build a gamescope command line
   by hand. Detail: `docs/agents/agent-interfaces.md`, "Rules for test clients".
6. **No windows, no input injection.** Test clients run in headless
   gamescope or under Godot's `--headless`, never as windows on the owner's
   desktop, and are driven from inside through the control channel. Never
   send input to the owner's display with xdotool, ydotool or anything
   else. The one exception is a desktop benchmark, run only when the owner
   says the machine is free; a headless one is relative only. Detail:
   `docs/agents/agent-interfaces.md`, "Benchmarks on the desktop".
7. **Stop processes by PID only.** Stop only the PIDs you started, or go
   through the launcher. Never `pkill`, `killall` or `pgrep -f` by name.
   Leave nothing of yours running. Detail: `docs/agents/agent-interfaces.md`.
8. **The checkout and its index are shared.** Stage only your own hunks
   and read `git diff --cached` before every commit. Never `git add -A`,
   `git commit -a` or a directory pathspec. A file another session also
   edited ships with its hunks unless you stage by hunk. Detail:
   `CONTRIBUTING.md`, "Working in a shared checkout".
9. **Land finished work on main.** Rebase and fast-forward: linear
   history, no merge commits, no review branches left behind. Never push;
   the owner pushes. Detail: `CONTRIBUTING.md`, "Landing work".
10. **Commit format.** Imperative subject under 72 characters, no full
    stop, then a body saying why, signed off with `git commit -s`. Detail:
    `CONTRIBUTING.md`, "Commits and pull requests".

Code conventions, including the rule that Godot objects are never touched
from the session thread, are in `CONTRIBUTING.md`, "Code style".
