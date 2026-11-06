# Goanna, unreleased

Changes on main since 0.17.0-alpha.

- The local player collides with active objects as the stock client does:
  an object whose properties set both `physical` and `collide_with_objects`
  blocks the player, can be stepped onto when lower than the step height,
  and can be stood on. Before, Goanna walked through boats, carts and every
  other physical object. As in the stock client, a physical object with
  `collide_with_objects = false` does not block, and standing on a moving
  object does not carry the player. Seen on 6 November 2026 against a
  Luanti 5.18.0 server running Mineclonia (with DorfCraft's mods, on its
  shared test host, exclusive mode) from Godot 4.5.1: walking into a one
  node physical entity stopped 0.012 nodes short of its face, the player
  stood on its top for eight seconds, and one with `collide_with_objects`
  false was walked through. Attached physical objects do not collide yet.
- The keyboard has a drop key, Q as in Luanti: it drops the wielded stack,
  or one item with Shift held, as the same inventory action the vanilla
  client sends. Only the controller could drop before. Seen working on 6
  November 2026 against a Luanti 5.18.0 server running Mineclonia (with
  DorfCraft's mods, on its shared test host) from Godot 4.5.1: Shift and Q
  took one of five cobblestone, Q alone the whole stack.
- Settings has a Key bindings screen (a tab in the pause menu's settings):
  every keyboard control in a table, changed by choosing it and pressing the
  new key. A key another control has is refused with the reason, Reset to
  defaults puts every key back, and the controls that cannot be changed
  (digging and placing, Escape, Ctrl+B) are listed greyed. Keys are saved
  under Luanti's own `keymap_*` names and key format.
