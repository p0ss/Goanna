// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Models: Luanti's own model loaders (Irrlicht's B3D, X, OBJ and glTF
// readers, compiled CPU-only from the submodule) behind a stub scene manager,
// a cache of loaded meshes by media name, conversion of an Irrlicht mesh to a
// Godot ArrayMesh with bones and weights, and a per-instance animator that
// drives SkinnedMesh's own keyframe evaluation (through goanna_animation)
// and the jiggle bones (goanna_jiggle) into skeleton bone poses.
//
// Coordinates: mesh units are Luanti world units (BS = 10 per node), z is
// mirrored into Godot's right-handed space, index order is kept.
//
// Threads: main thread only. The session owns one ModelCache (models()), and
// everything that loads a model runs on the main thread: node visuals for
// mesh nodes in GoannaSession::prepareContentIfReady, wield and item meshes,
// item icons, and EntityRenderer. None of these types has a lock, so a model
// must not be loaded from the session thread or a mesh worker. A ModelAnimator
// belongs to one entity or model[] preview and is stepped from
// EntityRenderer::sync. Main types: ModelLoader, ModelCache, GodotModel and
// ModelAnimator.

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "irrlichttypes_bloated.h"
#include <AnimSpec.h>
#include <IAnimatedMesh.h>
#include <SkinnedMesh.h>

#include "goanna_animation.h"
#include "goanna_jiggle.h"
#include "goanna_limbs.h"

struct BoneOverride;
namespace scene {
class IMeshManipulator;
class IMeshLoader;
}

namespace goanna {

struct StrokeFamily;

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
    // The node extras of a glTF model this cache has read (goanna_jiggle.h),
    // or null for one with none or not yet read.
    const ModelExtras *extras(const std::string &name) const;

private:
    // A model's stroke evaluator, from its extras and the family file they
    // name (each family read once).
    void buildStrokes(const std::string &name, ModelExtras &extras);
    ModelLoader m_loader;
    MediaGetter m_media;
    std::map<std::string, scene::IAnimatedMesh *> m_cache;
    std::map<std::string, ModelExtras> m_extras;
    std::map<std::string, std::shared_ptr<const StrokeFamily>> m_stroke_families;
};

// An Irrlicht mesh converted for Godot.
struct GodotModel {
    godot::Ref<godot::ArrayMesh> mesh;
    std::vector<u32> texture_slots; // per surface: index into ObjectProperties::textures
    // Per surface: the UV rectangle of each face (a set of triangles joined
    // by shared vertices), each once. The same rectangles go to the mesh in
    // CUSTOM0 for the parallax march; these tell the relief measure which
    // texels of a skin are one face (EntityRenderer::materialForMeshTexture).
    std::vector<std::vector<godot::Rect2>> surface_faces;
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
    // Animated models only: the jiggle bones and collider capsules
    // (goanna_jiggle.h). Empty for most models.
    JiggleRig jiggle;
    // Animated models only: a stroke evaluator (goanna_strokes.h) and the
    // bone whose override carries the server's stroke state, for a model
    // whose file declares a stroke plan. Null for most models.
    std::shared_ptr<const StrokeEvaluator> strokes;
    std::string stroke_state;
    ~GodotModel();
};

// Builds a Godot model from an Irrlicht mesh (does not take a reference),
// with the jiggle marks of its file, if it has any.
std::shared_ptr<GodotModel> buildGodotModel(scene::IAnimatedMesh *mesh, const ModelExtras *extras = nullptr);

// Where a model stands this frame, for fitting its feet to the ground
// (ModelAnimator::setGround): its mesh-to-world transform (Godot world,
// nodes), whether it is on the ground, and the highest walkable surface
// under a point (Luanti world nodes, x and z) between two heights.
struct GroundFrame {
    bool known = false;
    bool grounded = true;
    godot::Transform3D mesh_to_world;
    std::function<std::optional<float>(float x, float z, float top, float bottom)> floor;
};

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
    // advances, finished identity overrides are erased), swings the jiggle
    // bones (setJiggleFrame) and writes bone poses.
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
    // Models with a stroke plan (GodotModel::strokes) fit their feet to the
    // ground under them: each foot is lifted or lowered to the surface under
    // it, the body lowered for the lower foot, the leg bent to suit. The
    // renderer says where the model stands each frame.
    bool fitsFeet() const { return m_model->strokes != nullptr; }
    void setGround(GroundFrame frame) { m_ground = std::move(frame); }
    // The lift of each fitted foot and the body's drop after the last step,
    // nodes, for tests and status.
    size_t fittedFeet() const { return m_feet.size(); }
    float footLift(size_t i) const { return i < m_feet.size() ? m_feet[i].lift : 0.0f; }
    float bodyDrop() const { return m_body_drop; }
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

    // Jiggle bones (goanna_jiggle.h). Whether the model has any; where it is
    // and what its tips must stay out of, for the next step (until set, or
    // with simulate off, the bones take their target pose); the solver,
    // for tests and status.
    bool hasJiggle() const { return !m_model->jiggle.bones.empty(); }
    void setJiggleFrame(JiggleFrame frame) { m_jiggle_frame = std::move(frame); }
    const JiggleSolver &jiggle() const { return m_jiggle; }
    // This model's collider capsules after the last step, world space, from
    // its visual's global transform: what a drape or hair hung on it keeps
    // its tips out of.
    void jiggleColliders(const godot::Transform3D &mesh_to_world, std::vector<JiggleCapsule> &out) const;

private:
    void poseLimbs(float dt, JointTransforms &locals, const std::map<std::string, BoneOverride> &overrides);
    // A stroke from the server's stroke state (GodotModel::strokes): the
    // evaluated pose on its bones, over the game's animation and overrides.
    void poseStroke(float dt, JointTransforms &locals, const std::map<std::string, BoneOverride> &overrides);
    // Feet on the ground: findFeet once, fitFeet each step from where the
    // feet were last step, applyFeet on the global matrices.
    void findFeet();
    void fitFeet(float dt);
    void applyFeet();
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
    // The stroke being shown from the server's stroke state: its action
    // serial and phase, the angle last told and the angle shown (eased
    // towards it), and its own clock. Resent state with nothing changed
    // does not reset the clock: Luanti resends every override an object
    // holds whenever any one changes.
    struct MeleeStroke {
        bool active = false;
        int action = -1;
        int phase = 0;
        float told = 0.0f;
        float angle = 0.0f;
        float t = 0.0f;
    } m_melee;
    // Fitted feet: each leg's hip, knee and ankle joints, every joint below
    // each of them, and the foot's lift now (eased, nodes); the body's drop.
    struct FootFit {
        u32 hip = 0, knee = 0, ankle = 0;
        std::vector<u32> below_hip, below_knee, below_ankle;
        float lift = 0.0f;
    };
    std::vector<FootFit> m_feet;
    bool m_feet_found = false;
    float m_body_drop = 0.0f;
    GroundFrame m_ground;
    JiggleFrame m_jiggle_frame;
    JiggleSolver m_jiggle;
    bool m_posed = false; // m_globals holds a stepped pose
};

// How many loaded models carry a stroke evaluator, and how many stroke
// poses animators have evaluated, since start: for status and live tests.
int strokeModelCount();
uint64_t strokePoseCount();
// How many animator steps had a foot lifted or lowered more than 0.05
// nodes to the ground, and the most any foot was, nodes, since start.
uint64_t fittedFootFrames();
float fittedFootMost();

// Irrlicht matrix (row vectors, left-handed) to a Godot transform, z mirrored.
godot::Transform3D toGodotTransform(const core::matrix4 &m);
// And back.
core::matrix4 fromGodotTransform(const godot::Transform3D &t);

// Where an object attached to a parent's bone stands: GenericCAO puts the
// child's scene node under the parent's joint node, so the child inherits
// the parent's visual_size and the bone's own scale with its position. From
// the parent's root transform (nodes), its visual_size, the joint's global
// transform (jointGlobal, mesh units) and the attachment's position (BS) and
// rotation (degrees). The result is scaled by BS so the child's own visual,
// which divides mesh units by BS, comes out the size upstream draws it.
godot::Transform3D boneAttachmentTransform(const godot::Transform3D &parent_root,
        const v3f &parent_visual_size, const godot::Transform3D &bone_global,
        const v3f &position, const v3f &rotation_deg);

} // namespace goanna
