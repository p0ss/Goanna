// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Knees, elbows and water strokes (goanna_limbs.h), with no Godot runtime.
// Not built by default: cmake --build build --target goanna_limbs_test
//
// A character is built in code the shape of Minetest Game's (a body, a
// head, four limb boxes 12 pixels long on a 64 by 32 skin, and a walk that
// swings the limbs 40 degrees either way), so the test needs no game. If
// Mineclonia's and Minetest Game's own player models are installed where
// the Luanti flatpak keeps them, they are checked too.
//
// Checked: the four limbs are found by name and cut at mid height; no
// triangle of a limb crosses its cut after the split, the half below is on
// the limb's lower bone and the cut on its seam bone, and the cut's texture
// coordinates land on a pixel line; a knee bends the foot back and an elbow
// the hand forward, turning about the joint, and the seam's half turn keeps
// the joint's thickness; walking bends the knees coming through and the
// elbows swinging forward; the crawl takes both arms backward round over the
// back, half a stroke apart, and treading water spreads the arms and bends
// the knees; and the strokes ease in and out.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <IVertexBuffer.h>
#include <SSkinMeshBuffer.h>
#include <SkinnedMesh.h>

#include "activeobject.h"
#include "goanna_limbs.h"
#include "goanna_models.h"

using namespace goanna;
using godot::Vector3;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_limbs_test: " << message << "\n";
    }
}

// A box on `joint` from `lo` to `hi` (mesh units), each face its own quad
// with a 64 by 32 skin's texture coordinates: the sides span `v0` to `v1`
// down the limb.
void addBox(scene::SkinnedMeshBuilder &b, scene::SSkinMeshBuffer *buf, u16 buf_id,
        scene::SkinnedMesh::SJoint *joint, core::vector3df lo, core::vector3df hi, float v0, float v1) {
    const core::vector3df c[8] = {
        {lo.X, lo.Y, lo.Z}, {hi.X, lo.Y, lo.Z}, {hi.X, hi.Y, lo.Z}, {lo.X, hi.Y, lo.Z},
        {lo.X, lo.Y, hi.Z}, {hi.X, lo.Y, hi.Z}, {hi.X, hi.Y, hi.Z}, {lo.X, hi.Y, hi.Z},
    };
    // Four corners of each face, counter-clockwise from outside, and
    // whether it is a side (the texture runs down it) or an end.
    const int faces[6][4] = {{0, 1, 2, 3}, {5, 4, 7, 6}, {4, 0, 3, 7}, {1, 5, 6, 2}, {3, 2, 6, 7}, {4, 5, 1, 0}};
    const core::vector3df normals[6] = {{0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, -1, 0}};
    for (int f = 0; f < 6; ++f) {
        const u32 base = buf->Vertices_Standard->Data.size();
        const bool side = f < 4;
        for (int k = 0; k < 4; ++k) {
            const core::vector3df &p = c[faces[f][k]];
            float u = (k == 1 || k == 2) ? 0.0625f : 0.0f;
            float v = side ? (p.Y == hi.Y ? v0 : v1) : (k < 2 ? v0 : v0 + 0.125f);
            buf->Vertices_Standard->Data.push_back(video::S3DVertex(p, normals[f], video::SColor(255, 255, 255, 255),
                    core::vector2df(u, v)));
            b.addWeight(joint, buf_id, base + k, 1.0f);
        }
        for (u32 k : {0u, 1u, 2u, 0u, 2u, 3u})
            buf->Indices->Data.push_back((u16)(base + k));
    }
}

// The test character, in the shape of Minetest Game's (units of 1/10 node).
scene::SkinnedMesh *buildCharacter() {
    scene::SkinnedMeshBuilder b(scene::SkinnedMesh::SourceFormat::B3D);
    auto joint = [&](scene::SkinnedMesh::SJoint *parent, const char *name, core::vector3df t) {
        auto *j = b.addJoint(parent);
        j->Name = name;
        core::Transform tr;
        tr.translation = t;
        j->transform = tr;
        return j;
    };
    auto *root = joint(nullptr, "Player", {0, 0, 0});
    auto *body = joint(root, "Body", {0, 6.3f, 0});
    auto *head = joint(body, "Head", {0, 6.3f, 0});
    auto *arm_l = joint(body, "Arm_Left", {3.15f, 5.25f, 0});
    auto *arm_r = joint(body, "Arm_Right", {-3.15f, 5.25f, 0});
    auto *leg_r = joint(body, "Leg_Right", {-1.05f, 0, 0});
    auto *leg_l = joint(body, "Leg_Left", {1.05f, 0, 0});
    // Where a held item hangs, near the left hand, as Mineclonia's
    // Wield_Item hangs under its arm.
    joint(arm_l, "Wield_Item", {0.0f, -5.8f, 0.0f});
    scene::SSkinMeshBuffer *buf = b.addMeshBuffer();
    addBox(b, buf, 0, body, {-2.1f, 6.3f, -1.05f}, {2.1f, 12.6f, 1.05f}, 0.625f, 1.0f);
    addBox(b, buf, 0, head, {-2.1f, 12.6f, -2.1f}, {2.1f, 16.8f, 2.1f}, 0.0f, 0.25f);
    addBox(b, buf, 0, arm_l, {2.1f, 6.3f, -1.05f}, {4.2f, 12.6f, 1.05f}, 0.625f, 1.0f);
    addBox(b, buf, 0, arm_r, {-4.2f, 6.3f, -1.05f}, {-2.1f, 12.6f, 1.05f}, 0.625f, 1.0f);
    addBox(b, buf, 0, leg_r, {-2.1f, 0.0f, -1.05f}, {0.0f, 6.3f, 1.05f}, 0.625f, 1.0f);
    addBox(b, buf, 0, leg_l, {0.0f, 0.0f, -1.05f}, {2.1f, 6.3f, 1.05f}, 0.625f, 1.0f);
    // A walk, frames 0 to 20: legs and arms swing 40 degrees either way,
    // each arm with the opposite leg. Keys go straight into the animation
    // (finalize renumbers its joint ids with the joints').
    scene::SkinnedMesh::Animation &walk = b.getSingleAnimation();
    auto swing = [&](scene::SkinnedMesh::SJoint *j, float sign) {
        scene::SkinnedMesh::Animation::JointKeys jk;
        jk.joint_id = j->JointID;
        for (int f = 0; f <= 20; ++f) {
            const float a = sign * 40.0f * core::DEGTORAD * std::sin(f / 20.0f * 2.0f * core::PI);
            core::quaternion q;
            q.fromAngleAxis(a, core::vector3df(1, 0, 0));
            jk.keys.rotation.pushBack((f32)f, q);
        }
        walk.joint_keys.push_back(jk);
    };
    swing(leg_r, 1.0f);
    swing(leg_l, -1.0f);
    swing(arm_l, 1.0f);
    swing(arm_r, -1.0f);
    return std::move(b).finalize();
}

std::string slurp(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

const LimbBend *limbNamed(const std::vector<LimbBend> &limbs, LimbKind kind, bool right) {
    for (const LimbBend &l : limbs)
        if (l.kind == kind && l.right == right)
            return &l;
    return nullptr;
}

// A skinned mesh as the animator takes it: buildGodotModel without the
// Godot mesh, which needs the engine. The limbs and their bones as
// buildGodotModel finds and numbers them.
std::shared_ptr<GodotModel> animatorModel(scene::SkinnedMesh *mesh) {
    auto model = std::make_shared<GodotModel>();
    mesh->grab();
    model->source = mesh;
    mesh->grab();
    model->skinned = mesh;
    model->animated = true;
    model->joint_count = (int)mesh->getAllJoints().size();
    model->attached_bone.assign(model->joint_count, -1);
    model->bone_count = model->joint_count;
    model->limbs = findLimbs(*mesh);
    for (LimbBend &l : model->limbs) {
        l.bone = model->bone_count++;
        l.seam_bone = model->bone_count++;
    }
    return model;
}

// Each buffer of `mesh` as buildGodotModel assembles it (z mirrored, the
// strongest weight first), cut by splitLimbs.
std::vector<LimbMeshData> splitBuffers(const scene::IAnimatedMesh *mesh, const std::vector<LimbBend> &limbs) {
    std::vector<LimbMeshData> out;
    for (u32 b = 0; b < mesh->getMeshBufferCount(); ++b) {
        const auto *buf = static_cast<const scene::SSkinMeshBuffer *>(mesh->getMeshBuffer(b));
        const scene::WeightBuffer *w = buf->getWeights();
        LimbMeshData d;
        const u32 n = buf->getVertexBuffer()->getCount();
        for (u32 i = 0; i < n; ++i) {
            const core::vector3df p = buf->getVertexBuffer()->getPosition(i);
            const core::vector3df nr = buf->getVertexBuffer()->getNormal(i);
            const core::vector2df uv = buf->getVertexBuffer()->getTCoords(i);
            d.verts.push_back(Vector3(p.X, p.Y, -p.Z));
            d.normals.push_back(Vector3(nr.X, nr.Y, -nr.Z));
            d.uvs.push_back(godot::Vector2(uv.X, uv.Y));
            for (int k = 0; k < 4; ++k) {
                d.bones.push_back(w ? w->getJointIds(i)[k] : 0);
                d.weights.push_back(w ? w->getWeights(i)[k] : (k == 0 ? 1.0f : 0.0f));
            }
        }
        const scene::IIndexBuffer *ib = buf->getIndexBuffer();
        for (u32 i = 0; i < ib->getCount(); ++i)
            d.indices.push_back(ib->getType() == video::EIT_16BIT
                    ? (int)static_cast<const u16 *>(ib->getData())[i]
                    : (int)static_cast<const u32 *>(ib->getData())[i]);
        splitLimbs(limbs, d);
        out.push_back(d);
    }
    return out;
}

// Every limb triangle keeps to one side of its limb's cut, lower half and
// seam on their bones; seam texture coordinates land on the skin's pixel
// lines (a 64 pixel tall skin's, which a 32 tall one's are among).
void checkSplit(const std::vector<LimbMeshData> &buffers, const std::vector<LimbBend> &limbs,
        const std::string &what) {
    int crossing = 0, off_pixel = 0, seams = 0, lowers = 0, wrong_bone = 0;
    for (const LimbMeshData &d : buffers) {
        const auto &v = d.verts;
        const auto &uv = d.uvs;
        const auto &idx = d.indices;
        const auto &bones = d.bones;
        for (const LimbBend &l : limbs) {
            auto on = [&](int i) {
                return bones[i * 4] == l.joint || bones[i * 4] == l.bone || bones[i * 4] == l.seam_bone;
            };
            // No triangle joins the half above the cut to the half below.
            for (size_t t = 0; t + 2 < idx.size(); t += 3) {
                const int tri[3] = {idx[t], idx[t + 1], idx[t + 2]};
                if (!on(tri[0]) || !on(tri[1]) || !on(tri[2]))
                    continue;
                bool up = false, down = false;
                for (int i : tri) {
                    up |= bones[i * 4] == l.joint;
                    down |= bones[i * 4] == l.bone;
                }
                crossing += up && down;
            }
            // The halves on the right sides of the seam, near the limb's
            // cut, and the seam on a pixel line. A box that only just
            // crosses the cut goes whole to one side, so a vertex may be up
            // to half a pixel over it.
            for (int i = 0; i < (int)v.size(); ++i) {
                if (!on(i))
                    continue;
                const float y = v[i].y;
                if (bones[i * 4] == l.seam_bone) {
                    ++seams;
                    wrong_bone += std::fabs(y - l.cut_y) > 0.3f;
                    const float px = uv[i].y * 64.0f;
                    off_pixel += std::fabs(px - std::round(px)) > 1e-2f;
                } else if (bones[i * 4] == l.bone) {
                    ++lowers;
                    wrong_bone += y > l.cut_y + 0.3f;
                } else {
                    wrong_bone += y < l.cut_y - 0.3f;
                }
            }
        }
    }
    std::printf("%s: %d seam and %d lower vertices on %zu limbs\n", what.c_str(), seams, lowers,
            limbs.size());
    expect(crossing == 0, what + ": " + std::to_string(crossing) + " limb triangles cross their cut");
    expect(seams > 0 && lowers > 0, what + ": nothing was cut");
    expect(wrong_bone == 0, what + ": " + std::to_string(wrong_bone) + " limb vertices on the wrong bone");
    expect(off_pixel == 0, what + ": " + std::to_string(off_pixel) + " seam texture coordinates off a pixel line");
}

} // namespace

int main() {
    scene::SkinnedMesh *mesh = buildCharacter();
    expect(mesh != nullptr, "the test character did not build");
    if (!mesh)
        return 1;

    // 1. The limbs, found and cut.
    auto model = animatorModel(mesh);
    expect(model->limbs.size() == 4, "found " + std::to_string(model->limbs.size()) + " limbs, not 4");
    const LimbBend *knee = limbNamed(model->limbs, LimbKind::Leg, true);
    const LimbBend *elbow = limbNamed(model->limbs, LimbKind::Arm, false);
    expect(knee && elbow, "a leg or an arm is missing");
    if (!knee || !elbow)
        return 1;
    expect(std::fabs(knee->cut_y - 3.15f) < 1e-3f && std::fabs(elbow->cut_y - 9.45f) < 1e-3f,
            "the cuts are not at mid height");
    expect(std::fabs(knee->pivot.x - -1.05f) < 1e-3f && std::fabs(knee->pivot.z) < 1e-3f,
            "the knee does not turn about the middle of the leg");
    expect(model->bone_count == (int)mesh->getAllJoints().size() + 8,
            "the bones are not the joints and two a limb: " + std::to_string(model->bone_count));
    checkSplit(splitBuffers(mesh, model->limbs), model->limbs, "test character");

    // 2. Which way they bend, and the seam's half turn.
    {
        const Vector3 foot = bendTransform(*knee, 60.0f).xform(knee->end);
        const Vector3 hand = bendTransform(*elbow, 60.0f).xform(elbow->end);
        expect(foot.z > knee->end.z + 1.0f, "a knee bends the foot forward");
        expect(hand.z < elbow->end.z - 1.0f, "an elbow bends the hand back");
        expect(bendTransform(*knee, 60.0f).xform(knee->pivot).distance_to(knee->pivot) < 1e-4f,
                "a knee does not turn about itself");
        // A point on the front of the cut and one on the back, through the
        // seam's half turn at a right angle: as far apart as at rest, where
        // weighting them half to each side would draw them in.
        const Vector3 front = knee->pivot + Vector3(0, 0, -1.05f), back = knee->pivot + Vector3(0, 0, 1.05f);
        const godot::Transform3D seam = bendTransform(*knee, 45.0f);
        const float kept = seam.xform(front).distance_to(seam.xform(back));
        const godot::Transform3D full = bendTransform(*knee, 90.0f);
        const float blended = (front + full.xform(front)).distance_to(back + full.xform(back)) * 0.5f;
        std::printf("a knee at a right angle: the joint %.2f thick by the half turn, %.2f blended, %.2f at rest\n",
                kept, blended, front.distance_to(back));
        expect(std::fabs(kept - 2.1f) < 1e-3f, "the seam does not keep the joint's thickness");
    }

    // 3. Walking bends, and the strokes, as numbers.
    {
        expect(walkBend(LimbKind::Leg, 0.0f, 0.0f) < 10.0f, "a standing knee is bent");
        expect(walkBend(LimbKind::Leg, 0.0f, 300.0f) > 30.0f, "a leg coming through keeps a straight knee");
        expect(walkBend(LimbKind::Leg, 0.0f, 5000.0f) <= 75.0f, "a knee bends past 75 degrees walking");
        expect(walkBend(LimbKind::Arm, 40.0f, 0.0f) > walkBend(LimbKind::Arm, -40.0f, 0.0f),
                "an arm forward is no more bent than one back");
        int over_back = 0, under_chest = 0, apart = 0;
        for (int i = 0; i < 64; ++i) {
            const float phase = (i + 0.5f) / 64.0f * 2.0f * 3.14159265f;
            const LimbAngles r = strokeAngles(WaterPose::Swim, LimbKind::Arm, true, phase);
            const LimbAngles l = strokeAngles(WaterPose::Swim, LimbKind::Arm, false, phase);
            // Forward is -z: a hanging arm turned forward by p points to
            // (0, -cos p, -sin p) in the body's frame.
            const float z = -std::sin(r.pitch / 57.29578f);
            if (phase < 3.14159265f)
                over_back += z > 0.0f;
            else
                under_chest += z < 0.0f;
            apart += std::fabs(std::sin(r.pitch / 57.29578f) + std::sin(l.pitch / 57.29578f)) < 1e-3f;
        }
        expect(over_back == 32 && under_chest == 32,
                "the crawl does not recover over the back and pull under the chest");
        expect(apart == 64, "the arms are not half a stroke apart");
        // The breaststroke: both arms together, reaching forward and
        // sweeping out; the knees drawn up half a stroke after the pull.
        int together = 0;
        float reach = 0.0f, sweep = 0.0f, knee = 0.0f;
        for (int i = 0; i < 64; ++i) {
            const float phase = i / 64.0f * 2.0f * 3.14159265f;
            const LimbAngles r = strokeAngles(WaterPose::Paddle, LimbKind::Arm, true, phase);
            const LimbAngles l = strokeAngles(WaterPose::Paddle, LimbKind::Arm, false, phase);
            together += std::fabs(r.pitch - l.pitch) < 1e-4f && std::fabs(r.spread - l.spread) < 1e-4f;
            reach = std::max(reach, r.pitch);
            sweep = std::max(sweep, r.spread);
            knee = std::max(knee, strokeAngles(WaterPose::Paddle, LimbKind::Leg, true, phase).bend);
        }
        expect(together == 64, "the breaststroke's arms are not together");
        expect(reach > 80.0f && sweep > 40.0f && knee > 80.0f,
                "the breaststroke does not reach forward, sweep out and draw the knees up");
        expect(strokeRate(WaterPose::Paddle, 2.0f) > strokeRate(WaterPose::Paddle, 0.5f),
                "a faster breaststroke is no quicker");
        const LimbAngles tl = strokeAngles(WaterPose::Tread, LimbKind::Leg, true, 1.0f);
        const LimbAngles ta = strokeAngles(WaterPose::Tread, LimbKind::Arm, true, 1.0f);
        expect(ta.spread > 25.0f && tl.bend > 45.0f, "treading water does not spread the arms and bend the knees");
        expect(strokeRate(WaterPose::Swim, 3.0f) > strokeRate(WaterPose::Swim, 0.5f),
                "a faster swimmer does not stroke faster");
    }

    // 4. The animator: walking, then the crawl, then treading water, then
    // out of the water again.
    {
        ModelAnimator anim(model);
        scene::AnimSpec walk;
        scene::TrackAnimSpec t;
        t.min_frame = 0.0f;
        t.max_frame = 20.0f;
        t.fps = 20.0f;
        walk.tracks[0] = t;
        std::map<std::string, BoneOverride> none;
        const float dt = 1.0f / 60.0f;
        std::vector<float> lo(4, 1e9f), hi(4, -1e9f);
        for (int i = 0; i < 180; ++i) {
            anim.step(dt, walk, none, nullptr);
            if (i > 30)
                for (size_t k = 0; k < anim.limbCount(); ++k) {
                    lo[k] = std::min(lo[k], anim.limbBend(k));
                    hi[k] = std::max(hi[k], anim.limbBend(k));
                }
        }
        for (size_t k = 0; k < anim.limbCount(); ++k) {
            const LimbBend &l = anim.limb(k);
            std::printf("walking: %s %s bends %.0f to %.0f degrees\n", l.right ? "right" : "left",
                    l.kind == LimbKind::Leg ? "knee" : "elbow", lo[k], hi[k]);
            expect(hi[k] - lo[k] > 10.0f, "a walking limb does not bend and straighten");
            expect(hi[k] < 80.0f && lo[k] >= 0.0f, "a walking limb bends too far");
        }
        // The crawl, standing still in the air: each hand goes round its
        // shoulder backward, both the same way, a turn and more in 2.5 s.
        anim.setWaterPose(WaterPose::Swim, 1.5f);
        scene::AnimSpec still;
        std::vector<float> turned(4, 0.0f), last(4, 0.0f);
        std::vector<bool> have(4, false);
        for (int i = 0; i < 150; ++i) {
            anim.step(dt, still, none, nullptr);
            for (size_t k = 0; k < anim.limbCount(); ++k) {
                if (anim.limb(k).kind != LimbKind::Arm)
                    continue;
                Vector3 hand;
                anim.limbEnd(k, hand);
                const float y = hand.y - anim.limb(k).cut_y - 3.15f;
                const float a = std::atan2(hand.z, -y);
                if (have[k]) {
                    float d = a - last[k];
                    if (d > 3.14159265f)
                        d -= 2.0f * 3.14159265f;
                    if (d < -3.14159265f)
                        d += 2.0f * 3.14159265f;
                    turned[k] += d;
                }
                last[k] = a;
                have[k] = true;
            }
        }
        for (size_t k = 0; k < anim.limbCount(); ++k)
            if (anim.limb(k).kind == LimbKind::Arm) {
                std::printf("swimming: the %s hand turned %.0f degrees round its shoulder\n",
                        anim.limb(k).right ? "right" : "left", turned[k] * 57.29578f);
                expect(turned[k] > 1.8f * 3.14159265f, "a swimming arm does not go round backward");
            }
        // A held item stays in the hand through the bend: the wield joint
        // keeps its distance from the hand at rest while the elbow is bent.
        {
            size_t left = 0;
            for (size_t k = 0; k < anim.limbCount(); ++k)
                if (anim.limb(k).kind == LimbKind::Arm && !anim.limb(k).right)
                    left = k;
            Vector3 hand;
            anim.limbEnd(left, hand);
            godot::Transform3D wield;
            expect(anim.jointGlobal("Wield_Item", wield), "the wield joint is missing");
            // At rest the wield joint is at the body (6.3) plus the arm's
            // offset (5.25) plus its own (-5.8): y 5.75, under the hand.
            const float rest_gap = Vector3(elbow->end.x, 6.3f + 5.25f - 5.8f, 0.0f).distance_to(elbow->end);
            std::printf("swimming: the held item is %.2f from the hand with the elbow at %.0f degrees (%.2f at rest)\n",
                    wield.origin.distance_to(hand), anim.limbBend(left), rest_gap);
            expect(anim.limbBend(left) > 20.0f, "the elbow is not bent enough to test the held item");
            expect(std::fabs(wield.origin.distance_to(hand) - rest_gap) < 0.05f, "the held item left the hand");
        }
        // The breaststroke: at some point in a stroke both hands are out in
        // front of the body together (Godot's forward is -z).
        anim.setWaterPose(WaterPose::Paddle, 1.5f);
        float front = 1e9f;
        for (int i = 0; i < 150; ++i) {
            anim.step(dt, still, none, nullptr);
            float worst = -1e9f;
            for (size_t k = 0; k < anim.limbCount(); ++k)
                if (anim.limb(k).kind == LimbKind::Arm) {
                    Vector3 hand;
                    anim.limbEnd(k, hand);
                    worst = std::max(worst, hand.z);
                }
            front = std::min(front, worst);
        }
        std::printf("breaststroke: both hands reach %.2f in front of the body\n", -front);
        expect(front < -3.0f, "the breaststroke does not reach both hands forward");
        // Treading water: the hands out to the sides.
        anim.setWaterPose(WaterPose::Tread, 0.0f);
        for (int i = 0; i < 90; ++i)
            anim.step(dt, still, none, nullptr);
        for (size_t k = 0; k < anim.limbCount(); ++k) {
            if (anim.limb(k).kind != LimbKind::Arm)
                continue;
            Vector3 hand;
            anim.limbEnd(k, hand);
            expect(std::fabs(hand.x) > std::fabs(anim.limb(k).end.x) + 1.0f,
                    "treading water does not spread the arms");
        }
        // Out of the water: the strokes ease away, back to the rest.
        anim.setWaterPose(WaterPose::None, 0.0f);
        for (int i = 0; i < 120; ++i)
            anim.step(dt, still, none, nullptr);
        for (size_t k = 0; k < anim.limbCount(); ++k) {
            Vector3 end;
            anim.limbEnd(k, end);
            expect(end.distance_to(anim.limb(k).end) < 1.2f, "a limb stays in its stroke out of the water");
        }
    }

    // 5. The games' own player models, where they are installed.
    const char *home = std::getenv("HOME");
    const std::string games = std::string(home ? home : "") + "/.var/app/org.luanti.luanti/.minetest/games/";
    const std::string real[] = {
        games + "mineclonia/mods/ITEMS/mcl_armor/models/mcl_armor_character.b3d",
        games + "minetest_game/mods/player_api/models/character.b3d",
    };
    ModelLoader loader;
    for (const std::string &path : real) {
        const std::string bytes = slurp(path);
        if (bytes.empty()) {
            std::printf("skipped (not installed): %s\n", path.c_str());
            continue;
        }
        scene::IAnimatedMesh *m = loader.load(path, bytes);
        expect(m != nullptr, "cannot load " + path);
        if (!m)
            continue;
        auto *sm = dynamic_cast<scene::SkinnedMesh *>(m);
        expect(sm != nullptr, path + " is not skinned");
        if (sm) {
            auto gm = animatorModel(sm);
            expect(gm->limbs.size() == 4, path + ": found " + std::to_string(gm->limbs.size()) + " limbs, not 4");
            checkSplit(splitBuffers(sm, gm->limbs), gm->limbs, path.substr(path.rfind('/') + 1));
        }
        m->drop();
    }

    mesh->drop();
    std::cout << "goanna_limbs_test: " << g_checks << " checks, " << g_failures << " failures\n";
    return g_failures == 0 ? 0 : 1;
}
