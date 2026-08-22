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
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shader.hpp>
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
    // The head stays in the shadow pass through a second, shadow-only copy of
    // the mesh, so turning this off is the only thing that removes the shadow.
    void setShowBody(bool show) { m_show_body = show; }
    // 0..1 swing phase for the first-person arm (dig chop / place bob).
    void setArmSwing(float s) { m_arm_swing = s; }
    // Diffuse-inferred normal strength for mesh surfaces with no authored
    // _n/_s companion; 0 disables it. Mirrors GoannaClient::m_auto_bump.
    void setAutoBump(float strength) { m_auto_bump = strength; }

private:
    struct EntityNode {
        godot::Node3D *root = nullptr;
        godot::Node3D *visual = nullptr;
        godot::Label3D *nametag = nullptr;
        godot::Skeleton3D *skeleton = nullptr;
        // First-person body only: a second, shadow-only copy of the same
        // skinned mesh, posed without the head shrink so the shadow keeps its
        // head. Null for every other entity.
        godot::Skeleton3D *shadow_skeleton = nullptr;
        std::unique_ptr<ModelAnimator> animator;
        std::string arm_bone; // first-person arm, chosen by which side it shows on
        uint32_t visual_version = 0;
        uint32_t anim_version = 0;
        godot::Vector2 anim_range = godot::Vector2(-1, -1); // last applied frame loop
        std::string textures_key;
        float sprite_time = 0;
        int sprite_frame = 0;
        // node light at the entity, see sync(); light_pos is the node last read
        v3s16 light_pos{32767, 32767, 32767};
        float light_sky = 1.0f, light_block = 0.0f;
        bool light_known = false;
    };
    // The bone the first-person swing turns: the arm holding the wield item
    // where the game attaches one, otherwise the arm on the camera's right.
    // Empty while the skeleton has not been stepped and the answer would be a
    // coin toss. Caller holds session.mapLock().
    std::string chooseArmBone(GoannaSession &session, u16 self_id, const EntityNode &en, float yaw) const;
    void rebuildVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    bool buildMeshVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    bool buildItemVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    std::shared_ptr<GodotModel> modelFor(GoannaSession &session, const std::string &name);
    godot::Ref<godot::StandardMaterial3D> materialForTexture(GoannaSession &session,
            const std::string &texture, bool alpha, bool double_sided);
    // Only used for mesh-visual surfaces (buildMeshVisual): looks up LabPBR
    // _n/_s companions (or falls back to auto-bump) for the opaque case and
    // returns a ShaderMaterial on entity.gdshader when either is found,
    // otherwise the same plain material materialForTexture would build.
    // A separate function and cache rather than a mode on materialForTexture
    // because its other callers (sprites, wielditem-as-node) duplicate() the
    // result and call StandardMaterial3D-specific setters on it, which would
    // not compile, let alone make sense, against a ShaderMaterial.
    godot::Ref<godot::Material> materialForMeshTexture(GoannaSession &session,
            const std::string &texture, bool alpha, bool double_sided);

    godot::Node3D *m_root;
    std::map<u16, EntityNode> m_nodes;
    std::map<std::string, godot::Ref<godot::StandardMaterial3D>> m_materials;
    std::map<std::string, godot::Ref<godot::Material>> m_mesh_materials;
    std::map<std::string, std::shared_ptr<GodotModel>> m_models;
    godot::Ref<godot::Shader> m_sh_entity; // res://shaders/entity.gdshader, loaded once
    godot::Ref<godot::Shader> m_sh_entity_scissor; // its alpha scissor variant
    bool m_show_body = true;
    float m_arm_swing = 0.0f;
    float m_auto_bump = 0.35f;
};

} // namespace goanna
