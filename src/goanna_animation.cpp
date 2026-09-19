// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_animation.h"

#include <algorithm>
#include <variant>

namespace goanna {

JointTransforms animateTracks(const scene::SkinnedMesh &mesh, const scene::AnimSpec &anim,
        const OldJointTransforms &old_transforms) {
    const auto &joints = mesh.getAllJoints();
    // AnimatedMeshSceneNode leaves a static mesh's joints at the transforms
    // the loader gave them.
    if (mesh.isStatic()) {
        JointTransforms rest;
        rest.reserve(joints.size());
        for (const auto *joint : joints)
            rest.push_back(joint->transform);
        return rest;
    }

    struct Progress {
        scene::SkinnedMesh::AnimationProgress progress;
        s32 priority;
    };
    std::vector<Progress> progresses;
    progresses.reserve(anim.tracks.size());
    for (const auto &[track, spec] : anim.tracks) {
        // The active object only ever plays tracks the mesh has, but a
        // model[] preview asks for track 0 of whatever mesh it was given,
        // and SkinnedMesh::animateMesh throws on a track it does not have.
        if (track >= mesh.getTrackCount())
            continue;
        const float blend = spec.blend_duration > 0.0f ? spec.blend_progress / spec.blend_duration : 1.0f;
        progresses.push_back({{track, spec.cur_frame, blend}, spec.priority});
    }
    // Higher priority first: SkinnedMesh gives each joint to the first track
    // in the list that animates it.
    std::sort(progresses.begin(), progresses.end(),
            [](const Progress &a, const Progress &b) { return a.priority > b.priority; });
    std::vector<scene::SkinnedMesh::AnimationProgress> ordered;
    ordered.reserve(progresses.size());
    for (const auto &p : progresses)
        ordered.push_back(p.progress);

    if (old_transforms.size() == joints.size())
        return mesh.animateMesh(ordered, old_transforms);
    // Nothing to blend from yet.
    return mesh.animateMesh(ordered, OldJointTransforms(joints.size()));
}

void keepOldTransforms(const JointTransforms &transforms, OldJointTransforms &old_transforms) {
    old_transforms.resize(transforms.size());
    for (size_t i = 0; i < transforms.size(); ++i) {
        if (const auto *trs = std::get_if<core::Transform>(&transforms[i]))
            old_transforms[i] = *trs;
        else
            old_transforms[i] = std::nullopt;
    }
}

} // namespace goanna
