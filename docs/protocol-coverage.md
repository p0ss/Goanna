# Protocol coverage and the GDScript surface

What Goanna's session currently handles from a Luanti server (5.16 wire
format), and how the Godot side reads it via `GoannaClient`. Handlers are
transplanted from `Client::handleCommand_*` in
`luanti/src/network/clientpackethandler.cpp`.

## Handshake and world
| Packet | Status | Godot API |
|---|---|---|
| HELLO / AUTH_ACCEPT / ACCESS_DENIED / SRP | done (register, login, denial) | `connect_to`, `status()` |
| NODEDEF / ITEMDEF / ANNOUNCE_MEDIA / MEDIA | done, READY held until media complete | `status()` counters |
| BLOCKDATA (+GOTBLOCKS acks) | done, meshed with Luanti's `content_mapblock` | `poll_blocks(n)` |
| ADDNODE / REMOVENODE | done, re-meshes affected blocks | automatic |
| MOVEMENT / PRIVILEGES / MOVE_PLAYER | done, applied to the transplanted `LocalPlayer` | `step_player(...)` |
| TIME_OF_DAY (+speed), SET_SKY/SUN/MOON/STARS, CLOUD_PARAMS, SET_LIGHTING, OVERRIDE_DAY_NIGHT_RATIO | done | `sky_state()`, `set_time_of_day_override(t)` |
| ACTIVE_OBJECT_REMOVE_ADD / ACTIVE_OBJECT_MESSAGES | done (GenericCAO state transplanted); visuals: sprites, cubes, meshes (B3D, X, OBJ, glTF through Luanti's own loaders) with skeletal animation, bone overrides and bone attachments; item and wielditem entities through the transplanted wield mesh; node entity visuals are still placeholders | `sync_entities(dt)`, `entity_count()`, `entity_positions()`, `entity_list()` |
| CHAT_MESSAGE / TOSERVER_CHAT_MESSAGE | done | `take_chat()`, `send_chat(msg)` |
| HP / BREATH | done | `hp()`, `breath()` (also in `hud_state()`) |
| HUDADD / HUDCHANGE / HUDRM / HUD_SET_FLAGS / HUD_SET_PARAM | done, kept as Luanti `HudElement`s | `hud_state()` |
| INVENTORY / INVENTORY_FORMSPEC / SHOW_FORMSPEC / TOSERVER_INVENTORY_ACTION | done (Luanti `Inventory` deserialised; formspecs passed as strings; actions sent as Luanti's action strings) | `inventory_state()`, `inventory_formspec()`, `take_shown_formspecs()`, `send_inventory_fields(...)`, `inventory_action(str)`, `set_wield_index(i)`, `wield_index()` |
| DETACHED_INVENTORY / NODEMETA_CHANGED (and node metadata in BLOCKDATA) | done | `inventory_state_at("detached:<name>" or "nodemeta:x,y,z")`, `detached_inventory_names()` |
| death screen (builtin's `__builtin:death` formspec, no dedicated packet since 5.9) | done | `respawn()` |
| node formspecs (`Game::nodePlacement`: a right-clicked node whose metadata has a `formspec` opens it client-side unless sneaking) / TOSERVER_NODEMETA_FIELDS | done | shown formspecs carry `context: "nodemeta:x,y,z"`; `send_nodemeta_fields(context, formname, fields)`; `step_interact(..., sneak)` |
| textures for UI (item icons, HUD images) | via the texture-modifier DSL; item icons resolve an item's inventory_image (node items without one return null, UI keeps its placeholder) | `texture(name) -> Texture2D`, `item_icon(item_name) -> Texture2D` |
| INTERACT (dig start/stop/completed, place) / PLAYERITEM | done, raycast and dig timing from Luanti's own code | `step_interact(dt, dig, place, place_pressed)`, `set_wield_index(i)` |

NDT_MESH nodes go through the same loaders (`Client::getMesh` on the
stand-in client), so `node_visuals` handles them as upstream does.

## Not yet
- Item, wield-item and node entity visuals; the local player's wield hand.
- Particles, sounds, node metadata display, minimap data, camera packets,
  death screen, mod channels, client-side mods (SSCSM).
- Formspec `model[]` elements and `style[]`. Formspecs are otherwise parsed and drawn by
  `project/ui/formspec.gd`, with the layout maths from `GUIFormSpecMenu`.

## Coordinate conventions
Luanti positions are in BS units (10 per node), left-handed; Goanna's Godot
space is nodes with z mirrored: `godot = (x/BS, y/BS, -z/BS)`. Yaw values map
directly; pitch is negated. `LocalPlayer` and entity positions follow this.
