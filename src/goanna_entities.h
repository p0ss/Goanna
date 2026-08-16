// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Godot-side rendering of Goanna's active objects (players, mobs, items).
// First cut: sprites and upright sprites as billboards, cubes as textured
// boxes, meshes as capsule placeholders (model loaders come next), nametags
// as Label3D. Attachments follow their parent's position.

#include <map>
#include <memory>
#include <string>

#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/sprite3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

#include "irrlichttypes_bloated.h"

namespace goanna {

class GoannaSession;
class GoannaActiveObject;

class EntityRenderer {
public:
    explicit EntityRenderer(godot::Node3D *root) : m_root(root) {}
    ~EntityRenderer();
    // Sync visuals with session objects. Caller holds session.mapLock().
    void sync(GoannaSession &session, float dt, const godot::Vector3 &camera_pos);
    int count() const { return (int)m_nodes.size(); }
    // Positions (Godot space) of visible entities, for tests/UI.
    godot::Array positions() const;

private:
    struct EntityNode {
        godot::Node3D *root = nullptr;
        godot::Node3D *visual = nullptr;
        godot::Label3D *nametag = nullptr;
        uint32_t visual_version = 0;
        std::string textures_key;
        float sprite_time = 0;
        int sprite_frame = 0;
    };
    void rebuildVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    godot::Ref<godot::StandardMaterial3D> materialForTexture(GoannaSession &session,
            const std::string &texture, bool alpha, bool double_sided);

    godot::Node3D *m_root;
    std::map<u16, EntityNode> m_nodes;
    std::map<std::string, godot::Ref<godot::StandardMaterial3D>> m_materials;
};

} // namespace goanna
