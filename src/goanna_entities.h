// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Godot-side rendering of Goanna's active objects (players, mobs, items).
// Sprites and upright sprites as billboards, cubes as textured boxes, meshes
// through Luanti's own model loaders (goanna_models) with per-buffer textures,
// skinned and animated on a Skeleton3D, nametags as Label3D. Attachments
// follow their parent, at a bone when one is named.

#include <cstdint>
#include <map>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <memory>
#include <string>
#include <vector>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/label3d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/sprite3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "irrlichttypes_bloated.h"
#include "goanna_models.h"
#include "goanna_overlay_companions.h"

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
    void setOverseer(godot::Node3D *parent, const godot::Dictionary &layer);
    int count() const { return (int)m_nodes.size(); }
    // Positions (Godot space) of visible entities, for tests/UI.
    godot::Array positions() const;
    // Up to eight nearby physical actors, at collision-box foot height.
    godot::PackedVector4Array grass_interactors(GoannaSession &session) const;
    // One Dictionary per visible entity: id, name, position, visual, mesh,
    // frame (the frame of animation track 1, as the Lua API numbers tracks,
    // or -1 when it is not playing). Caller holds session.mapLock().
    godot::Array list(GoannaSession &session) const;
    // Read-only animation diagnostic for one entity: the tracks playing on
    // its mesh and the ones the server set, and each joint's local transform
    // from the last step's tracks next to its rest transform. Empty if the
    // entity is unknown. Caller holds session.mapLock().
    godot::Dictionary animation(GoannaSession &session, u16 id) const;
    // Where an object stands and which way it faces, for a particle spawner
    // attached to it: {"transform": Transform3D, "local": bool}, or empty
    // when the object is not known or not drawn.
    godot::Dictionary anchor(GoannaSession &session, u16 id) const;
    // The hands and feet that went into or came out of water since the last
    // call, for wake.gd's stroke splashes: {id, local, pos, limb ("hand" or
    // "foot"), into, speed (nodes a second)}. Emptied by the call.
    godot::Array takeStrokeEvents();
    // Build an item's wield mesh (Luanti's own wieldmesh code) as an
    // ArrayMesh; null if the item has no mesh. out_scale receives the wield
    // scale in Godot units. Caller holds session.mapLock(); main thread.
    godot::Ref<godot::ArrayMesh> buildItemMesh(GoannaSession &session, const ItemStack &item,
            bool check_wield_image, v3f *out_scale, bool relit = false);
    // First-person body: render the local player's model (mesh visuals only),
    // pinned to the predicted player with its head shrunk out of the camera.
    // The head stays in the shadow pass through a second, shadow-only copy of
    // the mesh, so turning this off is the only thing that removes the shadow.
    void setShowBody(bool show) { m_show_body = show; }
    // Third person camera (main.gd): the whole body, head and all, is drawn
    // whatever show_body says, as the vanilla client draws it.
    void setThirdPerson(bool on) { m_third_person = on; }
    // 0..1 swing phase for the first-person arm (dig chop / place bob).
    void setArmSwing(float s) { m_arm_swing = s; }
    // Diffuse-inferred normal strength for mesh surfaces with no authored
    // _n/_s companion; 0 disables it. Mirrors GoannaClient::m_auto_bump.
    // A change drops the cached mesh materials, which carry the inference
    // they were built with, so entities built from then on take the new
    // strength.
    void setAutoBump(float strength) {
        if (strength == m_auto_bump)
            return;
        m_auto_bump = strength;
        m_mesh_materials.clear();
    }
    // The parallax march through an authored _n's height on mesh entities,
    // 0 to 1: GoannaClient's "parallax" material strength (the Lowest
    // graphics profile's mat_parallax 0), so mobs follow the same setting as the
    // nodes. Applied to every material already built. GOANNA_ENTITY_PARALLAX
    // scales it, for an entities only A/B.
    void setParallax(float strength);
    // The anisotropic highlight on hair texels (_s green byte 12, see
    // direct_light.gdshaderinc), 0 to 1: GoannaClient's "hair" material
    // strength. GOANNA_HAIR_ANISO scales it, 0 for an entities only A/B.
    void setHair(float strength);
    // Hair drawn by the shader on the same texels (hair_strands.gdshaderinc),
    // 0 to 1: GoannaClient's "hair_shader" material strength.
    // GOANNA_HAIR_SHADER scales it, 0 for an entities only A/B.
    void setHairShader(float strength);
    // A material strength the entity shaders share with the nodes by name,
    // with no scaling of its own: "micro_shadow" (direct_light.gdshaderinc)
    // and "parallax_short" (entity_common.gdshaderinc). Applied to every
    // material already built and to those built later, as <name>_strength.
    void setChannel(const std::string &name, float strength);
    // A burning entity's flame (an upright sprite named for one) on the
    // flame material, as GoannaClient::set_flame_material. The sprite's
    // mesh is rebuilt at its next frame, so the switch takes within one.
    void setFlameMaterial(bool on) { m_flame_material = on; }
    // The formspec model[] element (upstream's GUIScene): a standalone copy of
    // a media mesh with its textures applied, posed at the first frame of the
    // loop, for the UI to hang under a SubViewport. Unshaded, alpha tested at
    // 0.5 and double sided, which is how upstream's GUI scene draws it, so it
    // needs no lights of its own. out_aabb receives the mesh bounds, which the
    // caller needs to centre and frame it. Null if the media has not arrived
    // or holds no geometry; the caller owns the returned node. A non-zero
    // speed on an animated model registers the preview for stepping in sync().
    // Caller holds session.mapLock(); main thread.
    godot::Node3D *buildModelPreview(GoannaSession &session, const std::string &mesh,
            const std::vector<std::string> &textures, float frame_begin, float frame_end,
            float speed, godot::AABB *out_aabb);

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
        // For the water strokes (goanna_limbs.h): where the body was last
        // sync and how fast it is going across, nodes a second, eased.
        v3f limb_last_pos;
        bool limb_have_pos = false;
        float limb_speed = 0.0f;
        int water_pose = 0;
        // Seconds since the body last had a water pose: a swimmer bobbing
        // at the surface leaves the water for a moment each bob.
        float water_pose_age = 1e9f;
        bool in_water = false;
        // How the body is moving, for the movement poses: its velocity
        // across and up (eased, nodes a second), speed last sync, and the
        // facing last sync and how fast it is turning.
        v3f motion_vel;
        float motion_speed = 0.0f, motion_accel = 0.0f;
        float motion_yaw = 0.0f, motion_yaw_rate = 0.0f;
        bool motion_have = false;
        // Each limb end (hand or foot) last sync: whether it was in water,
        // and where, for the stroke events.
        std::vector<char> limb_wet;
        std::vector<godot::Vector3> limb_last_end;
        uint32_t visual_version = 0;
        std::string textures_key;
        float sprite_time = 0;
        int sprite_frame = 0;
        // The sheet cell an upright sprite's mesh was last built for, as
        // row * spritediv.X + column; -1 before the first build.
        int sprite_cell = -1;
        // node light at the entity, see sync(); light_pos is the node last read
        v3s16 light_pos{32767, 32767, 32767};
        float light_sky = 1.0f, light_block = 0.0f;
        bool light_known = false;
        // A wall plate (goanna_upright_sprite.h): an upright sprite drawn on
        // the node face it lies against and lit per vertex from the nodes
        // in front of that face. wall_key is the map revisions its light was
        // read at; wall_check counts down to the next look.
        bool wall_plate = false;
        int wall_side = 0; // the quad seen: 0 front, 1 back
        uint64_t wall_key = 0;
        float wall_check = 0.0f;
    };
    // The bone the first-person swing turns: the arm holding the wield item
    // where the game attaches one, otherwise the arm on the camera's right.
    // Empty while the skeleton has not been stepped and the answer would be a
    // coin toss. Caller holds session.mapLock().
    std::string chooseArmBone(GoannaSession &session, u16 self_id, const EntityNode &en, float yaw) const;
    void rebuildVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    // source receives the Irrlicht mesh the visual was built from.
    bool buildMeshVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en,
            scene::IAnimatedMesh **source);
    bool buildItemVisual(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en);
    // An upright sprite's two quads (goanna_upright_sprite.h) showing one
    // cell of the sheet, each side through the entity shader with its own
    // texture.
    // With `wall`, the root's transform already on the face: the front quad
    // is cut at node boundaries and every vertex carries the wall's light
    // (CUSTOM1), as the node mesher gives the wall beside it.
    godot::Ref<godot::ArrayMesh> buildUprightSpriteMesh(GoannaSession &session,
            GoannaActiveObject &obj, int col, int row, const godot::Transform3D *wall = nullptr,
            int wall_side = 0);
    // Whether an upright sprite is a wall plate, its position put on the
    // face, and its mesh rebuilt when its light changes. Every sync.
    void updateWallPlate(GoannaSession &session, GoannaActiveObject &obj, EntityNode &en,
            float dt);
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
    // item is whether the texture is an item's (held or dropped) rather than
    // a mob or player skin; only an item takes a material class guessed
    // from its name. faces, from the model the texture is drawn on
    // (GodotModel::surface_faces), lets the relief be measured face by face;
    // the material is cached per texture, so the first model to ask decides.
    godot::Ref<godot::Material> materialForMeshTexture(GoannaSession &session,
            const std::string &texture, bool alpha, bool double_sided, bool item = false,
            const std::vector<godot::Rect2> *faces = nullptr);
    // The LabPBR companion ("_n" or "_s") a pack or the server supplies for
    // one image, or null.
    godot::Ref<godot::Texture2D> companionTexture(GoannaSession &session,
            const std::string &image, const char *suffix);
    // The companion for an overlay stack, composited layer by layer
    // (goanna_overlay_companions.h); null when no layer has one. Cached per
    // texture string, main thread only.
    godot::Ref<godot::Texture2D> compositeCompanion(GoannaSession &session,
            const std::string &texture, const std::vector<OverlayLayer> &layers,
            const char *suffix);
    // flame.gdshader over a whole sprite sheet, the cell taken from the
    // mesh's CUSTOM0 rectangle (docs/fire-material.md). Null if the texture
    // has not arrived.
    godot::Ref<godot::Material> flameSpriteMaterial(GoannaSession &session,
            const std::string &texture);
    // Unshaded, alpha tested, double sided material for a model[] preview
    // surface, matching GUIScene::setTexture.
    godot::Ref<godot::StandardMaterial3D> materialForPreviewTexture(GoannaSession &session,
            const std::string &texture);
    // Advance every live model[] preview that asked for animation, and forget
    // the ones whose skeleton has been freed with its formspec.
    void stepModelPreviews(float dt);

    godot::Node3D *m_root;
    godot::Node3D *m_overseer_root = nullptr;
    godot::Dictionary m_overseer_layer;
    bool overseerVisible(GoannaSession &session, GoannaActiveObject &object) const;
    std::map<u16, EntityNode> m_nodes;
    std::map<std::string, godot::Ref<godot::StandardMaterial3D>> m_materials;
    std::map<std::string, godot::Ref<godot::Material>> m_mesh_materials;
    std::map<std::string, godot::Ref<godot::Texture2D>> m_composite_companions;
    std::map<std::string, std::shared_ptr<GodotModel>> m_models;
    // Animated model[] previews, keyed by their skeleton's instance id so a
    // formspec that has been freed can be recognised without a dangling
    // pointer. The UI owns the nodes; this owns only the animation state.
    struct Preview {
        std::unique_ptr<ModelAnimator> animator;
        scene::AnimSpec anim; // GUIScene's: track 0 only
    };
    std::map<uint64_t, Preview> m_previews;
    godot::Ref<godot::Shader> m_sh_entity; // res://shaders/entity.gdshader, loaded once
    godot::Ref<godot::Shader> m_sh_entity_scissor; // its alpha scissor variant
    godot::Ref<godot::Shader> m_sh_entity_double; // the cull_disabled variants
    godot::Ref<godot::Shader> m_sh_entity_double_scissor;
    godot::Ref<godot::Shader> m_sh_diamond;
    godot::Ref<godot::Shader> m_sh_diamond_double;
    godot::Ref<godot::Shader> m_sh_flame, m_sh_flame_glow;
    std::map<std::string, godot::Ref<godot::Material>> m_flame_materials;
    bool m_flame_material = true;
    godot::Array m_stroke_events;
    bool m_show_body = true;
    bool m_third_person = false;
    float m_arm_swing = 0.0f;
    float m_auto_bump = 0.35f;
    float m_parallax = 1.0f;
    float m_hair = 0.0f;
    float m_hair_shader = 0.0f;
    std::map<std::string, float> m_channels; // see setChannel
};

} // namespace goanna
