# Agents

Goanna is developed with coding agents, and it offers agents two interfaces
of its own. This section covers both.

## The rules come first

[`AGENTS.md`](https://github.com/p0ss/Goanna/blob/main/AGENTS.md), at the
root of the repository, is the one statement of the rules for every agent
working in it: the text style, the transplant boundary, what counts as a
claim, the GPU and test client rules, stopping processes, the shared
checkout and how work lands. Each rule links to the page that holds its
detail, several of them in this section.

## Pages

- [Agent interfaces](agent-interfaces.md): the game development interface
  and the player agent interface, what each may do, the rules for test
  clients and the render service.
- [Control channel](control-channel.md): the loopback socket into a running
  client, its commands, the MCP server built on it, and cold verification.
- [The director](director.md): a language model as game master, as built.
  Operators set it up with [setting up a director](../host/director-setup.md);
  the full design is in [director design](../design/director-design.md).
