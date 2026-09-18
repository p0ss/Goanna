// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <algorithm>
#include <cmath>

namespace goanna {
// One clock for local hand contact, damage, sound and chips. Whole swings fit
// the tool time, with a minimum number of small chips for substantial blocks.
// A swing takes about a third of a second, not two thirds. The old .65 read as
// a slow, deliberate heave next to the vanilla client's animation; at .34 the
// tool swings at roughly twice the rate and a dig of the same length simply
// gets twice as many blows.
//
// Damage is unaffected by the change, which is why it is safe: the carve steps
// on `progress()`, which is landed over blows, so twice as many blows means
// twice as many smaller bites over the same dig rather than twice the wear.
constexpr double kSwingPeriod = .34;

struct MiningCycle {
    double elapsed = 0, duration = kSwingPeriod, period = kSwingPeriod;
    int blows = 1, landed = 0;
    void reset(double tool_time, int minimum_blows = 1) {
        duration = std::max(.24, tool_time);
        blows = std::max(1, (int)std::round(duration / kSwingPeriod));
        if (blows < minimum_blows) {
            blows = minimum_blows;
            duration = std::max(duration, blows * kSwingPeriod);
        }
        period = duration / blows;
        landed = 0;
        // START MID CYCLE, at the top of the downstroke, so the first thing a
        // player sees is the tool going FORWARD. From zero the pose begins at
        // full extension and retracts, which reads as winding up backwards
        // before the first blow has been struck. Landing at .62 of a period
        // puts the very first motion on the strike, and the first blow lands
        // after the remaining .38 rather than a whole period later.
        elapsed = period * .62;
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
