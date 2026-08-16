// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Godot-side rendering of Goanna's active objects (players, mobs, items).
// Sprites and upright sprites as billboards, cubes as textured boxes, meshes
// through Luanti's own model loaders (goanna_models) with per-buffer textures,
// skinned and animated on a Skeleton3D, nametags as Label3D. Attachments
// follow their parent, at a bone when one is named.

#include <map>
#include <memory>
#include <string>

#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/sprite3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

#include "irrlichttypes_bloated.h"
#include "goanna_models.h"

struct ItemStack;

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
    // One Dictionary per visible entity: id, name, position, visual, mesh,
    // frame (animation frame, or -1). Caller holds session.mapLock().
    godot::Array list(GoannaSession &session) const;
    // Build an item's wield mesh (Luanti's own wieldmesh code) as an
    // ArrayMesh; null if the item has no mesh. out_scale receives the wield
    // scale in Godot units. Caller holds session.mapLock(); main thread.
    godot::Ref<godot::ArrayMesh> buildItemMesh(GoannaSession &session, const ItemStack &item,
            bool check_wield_image, v3f *out_scale);
    // First-person body: render the local player's model (mesh visuals only),
    // pinned to the predicted player with its head shrunk out of the camera.
    void setShowBody(bool show) { m_show_body = show; }

private:
    struct EntityNode {
        godot::Node3D *root = nullptr;
        godot::Node3D *visual = nullptr;
        godot::Label3D *nametag = nullptr;
        godot::Skeleton3D *skeleton = nullptr;
        std::unique_ptr<ModelAnimator> animator;
        uint32_t visual_version = 0;
        uint32_t anim_version = 0;
        godot::Vector2 anim_range = godot::Vector2(-1, -1); // last applied frame loop
        std::string textures_key;
        float sprite_time = 0;
        int sprite_frame = 0;
    };
    void rebuildVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    bool buildMeshVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    bool buildItemVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    std::shared_ptr<GodotModel> modelFor(GoannaSession &session, const std::string &name);
    godot::Ref<godot::StandardMaterial3D> materialForTexture(GoannaSession &session,
            const std::string &texture, bool alpha, bool double_sided);

    godot::Node3D *m_root;
    std::map<u16, EntityNode> m_nodes;
    std::map<std::string, godot::Ref<godot::StandardMaterial3D>> m_materials;
    std::map<std::string, std::shared_ptr<GodotModel>> m_models;
    bool m_show_body = true;
};

} // namespace goanna
