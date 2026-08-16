// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// Transplanted from luanti/src/client/content_cao.h (GenericCAO).
// Goanna changes 2026-08, against Luanti 5.16.1: see content_cao.cpp.

#pragma once

// Goanna's client-side active object: the state half of Luanti's GenericCAO
// (client/content_cao.cpp), transplanted without Irrlicht scene nodes.
// Parses init data and AO_CMD_* messages exactly as GenericCAO does, keeps
// position/rotation interpolation (SmoothTranslator), animation, bone
// overrides, attachment and texture modifiers, and exposes a snapshot for
// the Godot side to render.

#include <cstdint>
#include <map>
#include <string>
#include <unordered_set>
#include <vector>

#include "activeobject.h"
#include "constants.h"
#include "irrlichttypes_bloated.h"
#include "itemgroup.h"
#include "object_properties.h"

class Map;
class IGameDef;
class LocalPlayer;

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
    // animation
    v2f animRange() const { return m_animation_range; }
    float animSpeed() const { return m_animation_speed; }
    float animBlend() const { return m_animation_blend; }
    bool animLoop() const { return m_animation_loop; }
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
    // The renderer advances dtime_passed and drops finished identity
    // overrides, as GenericCAO's animate callback does.
    std::map<std::string, BoneOverride> &boneOverridesMut() { return m_bone_override; }
    // Bumped whenever something the visual depends on changed (properties,
    // textures, texture modifier, sprite, mesh).
    uint32_t visualVersion() const { return m_visual_version; }
    uint32_t animVersion() const { return m_anim_version; }

private:
    void setAttachment(u16 parent_id, const std::string &bone, v3f position, v3f rotation, bool force_visible);

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
    v2f m_animation_range;
    float m_animation_speed = 15.0f;
    float m_animation_blend = 0.0f;
    bool m_animation_loop = true;
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
