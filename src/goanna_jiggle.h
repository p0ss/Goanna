// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Jiggle bones: client side secondary motion for bones a model marks in its
// glTF node extras, so a skirt lags and sways behind a walking body and a
// plait swings when the head turns. Purely cosmetic: it moves only how a
// model is drawn, from what the client already draws (the entity's own pose
// and its parent's), and tells the player nothing a vanilla client would
// not. The units and the behaviour are in docs/systems/jiggle-bones.md, the
// page DorfCraft authors against.
//
// Luanti's glTF loader drops node extras (tiniergltf::Node keeps none, and
// SkinnedMesh::SJoint has nowhere to put them), so ModelCache reads the
// JSON again here and the marks are matched to joints by node name, which
// is unique within a model.
//
// Coordinates: the rig is in mesh space with Godot's handedness, as
// toGodotTransform gives it (for a glTF model that is the file's own
// space); the solver works in world space, nodes, from the transform the
// renderer passes it each frame.
//
// Threads: main thread only, like the rest of goanna_models.h. Main types:
// ModelExtras (parsed marks), JiggleRig (per model), JiggleSolver (per
// animator instance).

#include <cmath>
#include <map>
#include <string>
#include <vector>

#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <SkinnedMesh.h>

#include "goanna_animation.h"

namespace goanna {

// {"jiggle": {...}} on a glTF node. Missing fields keep these defaults.
struct JiggleParams {
    float stiffness = 0.5f;     // 0 to 1: natural frequency, jiggleOmega
    float damping = 0.35f;      // 0 to 1: the damping ratio
    float gravity = 1.0f;       // times JIGGLE_GRAVITY
    float limit_degrees = 70.0f; // half angle of the cone round the target
    std::string chain;          // bones linked parent to child, in order
};

// {"jiggle_collider": {"radius": r, "tip": "<child bone>"}} on a glTF node:
// a capsule from the bone to its tip child, radius in the model's mesh
// units.
struct JiggleColliderMark {
    float radius = 0.0f;
    std::string tip;
};

// The marks a model's nodes carry, by node name.
struct ModelExtras {
    std::map<std::string, JiggleParams> jiggle;
    std::map<std::string, JiggleColliderMark> colliders;
    bool empty() const { return jiggle.empty() && colliders.empty(); }
};

// Reads the node extras of a .gltf (JSON) or a .glb (its JSON chunk), by
// file name. False if the bytes are neither or do not parse; true with an
// empty result for a model with no marks.
bool parseModelExtras(const std::string &name, const std::string &bytes, ModelExtras &out);

// World gravity, nodes a second squared, which JiggleParams::gravity
// multiplies.
constexpr float JIGGLE_GRAVITY = 9.81f;
// The solver's fixed step, and how many it takes in one frame at most.
constexpr float JIGGLE_STEP = 1.0f / 60.0f;
constexpr int JIGGLE_MAX_STEPS = 5;
// A model whose root moves further than this in one frame (nodes) has been
// teleported: its bones start again from their target pose.
constexpr float JIGGLE_TELEPORT = 2.0f;
// Beyond this distance from the camera (nodes) bones take their target
// pose and are not simulated.
constexpr float JIGGLE_DISTANCE = 32.0f;
// Natural frequency, radians a second, for a stiffness of 0 to 1.
float jiggleOmega(float stiffness);

// The bones that are simulated, the collider capsules and the joints both
// hang on, built once per model (buildJiggleRig).
struct JiggleBone {
    int joint = -1;
    JiggleParams params;
    // The bone's tip in the joint's own frame at rest: its child joint's
    // position, or for a bone with no child the far end of the vertices it
    // carries (docs/systems/jiggle-bones.md, "Tips").
    godot::Vector3 tip_local;
};

struct JiggleCollider {
    int joint = -1;
    // The capsule's ends in the joint's own frame, and its radius, mesh
    // units.
    godot::Vector3 a_local, b_local;
    float radius = 0.0f;
};

struct JiggleRig {
    std::vector<JiggleBone> bones;        // parents before children
    std::vector<JiggleCollider> colliders;
    bool empty() const { return bones.empty() && colliders.empty(); }
};

// The bones a hominid frame's colliders fall back to when a model marks no
// jiggle_collider of its own: chest, body and the four leg bones.
extern const char *const JIGGLE_FALLBACK_COLLIDERS[6];

// The rig for a skinned mesh: the jiggle bones the extras mark, and the
// colliders they mark or else the fallback bones (each with a capsule from
// its mesh extent). Either can be empty.
JiggleRig buildJiggleRig(const scene::SkinnedMesh &mesh, const ModelExtras *extras);

// A collider capsule in world space, nodes.
struct JiggleCapsule {
    godot::Vector3 a, b;
    float radius = 0.0f;
};

// What the renderer tells an animator about its model this frame.
struct JiggleFrame {
    // Off: the bones take their target pose and the state is dropped, so
    // the simulation starts again from rest when it is turned back on.
    bool simulate = false;
    // Mesh space (Godot handedness) to world, nodes: the visual's global
    // transform.
    godot::Transform3D mesh_to_world;
    // The capsules the tips are kept out of: the parent's, for a drape or
    // hair attached to a body's bone.
    std::vector<JiggleCapsule> colliders;
};

// Per animator instance: the simulated tips and their velocities.
class JiggleSolver {
public:
    // Turns the jiggle bones in `locals` (the target pose on entry) to
    // where the simulation has their tips, keeping each bone's length.
    void step(const JiggleRig &rig, const scene::SkinnedMesh &mesh, float dt,
            const JiggleFrame &frame, JointTransforms &locals);
    void reset() { m_have = false; }
    bool active() const { return m_have; }
    // For tests and status: per rig bone, where its tip was drawn after the
    // last step and where its target pose would put it, world space.
    size_t boneCount() const { return m_state.size(); }
    godot::Vector3 tip(size_t i) const { return m_state[i].shown; }
    godot::Vector3 target(size_t i) const { return m_state[i].target; }
    godot::Vector3 pivot(size_t i) const { return m_state[i].pivot; }
    int lastSteps() const { return m_last_steps; }

private:
    struct State {
        godot::Vector3 x, v, t_prev;
        godot::Vector3 shown, target, pivot;
    };
    // One pass down the joints at `world`: integrates each bone over h
    // seconds (none at 0), keeps its tip on its length, in its cone and out
    // of the capsules, and turns the bone there. `init` starts every tip at
    // its target; `write` puts the turned bones back into `locals`.
    void solve(const JiggleRig &rig, const scene::SkinnedMesh &mesh,
            const godot::Transform3D &world, float h, bool init, bool write,
            const std::vector<JiggleCapsule> &colliders, JointTransforms &locals);
    std::vector<State> m_state;
    bool m_have = false;
    float m_acc = 0.0f;
    godot::Transform3D m_prev_world;
    int m_last_steps = 0;
};

// The rig's collider capsules for a pose, in world space: `global` gives a
// joint's global transform (mesh space, Godot handedness).
template <typename GlobalOf>
void jiggleCapsules(const JiggleRig &rig, const GlobalOf &global,
        const godot::Transform3D &mesh_to_world, std::vector<JiggleCapsule> &out) {
    for (const JiggleCollider &c : rig.colliders) {
        const godot::Transform3D g = mesh_to_world * global(c.joint);
        const float det = std::abs(g.basis.determinant());
        const float scale = det > 0.0f ? std::cbrt(det) : 0.0f;
        if (scale <= 0.0f)
            continue; // a bone hidden at zero scale takes its capsule with it
        out.push_back({g.xform(c.a_local), g.xform(c.b_local), c.radius * scale});
    }
}

} // namespace goanna
