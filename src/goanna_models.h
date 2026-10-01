// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Models: Luanti's own model loaders (Irrlicht's B3D, X, OBJ and glTF
// readers, compiled CPU-only from the submodule) behind a stub scene manager,
// a cache of loaded meshes by media name, conversion of an Irrlicht mesh to a
// Godot ArrayMesh with bones and weights, and a per-instance animator that
// drives SkinnedMesh's own keyframe evaluation (through goanna_animation)
// into skeleton bone poses.
//
// Coordinates: mesh units are Luanti world units (BS = 10 per node), z is
// mirrored into Godot's right-handed space, index order is kept.

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "irrlichttypes_bloated.h"
#include <AnimSpec.h>
#include <IAnimatedMesh.h>
#include <SkinnedMesh.h>

#include "goanna_animation.h"
#include "goanna_limbs.h"

struct BoneOverride;
namespace scene {
class IMeshManipulator;
class IMeshLoader;
}

namespace goanna {

// Bytes of a media file by name; false if unknown.
using MediaGetter = std::function<bool(const std::string &name, std::string &out)>;

// The Irrlicht loaders and the mesh manipulator, without a scene graph.
class ModelLoader {
public:
    ModelLoader();
    ~ModelLoader();
    // Loads a model from memory; the returned mesh is grabbed for the caller.
    scene::IAnimatedMesh *load(const std::string &name, const std::string &bytes);
    scene::IMeshManipulator *manipulator();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

// Client::getMesh semantics: cached meshes are shared (and grabbed for the
// caller); uncached ones are freshly read so callers may mutate them.
class ModelCache {
public:
    explicit ModelCache(MediaGetter media);
    ~ModelCache();
    scene::IAnimatedMesh *getMesh(const std::string &name, bool cache);
    scene::IMeshManipulator *manipulator() { return m_loader.manipulator(); }

private:
    ModelLoader m_loader;
    MediaGetter m_media;
    std::map<std::string, scene::IAnimatedMesh *> m_cache;
};

// An Irrlicht mesh converted for Godot.
struct GodotModel {
    godot::Ref<godot::ArrayMesh> mesh;
    std::vector<u32> texture_slots; // per surface: index into ObjectProperties::textures
    // The Irrlicht mesh this was built from (grabbed), which an active
    // object resolves its animation track names against.
    scene::IAnimatedMesh *source = nullptr;
    // Skinned meshes only: the SkinnedMesh (grabbed) and the skeleton layout.
    // Bones 0..joint_count-1 take skin matrices (global * inverse bind);
    // joints with rigidly attached buffers get an extra bone taking the
    // global matrix, at attached_bone[joint] (or -1).
    scene::SkinnedMesh *skinned = nullptr;
    int joint_count = 0;
    std::vector<int> attached_bone;
    int identity_bone = -1; // for unweighted, unattached vertices, or -1
    // Limbs cut at the knee and elbow (goanna_limbs.h), each with two bones
    // of Goanna's own past the joints and attached bones.
    std::vector<LimbBend> limbs;
    int bone_count = 0;
    bool animated = false;
    ~GodotModel();
};

// Builds a Godot model from an Irrlicht mesh (does not take a reference).
std::shared_ptr<GodotModel> buildGodotModel(scene::IAnimatedMesh *mesh);

// Per-instance animation state for a skinned GodotModel: what Irrlicht's
// AnimatedMeshSceneNode does each frame (advance the tracks, pose the joints
// from them in priority order, blend from last frame's pose), Luanti's bone
// overrides, Goanna's first-person posing, and the resulting bone poses. The
// tracks themselves belong to the caller: an active object's, or a model[]
// preview's.
class ModelAnimator {
public:
    explicit ModelAnimator(std::shared_ptr<GodotModel> model);
    // AnimatedMeshSceneNode::OnAnimate: advances anim by dt seconds, poses
    // the joints from its tracks, applies overrides (their dtime_passed
    // advances, finished identity overrides are erased) and writes bone poses.
    // With a shrink joint set, unshrunk (when given) receives the same pose
    // without the shrink, for the shadow-only copy of the model.
    void step(float dt, scene::AnimSpec &anim, std::map<std::string, BoneOverride> &overrides,
            godot::Skeleton3D *skeleton, godot::Skeleton3D *unshrunk = nullptr);
    // The joints' local transforms the last step's tracks produced, before
    // bone overrides and Goanna's first-person posing (upstream's
    // PreTransSaves, which the next blend starts from). Nothing for a joint
    // that keeps a matrix; empty before the first step.
    const OldJointTransforms &animatedLocals() const { return m_old_transforms; }
    // A rebuilt visual of the same model carries on from the pose the old
    // one last showed, so a blend in progress is not cut short. Upstream
    // does not rebuild its scene node for the changes Goanna rebuilds for.
    void inheritPose(const ModelAnimator &previous);
    const GodotModel &model() const { return *m_model; }
    // Global transform (mesh space, Godot handedness) of a named joint after
    // the last step; false if unknown.
    bool jointGlobal(const std::string &name, godot::Transform3D &out) const;
    // Shrink a named joint (and everything attached to it) to near zero each
    // step; used to keep the local player's head out of the first-person
    // camera. No effect if the model has no such joint.
    void setShrinkJoint(const std::string &name);
    // Off in third person, where the whole head should be seen.
    void setShrinkEnabled(bool on) { m_shrink_enabled = on; }
    // Turn a named joint each step, in its parent's space, on top of the
    // animation and any server bone override: the first-person arm swing.
    // Relative rather than absolute because the model may bake a half turn
    // into the joint's rest (Mineclonia's character does, as a scale flip),
    // which an absolute pose silently mirrors.
    // freeze_arm holds the arm subtree and ancestors at their reference frame,
    // before applying server aiming and the local stroke.
    void setJointRotationOverride(const std::string &name, const v3f &euler_deg, bool freeze_arm = false);
    bool hasJoint(const std::string &name) const;

    // What the body is doing in the water (goanna_limbs.h), and how fast it
    // is going, nodes a second: the strokes ease in and out over a quarter
    // of a second.
    void setWaterPose(WaterPose pose, float speed);
    // How the body is moving this frame (goanna_limbs.h, BodyMotion), for
    // landing, falling, stepping up and leaning into starts, stops and
    // turns.
    void setMotion(const BodyMotion &motion) { m_motion = motion; }
    // The landing crouch now, 0 to 1, and how far the body is lowered for
    // it, mesh units; the lean forward and the bank left now, degrees.
    float landing() const { return m_land_amt; }
    float drop() const { return m_drop; }
    float lean() const { return m_lean; }
    float bank() const { return m_bank; }
    // Whether the last step had the body lying down (the game's swim pose):
    // its up axis nearer level than upright. False for a model with no Body.
    bool bodyLying() const { return m_body_lying; }
    // The limbs that bend, and where each one's far end (hand or foot) is
    // after the last step, mesh space in Godot's handedness.
    size_t limbCount() const { return m_model->limbs.size(); }
    const LimbBend &limb(size_t i) const { return m_model->limbs[i]; }
    bool limbEnd(size_t i, godot::Vector3 &out) const;
    // The local player's own body seen from its eye: its arms swing in front
    // of the lens, so their elbows keep only FIRST_PERSON_ELBOW of the
    // walking bend, or the hand and what it holds rise into the view with
    // every step. Third person keeps the whole bend.
    void setFirstPerson(bool on) { m_first_person = on; }
    static constexpr float FIRST_PERSON_ELBOW = 0.25f;
    // Each limb's bend after the last step, degrees, for tests and status.
    float limbBend(size_t i) const { return i < m_bend.size() ? m_bend[i] : 0.0f; }

private:
    void poseLimbs(float dt, JointTransforms &locals, const std::map<std::string, BoneOverride> &overrides);
    void updateMotion(float dt);
    LimbAngles motionAngles(size_t limb) const;
    void measureLimbs(float dt, const std::vector<core::matrix4> &skin,
            const std::map<std::string, BoneOverride> &overrides);
    void probeLimbSigns();
    // A joint's global transform with the bend of the limb it hangs below
    // (a held item's Wield_Item under the forearm), or as it is.
    godot::Transform3D bentGlobal(size_t joint) const;
    std::shared_ptr<GodotModel> m_model;
    OldJointTransforms m_old_transforms;
    std::vector<core::matrix4> m_globals;
    std::optional<u32> m_shrink_joint;
    bool m_shrink_enabled = true;
    std::optional<u32> m_rot_override_joint;
    std::string m_rot_override_name;
    v3f m_rot_override_euler;
    bool m_freeze_arm = false;
    JointTransforms m_arm_reference;
    // Limbs: each one's bend now, its swing last step and how fast it is
    // changing, eased; which way a turn about the joint's own x and z axes
    // moves its end (forward and outward); the stroke clock and how much of
    // each water pose is showing.
    std::vector<float> m_bend, m_eased_bend, m_swing, m_swing_rate;
    std::vector<float> m_pitch_sign, m_spread_sign;
    // Per joint: the limb whose lower half it hangs from (its rest position
    // below that limb's cut, under its joint), or -1.
    std::vector<int> m_lower_limb;
    bool m_have_swing = false;
    bool m_first_person = false;
    std::optional<u32> m_body_joint;
    bool m_body_lying = false;
    std::vector<core::matrix4> m_skin;
    WaterPose m_water = WaterPose::None;
    float m_water_speed = 0.0f;
    float m_pose_w[kPoseCount] = {};
    // Movement: what the renderer last said, and what follows from it.
    BodyMotion m_motion;
    float m_clock = 0.0f;
    float m_air_time = 0.0f, m_fall_peak = 0.0f, m_fall_w = 0.0f;
    float m_land = 0.0f, m_land_amt = 0.0f, m_drop = 0.0f;
    float m_step = 0.0f;
    int m_step_leg = -1;
    float m_prev_y = 0.0f;
    bool m_prev_grounded = true, m_have_y = false;
    float m_lean = 0.0f, m_bank = 0.0f;
    // The root joint, which the whole body leans and drops by, and which way
    // a turn about its x and z axes leans the body forward and left; a
    // leg's thigh and shin, for how far a crouch lowers the body.
    std::optional<u32> m_root_joint;
    float m_lean_sign = 1.0f, m_bank_sign = 1.0f;
    float m_leg_upper = 0.0f, m_leg_lower = 0.0f;
    float m_stroke_phase = 0.0f;
};

// Irrlicht matrix (row vectors, left-handed) to a Godot transform, z mirrored.
godot::Transform3D toGodotTransform(const core::matrix4 &m);

} // namespace goanna
