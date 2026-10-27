// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Jiggle bones (goanna_jiggle.h) on DorfCraft's real drape and hair models,
// with no Godot runtime. Built and run by `cmake --build build --target
// check`; JIGGLE_TRACE=1 prints each swing frame by frame.
//
// Checked, where the DorfCraft checkout is (DORFCRAFT, else
// ~/Documents/Code/DorfCraft; skipped cleanly without it):
// - every drape's and every hair model's node extras parse, and the marked
//   bones come out with DorfCraft's values (drapes 0.5 / 0.35 / 1 / 70,
//   plaits 0.6 / 0.4 / 1 / 35) and chains;
// - a drape on a body accelerating sideways swings its skirt against the
//   motion, and settles back within a second and a half of stopping; a
//   cloak streams back from a body accelerating forward; a plait swings
//   and settles the same way;
// - gravity pulls a horizontal bone down, about as far as the spring
//   allows, and the cone limit holds under a pull far past it;
// - a capsule pushes a tip out, and the fallback colliders of a hominid
//   frame come out of its bones' extents without disturbing a drape at
//   rest;
// - a teleport, or the simulation off, puts the bones at their pose;
// - the turned pose keeps each bone's length, and is the pose written;
// - a drape's own clip leaves its wearer's pose alone.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <SkinnedMesh.h>

#include "activeobject.h"
#include "constants.h"
#include "goanna_jiggle.h"
#include "goanna_models.h"

using namespace goanna;
using godot::Basis;
using godot::Transform3D;
using godot::Vector3;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_jiggle_test: " << message << "\n";
    }
}

std::string str(const Vector3 &v) {
    char buf[96];
    std::snprintf(buf, sizeof buf, "(%.4f, %.4f, %.4f)", v.x, v.y, v.z);
    return buf;
}

std::string num(float f) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.4f", f);
    return buf;
}

std::string slurp(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

std::vector<std::string> listDir(const std::string &dir, const std::string &prefix) {
    std::vector<std::string> out;
    if (DIR *d = opendir(dir.c_str())) {
        while (dirent *e = readdir(d)) {
            const std::string n = e->d_name;
            if (n.rfind(prefix, 0) == 0 && n.size() > 5 && n.compare(n.size() - 5, 5, ".gltf") == 0)
                out.push_back(n);
        }
        closedir(d);
    }
    std::sort(out.begin(), out.end());
    return out;
}

// A loaded model as the animator takes it: buildGodotModel without the
// Godot mesh, which needs the engine (goanna_limbs_test does the same).
struct Loaded {
    scene::SkinnedMesh *mesh = nullptr;
    ModelExtras extras;
    bool parsed = false;
    std::shared_ptr<GodotModel> model;
};

Loaded load(ModelLoader &loader, const std::string &dir, const std::string &file) {
    Loaded l;
    const std::string bytes = slurp(dir + "/" + file);
    if (bytes.empty())
        return l;
    l.parsed = parseModelExtras(file, bytes, l.extras);
    scene::IAnimatedMesh *m = loader.load(file, bytes);
    l.mesh = dynamic_cast<scene::SkinnedMesh *>(m);
    if (!l.mesh) {
        if (m)
            m->drop();
        return l;
    }
    auto model = std::make_shared<GodotModel>();
    model->source = l.mesh; // takes the loader's reference
    l.mesh->grab();
    model->skinned = l.mesh;
    model->animated = !l.mesh->isStatic();
    model->joint_count = (int)l.mesh->getAllJoints().size();
    model->attached_bone.assign(model->joint_count, -1);
    model->bone_count = model->joint_count;
    model->jiggle = buildJiggleRig(*l.mesh, &l.extras);
    l.model = model;
    return l;
}

// Steps an animator through a frame at `world`, with `colliders`.
void frame(ModelAnimator &an, const Transform3D &world, float dt,
        const std::vector<JiggleCapsule> &colliders = {}, bool simulate = true) {
    JiggleFrame f;
    f.simulate = simulate;
    f.mesh_to_world = world;
    f.colliders = colliders;
    an.setJiggleFrame(f);
    scene::AnimSpec none;
    std::map<std::string, BoneOverride> overrides;
    an.step(dt, none, overrides, nullptr);
}

size_t boneIndex(const GodotModel &m, const std::string &name) {
    const auto &joints = m.skinned->getAllJoints();
    for (size_t i = 0; i < m.jiggle.bones.size(); ++i)
        if (joints[m.jiggle.bones[i].joint]->Name.value_or("") == name)
            return i;
    return (size_t)-1;
}

float degrees(const Vector3 &a, const Vector3 &b) {
    return std::acos(std::clamp(a.normalized().dot(b.normalized()), -1.0f, 1.0f)) * 180.0f / (float)M_PI;
}

constexpr float DT = 1.0f / 60.0f;

// A body standing two seconds (its bones hanging where gravity and their
// springs balance, which for a bone not hanging straight down is a little
// off its pose), then accelerating along `dir` at 8 nodes/s^2 for half a
// second, stopping as hard, and standing again. Offsets are of the tip from
// where it hung at the start: the most it swings along dir while
// accelerating (negative is against the motion), the most it swings either
// way after stopping, and how far off it is 1.5 s after stopping.
struct Swing {
    float during = 0.0f, after_peak = 0.0f, settled = 1e9f;
};

Swing swing(const std::shared_ptr<GodotModel> &model, size_t bone, const Vector3 &dir) {
    ModelAnimator an(model);
    Swing out;
    Vector3 pos(0, 10, 0), vel;
    float t = 0.0f;
    const bool trace = std::getenv("JIGGLE_TRACE") != nullptr;
    auto run = [&](float seconds, float accel, auto &&each) {
        for (float e = 0.0f; e < seconds - 1e-6f; e += DT) {
            vel += dir * accel * DT;
            pos += vel * DT;
            t += DT;
            frame(an, Transform3D(Basis(), pos), DT);
            if (trace)
                std::printf("t %.3f pos %.3f tip %s target %s pivot %s\n", t, pos.dot(dir),
                        str(an.jiggle().tip(bone)).c_str(), str(an.jiggle().target(bone)).c_str(),
                        str(an.jiggle().pivot(bone)).c_str());
            each(e + DT);
        }
    };
    Vector3 hung;
    auto off = [&]() { return an.jiggle().tip(bone) - an.jiggle().target(bone) - hung; };
    run(2.0f, 0.0f, [](float) {});
    hung = an.jiggle().tip(bone) - an.jiggle().target(bone);
    run(0.5f, 8.0f, [&](float) { out.during = std::min(out.during, off().dot(dir)); });
    run(0.5f, -8.0f, [](float) {});
    run(2.0f, 0.0f, [&](float e) {
        out.after_peak = std::max(out.after_peak, std::fabs(off().dot(dir)));
        if (std::fabs(e - 1.5f) < DT * 0.5f)
            out.settled = off().length();
    });
    return out;
}

} // namespace

int main() {
    // 0. The units and the parsing, without any model.
    expect(std::fabs(jiggleOmega(0.0f) - 2.0f) < 1e-6f && std::fabs(jiggleOmega(1.0f) - 20.0f) < 1e-6f
                    && std::fabs(jiggleOmega(0.5f) - 11.0f) < 1e-6f,
            "stiffness 0, 0.5, 1 is not 2, 11, 20 rad/s");
    {
        ModelExtras e;
        const std::string glb_json = "{\"nodes\":[{\"name\":\"a\",\"extras\":{\"jiggle\":{\"stiffness\":0.25,"
                                     "\"chain\":\"c\"}}},{\"name\":\"b\",\"extras\":{\"jiggle_collider\":"
                                     "{\"radius\":0.2,\"tip\":\"a\"}}}]}";
        std::string glb = "glTF";
        auto u32le = [&](uint32_t v) {
            for (int i = 0; i < 4; ++i)
                glb.push_back((char)((v >> (8 * i)) & 0xff));
        };
        u32le(2);
        u32le((uint32_t)(20 + glb_json.size()));
        u32le((uint32_t)glb_json.size());
        u32le(0x4E4F534Au);
        glb += glb_json;
        const bool ok = parseModelExtras("x.glb", glb, e);
        expect(ok && e.jiggle.count("a") && std::fabs(e.jiggle["a"].stiffness - 0.25f) < 1e-6f
                        && e.jiggle["a"].chain == "c" && std::fabs(e.jiggle["a"].damping - 0.35f) < 1e-6f,
                "a .glb's JSON chunk is not read, or missing fields do not take their defaults");
        expect(ok && e.colliders.count("b") && std::fabs(e.colliders["b"].radius - 0.2f) < 1e-6f
                        && e.colliders["b"].tip == "a",
                "a jiggle_collider mark is not read");
        expect(!parseModelExtras("x.b3d", "whatever", e), "a .b3d is taken for glTF");
    }

    const char *env = std::getenv("DORFCRAFT");
    const char *home = std::getenv("HOME");
    const std::string root = env ? env : std::string(home ? home : "") + "/Documents/Code/DorfCraft";
    const std::string kit = root + "/mods/kindred_creatures/models";
    const std::string appearance = kit + "/appearance";
    const std::vector<std::string> drapes = listDir(appearance, "creature_kit_drape_");
    if (drapes.empty()) {
        std::printf("goanna_jiggle_test: skipped the DorfCraft models (no checkout at %s)\n", root.c_str());
        std::cout << "goanna_jiggle_test: " << g_checks << " checks, " << g_failures << " failures\n";
        return g_failures == 0 ? 0 : 1;
    }
    ModelLoader loader;

    // 1. The marks on every drape: each skirt bone a chain of one, each
    // cloak one chain, DorfCraft's values.
    int drape_bones = 0;
    for (const std::string &f : drapes) {
        Loaded l = load(loader, appearance, f);
        expect(l.parsed && l.model, f + " does not load, or its extras do not parse");
        if (!l.model)
            continue;
        expect(!l.extras.jiggle.empty(), f + " marks no jiggle bones");
        expect(l.model->jiggle.bones.size() == l.extras.jiggle.size(), f + ": "
                + std::to_string(l.extras.jiggle.size()) + " marked bones but "
                + std::to_string(l.model->jiggle.bones.size()) + " in the rig");
        for (const auto &[name, p] : l.extras.jiggle) {
            ++drape_bones;
            expect(p.stiffness == 0.5f && p.damping == 0.35f && p.gravity == 1.0f && p.limit_degrees == 70.0f,
                    f + "/" + name + " is not 0.5 / 0.35 / 1 / 70");
            const bool cloak = name.rfind("drape_cloak_", 0) == 0;
            const bool skirt = name.rfind("drape_skirt_", 0) == 0;
            expect(cloak || skirt, f + ": unexpected jiggle bone " + name);
            if (cloak)
                expect(p.chain == "drape_cloak", f + "/" + name + " is in chain " + p.chain);
            if (skirt)
                expect(p.chain == name, f + "/" + name + " is in chain " + p.chain + ", not its own");
        }
        // Every tip hangs down.
        for (const JiggleBone &b : l.model->jiggle.bones)
            expect(b.tip_local.y < -0.05f, f + ": a bone's tip " + str(b.tip_local) + " does not hang down");
    }
    expect(drape_bones > 0, "no drape bones at all");

    // The hair models: those that mark plaits.
    const std::vector<std::string> hairs = listDir(appearance, "creature_kit_hair_");
    int marked_hair = 0, plait_bones = 0;
    std::string a_plait;
    for (const std::string &f : hairs) {
        ModelExtras e;
        const bool ok = parseModelExtras(f, slurp(appearance + "/" + f), e);
        expect(ok, f + "'s JSON does not parse");
        if (e.jiggle.empty())
            continue;
        ++marked_hair;
        if (a_plait.empty() && f.find("plaits") != std::string::npos)
            a_plait = f;
        for (const auto &[name, p] : e.jiggle) {
            ++plait_bones;
            expect(p.stiffness == 0.6f && p.damping == 0.4f && p.gravity == 1.0f && p.limit_degrees == 35.0f,
                    f + "/" + name + " is not 0.6 / 0.4 / 1 / 35");
        }
    }
    std::printf("goanna_jiggle_test: %zu drapes (%d bones), %zu hair models of which %d mark %d bones\n",
            drapes.size(), drape_bones, hairs.size(), marked_hair, plait_bones);

    // 2. The tabard on a body accelerating sideways (+x): the front right
    // skirt swings to -x, then settles. The cloak on a body accelerating
    // forward (-z, glTF's and Godot's forward) streams back. A plait's end
    // on a head accelerating sideways.
    Loaded tabard = load(loader, appearance, "creature_kit_drape_frame_medium_tabard.gltf");
    Loaded cloak = load(loader, appearance, "creature_kit_drape_frame_medium_cloak.gltf");
    if (tabard.model) {
        const size_t fr = boneIndex(*tabard.model, "drape_skirt_fr");
        expect(fr != (size_t)-1, "the tabard has no drape_skirt_fr jiggle bone");
        if (fr != (size_t)-1) {
            const Swing s = swing(tabard.model, fr, Vector3(1, 0, 0));
            std::printf("goanna_jiggle_test: tabard skirt, sideways: swings %s nodes accelerating, "
                        "peak %s after stopping, %s off 1.5 s later\n",
                    num(s.during).c_str(), num(s.after_peak).c_str(), num(s.settled).c_str());
            expect(s.during < -0.02f, "the skirt does not swing against a sideways acceleration: "
                    + num(s.during));
            expect(s.after_peak > 0.02f, "the skirt does not swing on when the body stops");
            expect(s.settled < 0.1f * s.after_peak && s.settled < 0.01f,
                    "the skirt has not settled 1.5 s after stopping: " + num(s.settled) + " nodes off");
        }
    }
    if (cloak.model) {
        const size_t last = boneIndex(*cloak.model, "drape_cloak_2");
        expect(last != (size_t)-1, "the cloak has no drape_cloak_2 jiggle bone");
        if (last != (size_t)-1) {
            const Swing s = swing(cloak.model, last, Vector3(0, 0, -1));
            std::printf("goanna_jiggle_test: cloak hem, forward: swings %s, peak %s, %s off 1.5 s later\n",
                    num(s.during).c_str(), num(s.after_peak).c_str(), num(s.settled).c_str());
            expect(s.during < -0.02f, "the cloak does not stream back from a forward acceleration: "
                    + num(s.during));
            expect(s.settled < 0.01f, "the cloak has not settled 1.5 s after stopping: " + num(s.settled));
        }
    }
    if (!a_plait.empty()) {
        Loaded plait = load(loader, appearance, a_plait);
        size_t end = (size_t)-1;
        if (plait.model)
            for (size_t i = 0; i < plait.model->jiggle.bones.size(); ++i)
                if (plait.model->skinned->getAllJoints()[plait.model->jiggle.bones[i].joint]->Name
                                .value_or("").find("_2") != std::string::npos)
                    end = i;
        expect(end != (size_t)-1, a_plait + " has no plait end bone");
        if (end != (size_t)-1) {
            const Swing s = swing(plait.model, end, Vector3(1, 0, 0));
            std::printf("goanna_jiggle_test: %s end, sideways: swings %s, peak %s, %s off 1.5 s later\n",
                    a_plait.c_str(), num(s.during).c_str(), num(s.after_peak).c_str(), num(s.settled).c_str());
            expect(s.during < -0.01f, "the plait does not swing against a sideways acceleration: "
                    + num(s.during));
            expect(s.settled < 0.01f, "the plait has not settled 1.5 s after stopping: " + num(s.settled));
        }
    }

    // 3. Gravity, the cone, a capsule, a teleport and the switch, on the
    // tabard's front right skirt, laid horizontal for the first two (the
    // body on its side).
    if (tabard.model) {
        const size_t fr = boneIndex(*tabard.model, "drape_skirt_fr");
        const Transform3D side(Basis(Vector3(0, 0, 1), (float)M_PI / 2), Vector3(0, 10, 0));
        auto settle = [&](const std::shared_ptr<GodotModel> &model, const std::vector<JiggleCapsule> &caps,
                              const Transform3D &w) {
            auto an = std::make_unique<ModelAnimator>(model);
            for (int i = 0; i < 240; ++i)
                frame(*an, w, DT, caps);
            return an;
        };
        {
            auto an = settle(tabard.model, {}, side);
            const JiggleSolver &j = an->jiggle();
            const Vector3 rest = j.target(fr) - j.pivot(fr), now = j.tip(fr) - j.pivot(fr);
            const float sag = degrees(rest, now);
            std::printf("goanna_jiggle_test: horizontal skirt sags %.1f degrees under gravity\n", sag);
            expect(std::fabs(rest.y) < 0.05f, "the laid skirt's target is not horizontal: " + str(rest));
            expect(now.y < rest.y && sag > 5.0f && sag < 40.0f,
                    "gravity does not pull a horizontal bone down: " + num(sag) + " degrees, tip " + str(now));
            expect(std::fabs(now.length() - rest.length()) < 1e-4f,
                    "the simulated bone is " + num(now.length()) + " long, not " + num(rest.length()));
            // The pose written back: the joint's global turns the bone's
            // tip to where the solver has it.
            Transform3D g;
            an->jointGlobal("drape_skirt_fr", g);
            const Vector3 drawn = side.xform(g.xform(tabard.model->jiggle.bones[fr].tip_local));
            expect((drawn - j.tip(fr)).length() < 1e-3f,
                    "the bone is drawn with its tip at " + str(drawn) + ", not the solver's " + str(j.tip(fr)));
        }
        {
            // Pulled far past its cone: it stops at the cone.
            auto heavy = std::make_shared<GodotModel>(*tabard.model);
            heavy->source->grab();
            heavy->skinned->grab();
            for (JiggleBone &b : heavy->jiggle.bones) {
                b.params.gravity = 40.0f;
                b.params.limit_degrees = 20.0f;
            }
            auto an = settle(heavy, {}, side);
            const JiggleSolver &j = an->jiggle();
            const float sag = degrees(j.target(fr) - j.pivot(fr), j.tip(fr) - j.pivot(fr));
            std::printf("goanna_jiggle_test: under 40 g with a 20 degree cone it sags %.2f degrees\n", sag);
            expect(sag <= 20.05f && sag > 19.0f, "the cone limit does not hold: " + num(sag) + " degrees");
        }
        {
            // A capsule through where the tip would hang.
            auto an = settle(tabard.model, {}, Transform3D(Basis(), Vector3(0, 10, 0)));
            const Vector3 t = an->jiggle().tip(fr);
            const JiggleCapsule cap{t + Vector3(0, -0.5f, 0), t + Vector3(0, 0.5f, 0), 0.1f};
            auto pushed = settle(tabard.model, {cap}, Transform3D(Basis(), Vector3(0, 10, 0)));
            const Vector3 tip = pushed->jiggle().tip(fr);
            const float d = Vector3(tip.x - t.x, 0, tip.z - t.z).length();
            std::printf("goanna_jiggle_test: a 0.1 node capsule on the tip pushes it %.4f nodes out\n", d);
            expect(d >= 0.1f - 1e-3f, "a capsule does not push the tip out: " + num(d) + " from its axis");
        }
        {
            // Teleported fifty nodes: straight back to the pose (within the
            // one step of gravity the frame still takes).
            ModelAnimator an(tabard.model);
            for (int i = 0; i < 30; ++i)
                frame(an, Transform3D(Basis(), Vector3(i * 0.15f, 10, 0)), DT);
            frame(an, Transform3D(Basis(), Vector3(50, 10, 0)), DT);
            const float off = (an.jiggle().tip(fr) - an.jiggle().target(fr)).length();
            expect(off < 2e-3f, "a teleport leaves the skirt " + num(off) + " nodes off its pose");
            // Off: the joint takes its rest pose exactly.
            frame(an, Transform3D(Basis(), Vector3(50, 10, 0)), DT, {}, false);
            Transform3D g;
            an.jointGlobal("drape_skirt_fr", g);
            const auto &joint = tabard.mesh->getAllJoints()[tabard.model->jiggle.bones[fr].joint];
            const Transform3D rest_local =
                    toGodotTransform(std::get<core::Transform>(joint->transform).buildMatrix());
            expect((g.origin - rest_local.origin).length() < 1e-5f && g.basis.is_equal_approx(rest_local.basis),
                    "with the simulation off the skirt is not at its rest pose");
            expect(!an.jiggle().active(), "the solver keeps state with the simulation off");
        }
        {
            // Substeps: a 30 fps frame takes two steps, a long frame the cap.
            ModelAnimator an(tabard.model);
            frame(an, Transform3D(), DT);
            frame(an, Transform3D(), 1.0f / 30.0f + 1e-4f);
            expect(an.jiggle().lastSteps() == 2, "a 30 fps frame took "
                    + std::to_string(an.jiggle().lastSteps()) + " steps, not 2");
            frame(an, Transform3D(), 0.5f);
            expect(an.jiggle().lastSteps() == JIGGLE_MAX_STEPS, "a long frame is not capped");
        }
    }

    // 4. A hominid frame's fallback colliders, and a drape's clip leaving
    // its wearer's pose alone.
    Loaded body = load(loader, kit + "/peoples", "aurochs_person_male_carved_adult.gltf");
    expect(body.model != nullptr, "the aurochs body does not load");
    if (body.model) {
        const JiggleRig &rig = body.model->jiggle;
        expect(rig.bones.empty(), "the body has jiggle bones");
        expect(rig.colliders.size() == 6, "the body has " + std::to_string(rig.colliders.size())
                + " fallback colliders, not 6");
        std::map<std::string, const JiggleCollider *> by;
        for (const JiggleCollider &c : rig.colliders)
            by[*body.mesh->getAllJoints()[c.joint]->Name] = &c;
        for (const char *n : JIGGLE_FALLBACK_COLLIDERS)
            expect(by.count(n) != 0, std::string("no fallback collider on ") + n);
        if (by.count("chest") && by.count("leg_left")) {
            std::printf("goanna_jiggle_test: chest capsule r %.3f %s to %s, leg_left r %.3f %s to %s\n",
                    by["chest"]->radius, str(by["chest"]->a_local).c_str(), str(by["chest"]->b_local).c_str(),
                    by["leg_left"]->radius, str(by["leg_left"]->a_local).c_str(),
                    str(by["leg_left"]->b_local).c_str());
            // The chest box is 0.6 wide, 0.475 tall and 0.506 deep: a
            // capsule across it, radius the larger of the other half sides.
            expect(std::fabs(by["chest"]->radius - 0.253f) < 0.01f, "chest radius " + num(by["chest"]->radius));
            // The thigh is 0.256 wide, 0.537 long and 0.319 deep: upright.
            const JiggleCollider &leg = *by["leg_left"];
            expect(std::fabs(leg.radius - 0.16f) < 0.01f, "leg radius " + num(leg.radius));
            expect(std::fabs((leg.b_local - leg.a_local).normalized().y) > 0.99f,
                    "the thigh's capsule is not upright");
        }
        ModelAnimator wearer(body.model);
        frame(wearer, Transform3D(), DT);
        std::vector<JiggleCapsule> caps;
        wearer.jiggleColliders(Transform3D(Basis(), Vector3(0, 10, 0)), caps);
        expect(caps.size() == 6, "the wearer gives " + std::to_string(caps.size()) + " capsules");
        if (tabard.model) {
            Transform3D before, after;
            wearer.jointGlobal("chest", before);
            ModelAnimator drape(tabard.model);
            scene::AnimSpec walk;
            if (auto t = tabard.mesh->getTrackNumber("walk"))
                walk.tracks[*t] = scene::TrackAnimSpec{};
            std::map<std::string, BoneOverride> none;
            for (int i = 0; i < 30; ++i) {
                drape.step(DT, walk, none, nullptr);
                frame(wearer, Transform3D(), DT);
            }
            wearer.jointGlobal("chest", after);
            expect(before.is_equal_approx(after), "a drape playing walk moved its wearer's chest");
            expect((void *)tabard.mesh != (void *)body.mesh, "the drape and the body share a mesh");
            // Hung on the chest with the wearer's capsules, every skirt tip
            // at rest is clear of the body: the colliders do not fight the
            // pose.
            ModelAnimator hung(tabard.model);
            Transform3D chest;
            wearer.jointGlobal("chest", chest);
            const Transform3D drape_world = Transform3D(Basis(), Vector3(0, 10, 0)) * chest;
            ModelAnimator free(tabard.model);
            for (int i = 0; i < 120; ++i) {
                frame(hung, drape_world, DT, caps);
                frame(free, drape_world, DT);
            }
            for (size_t b = 0; b < hung.jiggle().boneCount(); ++b) {
                const float off = (hung.jiggle().tip(b) - free.jiggle().tip(b)).length();
                expect(off < 1e-3f, "skirt " + std::to_string(b) + " is pushed " + num(off)
                        + " nodes by the wearer's own body at rest");
            }
        }
    }

    std::cout << "goanna_jiggle_test: " << g_checks << " checks, " << g_failures << " failures\n";
    return g_failures == 0 ? 0 : 1;
}
