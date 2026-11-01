// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The step planner (goanna_steps.h) driven over scripted terrain with no
// Godot runtime. Built and run by `cmake --build build --target check`.
//
// Usage: goanna_steps_test [stroke fixture dir], default tools/test/strokes,
// read from the repository root, for the stroke family's pelvis drop.
//
// The terrain and path are DorfCraft's strokes/stance_fixture.lua: a floor
// whose top is y = 0 and a half slab (top 0.5) across the path from
// z = -4.5 to -2.5; stand, walk forward over the slab, turn a quarter left
// and back, stroke standing at the slab's edge, strafe, back away, stand.
// The root steps up and down at once, as that fixture's physics does.
// Bodies: the stroke fixture's reference biped, a small stocky biped and a
// quadruped (both made up for this test), at the fixture's pace and at
// Mineclonia's walking pace, at 60 and 20 frames a second.
//
// Checked, for every run:
// - a planted foot never moves (slide 0);
// - a planted foot stands on the terrain under it;
// - every landing found a foothold (no unreachable);
// - while grounded, some foot is always planted;
// - standing still, once settled, no foot steps;
// - the body is lowered at most STEP_DROP_MOST leg lengths;
// - bipeds at 60 fps: a planted foot is out of reach by at most 0.03
//   nodes at the fixture's pace, 0.1 at Mineclonia's walking pace.
// Quadrupeds and 20 fps runs are reported, not checked, for reach.
//
// Then a wolf with two girdles (DorfCraft's wolf_carved_adult: hind legs
// on the pelvis, fore legs on the chest) walks over the slab at its own
// walking pace, turns, trots back at twice it, walks, backs and stands.
// Checked: the planted, ground, foothold and standing rules above; at a
// walk one leg at a time, in the order hind, fore, other hind, other fore
// (the reverse backing; on level ground and a second into the gait, as a
// step or the change of gait may take one out of turn; at 60 fps); at a
// trot only diagonal pairs swing together; it walks below the trot's
// Froude number and trots above; the chest rises against the pelvis
// climbing onto the slab and (at 60 fps) falls stepping off; settled
// standing (after 1.2 s: four feet settle in two pairs) no foot steps.
// It prints, per run, steps, settles, forced lifts, rejected and
// unreachable footholds, frames out of reach and the body's height.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <json/json.h>

#include "goanna_steps.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        if (g_failures <= 40)
            std::cerr << "goanna_steps_test: " << message << "\n";
    }
}

// The fixture's terrain: boxes {lo, hi}.
struct Box {
    float lo[3], hi[3];
};
const std::vector<Box> kTerrain = {
        {{-8, -1, -12}, {8, 0, 8}},
        {{-8, 0, -4.5f}, {8, 0.5f, -2.5f}},
};

std::optional<float> floorAt(float x, float z, float top, float bottom) {
    std::optional<float> best;
    for (const Box &b : kTerrain) {
        if (x < b.lo[0] || x > b.hi[0] || z < b.lo[2] || z > b.hi[2])
            continue;
        const float h = b.hi[1];
        if (h <= top && h >= bottom && (!best || h > *best))
            best = h;
    }
    return best;
}

struct BodyLeg {
    float x, y, z; // hip from the root: right, up, forward, nodes
    float length, ankle;
    int group;
    int slow_group = -1, girdle = 0;
};

struct Body {
    std::string name;
    float hip; // hip height, for the stroke stance and drop
    std::vector<BodyLeg> legs;
    bool biped = true;
};

// The stroke family's pelvis drop (hip heights) at the 45 degree stroke,
// a sample a 1/rate second, and the largest pelvis turn any stroke asks.
struct Family {
    double rate = 30, commit = 0.42, length = 1.85;
    std::vector<double> drop;
    double most_turn = 0;
};

bool readFamily(const std::string &path, Family &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    std::ostringstream s;
    s << f.rdbuf();
    const std::string text = s.str();
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    Json::Value root;
    std::string errors;
    if (!reader->parse(text.data(), text.data() + text.size(), &root, &errors))
        return false;
    out.rate = root["rate"].asDouble();
    out.commit = root["timing"]["commit"].asDouble();
    out.length = root["timing"]["length"].asDouble();
    for (const Json::Value &st : root["strokes"]) {
        for (const Json::Value &sm : st["samples"]) {
            const double w = std::fabs(sm["pelvis"][3].asDouble());
            out.most_turn = std::max(out.most_turn, 2 * std::acos(std::min(1.0, w)) * 180 / M_PI);
            if (st["angle"].asDouble() == 45)
                out.drop.push_back(sm["drop"][1].asDouble());
        }
    }
    return !out.drop.empty();
}

struct Segment {
    float seconds;
    float vx, vz; // nodes a second
    float yaw_rate; // radians a second
    bool stroke;
};

struct Result {
    StepStats stats;
    float slide = 0, off_ground = 0, drop_low = 0, twist = 0;
    int no_support = 0, still_steps = 0;
};

Result run(const Body *body_ptr, const std::vector<Segment> &script, float dt, float pace, const Family &fam) {
    const Body &body = *body_ptr;
    std::vector<StepLeg> legs;
    for (const BodyLeg &l : body_ptr->legs)
        legs.push_back({l.length, l.ankle, l.group, l.slow_group, l.girdle});
    StepPlanner planner(legs);
    Result res;
    float x = 0, z = 0, yaw = M_PI;
    std::vector<StepFoot> last;
    for (const Segment &seg : script) {
        // Faster paces cover the same ground: moving segments are shorter.
        const bool moving = seg.vx != 0 || seg.vz != 0;
        const float k = moving ? pace : 1.0f;
        const int frames = (int)std::lround(seg.seconds / k / dt);
        float stroke_t = 0;
        for (int f = 0; f < frames; ++f) {
            x += seg.vx * k * dt;
            z += seg.vz * k * dt;
            yaw += seg.yaw_rate * dt;
            const float y = (z <= -2.5f && z >= -4.5f) ? 0.5f : 0.0f;
            const float fx = -std::sin(yaw), fz = std::cos(yaw); // forward
            const float rx = std::cos(yaw), rz = std::sin(yaw); // right
            StepInput in;
            in.dt = dt;
            in.root = {x, y, z};
            in.yaw = yaw;
            in.floor = floorAt;
            if (seg.stroke) {
                stroke_t += dt;
                const double t = std::min<double>(stroke_t, fam.length);
                in.hold = t >= fam.commit && t < fam.length;
                const size_t k = std::min(fam.drop.size() - 1, (size_t)(t * fam.rate));
                in.crouch = float(fam.drop[k] * body.hip);
            }
            for (const BodyLeg &l : body.legs) {
                in.hips.push_back({x + rx * l.x + fx * l.z, y + l.y, z + rz * l.x + fz * l.z});
                // The stroke's stance: the left foot forward and out, the
                // right back and out, in hip heights (evaluate.lua).
                float sx = l.x, sz = l.z;
                if (seg.stroke && body.biped) {
                    sx += (l.x < 0 ? -0.1f : 0.1f) * body.hip;
                    sz += (l.x < 0 ? 0.2f : -0.2f) * body.hip;
                }
                in.rest.push_back({x + rx * sx + fx * sz, y, z + rz * sx + fz * sz});
            }
            const uint64_t steps_before = planner.stats().steps;
            const StepStats before = planner.stats();
            planner.step(in);
            if (std::getenv("STEPS_EVENTS") && body.name == std::getenv("STEPS_EVENTS")) {
                const StepStats &now = planner.stats();
                const char *what = now.unreachable > before.unreachable ? "unreachable"
                        : now.stretched > before.stretched                 ? "stretched"
                        : now.steps > steps_before && seg.vx == 0 && seg.vz == 0 && seg.yaw_rate == 0 && !seg.stroke
                                ? "still step"
                                : nullptr;
                if (what)
                    std::printf("  %s pace %.0f dt %.3f seg %d frame %d root %.2f %.2f %.2f drop %.3f\n", what, pace,
                            dt, int(&seg - &script[0]), f, x, y, z, planner.drop());
            }
            const auto &feet = planner.feet();
            int planted = 0;
            for (size_t i = 0; i < feet.size(); ++i) {
                if (!feet[i].planted)
                    continue;
                ++planted;
                if (!last.empty() && last[i].planted && last[i].supported && feet[i].supported) {
                    const float d = std::hypot(std::hypot(feet[i].sole[0] - last[i].sole[0],
                                                       feet[i].sole[1] - last[i].sole[1]),
                            feet[i].sole[2] - last[i].sole[2]);
                    res.slide = std::max(res.slide, d);
                }
                if (feet[i].supported) {
                    auto h = floorAt(feet[i].sole[0], feet[i].sole[2], feet[i].sole[1] + 0.01f,
                            feet[i].sole[1] - 0.01f);
                    res.off_ground = std::max(res.off_ground, h ? std::fabs(*h - feet[i].sole[1]) : 1.0f);
                }
            }
            if (planted == 0)
                ++res.no_support;
            // Standing, not striking, past the first second: settled.
            if (seg.vx == 0 && seg.vz == 0 && seg.yaw_rate == 0 && !seg.stroke && f * dt > 1.0f)
                res.still_steps += int(planner.stats().steps - steps_before);
            res.drop_low = std::min(res.drop_low, planner.drop());
            res.twist = std::max(res.twist, std::fabs(planner.pelvisYaw()));
            if (std::getenv("STEPS_TRACE") && body.name == std::getenv("STEPS_TRACE") && pace == 1.0f && dt > 0.04f && (!std::getenv("STEPS_SEG") || int(&seg - &script[0]) == std::atoi(std::getenv("STEPS_SEG")))) {
                std::printf("t root %.2f %.2f %.2f drop %.3f", x, y, z, planner.drop());
                for (size_t i = 0; i < feet.size(); ++i) {
                    const auto &h = in.hips[i];
                    const float r = std::hypot(std::hypot(h[0] - feet[i].sole[0], h[2] - feet[i].sole[2]),
                            h[1] + planner.drop() - feet[i].sole[1] - body.legs[i].ankle);
                    std::printf(" | %c %.2f %.2f %.2f r%.2f", feet[i].planted ? 'P' : 'S', feet[i].sole[0],
                            feet[i].sole[1], feet[i].sole[2], r / body.legs[i].length);
                }
                std::printf(" st%llu f%llu\n", (unsigned long long)planner.stats().steps,
                        (unsigned long long)planner.stats().forced);
            }
            last = feet;
        }
    }
    res.stats = planner.stats();
    return res;
}

} // namespace

int main(int argc, char **argv) {
    const std::string dir = argc > 1 ? argv[1] : "tools/test/strokes";
    Family fam;
    expect(readFamily(dir + "/family.json", fam), "cannot read " + dir + "/family.json");
    if (fam.drop.empty())
        fam.drop.push_back(0);

    // The stroke fixture's reference body (tools/test/strokes/reference.json):
    // hips 14.5 units up and 1.5 out, thigh 7, shin 6, ankle 1.5, 16 a node.
    const float u = 1.0f / 16.0f;
    const Body reference{"reference biped", 14.5f * u,
            {{-1.5f * u, 14.5f * u, 0, 13 * u, 1.5f * u, 0}, {1.5f * u, 14.5f * u, 0, 13 * u, 1.5f * u, 1}}};
    // A small stocky biped (made up): short legs set wide.
    const Body stocky{"small stocky biped", 0.55f,
            {{-0.11f, 0.55f, 0, 0.47f, 0.05f, 0}, {0.11f, 0.55f, 0, 0.47f, 0.05f, 1}}};
    // A quadruped (made up), trotting: diagonal pairs step together.
    const Body quad{"quadruped",
            0.6f,
            {{-0.18f, 0.6f, 0.4f, 0.55f, 0.04f, 0},
                    {0.18f, 0.6f, 0.4f, 0.55f, 0.04f, 1},
                    {-0.18f, 0.6f, -0.4f, 0.55f, 0.04f, 1},
                    {0.18f, 0.6f, -0.4f, 0.55f, 0.04f, 0}},
            false};

    // stance_fixture.lua's script (velocities at pace 1).
    const std::vector<Segment> stance = {
            {1, 0, 0, 0, false},
            {3.2f, 0, -1.4f, 0, false},
            {1, 0, 0, float(M_PI / 2), false},
            {0.6f, 0, 0, float(-M_PI / 2), false},
            {1.9f, 0, 0, 0, true},
            {1, 1, 0, 0, false},
            {1.2f, 0, 1.2f, 0, false},
            {0.8f, 0, 0, 0, false},
            {1.5f, 0, 0, 0, false}, // not in the fixture: settled standing
    };

    std::printf("stroke family: pelvis drop at 45 degrees %.3f to %.3f hip heights, "
                "largest pelvis turn of any stroke %.1f degrees\n",
            *std::min_element(fam.drop.begin(), fam.drop.end()),
            *std::max_element(fam.drop.begin(), fam.drop.end()), fam.most_turn);
    std::printf("%-20s %5s %4s %6s %5s %6s %6s %4s %5s %6s %8s %7s %6s\n", "body", "pace", "fps", "steps",
            "settl", "forced", "reject", "unre", "strch", "worst", "slide", "drop", "twist");
    for (const Body *body : {&reference, &stocky, &quad}) {
        for (float pace : {1.0f, 3.0f}) {
            for (float fps : {60.0f, 20.0f}) {
                const Result r = run(body, stance, 1.0f / fps, pace, fam);
                const StepStats &s = r.stats;
                std::printf("%-20s %5.1f %4.0f %6llu %5llu %6llu %6llu %4llu %5llu %6.3f %8.1e %7.3f %6.1f\n",
                        body->name.c_str(), 1.4f * pace, fps, (unsigned long long)s.steps,
                        (unsigned long long)s.settles, (unsigned long long)s.forced,
                        (unsigned long long)s.rejected, (unsigned long long)s.unreachable,
                        (unsigned long long)s.stretched, s.most_stretch, r.slide, r.drop_low,
                        r.twist * 180 / M_PI);
                const std::string what = body->name + " at " + std::to_string(1.4f * pace) + " n/s, "
                        + std::to_string((int)fps) + " fps: ";
                expect(r.slide == 0.0f, what + "a planted foot moved " + std::to_string(r.slide));
                expect(r.off_ground < 1e-4f, what + "a planted foot off the ground by " + std::to_string(r.off_ground));
                expect(s.unreachable == 0, what + std::to_string(s.unreachable) + " landings with no foothold");
                expect(r.no_support == 0, what + std::to_string(r.no_support) + " frames with no foot planted");
                expect(r.still_steps == 0, what + std::to_string(r.still_steps) + " steps while standing settled");
                expect(s.steps > 10, what + "only " + std::to_string(s.steps) + " steps");
                const float shortest = body->legs[0].length;
                expect(r.drop_low >= -0.5f - STEP_DROP_MOST * shortest - 1e-4f,
                        what + "body lowered " + std::to_string(r.drop_low));
                // Out of reach, checked for bipeds at a display's frame
                // rate only; the rest is reported (docs/systems/
                // melee-strokes.md says what fails).
                if (body->biped && fps > 30) {
                    const float limit = pace > 1 ? 0.1f : 0.03f;
                    expect(s.most_stretch <= limit,
                            what + "a planted foot out of reach by " + std::to_string(s.most_stretch));
                }
            }
        }
    }

    // The wolf: hips 0.72 up; hind 0.28 behind the root, legs 0.5 with the
    // ankle 0.22 up; fore 0.38 ahead, legs 0.56, ankle 0.16. Walk groups in
    // order: left hind, left fore, right hind, right fore. Its walking
    // pace is 1 node a second; the trot is twice that.
    {
        const Body wolf{"wolf",
                0.72f,
                {{-0.125f, 0.72f, -0.28f, 0.5f, 0.22f, 1, 0, 0},
                        {-0.125f, 0.72f, 0.375f, 0.56f, 0.16f, 0, 1, 1},
                        {0.125f, 0.72f, -0.28f, 0.5f, 0.22f, 0, 2, 0},
                        {0.125f, 0.72f, 0.375f, 0.56f, 0.16f, 1, 3, 1}},
                false};
        // Forward is -z here (yaw pi), as in the fixture.
        const std::vector<Segment> path = {
                {1, 0, 0, 0, false}, {4, 0, -1.0f, 0, false}, {1, 0, 0, float(M_PI), false},
                {3, 0, 2.0f, 0, false}, {2, 0, 1.0f, 0, false}, {2, 0, -0.6f, 0, false}, {1.5f, 0, 0, 0, false}};
        for (float fps : {60.0f, 20.0f}) {
            const float dt = 1.0f / fps;
            std::vector<StepLeg> legs;
            for (const BodyLeg &l : wolf.legs)
                legs.push_back({l.length, l.ankle, l.group, l.slow_group, l.girdle});
            StepPlanner p(legs);
            float x = 0, z = 0, yaw = M_PI, slide = 0, off = 0, pitch_most = 0, pitch_least = 0;
            int no_support = 0, still_steps = 0, two_at_walk = 0, out_of_order = 0, wrong_pair = 0;
            int walk_frames_fast = 0, trot_frames_slow = 0, last_lift = -1;
            float since_change = 0;
            uint64_t walk_steps = 0, trot_steps = 0;
            std::vector<StepFoot> last;
            const std::string what = "wolf at " + std::to_string((int)fps) + " fps: ";
            for (const Segment &seg : path) {
                const int frames = (int)std::lround(seg.seconds / dt);
                for (int f = 0; f < frames; ++f) {
                    x += seg.vx * dt;
                    z += seg.vz * dt;
                    yaw += seg.yaw_rate * dt;
                    const float y = (z <= -2.5f && z >= -4.5f) ? 0.5f : 0.0f;
                    const float fx = -std::sin(yaw), fz = std::cos(yaw), rx = std::cos(yaw), rz = std::sin(yaw);
                    StepInput in;
                    in.dt = dt;
                    in.root = {x, y, z};
                    in.yaw = yaw;
                    in.floor = floorAt;
                    for (const BodyLeg &l : wolf.legs) {
                        in.hips.push_back({x + rx * l.x + fx * l.z, y + l.y, z + rz * l.x + fz * l.z});
                        in.rest.push_back({x + rx * l.x + fx * l.z, y, z + rz * l.x + fz * l.z});
                    }
                    const uint64_t before = p.stats().steps;
                    std::vector<char> was_planted;
                    for (const StepFoot &ft : p.feet())
                        was_planted.push_back(ft.planted);
                    const bool was_walking = p.walking();
                    p.step(in);
                    if (p.walking() != was_walking) {
                        last_lift = -1; // a new gait starts its order afresh
                        since_change = 0;
                    }
                    since_change = std::min(since_change + dt, (float)f * dt);
                    const auto &feet = p.feet();
                    const float speed = std::hypot(seg.vx, seg.vz);
                    const float froude = speed * speed / (9.81f * 0.53f);
                    if (speed > 0 && f * dt > 0.6f) {
                        if (froude > STEP_TROT_FROUDE + 0.1f && p.walking())
                            ++trot_frames_slow;
                        if (froude < STEP_WALK_FROUDE - 0.1f && !p.walking())
                            ++walk_frames_fast;
                    }
                    int swinging = 0, planted = 0;
                    for (size_t i = 0; i < feet.size(); ++i) {
                        if (!feet[i].planted) {
                            ++swinging;
                            // A leg lifting this frame: the walk's order.
                            if (!was_planted.empty() && was_planted[i] && p.walking() && speed > 0) {
                                const int g = wolf.legs[i].slow_group;
                                // On level ground: a step up or down may
                                // take a foot out of turn.
                                // Settled into the gait: a second after it or
                                // the direction changed (after a trot the
                                // pairs are in step, and a foot well out of
                                // reach goes out of turn while they part).
                                const bool level = std::fabs(z + 2.5f) > 0.9f && std::fabs(z + 4.5f) > 0.9f
                                        && since_change > 1.0f;
                                const bool backing = (-std::sin(yaw)) * seg.vx + std::cos(yaw) * seg.vz < 0;
                                if (last_lift >= 0 && g != (last_lift + (backing ? 3 : 1)) % 4 && level) {
                                    ++out_of_order;
                                }
                                last_lift = g;
                            }
                            continue;
                        }
                        ++planted;
                        if (!last.empty() && last[i].planted && last[i].supported && feet[i].supported)
                            slide = std::max(slide, std::hypot(std::hypot(feet[i].sole[0] - last[i].sole[0],
                                                                    feet[i].sole[1] - last[i].sole[1]),
                                                            feet[i].sole[2] - last[i].sole[2]));
                        if (feet[i].supported) {
                            auto h = floorAt(feet[i].sole[0], feet[i].sole[2], feet[i].sole[1] + 0.01f,
                                    feet[i].sole[1] - 0.01f);
                            off = std::max(off, h ? std::fabs(*h - feet[i].sole[1]) : 1.0f);
                        }
                    }
                    if (!p.walking()) {
                        // Swinging legs at a trot: a diagonal pair or one.
                        for (size_t i = 0; i < feet.size(); ++i)
                            for (size_t j = i + 1; j < feet.size(); ++j)
                                if (!feet[i].planted && !feet[j].planted && wolf.legs[i].group != wolf.legs[j].group)
                                    ++wrong_pair;
                        trot_steps += p.stats().steps - before;
                    } else {
                        if (swinging > 1 && speed > 0)
                            ++two_at_walk;
                        walk_steps += p.stats().steps - before;
                    }
                    if (planted == 0)
                        ++no_support;
                    // Four feet take longer to settle than two: 1.2 s.
                    if (speed == 0 && seg.yaw_rate == 0 && f * dt > 1.2f) {
                        still_steps += int(p.stats().steps - before);
                    }
                    // Fore feet on the slab, hind feet on the floor.
                    // The chest against the pelvis: up while climbing onto the
                    // slab, down while stepping off it.
                    const float pitch = p.girdleDrop(1) - p.girdleDrop(0);
                    if (seg.vz < 0)
                        pitch_most = std::max(pitch_most, pitch);
                    else if (seg.vz > 0)
                        pitch_least = std::min(pitch_least, pitch);
                    last = feet;
                }
            }
            const StepStats &s = p.stats();
            std::printf("wolf %2.0f fps: %llu steps (%llu walking, %llu trotting), forced %llu, unreachable %llu, "
                        "stretched %llu frames (worst %.3f), chest against pelvis %.3f to %.3f, walk lifts out of order %d\n",
                    fps, (unsigned long long)s.steps, (unsigned long long)walk_steps, (unsigned long long)trot_steps,
                    (unsigned long long)s.forced, (unsigned long long)s.unreachable,
                    (unsigned long long)s.stretched, s.most_stretch, pitch_least, pitch_most, out_of_order);
            expect(slide == 0.0f, what + "a planted foot moved " + std::to_string(slide));
            expect(off < 1e-4f, what + "a planted foot off the ground by " + std::to_string(off));
            expect(s.unreachable == 0, what + std::to_string(s.unreachable) + " landings with no foothold");
            expect(no_support == 0, what + std::to_string(no_support) + " frames with no foot planted");
            expect(still_steps == 0, what + std::to_string(still_steps) + " steps while standing settled");
            expect(walk_steps > 10 && trot_steps > 10, what + "walked " + std::to_string(walk_steps)
                            + " steps and trotted " + std::to_string(trot_steps));
            expect(two_at_walk == 0, what + std::to_string(two_at_walk) + " walking frames with two legs up");
            // The walk's order and the chest stepping down at a display's
            // frame rate; at 20 fps, reported (forced lifts break the order).
            if (fps > 30)
                expect(out_of_order == 0, what + std::to_string(out_of_order) + " walking lifts out of order");
            expect(wrong_pair == 0, what + std::to_string(wrong_pair) + " trotting frames with a lateral pair up");
            expect(trot_frames_slow == 0 && walk_frames_fast == 0,
                    what + "walked at a trot's speed " + std::to_string(trot_frames_slow)
                            + " frames, trotted at a walk's " + std::to_string(walk_frames_fast));
            expect(pitch_most > 0.2f, what + "chest raised only " + std::to_string(pitch_most) + " climbing");
            if (fps > 30)
                expect(pitch_least < -0.2f, what + "chest lowered only " + std::to_string(pitch_least) + " stepping down");
        }
    }

    // A body thrown in the air and caught again plants its feet afresh, and
    // a teleport resets them.
    {
        StepPlanner p({{0.8f, 0.09f, 0}, {0.8f, 0.09f, 1}});
        StepInput in;
        in.dt = 1.0f / 60;
        in.floor = floorAt;
        auto at = [&](float x, float y, float z) {
            in.root = {x, y, z};
            in.hips = {{x - 0.1f, y + 0.85f, z}, {x + 0.1f, y + 0.85f, z}};
            in.rest = {{x - 0.1f, y, z}, {x + 0.1f, y, z}};
        };
        at(0, 0, 0);
        p.step(in);
        in.grounded = false;
        at(0, 1, 0);
        p.step(in);
        expect(!p.feet()[0].planted && !p.feet()[1].planted, "feet planted in the air");
        in.grounded = true;
        at(0, 0, 0);
        p.step(in);
        expect(p.feet()[0].planted && p.feet()[1].planted, "feet not planted on landing");
        at(5, 0, 5);
        p.step(in);
        expect(std::fabs(p.feet()[0].sole[0] - 4.9f) < 1e-4f, "a teleport did not reset the feet");
    }

    std::printf("goanna_steps_test: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
