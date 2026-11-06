# Goanna, unreleased

Changes on main since 0.17.0-alpha.

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
