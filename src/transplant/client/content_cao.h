// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Transplanted from luanti/src/client/content_cao.h (GenericCAO).
// Goanna changes 2026-09, against Luanti 5.17.0: see content_cao.cpp.

#pragma once

// Goanna's client-side active object: the state half of Luanti's GenericCAO
// (client/content_cao.cpp), transplanted without Irrlicht scene nodes.
// Parses init data and AO_CMD_* messages exactly as GenericCAO does, keeps
// position/rotation interpolation (SmoothTranslator), animation, bone
// overrides, attachment and texture modifiers, and exposes a snapshot for
// the Godot side to render.

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

#include <AnimSpec.h>

#include "activeobject.h"
#include "constants.h"
#include "irrlichttypes_bloated.h"
#include "itemgroup.h"
#include "object_properties.h"

class Map;
class IGameDef;
class LocalPlayer;
namespace scene {
class IAnimatedMesh;
}

namespace goanna {

// Copied from luanti/src/client/content_cao.h (LGPL-2.1-or-later).
template<typename T>
struct SmoothTranslator {
    T val_old;
    T val_current;
    T val_target;
    f32 anim_time = 0;
    f32 anim_time_counter = 0;
    bool aim_is_end = true;
    void init(T current);
    void update(T new_target, bool is_end_position = false, float update_interval = -1);
    void translate(f32 dtime);
};
struct SmoothTranslatorWrappedv3f : SmoothTranslator<v3f> {
    void translate(f32 dtime);
};

// Goanna: stands in for the scene::AnimatedMeshSceneNode GenericCAO keeps in
// m_animated_meshnode, as far as animation goes: the mesh the renderer built
// the object's visual from, which track ids are resolved against, and the
// animation playing on it, which the renderer advances and poses the joints
// from (AnimatedMeshSceneNode::OnAnimate). Main thread only.
class AnimatedMeshNodeStandIn {
public:
    explicit AnimatedMeshNodeStandIn(scene::IAnimatedMesh *mesh) : m_mesh(mesh) {}
    scene::IAnimatedMesh *getMesh() const { return m_mesh; }
    scene::AnimSpec &getAnimation() { return m_anim; }
    const scene::AnimSpec &getAnimation() const { return m_anim; }

private:
    scene::IAnimatedMesh *m_mesh;
    scene::AnimSpec m_anim;
};

class GoannaActiveObject {
public:
    GoannaActiveObject(u16 id, u8 type);

    // GenericCAO::processInitData / processMessage, transplanted.
    void initialize(const std::string &data, LocalPlayer *local_player);
    void processMessage(const std::string &data, LocalPlayer *local_player);

    // Motion part of GenericCAO::step: attached objects follow their parent
    // (resolved by the caller), physical ones collide with the map, others
    // integrate velocity/acceleration; interpolation advances.
    void step(float dtime, Map *map, IGameDef *gamedef, const GoannaActiveObject *parent);

    // --- state (BS units, Luanti space, as in GenericCAO) ---
    u16 id() const { return m_id; }
    u8 type() const { return m_type; }
    const std::string &name() const { return m_name; }
    bool isPlayer() const { return m_is_player; }
    bool isLocalPlayer() const { return m_is_local_player; }
    bool isVisible() const { return m_is_visible && m_prop.is_visible; }
    u16 hp() const { return m_hp; }
    v3f position() const { return m_pos_translator.val_current; }
    v3f rotation() const { return m_rot_translator.val_current; }
    v3f rawPosition() const { return m_position; }
    const ObjectProperties &props() const { return m_prop; }
    const std::string &textureModifier() const { return m_current_texture_modifier; }
    // Skeletal animation, by track (Luanti 5.17). processMessage runs on the
    // session thread and has no mesh, so it queues AO_CMD_SET_ANIMATION,
    // AO_CMD_SET_ANIMATION_SPEED and AO_CMD_STOP_ANIMATION; everything below
    // runs on the main thread, under the session's map lock, from the
    // renderer, which has the mesh.
    //
    // What GenericCAO::addToScene and the visual expiry in GenericCAO::step do
    // for animation. The renderer calls this each time it builds the visual:
    // with the mesh for a mesh visual, null for any other. The first call
    // stands in for addToScene. The mesh must outlive the object.
    void setAnimatedMesh(scene::IAnimatedMesh *mesh);
    bool addedToScene() const { return m_added_to_scene; }
    // Applies the queued animation commands, now that the tracks can be
    // resolved. Does nothing before the first setAnimatedMesh.
    void applyDeferredAnimation(LocalPlayer *local_player);
    // AnimatedMeshSceneNode::getAnimation: what is playing on the mesh. Null
    // without a mesh.
    scene::AnimSpec *meshAnimation()
    { return m_animated_meshnode ? &m_animated_meshnode->getAnimation() : nullptr; }
    const scene::AnimSpec *meshAnimation() const
    { return m_animated_meshnode ? &m_animated_meshnode->getAnimation() : nullptr; }
    // The animation for all tracks as specified by the server.
    const scene::AnimSpec &serverAnimation() const { return m_animation; }
    size_t deferredAnimationCount() const { return deferred_animation_cmds.size(); }
    // sprite animation
    v2s16 spriteBasepos() const { return m_tx_basepos; }
    int spriteFrames() const { return m_anim_num_frames; }
    float spriteFrameLength() const { return m_anim_framelength; }
    bool spriteSelectByYawPitch() const { return m_tx_select_horiz_by_yawpitch; }
    // attachment
    u16 attachmentParent() const { return m_attachment_parent_id; }
    const std::string &attachmentBone() const { return m_attachment_bone; }
    v3f attachmentPosition() const { return m_attachment_position; }
    v3f attachmentRotation() const { return m_attachment_rotation; }
    bool attachmentForceVisible() const { return m_force_visible; }
    const std::map<std::string, BoneOverride> &boneOverrides() const { return m_bone_override; }
    // GenericCAO::getGroups / isImmortal, for client-side fall damage.
    const ItemGroupList &armorGroups() const { return m_armor_groups; }
    bool isImmortal() const { return itemgroup_get(m_armor_groups, "immortal") != 0; }
    // The renderer advances dtime_passed and drops finished identity
    // overrides, as GenericCAO's animate callback does.
    std::map<std::string, BoneOverride> &boneOverridesMut() { return m_bone_override; }
    // Bumped whenever something the visual depends on changed (properties,
    // textures, texture modifier, sprite, mesh).
    uint32_t visualVersion() const { return m_visual_version; }
    uint32_t animVersion() const { return m_anim_version; }

private:
    void setAttachment(u16 parent_id, const std::string &bone, v3f position, v3f rotation, bool force_visible);

    // An animation command processMessage read and could not apply yet.
    struct DeferredAnimationCmd {
        enum Kind : u8 { SET, SPEED, STOP } kind;
        scene::TrackId track_id;
        scene::TrackAnimSpec anim; // SET: the whole spec; SPEED: its fps
    };
    void deferAnimationCmd(DeferredAnimationCmd &&cmd);
    // GenericCAO's, from luanti/src/client/content_cao.cpp; see the note there.
    void applyTrackAnimation(scene::TrackId &&track_id, scene::TrackAnimSpec anim,
            LocalPlayer *local_player);
    void applyAnimationSpeed(const scene::TrackId &track_id, f32 new_fps);
    void stopTrackAnimation(const scene::TrackId &track_id);
    void updateAnimation(u16 track_nr);
    std::optional<u16> resolveTrackId(const scene::TrackId &id, bool lax = false);

    u16 m_id;
    u8 m_type;
    std::string m_name;
    bool m_is_player = false;
    bool m_is_local_player = false;
    bool m_is_visible = true;
    u16 m_hp = 1;
    v3f m_position, m_velocity, m_acceleration, m_rotation;
    SmoothTranslator<v3f> m_pos_translator;
    SmoothTranslatorWrappedv3f m_rot_translator;
    ObjectProperties m_prop;
    aabb3f m_selection_box = aabb3f(-0.5f * BS, -0.5f * BS, -0.5f * BS, 0.5f * BS, 0.5f * BS, 0.5f * BS);
    std::string m_current_texture_modifier;
    // sprite
    v2s16 m_tx_basepos;
    bool m_initial_tx_basepos_set = false;
    bool m_tx_select_horiz_by_yawpitch = false;
    int m_anim_num_frames = 1;
    float m_anim_framelength = 0.2f;
    // animation
    /// The animation for all tracks as specified by the server.
    /// This is usually what is used, unless overridden by a local player animation.
    scene::AnimSpec m_animation;
    /// For the local player CAO, animations may be overridden by the client
    /// based on the in-game state of the local player (e.g. walking, digging, idling).
    /// See also LocalPlayerAnimation (player.h), LocalPlayer::last_animation (localplayer.h).
    bool m_local_player_animation = false;
    // Upstream's deferred_set_animation_cmds, holding every animation
    // command rather than only set_animation before addToScene.
    std::vector<DeferredAnimationCmd> deferred_animation_cmds;
    std::unique_ptr<AnimatedMeshNodeStandIn> m_animated_meshnode;
    bool m_added_to_scene = false; // stands in for m_smgr being set
    std::map<std::string, BoneOverride> m_bone_override;
    // attachment
    u16 m_attachment_parent_id = 0;
    std::string m_attachment_bone;
    v3f m_attachment_position, m_attachment_rotation;
    bool m_force_visible = false;
    std::unordered_set<u16> m_attachment_child_ids;
    ItemGroupList m_armor_groups;
    uint32_t m_visual_version = 1;
    uint32_t m_anim_version = 1;
};

} // namespace goanna
