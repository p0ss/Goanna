// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Jiggle bones: reading the marks from a glTF's node extras, building a
// model's rig (tips and collider capsules from its rest pose), and the
// per instance solver. See goanna_jiggle.h and
// docs/systems/jiggle-bones.md.

#include "goanna_jiggle.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <memory>

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/quaternion.hpp>

#include <json/json.h>

#include <IVertexBuffer.h>
#include <SSkinMeshBuffer.h>

#include "goanna_models.h"

using godot::Basis;
using godot::Quaternion;
using godot::Transform3D;
using godot::Vector3;

namespace goanna {

const char *const JIGGLE_FALLBACK_COLLIDERS[6] = {
    "chest", "body", "leg_left", "leg_right", "leg_left_lower", "leg_right_lower",
};

float jiggleOmega(float stiffness) {
    return 2.0f + 18.0f * std::clamp(stiffness, 0.0f, 1.0f);
}

// ---- the marks -------------------------------------------------------------

namespace {

bool endsWith(const std::string &s, const char *suffix) {
    const size_t n = std::strlen(suffix);
    if (s.size() < n)
        return false;
    for (size_t i = 0; i < n; ++i)
        if (std::tolower((unsigned char)s[s.size() - n + i]) != suffix[i])
            return false;
    return true;
}

u32 readU32(const std::string &b, size_t at) {
    return (u32)(unsigned char)b[at] | (u32)(unsigned char)b[at + 1] << 8
            | (u32)(unsigned char)b[at + 2] << 16 | (u32)(unsigned char)b[at + 3] << 24;
}

float number(const Json::Value &o, const char *key, float fallback) {
    const Json::Value &v = o[key];
    return v.isNumeric() ? v.asFloat() : fallback;
}

} // namespace

bool parseModelExtras(const std::string &name, const std::string &bytes, ModelExtras &out) {
    out = ModelExtras();
    std::string json;
    if (endsWith(name, ".gltf")) {
        json = bytes;
    } else if (endsWith(name, ".glb")) {
        // Header: magic, version, length; then the JSON chunk, which the
        // format requires to come first.
        if (bytes.size() < 20 || bytes.compare(0, 4, "glTF") != 0)
            return false;
        const u32 len = readU32(bytes, 12);
        if (readU32(bytes, 16) != 0x4E4F534Au || 20 + (size_t)len > bytes.size())
            return false;
        json = bytes.substr(20, len);
    } else {
        return false;
    }
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value root;
    std::string errors;
    if (!reader->parse(json.data(), json.data() + json.size(), &root, &errors) || !root.isObject())
        return false;
    const Json::Value &nodes = root["nodes"];
    if (!nodes.isArray())
        return true;
    for (const Json::Value &node : nodes) {
        if (!node.isObject() || !node["name"].isString() || !node["extras"].isObject())
            continue;
        const std::string node_name = node["name"].asString();
        const Json::Value &extras = node["extras"];
        const Json::Value &j = extras["jiggle"];
        if (j.isObject()) {
            JiggleParams p;
            p.stiffness = std::clamp(number(j, "stiffness", p.stiffness), 0.0f, 1.0f);
            p.damping = std::clamp(number(j, "damping", p.damping), 0.0f, 1.0f);
            p.gravity = number(j, "gravity", p.gravity);
            p.limit_degrees = std::clamp(number(j, "limit_degrees", p.limit_degrees), 0.0f, 180.0f);
            p.chain = j["chain"].isString() ? j["chain"].asString() : node_name;
            out.jiggle[node_name] = p;
        }
        const Json::Value &c = extras["jiggle_collider"];
        if (c.isObject()) {
            JiggleColliderMark m;
            m.radius = std::max(0.0f, number(c, "radius", 0.0f));
            if (c["tip"].isString())
                m.tip = c["tip"].asString();
            out.colliders[node_name] = m;
        }
    }
    return true;
}

// ---- the rig ---------------------------------------------------------------

namespace {

Transform3D localOf(const scene::SkinnedMesh::SJoint::VariantTransform &t) {
    if (const auto *m = std::get_if<core::matrix4>(&t))
        return toGodotTransform(*m);
    return toGodotTransform(std::get<core::Transform>(t).buildMatrix());
}

// A vertex the joint carries, at rest, mesh space (Godot handedness).
struct Carried {
    Vector3 pos;
    float weight;
};

} // namespace

JiggleRig buildJiggleRig(const scene::SkinnedMesh &mesh, const ModelExtras *extras) {
    JiggleRig rig;
    const auto &joints = mesh.getAllJoints();
    const size_t n = joints.size();
    if (!n)
        return rig;
    // The rest pose: each joint's global transform, and the skin matrix that
    // takes a vertex from where the file has it to where the rest pose draws
    // it (the identity when the bind pose is the rest pose).
    std::vector<core::matrix4> globals(n);
    for (size_t i = 0; i < n; ++i) {
        if (const auto *m = std::get_if<core::matrix4>(&joints[i]->transform))
            globals[i] = *m;
        else
            globals[i] = std::get<core::Transform>(joints[i]->transform).buildMatrix();
    }
    mesh.calculateGlobalMatrices(globals);
    const std::vector<core::matrix4> skin = mesh.calculateSkinMatrices(globals);
    std::vector<Transform3D> rest(n);
    for (size_t i = 0; i < n; ++i)
        rest[i] = toGodotTransform(globals[i]);

    // The vertices each joint carries.
    std::vector<std::vector<Carried>> carried(n);
    for (u32 b = 0; b < mesh.getMeshBufferCount(); ++b) {
        const auto *buf = static_cast<const scene::SSkinMeshBuffer *>(
                const_cast<scene::SkinnedMesh &>(mesh).getMeshBuffer(b));
        const scene::WeightBuffer *w = buf ? buf->getWeights() : nullptr;
        if (!w)
            continue;
        const scene::IVertexBuffer *vb = buf->getVertexBuffer();
        for (u32 v = 0; v < vb->getCount(); ++v) {
            const auto &ids = w->getJointIds(v);
            const auto &ws = w->getWeights(v);
            for (int k = 0; k < 4; ++k) {
                if (ws[k] <= 0.0f || ids[k] >= n)
                    continue;
                core::vector3df p = vb->getPosition(v);
                skin[ids[k]].transformVect(p);
                carried[ids[k]].push_back({Vector3(p.X, p.Y, -p.Z), ws[k]});
            }
        }
    }

    auto childrenOf = [&](size_t j) {
        std::vector<size_t> out;
        for (size_t i = 0; i < n; ++i)
            if (joints[i]->ParentJointID && *joints[i]->ParentJointID == j)
                out.push_back(i);
        return out;
    };
    auto name = [&](size_t j) -> std::string {
        return joints[j]->Name ? *joints[j]->Name : std::string();
    };

    // Jiggle bones, in joint order, which is parents first (the joints are
    // topologically sorted; SkinnedMesh::calculateGlobalMatrices relies on
    // it too).
    if (extras) {
        for (size_t j = 0; j < n; ++j) {
            auto it = extras->jiggle.find(name(j));
            if (it == extras->jiggle.end())
                continue;
            JiggleBone bone;
            bone.joint = (int)j;
            bone.params = it->second;
            // Tip: the child in the same chain, else any child, else the far
            // end of what the bone carries.
            const std::vector<size_t> kids = childrenOf(j);
            int tip_child = -1;
            for (size_t k : kids) {
                auto kt = extras->jiggle.find(name(k));
                if (kt != extras->jiggle.end() && kt->second.chain == bone.params.chain) {
                    tip_child = (int)k;
                    break;
                }
            }
            if (tip_child < 0 && !kids.empty())
                tip_child = (int)kids.front();
            if (tip_child >= 0) {
                bone.tip_local = localOf(joints[tip_child]->transform).origin;
            } else {
                // A leaf: towards the weighted centroid of its vertices, as
                // far as the furthest of them reaches along that line.
                const Vector3 head = rest[j].origin;
                Vector3 sum;
                float total = 0.0f;
                for (const Carried &c : carried[j]) {
                    sum += c.pos * c.weight;
                    total += c.weight;
                }
                Vector3 dir(0, -1, 0);
                float length = 0.0f;
                if (total > 0.0f) {
                    const Vector3 off = sum / total - head;
                    if (off.length() > 1e-4f)
                        dir = off.normalized();
                    for (const Carried &c : carried[j])
                        length = std::max(length, (c.pos - head).dot(dir));
                }
                if (length < 1e-3f)
                    length = 0.25f; // carries nothing: a quarter mesh unit down
                bone.tip_local = rest[j].affine_inverse().xform(head + dir * length);
            }
            if (bone.tip_local.length() > 1e-5f)
                rig.bones.push_back(bone);
        }
    }

    // Colliders: the marked ones, or else the fallback bones.
    const bool marked = extras && !extras->colliders.empty();
    for (size_t j = 0; j < n; ++j) {
        const std::string nm = name(j);
        if (marked) {
            auto it = extras->colliders.find(nm);
            if (it == extras->colliders.end() || it->second.radius <= 0.0f)
                continue;
            JiggleCollider c;
            c.joint = (int)j;
            c.radius = it->second.radius;
            c.a_local = Vector3();
            c.b_local = Vector3();
            if (auto tip = mesh.getJointNumber(it->second.tip))
                c.b_local = rest[j].affine_inverse().xform(rest[*tip].origin);
            rig.colliders.push_back(c);
            continue;
        }
        if (std::find_if(std::begin(JIGGLE_FALLBACK_COLLIDERS), std::end(JIGGLE_FALLBACK_COLLIDERS),
                    [&](const char *f) { return nm == f; }) == std::end(JIGGLE_FALLBACK_COLLIDERS))
            continue;
        // From the mesh extent: the box round the vertices the bone carries
        // most of (weight at least a half), in the bone's own frame. The
        // capsule runs along the box's longest side through its middle, its
        // radius the larger of the other two half sides, its ends rounded
        // inside the box's ends.
        const Transform3D to_bone = rest[j].affine_inverse();
        Vector3 lo(1e30f, 1e30f, 1e30f), hi(-1e30f, -1e30f, -1e30f);
        int count = 0;
        for (const Carried &cv : carried[j]) {
            if (cv.weight < 0.5f)
                continue;
            const Vector3 p = to_bone.xform(cv.pos);
            lo = Vector3(std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z));
            hi = Vector3(std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z));
            ++count;
        }
        if (count < 2)
            continue;
        const Vector3 mid = (lo + hi) * 0.5f, half = (hi - lo) * 0.5f;
        int axis = 0;
        if (half.y > half[axis])
            axis = 1;
        if (half.z > half[axis])
            axis = 2;
        float radius = 0.0f;
        for (int k = 0; k < 3; ++k)
            if (k != axis)
                radius = std::max(radius, half[k]);
        if (radius <= 0.0f)
            continue;
        Vector3 along;
        along[axis] = std::max(0.0f, half[axis] - radius);
        JiggleCollider c;
        c.joint = (int)j;
        c.radius = radius;
        c.a_local = mid - along;
        c.b_local = mid + along;
        rig.colliders.push_back(c);
    }
    return rig;
}

// ---- the solver ------------------------------------------------------------

namespace {

Vector3 closestOnSegment(const Vector3 &a, const Vector3 &b, const Vector3 &p) {
    const Vector3 ab = b - a;
    const float len2 = ab.length_squared();
    if (len2 < 1e-12f)
        return a;
    return a + ab * std::clamp((p - a).dot(ab) / len2, 0.0f, 1.0f);
}

// Keeps a tip `x` on the sphere of radius `length` round the pivot, within
// `limit` radians of the target direction, and outside the capsules.
Vector3 constrain(Vector3 x, const Vector3 &pivot, const Vector3 &target_dir, float length,
        float limit, const std::vector<JiggleCapsule> &capsules) {
    for (int iter = 0; iter < 3; ++iter) {
        Vector3 d = x - pivot;
        const float len = d.length();
        d = len > 1e-6f ? d / len : target_dir;
        const float cosang = std::clamp(d.dot(target_dir), -1.0f, 1.0f);
        if (std::acos(cosang) > limit) {
            Vector3 axis = target_dir.cross(d);
            if (axis.length_squared() < 1e-12f)
                axis = std::fabs(target_dir.x) < 0.9f ? target_dir.cross(Vector3(1, 0, 0))
                                                      : target_dir.cross(Vector3(0, 1, 0));
            d = target_dir.rotated(axis.normalized(), limit);
        }
        x = pivot + d * length;
        bool pushed = false;
        for (const JiggleCapsule &c : capsules) {
            const Vector3 q = closestOnSegment(c.a, c.b, x);
            Vector3 off = x - q;
            const float dist = off.length();
            if (dist >= c.radius)
                continue;
            // Straight out from the capsule's axis; a tip right on the axis
            // goes out the way the bone points from the pivot.
            off = dist > 1e-6f ? off / dist : d;
            x = q + off * c.radius;
            pushed = true;
        }
        if (!pushed)
            break;
    }
    return x;
}

Transform3D interpolate(const Transform3D &a, const Transform3D &b, float t) {
    return a.interpolate_with(b, t);
}

} // namespace

void JiggleSolver::step(const JiggleRig &rig, const scene::SkinnedMesh &mesh, float dt,
        const JiggleFrame &frame, JointTransforms &locals) {
    if (rig.bones.empty())
        return;
    if (!frame.simulate || locals.size() != mesh.getAllJoints().size()) {
        m_have = false;
        m_last_steps = 0;
        return;
    }
    if (m_state.size() != rig.bones.size()) {
        m_state.assign(rig.bones.size(), State());
        m_have = false;
    }
    const Transform3D &world = frame.mesh_to_world;
    // A teleport, or a jump the bones cannot have followed.
    if (m_have && (world.origin - m_prev_world.origin).length() > JIGGLE_TELEPORT)
        m_have = false;
    if (!m_have) {
        solve(rig, mesh, world, 0.0f, true, false, frame.colliders, locals);
        m_have = true;
        m_acc = 0.0f;
        m_prev_world = world;
    }
    m_acc += std::clamp(dt, 0.0f, 0.25f);
    int steps = (int)(m_acc / JIGGLE_STEP);
    if (steps > JIGGLE_MAX_STEPS) {
        // Behind by more than the cap allows (a long frame): catch up
        // what the cap allows and drop the rest, rather than spiral.
        steps = JIGGLE_MAX_STEPS;
        m_acc = 0.0f;
    } else {
        m_acc -= steps * JIGGLE_STEP;
    }
    // Each step sees the model's frame part of the way from last frame's to
    // this one's, so a fast moving body still swings its bones smoothly.
    for (int s = 0; s < steps; ++s)
        solve(rig, mesh, interpolate(m_prev_world, world, (float)(s + 1) / (float)steps),
                JIGGLE_STEP, false, false, frame.colliders, locals);
    // The pose drawn: the tips where the steps left them, against where the
    // pivots are this frame.
    solve(rig, mesh, world, 0.0f, false, true, frame.colliders, locals);
    m_prev_world = world;
    m_last_steps = steps;
}

void JiggleSolver::solve(const JiggleRig &rig, const scene::SkinnedMesh &mesh,
        const Transform3D &world, float h, bool init, bool write,
        const std::vector<JiggleCapsule> &colliders, JointTransforms &locals) {
    const auto &joints = mesh.getAllJoints();
    const size_t n = joints.size();
    // Globals down the joints, each jiggle bone turned before its children
    // are placed on it.
    std::vector<Transform3D> g(n);
    size_t next = 0;
    const Transform3D to_mesh = world.affine_inverse();
    const Vector3 gravity(0, -JIGGLE_GRAVITY, 0);
    for (size_t i = 0; i < n; ++i) {
        const auto parent = joints[i]->ParentJointID;
        g[i] = parent ? g[*parent] * localOf(locals[i]) : localOf(locals[i]);
        if (next >= rig.bones.size() || rig.bones[next].joint != (int)i)
            continue;
        const JiggleBone &bone = rig.bones[next];
        State &st = m_state[next];
        ++next;
        const Vector3 head = g[i].origin;
        const Vector3 tip = g[i].xform(bone.tip_local);
        const Vector3 pivot = world.xform(head);
        const Vector3 target = world.xform(tip);
        const float length = (target - pivot).length();
        if (length < 1e-6f)
            continue;
        const Vector3 target_dir = (target - pivot) / length;
        st.pivot = pivot;
        st.target = target;
        if (init) {
            st.x = target;
            st.v = Vector3();
            st.t_prev = target;
        }
        const float limit = bone.params.limit_degrees * (float)M_PI / 180.0f;
        Vector3 x = st.x;
        if (h > 0.0f) {
            const float omega = jiggleOmega(bone.params.stiffness);
            const float zeta = bone.params.damping;
            // A damped spring pulling the tip toward where the target pose
            // has it, damped against the target's own motion (so a body
            // walking steadily does not drag its skirt behind it), and
            // gravity. The bone's inertia is the tip lagging its moving
            // target. The spring pulls from where the target was at the
            // start of the step, where the tip is: pulling toward its end
            // led the tip by a step's worth of the body's speed, so a body
            // accelerating steadily swung its skirt forward, not back.
            const Vector3 target_vel = (target - st.t_prev) / h;
            const Vector3 accel = (st.t_prev - st.x) * (omega * omega)
                    + (target_vel - st.v) * (2.0f * zeta * omega) + gravity * bone.params.gravity;
            st.t_prev = target;
            const Vector3 start = st.x;
            st.v += accel * h;
            x = constrain(st.x + st.v * h, pivot, target_dir, length, limit, colliders);
            st.v = (x - start) / h;
            st.x = x;
        } else {
            x = constrain(x, pivot, target_dir, length, limit, colliders);
            if (init)
                st.x = x;
        }
        st.shown = x;
        // Turn the bone so its tip points where the simulation has it,
        // about its head, in mesh space: the shortest arc keeps its length
        // and its twist as near the target's as a swing allows.
        const Vector3 from = tip - head;
        const Vector3 to = to_mesh.xform(x) - head;
        if (from.length_squared() < 1e-12f || to.length_squared() < 1e-12f)
            continue;
        const Vector3 f = from.normalized(), t = to.normalized();
        if (f.dot(t) > 0.9999999f)
            continue;
        const Quaternion arc(f, t);
        g[i].basis = Basis(arc) * g[i].basis;
        if (write) {
            const Transform3D local = parent ? g[*parent].affine_inverse() * g[i] : g[i];
            locals[i] = fromGodotTransform(local);
        }
    }
}

} // namespace goanna
