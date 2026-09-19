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

// AnimatedMeshSceneNode::copyOldTransforms: records transforms as the pose to
// blend from next frame.
void keepOldTransforms(const JointTransforms &transforms, OldJointTransforms &old_transforms);

} // namespace goanna
