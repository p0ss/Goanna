// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Posing joints from several animation tracks at once, after Irrlicht's
// AnimatedMeshSceneNode::animateJoints and copyOldTransforms. See
// goanna_animation.h.

#include "goanna_animation.h"

#include <algorithm>
#include <cmath>
#include <variant>

namespace goanna {

bool animationAllowsSteps(const scene::SkinnedMesh &mesh, const scene::AnimSpec &anim,
        const std::vector<u16> &step_tracks, bool stroke_body) {
    for (const auto &[track, spec] : anim.tracks) {
        if (track >= mesh.getTrackCount())
            continue;
        const std::string &name = mesh.getAnimation(track).name;
        for (const char *rest : {"sleep", "lay", "sit", "die", "dead"}) {
            const std::string prefix(rest);
            if (name == prefix || name.rfind(prefix + "_", 0) == 0)
                return false;
        }
        if (!stroke_body && std::find(step_tracks.begin(), step_tracks.end(), track) == step_tracks.end())
            return false;
    }
    return true;
}

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

bool decodeLocalBodyTracks(const core::vector3df &position, const core::vector3df &scale, LocalBodyTracks &out) {
    out = LocalBodyTracks();
    if (std::lround(scale.Z) != 1)
        return false;
    auto track = [](float v) { return std::max(-1, (int)std::lround(v) - 1); };
    out.idle = track(position.X);
    out.walk = track(position.Y);
    out.dig = track(position.Z);
    out.walk_dig = track(scale.X);
    out.speed = scale.Y;
    return out.any();
}

void LocalBodyAnimation::restore(const scene::AnimSpec &server, scene::AnimSpec &shown) {
    for (int nr : m_declared) {
        auto it = server.tracks.find((u16)nr);
        if (it != server.tracks.end())
            shown.tracks[(u16)nr] = it->second;
        else
            shown.tracks.erase((u16)nr);
    }
    m_active = false;
    m_track = -1;
}

void LocalBodyAnimation::apply(const LocalBodyTracks &tracks, const LocalBodyInput &in,
        const scene::SkinnedMesh &mesh, const scene::AnimSpec &server, scene::AnimSpec &shown) {
    const int count = mesh.getTrackCount();
    auto valid = [&](int nr) { return nr >= 0 && nr < count ? nr : -1; };
    std::vector<int> declared;
    for (int nr : {tracks.idle, tracks.walk, tracks.dig, tracks.walk_dig}) {
        if (valid(nr) >= 0 && std::find(declared.begin(), declared.end(), nr) == declared.end())
            declared.push_back(nr);
    }
    if (m_active && declared != m_declared)
        restore(server, shown);
    m_declared = declared;
    auto is_declared = [&](int nr) {
        return std::find(declared.begin(), declared.end(), nr) != declared.end();
    };
    // A clip of the server's own: the client stands aside.
    bool own = false;
    for (const auto &[nr, t] : server.tracks) {
        if (t.priority <= 0 && t.max_frame > t.min_frame && !is_declared(nr))
            own = true;
    }
    const bool walking = in.movement_speed > 0.001f;
    const bool digging = in.dig || in.place;
    int want = walking && digging ? valid(tracks.walk_dig) : walking ? valid(tracks.walk) :
            digging ? valid(tracks.dig) : valid(tracks.idle);
    if (own || in.attached)
        want = -1;
    if (want < 0) {
        if (m_active)
            restore(server, shown);
        return;
    }
    float fps = tracks.speed;
    // A dig at the server's speed for it, which keeps the swing in time
    // with the block. Not idle or walk: a server may hold those at a speed
    // meant for another model's frames (Mineclonia's 30 on the first track).
    auto st = server.tracks.find((u16)want);
    if (digging && st != server.tracks.end() && st->second.max_frame > st->second.min_frame
            && st->second.fps != 0.0f) {
        fps = st->second.fps;
    } else {
        if (walking)
            fps *= in.movement_speed;
        if (in.fast)
            fps *= 1.5f;
        if (in.sneak && walking)
            fps /= 2;
    }
    if (!m_active || want != m_track) {
        scene::TrackAnimSpec a;
        a.setFrameRange(0.0f, mesh.getMaxFrameNumber((u16)want));
        a.fps = fps;
        a.loop = true;
        a.priority = 0;
        a.blend_duration = 0.15f;
        a.cur_frame = fps >= 0 ? a.min_frame : a.max_frame;
        // Already showing on the mesh (the server's own idle, say): carry
        // on from where it is.
        auto mt = shown.tracks.find((u16)want);
        if (mt != shown.tracks.end() && mt->second.max_frame > mt->second.min_frame) {
            a.cur_frame = std::clamp(mt->second.cur_frame, a.min_frame, a.max_frame);
            a.blend_duration = mt->second.blend_duration;
            a.blend_progress = mt->second.blend_progress;
        }
        m_spec = a;
        m_track = want;
        m_active = true;
    } else {
        m_spec.fps = fps;
    }
    for (int nr : declared) {
        if (nr != want)
            shown.tracks.erase((u16)nr);
    }
    shown.tracks[(u16)want] = m_spec;
}

void LocalBodyAnimation::keep(const scene::AnimSpec &shown) {
    if (!m_active)
        return;
    auto it = shown.tracks.find((u16)m_track);
    if (it != shown.tracks.end())
        m_spec = it->second;
}

} // namespace goanna
