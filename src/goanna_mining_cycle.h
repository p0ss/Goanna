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
// The first swing starts this far through its period, at the top of the
// downstroke, so the first thing a player sees is the tool going FORWARD.
// From the start of a period the pose begins at full extension and retracts,
// which reads as winding up backwards before a blow has been struck.
constexpr double kSwingLead = .62;

struct MiningCycle {
    double elapsed = 0, duration = kSwingPeriod, period = kSwingPeriod;
    int blows = 1, landed = 0;
    void reset(double tool_time, int minimum_blows = 1) {
        duration = std::max(.24, tool_time);
        // The swings are placed so the LAST blow lands exactly at the tool
        // time. The first swing is shorter by the lead, so blows less the
        // lead whole periods fill the tool time. Starting the clock at the lead
        // instead finished every dig .62 of a swing before the server's
        // tool time, earlier than a vanilla client ever reports a dig.
        blows = std::max(1, (int)std::round(duration / kSwingPeriod + kSwingLead));
        if (blows < minimum_blows) {
            blows = minimum_blows;
            duration = std::max(duration, (blows - kSwingLead) * kSwingPeriod);
        }
        period = duration / (blows - kSwingLead);
        landed = 0;
        elapsed = 0;
    }
    // Swing periods since the start, counted from the lead.
    double swings() const { return elapsed / period + kSwingLead; }
    bool advance(double dt) {
        elapsed = std::min(duration, elapsed + std::max(0.0, dt));
        const int next = std::min(blows, (int)std::floor(swings() + 1e-6));
        const bool contact = next > landed;
        landed = next;
        return contact; // skipped frames catch up damage, without a sound storm
    }
    float progress() const { return (float)landed / blows; }
    bool complete() const { return landed == blows; }
    float pose(bool contact) const {
        if (contact || complete()) return 1;
        double phase = std::fmod(swings(), 1.0);
        // Lift/recover, hold the wind-up, then a quicker deliberate downstroke.
        double t = phase < .28 ? 1.0-phase/.28 : (phase-.62)/.38;
        t = std::clamp(t, 0.0, 1.0);
        return (float)(t*t*(3-2*t));
    }
};
}
