// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <algorithm>
#include <cmath>

namespace goanna {
// One clock for local hand contact, damage, sound and chips. Whole swings fit
// the tool time, with a minimum number of small chips for substantial blocks.
struct MiningCycle {
    double elapsed = 0, duration = .65, period = .65;
    int blows = 1, landed = 0;
    void reset(double tool_time, int minimum_blows = 1) {
        elapsed = 0;
        duration = std::max(.24, tool_time);
        blows = std::max(1, (int)std::round(duration / .65));
        if (blows < minimum_blows) {
            blows = minimum_blows;
            duration = std::max(duration, blows * .65);
        }
        period = duration / blows;
        landed = 0;
    }
    bool advance(double dt) {
        elapsed = std::min(duration, elapsed + std::max(0.0, dt));
        const int next = std::min(blows, (int)std::floor(elapsed / period + 1e-6));
        const bool contact = next > landed;
        landed = next;
        return contact; // skipped frames catch up damage, without a sound storm
    }
    float progress() const { return (float)landed / blows; }
    bool complete() const { return landed == blows; }
    float pose(bool contact) const {
        if (contact || complete()) return 1;
        double phase = std::fmod(elapsed, period) / period;
        // Lift/recover, hold the wind-up, then a quicker deliberate downstroke.
        double t = phase < .28 ? 1.0-phase/.28 : (phase-.62)/.38;
        t = std::clamp(t, 0.0, 1.0);
        return (float)(t*t*(3-2*t));
    }
};
}
