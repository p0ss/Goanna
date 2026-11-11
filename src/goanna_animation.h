// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Skeletal animation by track, without a scene node. Luanti 5.17 plays
// several animation tracks on one mesh at once, and Irrlicht's
// AnimatedMeshSceneNode poses the joints from them each frame: every track
// advances, the tracks are taken in order of priority, and each one blends
// from the pose shown the frame before. This does the same with no scene
// node and no Godot, so the native tests can check it. ModelAnimator
// (goanna_models) turns the result into bone poses; the tracks themselves
// come from the transplanted active object (content_cao).
//
// Pure functions with no state of their own; ModelAnimator calls them on the
// main thread. Main functions: animateTracks and keepOldTransforms, over
// the JointTransforms and OldJointTransforms types. LocalBodyAnimation, at
// the end, keeps the one piece of state: the own body's local clip.

#include <optional>
#include <vector>

#include <AnimSpec.h>
#include <SkinnedMesh.h>
#include <Transform.h>

namespace goanna {

// One local transform per joint, as SkinnedMesh::animateMesh returns them.
using JointTransforms = std::vector<scene::SkinnedMesh::SJoint::VariantTransform>;

// One entry per joint: the local transform the joint showed last frame,
// before bone overrides, or nothing for a joint that keeps a matrix. This is
// what AnimatedMeshSceneNode keeps as PreTransSaves and what a track with a
// blend time blends from.
using OldJointTransforms = std::vector<std::optional<core::Transform>>;

// AnimatedMeshSceneNode::animateJoints: the joints' local transforms for the
// tracks playing in anim. A joint takes its transform from the highest
// priority track that animates it, and a joint no track animates is at its
// rest transform. Tracks of equal priority come in the order the track map
// iterates, as upstream's do. A track still blending interpolates from
// old_transforms, which needs one entry per joint. A static mesh keeps its
// rest transforms. A track the mesh does not have is skipped.
JointTransforms animateTracks(const scene::SkinnedMesh &mesh, const scene::AnimSpec &anim,
        const OldJointTransforms &old_transforms);

// Whether every playing track permits standing foot placement. Rest clips
// must keep their authored pelvis and legs even on a body with strokes.
bool animationAllowsSteps(const scene::SkinnedMesh &mesh, const scene::AnimSpec &anim,
        const std::vector<u16> &step_tracks, bool stroke_body);

// AnimatedMeshSceneNode::copyOldTransforms: records transforms as the pose to
// blend from next frame.
void keepOldTransforms(const JointTransforms &transforms, OldJointTransforms &old_transforms);

// The own body's idle, walk and dig clips played by the client from its
// own controls, on a body whose clips are separate named tracks. Upstream's
// set_local_animation does this for a model whose clips are frame ranges
// of its first track (character.b3d), and Goanna plays that as upstream
// does (content_cao's stepLocalPlayerAnimation); a glTF body with one
// track a clip cannot be described by frame ranges. A Kindred server
// declares the tracks on a bone no mesh has (LOCAL_BODY_BONE), which stock
// clients ignore: position x, y, z the idle, walk and dig tracks and scale
// x the walk while digging, each a track number counted from 1 (0 none),
// scale y the clips' speed and scale z the declaration's version (1).
//
// The client chooses the clip as upstream does (walking from the movement
// input, digging from dig or place; attached: none) and plays it in place
// of the server's: declared tracks the server plays are not shown, as
// upstream ignores a server animation with a local range. A dig's speed is
// the server's for the same track when the server plays it (kept in time
// with the block); otherwise, and for idle and walk always, the declared
// speed scaled as upstream scales it.
// While the server shows a clip of its own that is not declared (a
// priority 0 track with a range: sit, lay, swim, die, a guard), the
// client defers to it entirely.
constexpr const char *LOCAL_BODY_BONE = "kindred_local_anim";

struct LocalBodyTracks {
    int idle = -1, walk = -1, dig = -1, walk_dig = -1; // track numbers from 0; -1 none
    float speed = 1.0f;
    bool any() const { return idle >= 0 || walk >= 0 || dig >= 0 || walk_dig >= 0; }
};
// False, and out left with no tracks, unless the values are a version 1
// declaration.
bool decodeLocalBodyTracks(const core::vector3df &position, const core::vector3df &scale, LocalBodyTracks &out);

struct LocalBodyInput {
    float movement_speed = 0; // PlayerControl's, 0 to 1
    bool dig = false, place = false, sneak = false;
    bool fast = false; // fast movement in use, as upstream reckons it
    bool attached = false;
};

class LocalBodyAnimation {
public:
    // Before the mesh animation advances: lay the local clip over it (the
    // mesh's own animation, which the renderer advances), or give the
    // declared tracks back to the server's animation when deferring.
    void apply(const LocalBodyTracks &tracks, const LocalBodyInput &in, const scene::SkinnedMesh &mesh,
            const scene::AnimSpec &server, scene::AnimSpec &shown);
    // After it advanced: keep the local clip's progress.
    void keep(const scene::AnimSpec &shown);
    bool active() const { return m_active; }
    int track() const { return m_active ? m_track : -1; }

private:
    void restore(const scene::AnimSpec &server, scene::AnimSpec &shown);
    bool m_active = false;
    int m_track = -1;
    scene::TrackAnimSpec m_spec;
    std::vector<int> m_declared;
};

} // namespace goanna
