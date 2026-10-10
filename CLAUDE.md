@AGENTS.md

## Notes for Claude only

The rules are in `AGENTS.md`, imported above. These notes add only what is
particular to Claude Code.

- **Commit trailer.** After the `git commit -s` sign off, end the message
  with the `Co-Authored-By:` line the session's attribution reminder gives
  (for example `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`).
- **The MCP server.** `claude mcp add goanna <checkout>/tools/goanna-mcp`
  registers the game development interface as tools. Its
  `goanna_session action=start` goes through the same launcher as
  `tools/goanna-headless` and obeys the same rules. See
  `docs/control-channel.md`, "Driving it from an agent".
- **Subagents.** Put rules 5 to 8 of `AGENTS.md` in every subagent's brief
  that may start a client, render or commit; a subagent does not always
  read this file.
- **When the owner wants the GPU,** stop your GPU subagents with TaskStop
  at once (a message only reaches them at their next tool round), confirm
  with `nvidia-smi` that nothing of theirs is left, and only then say the
  card is free.
- **Agent worktrees.** Removing a subagent's worktree makes that agent
  impossible to resume. Send any follow up first, then remove it once its
  work has landed (`CONTRIBUTING.md`, "Landing work").
