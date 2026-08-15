#pragma once

#include <memory>

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>

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
    // Number of received blocks not yet consumed by the Godot side.
    int pending_block_count();

protected:
    static void _bind_methods();

private:
    std::unique_ptr<GoannaSession> m_session;
};

} // namespace goanna
