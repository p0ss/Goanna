// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Natural attacks (goanna_natural.h) without Godot: the plan read from a
// model's extras, the clips bracketing a parameter as the server's Lua
// brackets them (DorfCraft's kit/natural/lib.lua), and the blended pose
// against a small skinned mesh posed the way ModelAnimator poses it.
//
//   goanna_natural_test [model.gltf]   with a model, its plan is read too

#include "goanna_natural.h"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <variant>

#include <json/json.h>

#include <SkinnedMesh.h>

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

bool nearf(float a, float b, float eps = 1e-3f) {
    return std::fabs(a - b) < eps;
}

Json::Value parse(const std::string &text) {
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value v;
    std::string errors;
    reader->parse(text.data(), text.data() + text.size(), &v, &errors);
    return v;
}

// The plan as bake.py writes it (the adult wolf's, trimmed).
const char *PLAN = R"({"state": "kindred_stroke", "format": 5, "hip": 0.71875, "attacks": [
 {"kind": "bite", "clips": ["natural_bite_low", "natural_bite_mid", "natural_bite_high"], "length": 0.9,
  "commit": 0.25, "active": [0.38, 0.6], "heights": [0.254, 0.7882, 2.0878], "reach": [1.936, 2.1566, 1.674]},
 {"kind": "lunge", "clips": ["natural_lunge_low", "natural_lunge_mid", "natural_lunge_high"], "length": 1.3,
  "commit": 0.3, "active": [0.48, 0.74], "travel": {"from": 0.3, "to": 0.66, "distance": 1.1}}]})";

void testPlan() {
    NaturalPlan plan;
    check(parseNaturalPlan(parse(PLAN), plan), "the plan parses");
    check(plan.state == "kindred_stroke", "the state bone");
    check(plan.attacks.size() == 2, "two attacks");
    check(plan.attacks[1].kind == "lunge" && plan.attacks[1].clips.size() == 3, "the lunge's three clips");
    check(nearf(plan.attacks[0].length, 0.9f), "the bite's length");
    NaturalPlan bad;
    check(!parseNaturalPlan(parse(R"({"attacks": [{"kind": "bite", "clips": []}]})"), bad), "no clips is refused");
    check(!parseNaturalPlan(parse(R"({"attacks": []})"), bad), "no attacks is refused");
}

void testBracket() {
    // As lib.lua's N.bracket and N.nearest, for three variants.
    struct Case {
        float p;
        int a, b;
        float w;
    } cases[] = {{0.0f, 0, 1, 0.0f}, {0.4f, 0, 1, 0.4f}, {1.0f, 1, 2, 0.0f}, {1.25f, 1, 2, 0.25f},
            {2.0f, 1, 2, 1.0f}, {-1.0f, 0, 1, 0.0f}, {5.0f, 1, 2, 1.0f}};
    for (const Case &c : cases) {
        const NaturalBlend b = naturalBracket(3, c.p);
        check(b.a == c.a && b.b == c.b && nearf(b.weight, c.w), "bracket of a parameter");
    }
    check(naturalNearest(3, 1.49f) == 1 && naturalNearest(3, 1.5f) == 2 && naturalNearest(3, 9.0f) == 2,
            "nearest clip");
    check(naturalNearest(3, NAN) == 0 && naturalBracket(3, NAN).weight == 0.0f, "a bad parameter is the first clip");
}

// A neck and a tail on a root; three clips hold the neck at -40, -10 and
// +20 degrees about X over frames 0 to 1; no clip moves the tail.
scene::SkinnedMesh *buildMesh() {
    scene::SkinnedMeshBuilder b(scene::SkinnedMesh::SourceFormat::OTHER);
    auto *root = b.addJoint();
    root->Name = "root";
    auto *neck = b.addJoint(root);
    neck->Name = "neck";
    neck->transform = core::Transform{core::vector3df(0, 1, -2)};
    auto *tail = b.addJoint(root);
    tail->Name = "tail";
    tail->transform = core::Transform{core::vector3df(0, 1, 2)};
    for (auto [name, deg] : {std::pair{"natural_bite_low", -40.0f}, {"natural_bite_mid", -10.0f},
                 {"natural_bite_high", 20.0f}}) {
        auto &anim = b.getAnimation(b.addAnimation());
        anim.name = name;
        scene::SkinnedMesh::Keys k;
        const core::quaternion q(core::vector3df(deg * core::DEGTORAD, 0, 0));
        k.rotation.pushBack(0.0f, q);
        k.rotation.pushBack(1.0f, q);
        k.position.pushBack(0.0f, core::vector3df(0, 1, -2));
        k.position.pushBack(1.0f, core::vector3df(0, 1, -2 - (deg + 40.0f) / 60.0f));
        anim.joint_keys.push_back({neck->JointID, k});
    }
    return std::move(b).finalize();
}

float pitch(const JointTransforms &pose, u16 joint) {
    const auto *t = std::get_if<core::Transform>(&pose[joint]);
    if (!t)
        return NAN;
    core::vector3df e;
    t->rotation.toEuler(e);
    return e.X * core::RADTODEG;
}

void testBlend() {
    scene::SkinnedMesh *mesh = buildMesh();
    const u16 neck = *mesh->getJointNumber("neck"), tail = *mesh->getJointNumber("tail");
    const u16 low = *mesh->getTrackNumber("natural_bite_low"), mid = *mesh->getTrackNumber("natural_bite_mid"),
              high = *mesh->getTrackNumber("natural_bite_high");
    // The server played the clip nearest p = 1.5 (high) and its state says
    // 1.5: the frame's pose is the high clip's.
    scene::AnimSpec anim;
    scene::TrackAnimSpec playing;
    playing.min_frame = 0.0f;
    playing.max_frame = 1.0f;
    playing.loop = false;
    playing.cur_frame = 0.5f;
    anim.tracks[high] = playing;
    const OldJointTransforms none(mesh->getAllJoints().size());
    JointTransforms locals = animateTracks(*mesh, anim, none);
    check(nearf(pitch(locals, neck), 20.0f, 0.05f), "the playing clip's pose");
    const NaturalBlend b = naturalBracket(3, 1.5f);
    const u16 tracks[] = {low, mid, high};
    JointTransforms blended = locals;
    blendNaturalPose(*mesh, playing, tracks[b.a], tracks[b.b], b.weight, 1.0f, blended);
    check(nearf(pitch(blended, neck), 5.0f, 0.05f), "halfway between mid and high: +5 degrees");
    const auto *t = std::get_if<core::Transform>(&blended[neck]);
    // Positions at frame 0.5: mid -2 - 0.5*0.5 = -2.25, high -2 - 1*0.5 = -2.5; halfway -2.375.
    check(t && nearf(t->translation.Z, -2.375f), "translation halfway between the clips");
    check(nearf(pitch(blended, tail), pitch(locals, tail)), "a joint no attack clip moves is left alone");
    // Blending in from the clip before (half done): halfway from the frame's
    // pose to the blend.
    JointTransforms half = locals;
    blendNaturalPose(*mesh, playing, tracks[b.a], tracks[b.b], b.weight, 0.5f, half);
    check(nearf(pitch(half, neck), 12.5f, 0.1f), "half blended in: halfway from the frame's pose");
    // Nothing when not blended in at all.
    JointTransforms zero = locals;
    blendNaturalPose(*mesh, playing, tracks[b.a], tracks[b.b], b.weight, 0.0f, zero);
    check(nearf(pitch(zero, neck), 20.0f, 0.05f), "not blended in: the frame's pose");
    // The low end: p = 0.25 between low and mid.
    const NaturalBlend c = naturalBracket(3, 0.25f);
    JointTransforms quarter = locals;
    blendNaturalPose(*mesh, playing, tracks[c.a], tracks[c.b], c.weight, 1.0f, quarter);
    check(nearf(pitch(quarter, neck), -32.5f, 0.05f), "a quarter from low to mid: -32.5 degrees");
    mesh->drop();
}

void testModel(const char *path) {
    std::ifstream f(path);
    std::stringstream ss;
    ss << f.rdbuf();
    const Json::Value root = parse(ss.str());
    NaturalPlan plan;
    check(parseNaturalPlan(root["extras"]["natural"], plan), "the model's plan parses");
    std::printf("%s: %zu attacks", path, plan.attacks.size());
    int found = 0, wanted = 0;
    for (const auto &a : plan.attacks) {
        std::printf(", %s (%zu clips, %.2f s)", a.kind.c_str(), a.clips.size(), a.length);
        for (const std::string &clip : a.clips) {
            ++wanted;
            for (const Json::Value &anim : root["animations"])
                if (anim["name"].asString() == clip)
                    ++found;
        }
    }
    std::printf("; %d of %d clips in the file\n", found, wanted);
    check(found == wanted && wanted > 0, "every clip the plan names is in the model");
}

} // namespace

int main(int argc, char **argv) {
    testPlan();
    testBracket();
    testBlend();
    if (argc > 1)
        testModel(argv[1]);
    if (g_failures)
        std::printf("%d failures\n", g_failures);
    else
        std::printf("goanna_natural_test: all passed\n");
    return g_failures ? 1 : 0;
}
