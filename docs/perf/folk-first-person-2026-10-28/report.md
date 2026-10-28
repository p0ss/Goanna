# Folk heads in first person

28 October 2026. Local native Flatpak Luanti 5.17.0, installed Mineclonia,
DorfCraft creature bodies and Godot 4.5.1 headless, using an isolated test
save and a private body-selection command. No owner save changed.

The local player renderer requested only `Head` for first-person shrinking.
DorfCraft folk and hominin frames use `head`. The renderer now selects
`Head` where present and otherwise `head`; the change applies to any local
player model with either convention, rather than to one species.

A real connected tigerfolk player was inspected through its Godot skeletons:

| Camera | Visible head/jaw scale | Shadow head scale |
| --- | --- | --- |
| First person | 0.01 / 0.01 | 1.0 |
| Third person behind | 1.0 / 1.0 | 1.0 |
| First person again | 0.01 / 0.01 | 1.0 |

All five native client assertions passed; measurements are in results.json
and the headless probe is client.gd. This inspects actual rendered-model
skeleton state under the dummy renderer; it is not a screenshot review.
The existing attachment test passed all nine checks. The style gate passed.

The local extension was rebuilt in project/bin. An already running Goanna
process must exit and restart to load it. This does not change the server's
body, collision box, eye height or animations.
