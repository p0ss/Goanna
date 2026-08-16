#pragma once

#include <map>
#include <memory>

#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/omni_light3d.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "irrlichttypes_bloated.h"

class MapBlock;

namespace goanna {

class GoannaSession;

// Root node of a Goanna session. Owns the transplanted Luanti client and
// feeds what it produces (mapblock meshes, player pose) into the scene.
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
    // Point lights for light-emitting nodes: keeps up to max_lights OmniLight3Ds
    // on the nearest bright nodes to `around` (Godot space, nodes).
    void update_lights(const godot::Vector3 &around, int max_lights);

    // Sky/sun/fog/lighting state from the server, in Godot terms (see goanna_sky.h).
    godot::Dictionary sky_state() const;
    void set_time_of_day_override(float tod);

    godot::Dictionary step_player(double dt, const godot::Dictionary &keys, float pitch_deg, float yaw_deg);

protected:
    static void _bind_methods();

private:
    godot::Ref<godot::Material> materialFor(const struct MaterialKey &key);
    void harvestLights(v3s16 bp, MapBlock *block);

    std::unique_ptr<GoannaSession> m_session;
    std::map<v3s16, godot::MeshInstance3D *> m_block_nodes;
    std::map<uint64_t, godot::Ref<godot::Material>> m_materials;
    godot::Ref<godot::Shader> m_sh_water, m_sh_leaves, m_sh_plants, m_sh_glass;
    bool m_shaders_loaded = false;

    struct NodeLight { godot::Vector3 pos; float level; godot::Color color; };
    std::map<v3s16, std::vector<NodeLight>> m_block_lights;
    std::vector<godot::OmniLight3D *> m_light_pool;
};

} // namespace goanna
