# Goanna, unreleased

Changes on main since 0.15.1-alpha.

## The F free camera key is gone

`F` used to toggle a free camera, in games you started yourself, that left
the body behind and passed through terrain. That is not something a vanilla
client offers, so Goanna no longer binds it to any key. The camera remains
as a development view behind the control channel.

## K flies, as in the vanilla client

`K` (D-pad left on a controller) turns Luanti's own fly mode on and off,
with the same notice above the hotbar. It moves the real player, keeps
collision and needs the server's `fly` privilege, so it is the fly a vanilla
client has, not a cheat.
