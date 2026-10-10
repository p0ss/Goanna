# Hosting a world

Goanna joins ordinary, unmodified Luanti servers over the ordinary
protocol, so a server needs nothing special for Goanna players to join it,
and Goanna players and Luanti players can share a world. This section is for
the person running the server.

## From Goanna's menu

Start Game can host the world it starts. Hosting starts a normal Luanti
server and can expose a name, description, password, port, player limit and
public-list announcement. There is no built in server and no private
protocol: Goanna finds Luanti on the machine, launches an ordinary server on
it and joins over the network like any other client. How it finds Luanti is
in [installing Goanna](../play/install.md#which-luanti-start-game-uses).

## Running a server yourself

An ordinary Luanti 5.17.0 server works, and you will want your own for
anything beyond a quick look. Goanna offers protocol versions 37 to 53, as
Luanti 5.17's own client does, so older 5.x servers can negotiate a
connection, but only 5.17.0 has been run since Goanna moved to it. Goanna
connects over the ordinary protocol and asks for nothing special. The
quickest option is Luanti's own Development Test game, which is small, ugly
and exercises the basics:

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

A server running a full game such as minetest_game or Mineclonia works the
same way. Mineclonia is the most tested game; elsewhere expect gaps in the
long tail of drawtypes, formspecs, particles and item models.

## The Goanna server mod

`goanna_server_mod` is optional. A server without it is drawn exactly as a
vanilla client draws it. With it, the operator can grant capabilities a
vanilla client lacks, each one off until granted, and each a setting in
`minetest.conf`:

- **Far rendering**: coarse summaries of terrain the player has not been
  near, so the view reaches the horizon. See
  [far rendering](../systems/far-rendering.md).
- **Baked terrain**: surface tiles straight from a Terrain Diffusion bake.
  See [baked terrain](../systems/baked-terrain.md).
- **The director**: a language model as game master. See
  [setting up a director](director-setup.md).

The local server Goanna starts from its own menu installs the mod and grants
far rendering, since there is no one there to be unfair to. The mod's
settings, its handshake and the reasoning for each grant are in its
[README](https://github.com/p0ss/Goanna/blob/main/goanna_server_mod/README.md).
Which abilities need a grant at all, and which never may, is set out in
[capabilities](../design/capabilities.md) and
[validating capabilities](../design/validation.md).
