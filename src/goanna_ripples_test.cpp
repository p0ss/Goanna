// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The ripple field's physics, with no Godot runtime: RippleField alone.
// Not built by default: cmake --build build --target goanna_ripples_test
//
// What the point rings could not do and this must: a body moving through the
// water pushes a crest up ahead of it and leaves its waves in a V behind,
// a body standing still makes a dimple rather than a hole, a bank stops a
// wave, and waves that reach the edge of the patch are soaked up rather
// than thrown back. The numbers it prints are what the look was tuned on.

#include "goanna_ripples.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>

using namespace goanna;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_ripples_test: " << message << "\n";
    }
}

// Runs `seconds` of frames at 60 a second with these bodies, the body
// moving along its velocity each frame.
void run(RippleField &f, std::vector<RippleBody> bodies, float seconds) {
    const float dt = 1.0f / 60.0f;
    for (float t = 0.0f; t < seconds; t += dt) {
        for (RippleBody &b : bodies) {
            b.x += b.vx * dt;
            b.z += b.vz * dt;
        }
        f.step(dt, bodies);
    }
}

// The largest |height| along a segment of x at z, and where it is.
std::pair<float, float> peakAlongX(const RippleField &f, float x0, float x1, float z) {
    float best = 0.0f, at = x0;
    for (float x = x0; x <= x1; x += 0.03125f) {
        float h = std::fabs(f.height(x, z));
        if (h > best) {
            best = h;
            at = x;
        }
    }
    return {best, at};
}

bool finite(const RippleField &f) {
    for (float h : f.heights())
        if (!std::isfinite(h))
            return false;
    return true;
}

} // namespace

int main() {
    // 1. Nothing on it: still, asleep, and stepping it costs nothing.
    {
        RippleField f(32);
        run(f, {}, 1.0f);
        expect(f.asleep() && f.peak() == 0.0f, "empty water is not still");
    }
    // 2. A body standing in the water: a dimple under it that stays a
    // dimple, not a hole that deepens for as long as it stands there.
    {
        RippleField f(32);
        RippleBody b;
        b.x = 16.0f;
        b.z = 16.0f;
        b.press = 1.0f;
        run(f, {b}, 5.0f);
        const float at5 = f.height(16.0f, 16.0f);
        run(f, {b}, 5.0f);
        const float at10 = f.height(16.0f, 16.0f);
        std::printf("standing: dimple %.4f at 5 s, %.4f at 10 s\n", at5, at10);
        expect(at5 < 0.0f && at10 < 0.0f, "a standing body does not press the water down");
        expect(std::fabs(at10 - at5) < 0.25f * std::fabs(at5), "a standing body digs an ever deeper hole");
        expect(!f.asleep(), "water under a body fell asleep");
    }
    // 3. A body walking through at 3 nodes a second along +x. The field is
    // moved with it, as wake.gd moves it with the eye.
    {
        RippleField f(32);
        f.setOrigin(0, 0);
        RippleBody b;
        b.x = 4.0f;
        b.z = 16.0f;
        b.vx = 3.0f;
        b.press = 1.0f;
        b.displace = 0.1f;
        std::vector<RippleBody> bodies = {b};
        run(f, bodies, 5.0f);
        const float bx = 4.0f + 3.0f * 5.0f;
        // Ahead: a crest standing up in front of the body, and quiet water
        // further on, because the waves cannot outrun it.
        auto near_ahead = peakAlongX(f, bx + 0.2f, bx + 1.2f, 16.0f);
        auto far_ahead = peakAlongX(f, bx + 2.5f, bx + 5.0f, 16.0f);
        float crest = -1.0f;
        for (float x = bx + 0.2f; x <= bx + 1.2f; x += 0.03125f)
            crest = std::max(crest, f.height(x, 16.0f));
        std::printf("walking 3 n/s: crest ahead %.4f at +%.2f, far ahead %.4f\n",
                crest, near_ahead.second - bx, far_ahead.first);
        expect(crest > 0.0f, "no crest ahead of a moving body");
        expect(far_ahead.first < 0.2f * near_ahead.first, "waves run far out ahead of a body faster than them");
        // Behind: across the path, 3 nodes back, the waves stand out to
        // either side (the arms of the V), not along the path itself.
        const float back = bx - 3.0f;
        float best = 0.0f, lateral = 0.0f;
        for (float dz = 0.0f; dz <= 4.0f; dz += 0.0625f) {
            float h = 0.0f;
            // The arm's height, not one sample of its ripple.
            for (float dx = -0.5f; dx <= 0.5f; dx += 0.0625f)
                h = std::max(h, std::fabs(f.height(back + dx, 16.0f + dz)));
            if (h > best) {
                best = h;
                lateral = dz;
            }
        }
        const float angle = std::atan2(lateral, 3.0f) * 180.0f / 3.14159265f;
        std::printf("walking 3 n/s: strongest wave 3 nodes back is %.2f nodes out (V half angle %.0f degrees), %.4f high\n",
                lateral, angle, best);
        expect(angle > 12.0f && angle < 45.0f, "the wake is not a V: half angle " + std::to_string(angle));
        // Both arms: the pattern is symmetric about the path.
        const float left = std::fabs(f.height(back, 16.0f + lateral));
        const float right = std::fabs(f.height(back, 16.0f - lateral));
        expect(std::fabs(left - right) < 0.05f * best + 1e-5f, "the V is lopsided");
        // Steepness, which is what the water shader shows.
        float slope = 0.0f;
        for (float x = bx - 6.0f; x <= bx + 1.0f; x += 0.0625f)
            for (float z = 12.0f; z <= 20.0f; z += 0.0625f) {
                const float gx = (f.height(x + 0.0625f, z) - f.height(x - 0.0625f, z)) / 0.125f;
                const float gz = (f.height(x, z + 0.0625f) - f.height(x, z - 0.0625f)) / 0.125f;
                slope = std::max(slope, std::sqrt(gx * gx + gz * gz));
            }
        std::printf("walking 3 n/s, press 1, displace 0.1: steepest slope %.3f\n", slope);
        expect(finite(f), "walking made the field blow up");
    }
    // 4. A bank. A splash at node 10 with a wall of land at nodes 12 and 13:
    // the water past the wall stays still, and the wall's own cells stay
    // flat.
    {
        std::vector<uint8_t> mask(32 * 32, 1);
        for (int j = 0; j < 32; ++j)
            for (int i = 12; i <= 13; ++i)
                mask[(size_t)j * 32 + i] = 0;
        RippleField walled(32), open(32);
        walled.setWater(mask);
        walled.impulse(10.0f, 16.0f, 2.0f, 0.3f);
        open.impulse(10.0f, 16.0f, 2.0f, 0.3f);
        float beyond_walled = 0.0f, beyond_open = 0.0f;
        for (int s = 0; s < 360; ++s) {
            walled.step(1.0f / 60.0f, {});
            open.step(1.0f / 60.0f, {});
            beyond_walled = std::max(beyond_walled, peakAlongX(walled, 14.5f, 20.0f, 16.0f).first);
            beyond_open = std::max(beyond_open, peakAlongX(open, 14.5f, 20.0f, 16.0f).first);
        }
        std::printf("bank: past the wall %.5f, same place with no wall %.5f\n", beyond_walled, beyond_open);
        expect(beyond_open > 0.0f && beyond_walled < 0.02f * beyond_open, "a wave passes through a bank");
        expect(walled.height(12.5f, 16.0f) == 0.0f, "the bank itself moves");
    }
    // 5. The sponge and sleep: a splash dies away, the patch goes still and
    // sleeps, rather than the waves bouncing round it for ever.
    {
        RippleField f(32);
        f.impulse(16.0f, 16.0f, 3.0f, 0.3f);
        int frames = 0;
        while (!f.asleep() && frames < 60 * 30) {
            f.step(1.0f / 60.0f, {});
            ++frames;
        }
        std::printf("splash: still and asleep after %.1f s\n", frames / 60.0f);
        expect(f.asleep(), "a splash never settles");
        expect(frames < 60 * 20, "a splash takes over 20 s to settle");
    }
    // 6. Moving the patch keeps the water on it where it was in the world.
    {
        RippleField f(32);
        f.impulse(16.0f, 16.0f, 2.0f, 0.3f);
        run(f, {}, 0.5f);
        const float before = f.height(16.7f, 16.2f);
        f.setOrigin(2, -1);
        const float after = f.height(16.7f, 16.2f);
        expect(before != 0.0f && std::fabs(before - after) < 1e-6f, "moving the patch moved the waves");
    }
    // 7. Hard use: a fast body, a sharp turn and a splash, for ten seconds.
    {
        RippleField f(32);
        RippleBody b;
        b.x = 6.0f;
        b.z = 6.0f;
        b.vx = 8.0f;
        b.press = 3.0f;
        b.displace = 0.3f;
        run(f, {b}, 2.0f);
        b.x += 16.0f;
        b.vx = 0.0f;
        b.vz = 8.0f;
        f.impulse(b.x, b.z, 4.0f, 0.3f);
        run(f, {b}, 2.0f);
        run(f, {}, 6.0f);
        std::printf("hard use: peak %.4f after\n", f.peak());
        expect(finite(f) && f.peak() < 1.0f, "hard use made the field blow up");
    }

    // 9. What first person sees: the steepest slope 0.4 to 1.5 and 1.5 to 6
    // nodes from a swimmer (nearer is the body itself), as RippleField::swimmer sets
    // it up for wake.gd, doing what a body really does in water. The rings'
    // trail was about 0.3. Moving across the water must show plainly (over
    // a tenth for a player); dropping in must leave a ring that can be seen
    // (over 0.06); bobbing gently, a fifth of a node up and down, makes
    // faint rings in real water too, and here must merely make some (over
    // 0.02). Holding still must leave the water still: waves that came from
    // nothing the player did were the first complaint.
    struct Motion {
        const char *what;
        float speed;          // along x, nodes a second
        float bob;            // peak rate its submerged depth changes, n/s
        float drop;           // rate it sinks in for the first 0.3 s
    };
    const Motion motions[] = {
        {"holding still", 0.0f, 0.0f, 0.0f},
        {"wading at 1 n/s", 1.0f, 0.0f, 0.0f},
        {"swimming at 2 n/s", 2.0f, 0.0f, 0.0f},
        {"swimming at 3 n/s", 3.0f, 0.0f, 0.0f},
        {"bobbing in place", 0.0f, 0.8f, 0.0f},
        {"dropping in, then still", 0.0f, 0.0f, 3.0f},
    };
    for (float scale : {1.0f, 0.7f}) {
        for (const Motion &m : motions) {
            RippleField f(32);
            float x = 4.0f, t = 0.0f;
            // Dropping in is looked at two seconds after, when its ring has
            // spread (at 1.2 nodes a second) to where the eye sees it; the
            // rest after five.
            const int frames = m.drop > 0.0f ? 120 : 300;
            for (int i = 0; i < frames; ++i) {
                t += 1.0f / 60.0f;
                x += m.speed / 60.0f;
                float sinking = m.bob * std::sin(6.2831853f * 0.6f * t);
                if (t < 0.3f)
                    sinking += m.drop;
                f.step(1.0f / 60.0f, {RippleField::swimmer(x, 16.0f, m.speed, 0.0f, sinking, scale)});
            }
            float seen = 0.0f, near = 0.0f;
            for (float px = x - 6.0f; px <= x + 6.0f; px += 0.0625f)
                for (float pz = 10.0f; pz <= 22.0f; pz += 0.0625f) {
                    const float r = std::hypot(px - x, pz - 16.0f);
                    if (r < 0.4f)
                        continue;
                    const float gx = (f.height(px + 0.0625f, pz) - f.height(px - 0.0625f, pz)) / 0.125f;
                    const float gz = (f.height(px, pz + 0.0625f) - f.height(px, pz - 0.0625f)) / 0.125f;
                    const float g = std::sqrt(gx * gx + gz * gz);
                    if (r < 1.5f)
                        near = std::max(near, g);
                    else
                        seen = std::max(seen, g);
                }
            std::printf("seen from a swimmer at scale %.1f %s: steepest slope 0.4 to 1.5 nodes out %.3f, "
                    "1.5 to 6 %.3f\n", scale, m.what, near, seen);
            const std::string what = std::string(scale == 1.0f ? "a player " : "an animal ") + m.what;
            if (m.speed == 0.0f && m.bob == 0.0f && m.drop == 0.0f) {
                expect(seen == 0.0f && f.asleep(), what + " disturbs the water: " + std::to_string(seen));
                continue;
            }
            float floor = scale == 1.0f ? 0.1f : 0.06f;
            if (m.drop > 0.0f)
                floor = scale == 1.0f ? 0.06f : 0.04f;
            if (m.bob > 0.0f)
                floor = scale == 1.0f ? 0.02f : 0.008f;
            expect(seen > floor, what + " barely marks the water: " + std::to_string(seen));
            // And hard by the body, the first node round it, which the
            // first tuning left out as under the camera: it is in plain
            // view looking down, and lay flat. (Not two seconds after
            // dropping in: that ring has spread past it by then.)
            if (m.drop == 0.0f)
                expect(near > 1.5f * floor, what + " leaves the water flat round itself: " + std::to_string(near));
            expect(seen < 0.7f, what + " churns the water: " + std::to_string(seen));
            expect(finite(f), what + " made the field blow up");
        }
    }
    // Going in and out of the water: every crest has its trough (a pattern
    // of bright rings alone is not water), no water is made or lost, and
    // jumping up and down for five seconds stays a splash. The second tuning
    // lifted the surface with the body's speed and piled up mounds.
    {
        RippleField f(32);
        float t = 0.0f, hi = 0.0f, lo = 0.0f, sum_worst = 0.0f;
        for (int i = 0; i < 300; ++i) {
            t += 1.0f / 60.0f;
            // In and out every 0.6 s, as fast as the swimmer counts.
            const float sinking = std::fmod(t, 0.6f) < 0.3f ? 3.0f : -3.0f;
            f.step(1.0f / 60.0f, {RippleField::swimmer(16.0f, 16.0f, 0.0f, 0.0f, sinking, 1.0f)});
            // Under the body, which hides it, the water is pushed down and
            // let back by the whole depth the body goes in; what shows is
            // round it, from its edge out.
            float sum = 0.0f;
            const std::vector<float> &hs = f.heights();
            for (int j = 0; j < f.cells(); ++j)
                for (int i = 0; i < f.cells(); ++i) {
                    const float h = hs[(size_t)j * f.cells() + i];
                    sum += h;
                    const float cx = f.cornerX() + (i + 0.5f) * f.cellSize() - 16.0f;
                    const float cz = f.cornerZ() + (j + 0.5f) * f.cellSize() - 16.0f;
                    if (std::hypot(cx, cz) < RippleField::kSwimRadius + 2.0f * RippleField::kEdge)
                        continue;
                    hi = std::max(hi, h);
                    lo = std::min(lo, h);
                }
            sum_worst = std::max(sum_worst, std::fabs(sum) * f.cellSize() * f.cellSize());
        }
        std::printf("jumping in and out for 5 s, round the body: highest crest %.3f, deepest trough %.3f, "
                "water made at worst %.5f node^3\n", hi, lo, sum_worst);
        expect(hi < 0.3f && lo > -0.3f, "jumping in and out piles the water up");
        expect(-lo > 0.5f * hi && hi > 0.5f * -lo, "jumping in and out makes crests without troughs or troughs without crests");
        expect(sum_worst < 0.01f, "jumping in and out makes or loses water");
    }
    // The pattern is round the body, not behind it: a swimmer's own
    // disturbance, the crest it shoves up and the trough it leaves, is
    // centred within a quarter node of where it is.
    {
        RippleField f(32);
        float x = 4.0f;
        for (int i = 0; i < 180; ++i) {
            x += 2.0f / 60.0f;
            f.step(1.0f / 60.0f, {RippleField::swimmer(x, 16.0f, 2.0f, 0.0f, 0.0f, 1.0f)});
        }
        float hi = -1.0f, lo = 1.0f, at_hi = 0.0f, at_lo = 0.0f;
        for (float px = x - 3.0f; px <= x + 3.0f; px += 0.03125f) {
            const float h = f.height(px, 16.0f);
            if (h > hi) { hi = h; at_hi = px - x; }
            if (h < lo) { lo = h; at_lo = px - x; }
        }
        std::printf("swimming at 2 n/s: crest %.3f at %+.2f, trough %.3f at %+.2f nodes from the body\n",
                hi, at_hi, lo, at_lo);
        expect(at_hi > 0.0f && at_lo < 0.0f, "the crest is not ahead and the trough behind");
        expect(std::fabs(0.5f * (at_hi + at_lo)) < 0.25f, "the swimmer's pattern trails it");
    }

    // 10. Caustics, as water.gdshader draws them from the patch: the light
    // on a bed 1 node down scaled by 1 / (1 + 0.25 depth curvature), the
    // curvature over 2 cells either side, clamped to 0.3 to 2.5. Printed:
    // how much of the water round a swimmer at 2 n/s is visibly brightened
    // or darkened, and how much is at the clamps; nearly all of it at a
    // clamp would be a blown out pattern, none of it off 1 an invisible one.
    {
        RippleField f(32);
        float x = 4.0f;
        for (int i = 0; i < 300; ++i) {
            x += 2.0f / 60.0f;
            f.step(1.0f / 60.0f, {RippleField::swimmer(x, 16.0f, 2.0f, 0.0f, 0.0f, 1.0f)});
        }
        const float span = 2.0f * f.cellSize();
        int total = 0, bright = 0, dark = 0, clamped = 0;
        float most = 1.0f, least = 1.0f;
        for (float px = x - 6.0f; px <= x + 2.0f; px += 0.0625f)
            for (float pz = 12.0f; pz <= 20.0f; pz += 0.0625f) {
                const float c = f.height(px, pz);
                const float around = f.height(px + span, pz) + f.height(px - span, pz)
                        + f.height(px, pz + span) + f.height(px, pz - span);
                const float curvature = (around - 4.0f * c) / (span * span);
                const float focus = std::clamp(1.0f / std::max(1.0f + 0.25f * curvature, 0.05f), 0.3f, 2.5f);
                ++total;
                most = std::max(most, focus);
                least = std::min(least, focus);
                if (focus > 1.2f)
                    ++bright;
                if (focus < 0.83f)
                    ++dark;
                if (focus <= 0.3f || focus >= 2.5f)
                    ++clamped;
            }
        std::printf("caustics round a swimmer at 2 n/s, bed 1 node down: %.0f%% brighter by a fifth, "
                "%.0f%% darker, %.0f%% at a clamp; from %.2f to %.2f\n",
                100.0f * bright / total, 100.0f * dark / total, 100.0f * clamped / total, least, most);
        expect(bright > 0 && dark > 0, "a swimmer's ripples throw no caustics");
        expect(clamped < total / 10, "a swimmer's caustics are blown out");
    }

    // 8. Cost: a busy frame, one step of the whole patch with a body on it.
    {
        RippleField f(32);
        RippleBody b;
        b.x = 16.0f;
        b.z = 16.0f;
        b.vx = 3.0f;
        b.press = 1.0f;
        b.displace = 0.1f;
        run(f, {b}, 1.0f);
        const auto t0 = std::chrono::steady_clock::now();
        const int frames = 300;
        for (int i = 0; i < frames; ++i)
            f.step(1.0f / 60.0f, {b});
        const double ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count() / frames;
        std::printf("cost: %.3f ms a 60 Hz step\n", ms);
    }

    std::cout << "goanna_ripples_test: " << g_checks << " checks, " << g_failures << " failures\n";
    return g_failures == 0 ? 0 : 1;
}
