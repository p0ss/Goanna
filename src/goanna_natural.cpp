// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_natural.h"

#include <algorithm>
#include <cmath>
#include <variant>

#include <json/json.h>

namespace goanna {

bool parseNaturalPlan(const Json::Value &v, NaturalPlan &out) {
    if (!v.isObject() || !v["attacks"].isArray())
        return false;
    if (v["state"].isString())
        out.state = v["state"].asString();
    for (const Json::Value &a : v["attacks"]) {
        if (!a.isObject() || !a["clips"].isArray() || a["clips"].empty())
            return false;
        NaturalPlan::Attack attack;
        attack.kind = a["kind"].asString();
        attack.length = a["length"].asFloat();
        for (const Json::Value &c : a["clips"]) {
            if (!c.isString())
                return false;
            attack.clips.push_back(c.asString());
        }
        out.attacks.push_back(std::move(attack));
    }
    return !out.attacks.empty();
}

// As DorfCraft's kit/natural/lib.lua N.bracket and N.nearest.
NaturalBlend naturalBracket(int clips, float p) {
    NaturalBlend out;
    if (clips <= 1 || !std::isfinite(p))
        return out;
    p = std::clamp(p, 0.0f, (float)(clips - 1));
    const int i = std::min(clips - 2, (int)std::floor(p));
    out.a = i;
    out.b = i + 1;
    out.weight = p - (float)i;
    return out;
}

void blendNaturalPose(const scene::SkinnedMesh &mesh, const scene::TrackAnimSpec &playing, u16 a, u16 b,
        float weight, float amount, JointTransforms &locals) {
    if (a >= mesh.getTrackCount() || b >= mesh.getTrackCount() || amount <= 0.0f)
        return;
    scene::TrackAnimSpec spec = playing;
    spec.blend_duration = 0.0f;
    spec.blend_progress = 0.0f;
    scene::AnimSpec sa, sb;
    sa.tracks[a] = spec;
    sb.tracks[b] = spec;
    const OldJointTransforms none(locals.size());
    const JointTransforms pa = animateTracks(mesh, sa, none);
    const JointTransforms pb = animateTracks(mesh, sb, none);
    std::vector<bool> moved(locals.size(), false);
    for (u16 track : {a, b})
        for (const auto &jk : mesh.getAnimation(track).joint_keys)
            if (jk.joint_id < moved.size() && !jk.keys.empty())
                moved[jk.joint_id] = true;
    amount = std::min(amount, 1.0f);
    for (size_t i = 0; i < locals.size() && i < pa.size() && i < pb.size(); ++i) {
        if (!moved[i])
            continue;
        auto *l = std::get_if<core::Transform>(&locals[i]);
        auto *ta = std::get_if<core::Transform>(&pa[i]);
        auto *tb = std::get_if<core::Transform>(&pb[i]);
        if (!l || !ta || !tb)
            continue;
        core::quaternion q;
        q.slerp(ta->rotation, tb->rotation, weight);
        const core::vector3df t = ta->translation + (tb->translation - ta->translation) * weight;
        const core::vector3df s = ta->scale + (tb->scale - ta->scale) * weight;
        core::quaternion out;
        out.slerp(l->rotation, q, amount);
        l->rotation = out;
        l->translation = l->translation + (t - l->translation) * amount;
        l->scale = l->scale + (s - l->scale) * amount;
    }
}

int naturalNearest(int clips, float p) {
    if (clips <= 1 || !std::isfinite(p))
        return 0;
    return std::clamp((int)std::floor(p + 0.5f), 0, clips - 1);
}

} // namespace goanna
