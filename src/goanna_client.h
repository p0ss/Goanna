#pragma once

#include <godot_cpp/classes/node3d.hpp>

namespace goanna {

// Root node of a Goanna session. Owns the transplanted Luanti client and
// feeds what it produces (mapblock meshes, player pose) into the scene.
class GoannaClient : public godot::Node3D {
    GDCLASS(GoannaClient, godot::Node3D)

public:
    GoannaClient() = default;
    ~GoannaClient() override = default;

    godot::String hello() const;
    godot::String luanti_version() const;

protected:
    static void _bind_methods();
};

} // namespace goanna
