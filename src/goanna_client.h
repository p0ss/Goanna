// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

#include <map>
#include <memory>

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/omni_light3d.hpp>
#include <godot_cpp/classes/gpu_particles3d.hpp>
#include <godot_cpp/classes/particle_process_material.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "goanna_entities.h"
#include "irrlichttypes_bloated.h"
#include <SMaterial.h>

class MapBlock;

namespace goanna {

class GoannaSession;

// Root node of a Goanna session. Owns the transplanted Luanti client and
// feeds what it produces (mapblock meshes, player pose) into the scene.
// What a world material is keyed on: Luanti texture id, Goanna shader id
// (which carries Luanti's material type) and culling.
struct MaterialKey {
    u32 texture_id = 0;
    u32 shader_id = 0;
    bool backface_culling = true;
    uint64_t hash() const {
        return ((uint64_t)texture_id << 24) | ((uint64_t)(shader_id & 0xffff) << 1) | (backface_culling ? 1 : 0);
    }
};

class GoannaClient : public godot::Node3D {
    GDCLASS(GoannaClient, godot::Node3D)

public:
    GoannaClient();
    ~GoannaClient() override;

    godot::String hello() const;
    godot::String luanti_version() const;

    void connect_to(const godot::String &host, int port, const godot::String &player_name,
            const godot::String &password);
    void disconnect_from_server();
    godot::Dictionary status() const;

    // Mesh up to max_blocks newly received blocks into child MeshInstance3Ds.
    // Returns how many were processed.
    int poll_blocks(int max_blocks);
    int block_mesh_count() const { return (int)m_block_nodes.size(); }
    int material_count() const { return (int)m_materials.size(); }

    // Camera/player pose in Godot space; reported to the server so it
    // streams blocks around us. Position in nodes.
    void set_player_pose(const godot::Vector3 &pos, float pitch_deg, float yaw_deg);
    // Initial player position from the server, in Godot space (nodes).
    godot::Vector3 server_player_position() const;

    // Advance the local player by dt using Luanti's own movement code.
    // keys: {up,down,left,right,jump,sneak,aux1}; pitch/yaw in Godot degrees
    // (pitch positive = looking up). Returns {eye_pos, pos, pitch, yaw,
    // on_ground, in_liquid} in Godot space (nodes).
    // Digging/placing: call once per frame with button state. Returns
    // {type: "nothing"|"node"|"object", node, above, object_id, progress}.
    godot::Dictionary step_interact(double dt, bool dig, bool place, bool place_pressed, bool sneak = false);
    // Fields of a node's own formspec, for a "nodemeta:x,y,z" context.
    void send_nodemeta_fields(const godot::String &context, const godot::String &formname, const godot::Dictionary &fields);
    void set_wield_index(int index);
    int wield_index() const;
    // Raw Luanti inventory action string, e.g. "Move 1 current_player main 3 current_player main 5".
    void inventory_action(const godot::String &action);

    // Step and draw active objects (players, mobs, items).
    void sync_entities(double dt);
    int entity_count() const { return m_entities ? m_entities->count() : 0; }
    godot::Array entity_positions() const { return m_entities ? m_entities->positions() : godot::Array(); }
    godot::Array entity_list();
    // First-person body (the local player's own model, head shrunk away).
    void set_show_body(bool show);
    // First-person arm swing phase (0..1), driven from the input side.
    void set_arm_swing(float s);
    bool show_body() const { return m_show_body; }
    // Currently wielded item: its name (cheap; poll for changes), and its
    // wield mesh as {name, mesh: ArrayMesh or null, scale: Vector3}.
    godot::String wield_item_name();
    godot::Dictionary wield_info();
    // Mesh for an arbitrary item name: {name, mesh: ArrayMesh or null,
    // scale: Vector3}, for rendering 3D inventory icons. Node items get their
    // real node mesh (stairs, slabs, torches), so this is not cube-only.
    // Unlike wield_info this ignores wield_image, which is the wielded
    // override rather than the inventory representation.
    godot::Dictionary item_mesh(const godot::String &item_name);

    // Point lights for light-emitting nodes: keeps up to max_lights OmniLight3Ds
    // on the nearest bright nodes to `around` (Godot space, nodes).
    void update_lights(const godot::Vector3 &around, int max_lights);
    // Ambient motes: pooled particle emitters that follow nearby leaf, flora
    // and sand/gravel nodes, coloured from the node's texels. density scales
    // the count and per-emitter amount (0 = off). update_motes drives the pool.
    void set_motes(float density);
    float motes() const { return m_motes; }
    void update_motes(const godot::Vector3 &around, int max_emitters);

    // --- in-game data for the UI layer ---
    // Chat lines received since last call: [{type, sender, message}].
    godot::Array take_chat();
    void send_chat(const godot::String &message);
    int hp() const;
    int breath() const;
    // HUD elements: [{id, type, pos, name, scale, text, number, item, dir, align,
    // offset, world_pos, size, z_index, text2, style}], plus flags/hotbar info.
    godot::Dictionary hud_state() const;
    // Player inventory: {version, lists: {name: [{name, count, wear, description,
    // inventory_image, stack_max}]}}. Empty item names are empty slots.
    godot::Dictionary inventory_state();
    // Inventory at "current_player", "detached:<name>" or "nodemeta:x,y,z":
    // {found, version, lists}. version changes when detached inventories or
    // node metadata change, so callers can poll cheaply.
    godot::Dictionary inventory_state_at(const godot::String &location);
    godot::PackedStringArray detached_inventory_names();
    // Answer the death screen (builtin's "__builtin:death" formspec).
    void respawn();
    // Texture (ImageTexture) for a Luanti texture string (item icons, HUD images);
    // null if unavailable. Goes through the texture-modifier DSL.
    godot::Ref<godot::Texture2D> texture(const godot::String &name);
    // Inventory icon for an item name: its inventory_image texture if it has
    // one (tools, most items), else the item's own texture; null if unknown.
    // Node items without an inventory image return null (the UI keeps its
    // coloured-tile placeholder; a rendered node icon needs an offscreen pass).
    godot::Ref<godot::Texture2D> item_icon(const godot::String &item_name);
    // Formspecs
    godot::String inventory_formspec() const;
    godot::Array take_shown_formspecs(); // [{formspec, formname}]
    void send_inventory_fields(const godot::String &formname, const godot::Dictionary &fields);

    // Sky/sun/fog/lighting state from the server, in Godot terms (see goanna_sky.h).
    godot::Dictionary sky_state() const;
    void set_time_of_day_override(float tod);
    // True if the given eye position (Godot space, nodes) is inside a liquid
    // node; for underwater fog/tint. Cheap map lookup.
    bool is_underwater(const godot::Vector3 &eye);
    // Auto-bump strength: normal maps derived from diffuse luminance. 0 = off.
    // Rebuilds world materials so the change takes effect immediately.
    // Block edge bevel width as a fraction of a node (0 = off). Re-meshes.
    void set_bevel(float width);
    float bevel() const;
    void set_auto_bump(float strength);
    float auto_bump() const { return m_auto_bump; }
    // Mantle over single-block ledges (Luanti's autojump). On by default.
    void set_mantle(bool on) { m_mantle = on; }
    bool mantle() const { return m_mantle; }
    // Movement option flags, applied to the local player's PlayerSettings each
    // step (the transplanted movement code reads them).
    void set_aux1_descends(bool on) { m_aux1_descends = on; }
    bool aux1_descends() const { return m_aux1_descends; }
    void set_pitch_move(bool on) { m_pitch_move = on; }
    bool pitch_move() const { return m_pitch_move; }
    void set_always_fly_fast(bool on) { m_always_fly_fast = on; }
    bool always_fly_fast() const { return m_always_fly_fast; }
    // Interaction options (forwarded to the session, read in stepInteract).
    void set_safe_dig(bool on);
    bool safe_dig() const;
    void set_repeat_dig_interval(float s);
    float repeat_dig_interval() const;
    void set_repeat_place_interval(float s);
    float repeat_place_interval() const;

    godot::Dictionary step_player(double dt, const godot::Dictionary &keys, float pitch_deg, float yaw_deg);

    // World materials (shared by mapblocks and item entities): by key, or
    // straight from a Luanti SMaterial as the mesher leaves it.
    godot::Ref<godot::Material> materialFor(const MaterialKey &key);
    godot::Ref<godot::Material> materialForIrr(const video::SMaterial &m);

protected:
    static void _bind_methods();

private:
    void harvestLights(v3s16 bp, MapBlock *block);
    void harvestMotes(v3s16 bp, MapBlock *block);
    void ensureMoteMaterials();

    std::unique_ptr<GoannaSession> m_session;
    std::map<v3s16, godot::MeshInstance3D *> m_block_nodes;
    std::map<uint64_t, godot::Ref<godot::Material>> m_materials;
    godot::Ref<godot::Shader> m_sh_water, m_sh_leaves, m_sh_plants, m_sh_glass;
    bool m_shaders_loaded = false;
    float m_auto_bump = 0.35f;
    bool m_show_body = true;
    float m_arm_swing = 0.0f;
    bool m_mantle = true;
    bool m_aux1_descends = false;
    bool m_pitch_move = false;
    bool m_always_fly_fast = false;

    std::unique_ptr<EntityRenderer> m_entities;
    struct NodeLight { godot::Vector3 pos; float level; godot::Color color; };
    std::map<v3s16, std::vector<NodeLight>> m_block_lights;
    std::vector<godot::OmniLight3D *> m_light_pool;
    // kind: 0 = leaves (drift down), 1 = flora/pollen, 2 = sand/gravel dust
    struct MoteNode { godot::Vector3 pos; int kind; godot::Color color; };
    std::map<v3s16, std::vector<MoteNode>> m_block_motes;
    struct MoteEmitter { godot::GPUParticles3D *node = nullptr; godot::Vector3 at; int kind = -1; };
    std::vector<MoteEmitter> m_mote_pool;
    godot::Ref<godot::ParticleProcessMaterial> m_mote_proc[3];
    float m_motes = 0.5f;
};

} // namespace goanna
