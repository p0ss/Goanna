// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_limbs.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <utility>

#include <SSkinMeshBuffer.h>
#include <IVertexBuffer.h>

using namespace godot;

namespace goanna {

namespace {

constexpr float kPi = 3.14159265358979f;
constexpr float kDeg = 180.0f / kPi;

struct LimbName {
    const char *name;
    LimbKind kind;
    bool right;
};
constexpr LimbName kLimbNames[] = {
    {"Arm_Right", LimbKind::Arm, true},
    {"Arm_Left", LimbKind::Arm, false},
    {"Leg_Right", LimbKind::Leg, true},
    {"Leg_Left", LimbKind::Leg, false},
};

// A vertex is on a joint rigidly when that joint carries all of its weight.
bool rigidOn(const LimbMeshData &m, int v, int joint) {
    return m.bones[v * 4] == joint && m.weights[v * 4] > 0.999f;
}

} // namespace

std::vector<LimbBend> findLimbs(const scene::SkinnedMesh &mesh) {
    std::vector<LimbBend> out;
    const auto &joints = mesh.getAllJoints();
    // Where each joint is at rest, from the joints' own transforms: a loader
    // may leave GlobalMatrix unset until something animates the mesh.
    std::vector<core::matrix4> rest(joints.size());
    for (size_t i = 0; i < joints.size(); ++i) {
        if (auto *m = std::get_if<core::matrix4>(&joints[i]->transform))
            rest[i] = *m;
        else
            rest[i] = std::get<core::Transform>(joints[i]->transform).buildMatrix();
    }
    mesh.calculateGlobalMatrices(rest);
    for (const LimbName &ln : kLimbNames) {
        int joint = -1;
        for (const auto *j : joints)
            if (j->Name && *j->Name == ln.name)
                joint = j->JointID;
        if (joint < 0)
            continue;
        // The limb's own vertices, in Godot space, from every buffer.
        bool any = false;
        Vector3 lo, hi;
        for (u32 b = 0; b < mesh.getMeshBufferCount(); ++b) {
            const auto *buf = static_cast<const scene::SSkinMeshBuffer *>(mesh.getMeshBuffer(b));
            const scene::WeightBuffer *w = buf ? buf->getWeights() : nullptr;
            if (!w)
                continue;
            const u32 n = buf->getVertexBuffer()->getCount();
            for (u32 i = 0; i < n; ++i) {
                const auto &ids = w->getJointIds(i);
                const auto &ws = w->getWeights(i);
                if (ids[0] != joint || ws[0] < 0.999f)
                    continue;
                const core::vector3df p = buf->getVertexBuffer()->getPosition(i);
                const Vector3 g(p.X, p.Y, -p.Z);
                if (!any) {
                    lo = hi = g;
                    any = true;
                } else {
                    lo = Vector3(std::min(lo.x, g.x), std::min(lo.y, g.y), std::min(lo.z, g.z));
                    hi = Vector3(std::max(hi.x, g.x), std::max(hi.y, g.y), std::max(hi.z, g.z));
                }
            }
        }
        if (!any)
            continue;
        const Vector3 size = hi - lo;
        // An upright limb, hanging from its joint: a box taller than it is
        // wide, whose joint is at its top end.
        if (size.y < 1.5f * std::max(size.x, size.z))
            continue;
        const core::vector3df jp = rest[joint].getTranslation();
        if (std::fabs(jp.Y - hi.y) > std::fabs(jp.Y - lo.y))
            continue;
        LimbBend l;
        l.joint = joint;
        l.kind = ln.kind;
        l.right = ln.right;
        l.cut_y = 0.5f * (lo.y + hi.y);
        l.pivot = Vector3(0.5f * (lo.x + hi.x), l.cut_y, 0.5f * (lo.z + hi.z));
        l.end = Vector3(l.pivot.x, lo.y, l.pivot.z);
        out.push_back(l);
    }
    return out;
}

void splitLimbs(const std::vector<LimbBend> &limbs, LimbMeshData &m) {
    auto &verts = m.verts;
    auto &normals = m.normals;
    auto &uvs = m.uvs;
    auto &indices = m.indices;
    auto &bones = m.bones;
    auto &weights = m.weights;
    // A hundredth of a pixel on a 16 unit limb: vertices this close to the cut
    // are on it.
    constexpr float eps = 1e-3f;
    for (const LimbBend &l : limbs) {
        const int n0 = (int)verts.size();
        std::vector<int> on_limb(n0, 0);
        for (int v = 0; v < n0; ++v)
            on_limb[v] = rigidOn(m, v, l.joint) ? 1 : 0;
        // Each box is cut at its own middle. A limb's sleeve, trouser and
        // armour boxes are inflated round its skin box, and not evenly
        // (Mineclonia's leg armour reaches further below the leg than
        // above), so one height for all of them lands off the pixel line on
        // the outer ones. A side face spans its whole box, so a triangle
        // crossing the limb's cut gives its box's middle by its own height,
        // and its vertices take that cut, if it is near the limb's: a box
        // covering only part of the limb (Mineclonia's boots, which end just
        // over the knee) is cut at the knee, not half way down itself.
        std::vector<float> cut(n0, l.cut_y);
        std::vector<char> cut_set(n0, 0);
        for (size_t t = 0; t + 2 < indices.size(); t += 3) {
            const int tri[3] = {indices[t], indices[t + 1], indices[t + 2]};
            if (!on_limb[tri[0]] || !on_limb[tri[1]] || !on_limb[tri[2]])
                continue;
            float lo = verts[tri[0]].y, hi = lo;
            for (int v : tri) {
                lo = std::min(lo, verts[v].y);
                hi = std::max(hi, verts[v].y);
            }
            if (lo >= l.cut_y - eps || hi <= l.cut_y + eps)
                continue;
            const float mid = 0.5f * (lo + hi);
            float own = std::fabs(mid - l.cut_y) < 0.3f ? mid : l.cut_y;
            // A box that only just crosses the knee (the boots' top edge is
            // a twentieth of a pixel over it) is not cut at all: it goes
            // whole to the side it is on, rather than being cut a sliver
            // from its edge, off every pixel line.
            constexpr float sliver = 0.3f;
            if (hi - l.cut_y < sliver)
                own = hi + 1.0f;
            else if (l.cut_y - lo < sliver)
                own = lo - 1.0f;
            for (int v : tri)
                if (!cut_set[v]) {
                    cut[v] = own;
                    cut_set[v] = 1;
                }
        }
        auto side = [&](int v) -> int {
            const float y = verts[v].y, c = cut[v];
            return y > c + eps ? 1 : y < c - eps ? -1 : 0;
        };
        // New vertices on the cut, one per crossed edge, shared by the
        // triangles either side of that edge.
        std::map<std::pair<int, int>, int> cut_at;
        auto cut_vertex = [&](int a, int b) -> int {
            const auto key = std::make_pair(std::min(a, b), std::max(a, b));
            auto it = cut_at.find(key);
            if (it != cut_at.end())
                return it->second;
            const float c = cut[a];
            const float t = (c - verts[a].y) / (verts[b].y - verts[a].y);
            const int v = (int)verts.size();
            Vector3 p = verts[a].lerp(verts[b], t);
            p.y = c;
            verts.push_back(p);
            Vector3 nrm = normals[a].lerp(normals[b], t);
            normals.push_back(nrm.length() > 1e-6f ? nrm.normalized() : normals[a]);
            uvs.push_back(uvs[a].lerp(uvs[b], t));
            for (int k = 0; k < 4; ++k) {
                bones.push_back(k == 0 ? l.joint : 0);
                weights.push_back(k == 0 ? 1.0f : 0.0f);
            }
            on_limb.push_back(1);
            cut.push_back(c);
            cut_set.push_back(1);
            cut_at[key] = v;
            return v;
        };
        std::vector<int> out;
        const int tris = (int)indices.size() / 3;
        for (int t = 0; t < tris; ++t) {
            const int tri[3] = {indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]};
            bool mine = on_limb[tri[0]] && on_limb[tri[1]] && on_limb[tri[2]];
            int up = 0, down = 0;
            for (int v : tri) {
                up += side(v) > 0;
                down += side(v) < 0;
            }
            if (!mine || up == 0 || down == 0) {
                for (int v : tri)
                    out.push_back(v);
                continue;
            }
            // Clip the triangle against the cut into the part above and
            // the part below, walking its edges in order so both keep its
            // winding, then fan each part into triangles.
            std::vector<int> above, below;
            for (int k = 0; k < 3; ++k) {
                const int a = tri[k], b = tri[(k + 1) % 3];
                const int sa = side(a), sb = side(b);
                if (sa >= 0)
                    above.push_back(a);
                if (sa <= 0)
                    below.push_back(a);
                if ((sa > 0 && sb < 0) || (sa < 0 && sb > 0)) {
                    const int c = cut_vertex(a, b);
                    above.push_back(c);
                    below.push_back(c);
                }
            }
            for (const auto *poly : {&above, &below})
                for (size_t k = 1; k + 1 < poly->size(); ++k) {
                    out.push_back((*poly)[0]);
                    out.push_back((*poly)[k]);
                    out.push_back((*poly)[k + 1]);
                }
        }
        indices = out;
        // The half below the cut goes to the limb's lower bone, the cut
        // itself to its seam bone.
        for (int v = 0; v < (int)verts.size(); ++v) {
            if (!on_limb[v])
                continue;
            const int s = side(v);
            if (s > 0)
                continue;
            bones[v * 4] = s < 0 ? l.bone : l.seam_bone;
            weights[v * 4] = 1.0f;
            for (int k = 1; k < 4; ++k) {
                bones[v * 4 + k] = 0;
                weights[v * 4 + k] = 0.0f;
            }
        }
    }
}

Transform3D bendTransform(const LimbBend &limb, float degrees) {
    // About the limb's left-right axis through the pivot. Godot's forward is
    // -z: turning the hanging lower half by a positive angle about +x swings
    // its end to -z, forward, which is an elbow's way; a knee goes the other.
    const float a = (limb.kind == LimbKind::Arm ? degrees : -degrees) / kDeg;
    const Basis b(Vector3(1, 0, 0), a);
    return Transform3D(Basis(), limb.pivot) * Transform3D(b, Vector3())
            * Transform3D(Basis(), -limb.pivot);
}

float walkBend(LimbKind kind, float swing, float swing_rate) {
    if (kind == LimbKind::Leg) {
        // The foot lifts to come through as the leg swings forward, most at
        // the fastest of the swing, and the knee keeps a little give while
        // the leg carries the body back.
        return std::clamp(4.0f + 0.12f * std::max(0.0f, swing_rate), 0.0f, 75.0f);
    }
    // An arm bends at the elbow as it comes forward, more the further and
    // faster it swings, and hangs a little bent at rest.
    return std::clamp(8.0f + 0.5f * std::max(0.0f, swing) + 0.03f * std::max(0.0f, swing_rate),
            0.0f, 80.0f);
}

LimbAngles strokeAngles(WaterPose pose, LimbKind kind, bool right, float phase) {
    LimbAngles a;
    if (pose == WaterPose::Swim) {
        if (kind == LimbKind::Arm) {
            // The crawl: each arm turns backward all the way round, from
            // the hip over the back to reach past the head (the recovery,
            // elbow high and bent), then pulls under the chest back to the
            // hip nearly straight. The arms take turns, half a stroke apart.
            const float p = std::fmod(phase + (right ? 0.0f : kPi), 2.0f * kPi);
            a.pitch = -p * kDeg;
            const bool recovering = p < kPi;
            a.bend = recovering ? 30.0f + 70.0f * std::sin(p) : 25.0f;
            a.spread = recovering ? 12.0f * std::sin(p) : 0.0f;
        } else {
            // A flutter kick from the hip, three beats a stroke, the legs
            // opposite, the knee giving on the down beat.
            const float k = 3.0f * phase + (right ? 0.0f : kPi);
            a.pitch = 18.0f * std::sin(k);
            a.bend = 12.0f + 18.0f * std::max(0.0f, std::sin(k + 0.5f * kPi));
        }
    } else if (pose == WaterPose::Climb) {
        // Climbing hand over hand: each arm reaches up overhead in turn and
        // pulls down, elbow bending as it pulls; each knee comes up in turn
        // for the next rung, the leg opposite the reaching arm.
        const float p = phase + (right ? 0.0f : kPi);
        if (kind == LimbKind::Arm) {
            a.pitch = 150.0f + 25.0f * std::sin(p);
            a.spread = 10.0f;
            a.bend = 30.0f + 50.0f * std::max(0.0f, -std::sin(p));
        } else {
            const float lift = std::max(0.0f, std::sin(p + kPi));
            a.pitch = 15.0f + 40.0f * lift;
            a.bend = 15.0f + 75.0f * lift;
        }
    } else if (pose == WaterPose::Paddle) {
        // The breaststroke, upright: both arms together reach forward and
        // sweep out and back, elbows bending as they pull, then come in
        // under the chin and reach again; the legs, half a stroke later,
        // draw the knees up and out and kick back straight.
        const float u = 0.5f - 0.5f * std::cos(phase);
        const float v = 0.5f - 0.5f * std::cos(phase + kPi);
        if (kind == LimbKind::Arm) {
            a.pitch = 95.0f - 45.0f * u;
            a.spread = 10.0f + 45.0f * u;
            a.bend = 15.0f + 75.0f * u;
        } else {
            a.pitch = 15.0f + 45.0f * v;
            a.spread = 5.0f + 25.0f * v;
            a.bend = 10.0f + 90.0f * v;
        }
    } else if (pose == WaterPose::Tread) {
        if (kind == LimbKind::Arm) {
            // Sculling: arms out and forward, forearms sweeping in and out
            // together.
            a.pitch = 25.0f + 20.0f * std::sin(phase);
            a.spread = 40.0f + 10.0f * std::sin(phase + 0.5f * kPi);
            a.bend = 55.0f + 20.0f * std::sin(phase + 0.5f * kPi);
        } else {
            // The egg-beater: thighs forward and apart, each knee circling,
            // the legs half a cycle apart.
            const float k = phase + (right ? 0.0f : kPi);
            a.pitch = 45.0f + 15.0f * std::sin(k);
            a.spread = 12.0f;
            a.bend = 75.0f + 25.0f * std::sin(k + 0.5f * kPi);
        }
    }
    return a;
}

float strokeRate(WaterPose pose, float speed) {
    switch (pose) {
    case WaterPose::Swim:
        return 2.0f * kPi * (0.45f + 0.2f * std::clamp(speed, 0.0f, 4.0f));
    case WaterPose::Tread:
        return 2.0f * kPi * 0.8f;
    case WaterPose::Paddle:
        return 2.0f * kPi * (0.55f + 0.15f * std::clamp(speed, 0.0f, 4.0f));
    case WaterPose::Climb:
        // One reach of each hand for every 0.9 nodes climbed, up or down,
        // and still while the body holds on in place.
        return 2.0f * kPi * std::fabs(speed) / 0.9f;
    default:
        return 0.0f;
    }
}

float landDepth(float fall_speed) {
    // A step down (about 4.4 nodes a second off one node) is a small give,
    // a drop of several nodes the full crouch.
    if (fall_speed < 1.5f)
        return 0.0f;
    return std::clamp((fall_speed - 1.5f) / (kLandHard - 1.5f), 0.1f, 1.0f);
}

LimbAngles landAngles(LimbKind kind, float d) {
    LimbAngles a;
    if (d <= 0.0f)
        return a;
    if (kind == LimbKind::Leg) {
        // Hips forward and knees bent: a crouch.
        a.pitch = 50.0f * d;
        a.bend = 85.0f * d;
    } else {
        // Arms forward and a little bent, for balance.
        a.pitch = 30.0f * d;
        a.bend = 35.0f * d;
    }
    return a;
}

float legShortening(float upper, float lower, float hip, float knee) {
    // The thigh hangs `hip` degrees forward of straight down; the shin
    // turns back from the thigh by `knee`, so it hangs `hip - knee` from
    // straight down. Their heights together, against the straight leg's.
    const float a = hip / kDeg, b = (hip - knee) / kDeg;
    return upper * (1.0f - std::cos(a)) + lower * (1.0f - std::cos(b));
}

} // namespace goanna
