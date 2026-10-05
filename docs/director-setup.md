# Setting up a director

This is for the person running a server who wants a language model to act
as its game master. The director watches what players do, stages
encounters sized to their gear, and speaks as characters and as a
narrator. Everything it does is checked by the game first and written to an
audit log. [The director layer](director.md) is the design and says what
has been built and tested.

It is new and experimental. It has been driven by a test script and, once,
by a model in a short session with one player. Only Mineclonia has a
creature adapter, so on other games it can talk but not stage encounters.

## How the pieces fit

```
model  <-- MCP -->  goanna-director-mcp  <-- HTTP, this machine only -->  Luanti server
                   (tools/ in the Goanna                                 (goanna_server_mod
                    repository)                                           with the director on)
```

- The server mod connects to `tools/goanna-director-mcp` over loopback
  HTTP, with a secret token, so **the director service runs on the same
  machine as the Luanti server.**
- The model connects to the director service over MCP, the protocol most
  AI agent apps use for tools. The model itself can be anywhere: a hosted
  API or a model on your own computer.
- The director service ships only in the Goanna repository for now, not in
  the release zips. Get it with
  `git clone https://github.com/p0ss/Goanna.git`. It needs Python 3 and
  nothing else.

## 1. Turn the director on

**A world started from Goanna's menu** already has it: Goanna installs the
server mod, sets `goanna_director = true` and grants the mod HTTP access.
Start the world once, then go on to step 2.

**Any other Luanti server:**

1. Copy `goanna_server_mod/` from the Goanna repository into the world's
   `worldmods/` folder (or the server's `mods/` folder and enable it).
2. Add to the server's configuration file (`minetest.conf`, or the file
   given with `--config`):

   ```
   goanna_director = true
   secure.http_mods = goanna_server_mod
   ```

   If `secure.http_mods` already lists other mods, add `goanna_server_mod`
   to the list, separated by a comma. Without it the director cannot reach
   the director service.
3. Start the server once. The mod creates `<world>/goanna_director.conf`,
   holding the `url` it will connect to (default
   `http://127.0.0.1:30570`) and a random `token`. Keep the token private:
   anyone with it can direct your world.

Nothing happens to players until a director service connects.

## 2. Connect a model

Pick one of the three below. Each runs `tools/goanna-director-mcp` with
`--world` pointing at the world folder, so it can read the token and port.
For a world Goanna started, the world folder is under Goanna's data folder,
for example
`~/.local/share/godot/app_userdata/Goanna/luanti/<luanti>/worlds/<world>`
for its own Luanti, or `~/.var/app/org.luanti.luanti/.minetest/worlds/<world>`
for the Flatpak.

### Claude Code on the server machine

The simplest route, and the one used to build it.

```sh
claude mcp add goanna-director \
    -- /path/to/Goanna/tools/goanna-director-mcp --world /path/to/worlds/<world>
```

The `--` keeps `--world` for the director service rather than for
`claude`. Then start `claude` and give it a game master's brief (see
[A starting brief](#a-starting-brief)). It will see the `director_*` tools.

### Another app with a hosted model

Any app that can use MCP servers can run the director, with whichever
hosted model it offers. Most take a JSON configuration in this shape:

```json
{
  "mcpServers": {
    "goanna-director": {
      "command": "/path/to/Goanna/tools/goanna-director-mcp",
      "args": ["--world", "/path/to/worlds/<world>"]
    }
  }
}
```

Claude Desktop reads this from its `claude_desktop_config.json`; other apps
document where theirs goes. The app has to run on the server machine, or
reach it as described under [A server on another machine](#a-server-on-another-machine).
Not tried yet with anything but a test script.

### A model on your own computer, with Ollama

Ollama runs models locally, but it is not an MCP app on its own: it needs
an MCP host that sends its tool calls on, such as
[mcphost](https://github.com/mark3labs/mcphost), which takes the same
`mcpServers` configuration as above. Choose a model that supports tool
calling; small ones often call tools poorly, and a game master needs to
read events and answer within a few seconds. Not tried yet.

A local model uses your graphics card. If you play on the same computer,
expect lower frame rates while it runs.

### From a shell, or an agent that runs commands

`tools/goanna-director-cli` keeps one director service running and takes
tool calls as shell commands, so a person at a terminal, a script, or an
agent that acts one command at a time can be the game master without an
MCP app:

```sh
W=~/.var/app/org.luanti.luanti/.minetest/worlds/<world>
tools/goanna-director-cli --world $W serve &        # keep this running
tools/goanna-director-cli --world $W tools          # what it offers
tools/goanna-director-cli --world $W events '{"wait_s": 20}'
tools/goanna-director-cli --world $W player '{"name": "alice"}'
tools/goanna-director-cli --world $W speak \
    '{"as": "narrator", "to": "all", "text": "A cold wind rises."}'
```

A tool name may drop its `director_` prefix, and its arguments are one JSON
object. The answer prints as JSON; a refusal exits 1. The socket is private
to you, in `$XDG_RUNTIME_DIR`. Every call goes through the same checks,
budgets and audit log as from an MCP app.

Used on 5 October 2026 for a short session on a world started as Goanna's
menu starts one, hosted on the LAN: a Claude Code session cast a herder
who greeted the player, answered their public chat lines and remembered
them, while the player played in Goanna.

## A server on another machine

The director service has to run where the server runs. An MCP app on your
own computer can still use it, because MCP over standard input and output
works through SSH:

```json
{
  "mcpServers": {
    "goanna-director": {
      "command": "ssh",
      "args": ["you@server", "/path/to/Goanna/tools/goanna-director-mcp",
               "--world", "/path/to/worlds/<world>"]
    }
  }
}
```

This needs SSH keys set up so it logs in without a password prompt. Not
tried yet.

## A starting brief

The service already sends a short guide when a model connects (its MCP
`instructions`). A brief of your own sets the tone on top of that. For
example:

> You are the game master of a Mineclonia world. Start with
> `director_status` for what is on and what is left. Call
> `director_events` regularly to see what players are doing, and
> `director_player` before acting on anyone. Keep encounters fair: they are sized to each player's
> gear, and the pacing rules will tell you when to hold back. Speak through
> characters you cast with `director_cast_npc`, keep each line short, and
> remember what players tell them with `director_remember`. Never act on a
> player who has opted out; the server refuses it anyway. If something goes
> wrong, `director_undo` reverses an action and `director_stop` stops
> everything.

## What players see

- Anyone who joins while a director is connected gets one chat line saying
  it is active, what it can see and how to opt out.
- `/director` says what it is, its budgets and what it did near you.
- `/director optout` and `/director optin` turn it off and on for that
  player, and the choice lasts. A player who opts out is never targeted,
  spoken to or remembered, and nothing about them reaches the model.
- It reads public chat, as the server operator can. Direct messages and
  chat commands never reach it.

## Limits you can set

All are ordinary server settings; players can read them.

| Setting | Default | What it limits |
| --- | --- | --- |
| `goanna_director_points_per_hour` | 40 | Encounter size per hour, in points |
| `goanna_director_max_entities` | 24 | Director creatures in the world |
| `goanna_director_max_entities_per_player` | 8 | Director creatures per player |
| `goanna_director_speech_per_minute` | 6 | Lines a minute per character |
| `goanna_director_deny` | creepers, endermen and others | Creatures it may never spawn |
| `goanna_director_sees` | `exact` | `coarse` gives it regions and a gear score instead of positions and items |
| `goanna_director_chat` | `all` | `addressed` or `none` read less chat |
| `goanna_director_memory_text` | true | Whether characters remember lines the model writes |

`goanna_server_mod/settingtypes.txt` lists the rest.

## When it does not work

- **`/director` says "Director connected: no".** Is the director service
  running, with `--world` pointing at this world? Is `goanna_server_mod` in
  `secure.http_mods`? Does anything else hold the port in
  `goanna_director.conf`? The director service prints what it is doing to
  its error output, which most MCP apps show in their logs.
- **Encounters are refused.** Each refusal has a reason: `budget`,
  `pacing`, `opted_out`, `no_adapter` (a game other than Mineclonia) and
  others, listed in [Transport](director.md#transport).
- **To see everything it did**, read `/director log` in game (it needs the
  `server` privilege), or the audit log in
  `<world>/goanna_director/audit-<date>.jsonl`.
- **To stop it at once**, type `/director stop` in game. `/director start`
  lets it act again.
