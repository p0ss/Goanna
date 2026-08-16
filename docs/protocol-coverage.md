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
| ACTIVE_OBJECT_REMOVE_ADD / ACTIVE_OBJECT_MESSAGES | done (GenericCAO state transplanted); visuals: sprites, cubes, placeholders for meshes | `sync_entities(dt)`, `entity_count()`, `entity_positions()` |
| CHAT_MESSAGE / TOSERVER_CHAT_MESSAGE | done | `take_chat()`, `send_chat(msg)` |
| HP / BREATH | done | `hp()`, `breath()` (also in `hud_state()`) |
| HUDADD / HUDCHANGE / HUDRM / HUD_SET_FLAGS / HUD_SET_PARAM | done, kept as Luanti `HudElement`s | `hud_state()` |
| INVENTORY / INVENTORY_FORMSPEC / SHOW_FORMSPEC | done (Luanti `Inventory` deserialised; formspecs passed as strings) | `inventory_state()`, `inventory_formspec()`, `take_shown_formspecs()`, `send_inventory_fields(...)`, `set_wield_index(i)` |
| textures for UI (item icons, HUD images) | via the texture-modifier DSL | `texture(name) -> Texture2D` |

## Not yet
- Entity meshes (B3D/glTF/OBJ) and skeletal animation, attachments to bones.
- NDT_MESH nodes (need the same model loaders).
- Digging/placing/interaction (TOSERVER_INTERACT), inventory actions
  (TOSERVER_INVENTORY_ACTION), wield item visuals.
- Particles, sounds, node metadata display, minimap data, camera packets,
  death screen, mod channels, client-side mods (SSCSM).
- Formspec *rendering* (the parser transplant is separate from passing the
  strings through, which is what exists now).

## Coordinate conventions
Luanti positions are in BS units (10 per node), left-handed; Goanna's Godot
space is nodes with z mirrored: `godot = (x/BS, y/BS, -z/BS)`. Yaw values map
directly; pitch is negated. `LocalPlayer` and entity positions follow this.
