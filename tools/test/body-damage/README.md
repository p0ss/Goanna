# Body damage fixture

Inputs and expected output for `goanna_body_damage_test`
(`src/goanna_body_damage_test.cpp`), which checks that Goanna cuts a
wounded model exactly as DorfCraft's server mesh does.

`shield/` is DorfCraft's carried round shield after six runs of four
blows on DorfCraft's own damage controller: the wire form, each step's
wire state, what the server's runtime mesh adds to the base model for
that state (the generated buffer as base64, the primitives, the new
accessors and buffer views), and the base model itself,
`kindred_shield_carved_round.gltf`. All of it was written by DorfCraft's
`tools/kindred_creatures/kit/damage/client_fixture.lua` (DorfCraft commit
2218bb614, 8 November 2026); the model is DorfCraft's media, built by its
`tools/kindred_creatures/kit/strokes/build_shield.py`. Both projects have
the same maintainer.

The same tool also writes a sapiens adult case (a 1.4 MB base model, so
it is not kept here). To check it, write the fixture and run the test on
it with the DorfCraft checkout as the second argument:

    luajit tools/kindred_creatures/kit/damage/client_fixture.lua OUT
    goanna_body_damage_test OUT /path/to/DorfCraft
