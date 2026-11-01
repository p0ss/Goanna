// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The climb planner (goanna_climb.h) driven over scripted climbs with no
// Godot runtime. Built and run by `cmake --build build --target check`.
//
// The body is DorfCraft's sapiens frame at one node a mesh unit (hips 0.906
// above the root, legs 0.813 long; shoulders 1.281 up, 0.219 out, arms
// 0.562 long), facing +z. Climbs, at 60 and 20 frames a second:
// - a ladder on a wall at z = 0.5, up four nodes at 2.5 nodes a second
//   (about Luanti's climbing speed), a pause, and down again;
// - a player jumping onto a one-node ledge at z = 0.5 (jump speed 6.5,
//   gravity 17: a peak of 1.24 nodes) while walking into it;
// - a creature stepping up the same ledge at once (stepheight 1.1), its
//   position eased up over 0.15 s as a client sees it;
// - a jump at a ledge 1.5 nodes up, which the body falls back from;
// - a stroke starting half way up the ladder.
//
// Checked: a held hand or foot never moves; held limbs stay in reach; a
// hand and the opposite foot move together, never both pairs at once; a
// mantle ends with both feet on the ledge and the hands let go; a failed
// mantle and a stroke let go of everything; ended() comes once a climb.

#include <cmath>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>

#include "goanna_climb.h"

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        if (g_failures <= 40)
            std::cerr << "goanna_climb_test: " << message << "\n";
    }
}

// Left arm, right arm, left leg, right leg.
std::vector<ClimbLimb> body() {
    return {{0.562f, 0.0f, true, -1}, {0.562f, 0.0f, true, 1}, {0.813f, 0.09f, false, -1},
            {0.813f, 0.09f, false, 1}};
}

std::vector<StepVec> anchors(const StepVec &r) {
    return {{r[0] - 0.219f, r[1] + 1.281f, r[2]}, {r[0] + 0.219f, r[1] + 1.281f, r[2]},
            {r[0] - 0.094f, r[1] + 0.906f, r[2]}, {r[0] + 0.094f, r[1] + 0.906f, r[2]}};
}

float dist(const StepVec &a, const StepVec &b) {
    return std::hypot(std::hypot(a[0] - b[0], a[1] - b[1]), a[2] - b[2]);
}

struct Run {
    ClimbPlanner p{body()};
    std::vector<ClimbContact> last;
    int ended = 0;
    float slide = 0, stretch = 0;
    bool both_pairs = false;
    void step(const ClimbInput &in) {
        p.step(in);
        const auto &c = p.contacts();
        const auto &l = p.limbs();
        bool moving[2] = {false, false};
        for (size_t i = 0; i < c.size(); ++i) {
            if (!last.empty() && c[i].held && last[i].held && c[i].weight > 0.5f)
                slide = std::max(slide, dist(c[i].at, last[i].at));
            if (c[i].held && c[i].weight > 0.5f && p.mode() == ClimbMode::Ladder) {
                const float over = dist(in.anchors[i], c[i].at) - l[i].end - CLIMB_REACH * l[i].length;
                stretch = std::max(stretch, over);
            }
            if (!c[i].held && c[i].weight > 0.5f)
                moving[(l[i].arm == (l[i].side < 0)) ? 0 : 1] = true;
        }
        if (p.mode() == ClimbMode::Ladder && moving[0] && moving[1])
            both_pairs = true;
        if (p.ended())
            ++ended;
        last = c;
    }
};

void ladder(float fps) {
    const std::string tag = "ladder at " + std::to_string((int)fps) + " fps: ";
    Run r;
    const float dt = 1.0f / fps;
    // Pressed against the ladder, as a body walking into it stands: its
    // 0.3 node radius from the wall's face.
    StepVec root{0, 0, 0.2f};
    float t = 0;
    float vy = 0;
    bool struck = false;
    auto in = [&](bool grounded) {
        ClimbInput c;
        c.dt = dt;
        c.root = root;
        c.vy = vy;
        c.grounded = grounded;
        c.anchors = anchors(root);
        c.ladder = true;
        c.face = {0, root[1], 0.5f};
        c.face_nz = -1.0f;
        c.soles = {{-0.094f, root[1], 0.2f}, {0.094f, root[1], 0.2f}};
        return c;
    };
    // Up four nodes, a pause, down to the floor, then a while standing.
    while (t < 6.0f) {
        t += dt;
        vy = t < 1.6f ? 2.5f : t < 2.4f ? 0.0f : root[1] > 0 ? -2.5f : 0.0f;
        root[1] = std::max(0.0f, root[1] + vy * dt);
        r.step(in(root[1] <= 0.0f && t > 2.4f));
        if (t > 0.5f && t < 1.5f)
            expect(r.p.mode() == ClimbMode::Ladder, tag + "climbing while going up");
    }
    expect(r.p.mode() == ClimbMode::None, tag + "off the ladder standing at the foot");
    expect(r.p.weight() < 0.01f, tag + "let go of the ladder");
    expect(r.ended == 1, tag + "ended once, " + std::to_string(r.ended));
    expect(r.slide < 1e-4f, tag + "held limbs never move, slide " + std::to_string(r.slide));
    expect(r.stretch < (fps >= 60.0f ? 0.03f : 0.08f), tag + "held limbs in reach, over by " + std::to_string(r.stretch));
    expect(!r.both_pairs, tag + "one pair moves at a time");
    // Four nodes up and four down, each limb a move every half its length
    // or so: well over twenty moves, not hundreds.
    const uint64_t moves = r.p.stats().moves;
    expect(moves >= 20 && moves <= 120, tag + "moves " + std::to_string(moves));
    std::printf("ladder %2.0f fps: %llu moves, slide %.4f, most over reach %.3f\n", fps,
            (unsigned long long)moves, r.slide, r.stretch);

    // A stroke half way up lets go of everything.
    Run s;
    root = {0, 0, 0.2f};
    t = 0;
    while (t < 2.0f) {
        t += dt;
        vy = t < 1.0f ? 2.5f : 0.0f;
        root[1] += vy * dt;
        ClimbInput c = in(false);
        c.striking = t > 1.0f;
        s.step(c);
        struck |= c.striking;
    }
    expect(struck && s.p.mode() == ClimbMode::None && s.p.weight() < 0.01f, tag + "a stroke lets go");
}

// The ledge's top at `top` from z = 0.5 on; the body walks into it at 1.4
// nodes a second, held back by its 0.3 node radius until it is above it.
void mantle(float fps, float top, bool step_up, bool expect_land) {
    const std::string tag = std::string(step_up ? "step up" : "jump") + " to " + std::to_string(top).substr(0, 3)
            + " at " + std::to_string((int)fps) + " fps: ";
    Run r;
    const float dt = 1.0f / fps;
    StepVec root{0, 0, 0.1f};
    float vy = 0, t = 0, floor = 0, eased = 0;
    bool grounded = true, started = false;
    std::vector<StepVec> soles{{-0.094f, 0, 0.1f}, {0.094f, 0, 0.1f}};
    while (t < 3.0f) {
        t += dt;
        const float prev = root[1];
        if (step_up) {
            // The server lifts the body at once; the client eases there.
            if (!started && root[2] >= 0.2f) {
                started = true;
                floor = top;
            }
            eased += (floor - eased) * (1.0f - std::exp(-dt / 0.05f));
            root[1] = eased;
            grounded = std::fabs(floor - eased) < 0.02f;
        } else {
            if (!started && t > 0.2f) {
                started = true;
                vy = 6.5f;
                grounded = false;
            }
            if (!grounded) {
                // Over the ledge (the 0.3 node radius past its face at 0.5)
                // and above its top before this frame: it lands on it.
                floor = root[2] > 0.2f && root[1] >= top ? top : 0.0f;
                vy -= 17.0f * dt;
                root[1] += vy * dt;
                if (root[1] <= floor) {
                    root[1] = floor;
                    vy = 0;
                    grounded = true;
                }
            }
        }
        // Forward, unless the ledge is in the way.
        const float z = root[2] + 1.4f * dt;
        root[2] = root[1] >= top - 0.01f ? std::min(z, 1.5f) : std::min(z, 0.2f);
        const float sv = (root[1] - prev) / dt;
        ClimbInput c;
        c.dt = dt;
        c.root = root;
        c.vy = sv;
        c.grounded = grounded;
        c.anchors = anchors(root);
        c.ledge = root[1] < top - 0.05f;
        c.edge = {0, top, 0.5f};
        c.edge_nz = -1.0f;
        c.soles = soles;
        r.step(c);
    }
    const ClimbStats &s = r.p.stats();
    expect(s.mantles == 1, tag + "one mantle, " + std::to_string(s.mantles));
    expect(r.p.mode() == ClimbMode::None && r.p.weight() < 0.01f, tag + "let go at the end");
    expect(r.ended == 1, tag + "ended once, " + std::to_string(r.ended));
    expect(r.slide < 1e-4f, tag + "held limbs never move, slide " + std::to_string(r.slide));
    if (expect_land) {
        expect(s.landed == 1 && s.abandoned == 0, tag + "landed on the ledge");
        for (size_t i = 2; i < 4; ++i) {
            const StepVec &f = r.p.contacts()[i].at;
            expect(std::fabs(f[1] - top) < 1e-3f && f[2] > 0.5f, tag + "foot " + std::to_string(i) + " on the ledge");
        }
    } else {
        expect(s.landed == 0 && s.abandoned == 1, tag + "fell back and let go");
    }
    std::printf("%s%llu frames, landed %llu, abandoned %llu, moves %llu\n", tag.c_str(),
            (unsigned long long)s.mantle_frames, (unsigned long long)s.landed, (unsigned long long)s.abandoned,
            (unsigned long long)s.moves);
}

} // namespace

int main() {
    for (float fps : {60.0f, 20.0f}) {
        ladder(fps);
        mantle(fps, 1.0f, false, true);
        mantle(fps, 1.0f, true, true);
        mantle(fps, 1.5f, false, false);
    }
    if (g_failures) {
        std::cerr << "goanna_climb_test: " << g_failures << " of " << g_checks << " checks failed\n";
        return 1;
    }
    std::cout << "goanna_climb_test: all " << g_checks << " checks passed\n";
    return 0;
}
