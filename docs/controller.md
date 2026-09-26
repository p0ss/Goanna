# Game controllers

Goanna reads a game controller through Godot's own joypad input. Nobody has
played Goanna with a controller yet, on a Steam Deck or anywhere else. What
is described here is what the committed code does and what the headless
tests check, not what has been seen to work in a hand. Reports are welcome.

Written against Godot 4.5.1.

## Layout

The layout follows upstream Luanti 5.17's gamepad defaults
(`luanti/src/defaultsettings.cpp`), so a Luanti player's habits carry over.
Button names are the Xbox ones Godot uses; a PlayStation or Nintendo pad
maps them by position.

| Control | In play | Upstream setting |
| --- | --- | --- |
| Left stick | Move, analogue | `keymap_forward` and friends |
| Right stick | Look | `keymap_camera_yaw_left` and friends |
| A | Jump | `keymap_jump` |
| B | Sneak | `keymap_sneak` |
| X | Aux1 (fast, or descend) | `keymap_aux1` |
| Y | Inventory | `keymap_inventory` |
| RT | Dig (hold) | `keymap_dig` |
| LT | Place or use | `keymap_place` |
| RB | Next hotbar slot, repeats while held | `keymap_hotbar_next` |
| LB | Previous hotbar slot, repeats while held | `keymap_hotbar_previous` |
| D-pad down | Drop the wielded stack, one item while sneaking | `keymap_drop` |
| Start | Pause menu | `keymap_pause` |

Upstream also puts zoom on D-pad up, free move on D-pad left, screenshot on
D-pad right and the minimap on Back. Goanna has no zoom, screenshot or
minimap key, and its free camera is not upstream's free move, so those are
unbound. Chat has no controller binding. The drop action is new to Goanna:
the keyboard still has no drop key.

The bindings are InputMap actions (`goanna_jump`, `goanna_dig` and so on),
declared at startup in `project/gamepad.gd` from one table. They cannot be
rebound from the settings screen yet.

Movement is analogue: a stick part way over walks part speed, as upstream's
does. A key held on the keyboard at the same time wins, which is upstream's
rule too. Look speed is in degrees a second at full deflection and scales
with the field of view the way upstream's `joystick_frustum_sensitivity`
does, so 170 feels the same as upstream's default of 170.

## Menus, the inventory and server forms

Luanti's forms are laid out for a pointer, and a game's form has no focus
order Goanna could rely on. So outside play the left stick moves a cursor,
and the buttons click with it:

| Control | Outside play |
| --- | --- |
| Left stick | Move the cursor; it speeds up while held over |
| A | Left click, held to drag |
| X | Right click (take half a stack, place one item) |
| LB held | Shift, for a shift click that moves a whole stack across |
| Right stick up and down | Mouse wheel under the cursor |
| B or Start | Escape: close the form or menu |
| Y | Close the inventory, as `I` does |
| D-pad | Move focus through Goanna's own menus and settings |

Each click is an ordinary mouse event pushed into the window at the cursor,
the same path the control channel uses (`project/control_ui.gd`), so a form
cannot tell it from a mouse. That is why this was chosen over focus
navigation for forms: it reaches everything a mouse reaches, in every game,
with no per element work.

Goanna's own screens (the main menu, the pause menu, settings) are Godot
Controls that take focus, so the D-pad also moves focus through them. The
first D-pad press focuses the first control on screen, and A then presses
whatever has focus. Moving the stick goes back to the cursor. Moving a real
mouse hides the cursor.

The switch between play and the cursor follows the mouse: whenever Goanna
would release the mouse pointer (a window, the inventory, chat, Escape), the
controller becomes a cursor, and whenever it takes the pointer back, the
controller plays.

## Settings

The Controls tab has four settings, stored in `goanna.cfg` with the rest:

- Game controller (`pad_enabled`), on by default. Off, controller input is
  ignored everywhere.
- Controller look speed (`pad_look_speed`), 170 by default.
- Invert controller look (`pad_invert_y`), off by default.
- Controller deadzone (`pad_deadzone`), 0.15 by default. Upstream uses 0.25.
  Goanna's is lower because Steam Input can apply a deadzone of its own
  before Godot sees the stick. Raise it if the view drifts at rest.

## Steam Deck

Under Steam, including Game Mode on a Deck, Steam Input presents the Deck's
controls to games as a virtual Xbox style pad, which is what the layout
above assumes. None of this has been tried on a Deck. In particular:

- Text fields in forms (signs, books, a server's password) need a keyboard.
  Goanna does not open an on screen keyboard; Steam's own (Steam and X on a
  Deck) is the expected route and is untested.
- If Steam maps a trackpad to the mouse, Goanna sees an ordinary mouse,
  which forms already handle. Untested.
- The default deadzone and look speed are guesses for the Deck's sticks.

## Testing

`project/tests/gamepad.gd` feeds synthetic `InputEventJoypadButton` and
`InputEventJoypadMotion` events through `Input.parse_input_event` and checks
the actions, the deadzone, the keys handed to the client, look angles,
hotbar and drop edges, the off switch, the cursor's movement and its pushed
mouse and key events, and D-pad focus. It needs no GPU:

```sh
godot --headless --path project --script res://tests/gamepad.gd
```

What it does not show is how any of it feels, whether a real controller's
events arrive the way the synthetic ones do, or that analogue movement
reaches a server as expected. That needs a person, a controller and a
server.
