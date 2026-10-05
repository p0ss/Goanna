# Notes for coding agents working in this repository

This file is for any coding agent (Codex and others). Agents that read
`CLAUDE.md` get the same rules from there. Read `CLAUDE.md` in full before
changing anything: its text style, transplant, claims and boundary rules
apply to you exactly as written. The rules below are the ones whose breach
reaches outside the repository, repeated here so they cannot be missed.

## The owner's machine is shared

Several agents work in this checkout at once, and the owner uses the same
desktop while they do.

- **No windows on the desktop.** Test clients run headless, through
  `tools/goanna-headless` or the MCP server (`tools/goanna-mcp`), inside
  gamescope's headless backend. Do not start Godot or Luanti as a window
  unless the owner has asked to watch one.
- **Never inject input** into the owner's display (`DISPLAY=:0`,
  `WAYLAND_DISPLAY=wayland-0`) with xdotool, ydotool or anything else.
- **One game client on the GPU at a time.** A headless gamescope started
  beside another game client has twice put the NVIDIA driver into a state
  that needs a reboot, which stops every agent's rendering and the owner's
  games. Take every rendered frame and every GPU timing through the render
  service, `tools/goanna-render shoot JOB.json`, rather than a client of
  your own: it holds the GPU lock, keeps one server and one client up,
  queues jobs from every agent and gives the card back when the owner
  wants it (`docs/agent-interfaces.md`, "The render service"). Anything
  else on the GPU must hold `flock /tmp/claude-1000/goanna-gpu.lock` and
  run `tools/goanna-headless gpu-free` first; it exits 1 and names the
  client while one is running. Run fixtures with `tools/goanna-headless
  fixture SCENE`, never a gamescope command line built by hand: lavapipe
  environment variables do not keep gamescope itself off the card (it
  wedged the driver on 2026-10-02).
- **Stop processes only by the PIDs you started.** Never `pkill`,
  `killall` or `pgrep -f` by name: those hit other agents' clients and the
  owner's own game.
- **Commit only your own files**, staged by explicit path. Never
  `git add -A`, `git commit -a` or a directory pathspec: other agents'
  unfinished work is in the same tree.

The full rules for test clients are in `docs/agent-interfaces.md`, under
"Rules for test clients".
