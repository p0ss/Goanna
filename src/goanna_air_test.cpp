// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Fliers in the air (goanna_air.h), without Godot: a bird standing, cruising,
// turning, climbing, landing with and without the server's word, swooping
// and striking, at 60 frames a second over a flat floor.

#include "goanna_air.h"

#include <cmath>
#include <cstdio>
#include <functional>

#include <json/json.h>

using namespace goanna;

static int g_checks = 0, g_failures = 0;
static void check(bool ok, const char *what, double value = NAN) {
    ++g_checks;
    if (!ok) {
        ++g_failures;
        std::printf("FAIL %s", what);
        if (!std::isnan(value))
            std::printf("  %.3f", value);
        std::printf("\n");
    }
}

namespace {
constexpr float DT = 1.0f / 60.0f;
// Runs a flier for `seconds`, its position from path(t) and its yaw from
// yaw(t), the floor at 0. Returns the last output.
struct Flight {
    AirMotion motion;
    AirInput in;
    float t = 0.0f;
    AirOutput run(float seconds, const std::function<void(float, AirInput &)> &at,
            const std::function<void(const AirOutput &)> &each = nullptr) {
        AirOutput out;
        for (float s = 0.0f; s < seconds - 1e-4f; s += DT) {
            t += DT;
            in.dt = DT;
            at(t, in);
            in.floor = 0.0f;
            out = motion.step(in);
            if (each)
                each(out);
        }
        return out;
    }
};
} // namespace

static void planParsing() {
    Json::Value v;
    Json::CharReaderBuilder b;
    std::string errors;
    const std::string text = R"({"state":"kindred_stroke","legs":[{"upper":"leg_left","lower":"leg_left_lower"},)"
                             R"({"upper":"leg_right","lower":"leg_right_lower"}],"wings":["wing_left","wing_right"],)"
                             R"("leg_length":0.34,"clips":{"fly":"fly","stand":"idle","talons":"swoop"}})";
    std::unique_ptr<Json::CharReader> r(b.newCharReader());
    r->parse(text.data(), text.data() + text.size(), &v, &errors);
    AirPlan p;
    check(parseAirPlan(v, p), "a plan parses");
    check(p.legs.size() == 2 && p.wings.size() == 2 && p.state == "kindred_stroke", "its legs, wings and state bone");
    check(std::fabs(p.leg_length - 0.34f) < 1e-6f, "its leg length", p.leg_length);
    Json::Value bad = v;
    bad.removeMember("legs");
    check(!parseAirPlan(bad, p), "a plan without legs is refused");
}

static void standing() {
    Flight f;
    const AirOutput o = f.run(2.0f, [](float, AirInput &in) { in.x = 1, in.y = 0, in.z = 1; });
    check(!o.flying, "standing on the floor is not flying");
    check(o.weight < 0.01f, "standing, the clip's legs show", o.weight);
    check(std::fabs(o.beat_rate - 1.0f) < 0.01f && std::fabs(o.bank) < 1e-3f, "standing changes no beat or bank");
}

static void cruising() {
    Flight f;
    AirOutput o = f.run(2.0f, [](float t, AirInput &in) { in.x = 4.0f * t, in.y = 10, in.z = 0, in.yaw = 0; });
    check(o.flying && o.weight > 0.99f, "high up and moving, it flies", o.weight);
    check(o.reach < 0.01f, "cruising high, the legs are tucked", o.reach);
    check(o.beat_rate > 0.8f && o.beat_rate < 1.0f, "cruising at 4 nodes a second beats a little slower", o.beat_rate);
    check(std::fabs(o.bank) < 0.01f, "flying straight, no bank", o.bank);
    check(std::fabs(f.motion.vx() - 4.0f) < 0.05f, "the speed is worked out from the positions", f.motion.vx());
}

static void turning() {
    Flight left, right;
    AirOutput l = left.run(1.5f, [](float t, AirInput &in) {
        in.x = 3.0f * std::cos(t), in.y = 8, in.z = 3.0f * std::sin(t), in.yaw = t;
    });
    AirOutput r = right.run(1.5f, [](float t, AirInput &in) {
        in.x = 3.0f * std::cos(t), in.y = 8, in.z = -3.0f * std::sin(t), in.yaw = -t;
    });
    check(l.bank > 0.25f, "turning left at 1 rad/s banks the left wing down", l.bank);
    check(r.bank < -0.25f, "turning right banks the right wing down", r.bank);
    check(l.bank <= 0.5f + 1e-4f, "the bank is bounded", l.bank);
    // Across the yaw's wrap from +pi to -pi the turn rate stays the same.
    Flight w;
    AirOutput o = w.run(1.0f, [](float t, AirInput &in) {
        const float a = 3.0f + t;
        in.x = 3.0f * std::cos(a), in.y = 8, in.z = 3.0f * std::sin(a);
        in.yaw = std::remainder(a, 2.0f * (float)M_PI);
    });
    check(o.bank > 0.25f, "turning through the yaw's wrap still banks", o.bank);
}

static void climbing() {
    Flight f;
    AirOutput o = f.run(1.5f, [](float t, AirInput &in) { in.x = 0.5f * t, in.y = 3 + 2.0f * t, in.z = 0; });
    check(o.beat_rate > 1.5f, "climbing at 2 nodes a second, slowly forward, beats fast", o.beat_rate);
}

// Down from 3 nodes at 1 node a second onto the floor; the reach of the legs
// at 1.0 nodes up, with and without the server's landing word, and how soon
// the clip has the legs back once down.
static void landing() {
    for (int told = 0; told < 2; ++told) {
        Flight f;
        f.in.leg = 0.34f;
        if (told)
            f.in.manoeuvre = AirManoeuvre::Land, f.in.param = 3.0f;
        float reach_at_1 = -1.0f, reach_at_leg = -1.0f;
        f.run(3.0f, [](float t, AirInput &in) { in.x = 0.3f * t, in.y = std::max(0.0f, 3.0f - t), in.z = 0; },
                [&](const AirOutput &o) {
                    const float y = std::max(0.0f, 3.0f - f.t);
                    if (reach_at_1 < 0 && y <= 1.0f)
                        reach_at_1 = o.reach;
                    if (reach_at_leg < 0 && y <= 0.02f)
                        reach_at_leg = o.reach;
                });
        if (told)
            check(reach_at_1 > 0.2f, "told it is landing, the legs reach down from a node up", reach_at_1);
        else
            check(reach_at_1 < 0.05f, "untold, the legs stay tucked a node up", reach_at_1);
        check(reach_at_leg > 0.8f, "at touchdown the legs are down", reach_at_leg);
        AirOutput o = f.run(0.6f, [](float, AirInput &in) { in.y = 0; });
        check(!o.flying && o.weight < 0.05f, "on the floor, the clip has the legs back within 0.6 s", o.weight);
    }
}

static void swooping() {
    Flight f;
    f.in.manoeuvre = AirManoeuvre::Swoop, f.in.param = 1.0f;
    float at_04 = -1, at_10 = -1, reach_most = 0;
    f.run(1.6f, [](float t, AirInput &in) {
        in.since = t;
        in.x = 4.0f * t, in.y = 6.0f - 4.0f * t, in.z = 0;
    }, [&](const AirOutput &o) {
        if (at_04 < 0 && f.t >= 0.4f)
            at_04 = o.talons;
        if (at_10 < 0 && f.t >= 1.0f)
            at_10 = o.talons;
        if (f.t >= 0.5f) // from a standing start, once tucked
            reach_most = std::max(reach_most, o.reach);
    });
    check(at_04 < 0.05f, "early in the swoop the talons are back", at_04);
    check(at_10 > 0.8f, "at the swoop's contact the talons are forward", at_10);
    check(reach_most < 0.05f, "a swoop keeps its legs tucked until the talons", reach_most);
    AirOutput o = f.run(0.6f, [](float t, AirInput &in) { in.since = t, in.x = 4.0f * t, in.y = 2, in.z = 0; });
    check(o.talons < 0.05f, "past contact the talons go back", o.talons);
    // A swoop cut short (the state cleared) takes the talons back at once.
    Flight g;
    g.in.manoeuvre = AirManoeuvre::Swoop, g.in.param = 0.5f;
    g.run(0.5f, [](float t, AirInput &in) { in.since = t, in.x = 4.0f * t, in.y = 6, in.z = 0; });
    g.in.manoeuvre = AirManoeuvre::None;
    o = g.run(0.3f, [](float t, AirInput &in) { in.x = 4.0f * t, in.y = 6, in.z = 0; });
    check(o.talons < 0.05f, "a swoop cut short takes the talons back", o.talons);
}

static void striking() {
    Flight f;
    f.in.manoeuvre = AirManoeuvre::Strike;
    AirOutput o = f.run(0.2f, [](float t, AirInput &in) { in.since = t, in.x = 2.0f * t, in.y = 1.5f, in.z = 0; });
    check(o.talons > 0.8f, "a strike brings the talons forward at once", o.talons);
    o = f.run(0.6f, [](float t, AirInput &in) { in.since = t, in.x = 2.0f * t, in.y = 1.5f, in.z = 0; });
    check(o.talons < 0.1f, "and back after it", o.talons);
}

static void teleport() {
    Flight f;
    f.run(0.5f, [](float t, AirInput &in) { in.x = t, in.y = 5, in.z = 0; });
    AirOutput o = f.run(DT, [](float, AirInput &in) { in.x = 100, in.y = 5, in.z = 0; });
    check(std::fabs(f.motion.vx()) < 0.01f, "a teleport is not read as speed", f.motion.vx());
    check(o.beat_rate < 1.7f, "nor beats the wings for it", o.beat_rate);
}

int main() {
    planParsing();
    standing();
    cruising();
    turning();
    climbing();
    landing();
    swooping();
    striking();
    teleport();
    std::printf("goanna_air_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
