# Body damage

Wounds cut into creature bodies and carried shields on the client, from
a damage state a paired server mod sends, instead of a whole new model
for every wound. Against any other server nothing is sent and nothing
changes; an unmodified Luanti client on a paired server sees the wounds
painted on the skin instead.

## Why

DorfCraft's creature kit carves wounds out of a body's cell grid (its
`kit/damage/` modules, with Kythen's radial form). It used to draw each
wound by building a whole new glTF and sending it to every viewer as
dynamic media: about 1.4 MB for a sapiens worker, 55 to 170 KB for a cut
shield, per wound, per viewer. Luanti cannot patch part of a sent mesh.
The DorfCraft maintainer ruled on 8 November 2026 that the server send
only the damage and Goanna cut it.

## Where it comes from

DorfCraft's `mods/kindred_creatures/kit/damage/net.lua` and `wire.lua`
are the only sender. As with the [climate field](climate.md):

- The server grants a per player channel, `kindred:d:` and 32 lower case
  hex characters, through a HUD element named `kindred:damage` whose text
  is the channel name. The client joins only a name granted that way and
  sends `hello 1`.
- Only messages with an empty sender (the server) are taken.
- A body carries a 48 bit token for good once it is first hurt, as the
  override of a bone no mesh has, `kindred_damage`: position x is the low
  24 bits, y the high 24. Luanti sends it only to clients that know the
  object, so the client learns of a wounded body exactly when it is sent
  the body.

The client asks for what it sees and drops what it stops seeing, in
messages of at most 1024 bytes:

    want T [T ...]
    drop T [T ...]

where T is the token as 12 hex digits. The server answers a `want` only
for a body within the player's object range.

### Messages

JSON, each under 60000 bytes, version 1:

- `{"v":1,"kind":"form","key":K,"i":i,"n":n,"z":B}`: piece i of n of a
  form, base64 of zstd of its JSON. A form is sent once per session,
  before the first state that names it. It holds, per part, the damage
  grid (cell places as runs, the authored box of each cell, the bone
  scaffold and attachment routes, bone shells), and the render source
  fields the server's mesh build reads (part primitives, UV locations,
  wound patches, bones, clothing layers). No vitals, cords or aims.
- `{"v":1,"kind":"state","t":T,"r":R,"key":K,"tex":[...],"parts":{...}}`:
  a body's whole state at revision R. Each part that does not draw whole
  is `{"s":1}` (severed) or `{"x":runs, "rel":[sockets], "f":cell}`: its
  lost cells as runs of cell numbers, the sockets released for a cut-off
  child, and the support fracture. `tex` is the body's textures without
  the stock decals.
- `{"v":1,"kind":"parts","t":T,"r":R,"parts":{...}}`: the parts that
  changed; `null` for a part whole again.

Nothing is replayed. The server decides every strike, sever and fracture
and names the result cell by cell, so the client cannot drift from it.

## What the client does

`src/goanna_body_damage.cpp` is a port of DorfCraft's
`kit/damage/mesh.lua` `M.build`: the same cell faces, merged quads, stump
patches, clothing shells, texture coordinates and accessor layout. Its
output is spliced with the base model the client already has into one
binary glTF (`damageGlb`), which `ModelCache::putGenerated` hands to the
ordinary model loader under a name of its own, taking the base model's
node extras (stroke plans, jiggle chains). `EntityRenderer` draws a
wounded body with that model and the state's textures, at most four
builds and 8 ms a frame, the latest state only.

`goanna_body_damage_test` checks the port against the server: for the
fixture in `tools/test/body-damage` the generated vertex buffer is the
server's byte for byte, and the primitives, accessors and buffer views
match. `inspect target=body_damage` on the control channel gives counts,
build and load timings, and the bytes received by packet type.

## Stock clients

The server paints the lost surface cells' texels on the body's atlas with
`[fill` rectangles and scales a severed part's bone to nothing. Goanna
ignores both while it draws its own cut model: it uses `tex` from the
state, and the severed part is missing from its model anyway.

## Not done yet

- A body's model is rebuilt whole on the client for each change, which
  costs a model load (the loader parses the base model again) as well as
  the cut itself.
- Carcasses being butchered (`kit/carve.lua`) still send whole models.
