// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// How much of a body's melee stroke and foot fitting (goanna_strokes.h,
// ModelAnimator) is worked out, by its distance from the camera, so a crowd
// of combatants costs little more than the few nearest.
//
// Three tiers. Near and on screen (Full), the stroke is evaluated every
// step and the feet ask the map for the ground every step, as before.
// Further out, or near but off screen (Reduced), both run
// STROKE_REDUCED_RATE times a second: the stroke is evaluated one interval
// ahead and the pose shown is interpolated between the last two
// evaluations, and the feet keep easing towards the ground last found.
// Beyond STROKE_REDUCED_DISTANCE (Clip), neither runs and the game's own
// animation shows, the clip a stock client sees. Going in or out of Clip,
// the stroke pose fades over STROKE_DETAIL_BLEND seconds and the feet ease
// to or from the ground, so nothing pops.
//
// No Godot types: goanna_stroke_detail_test runs it on the fixtures with
// the evaluator alone. One StrokeLod belongs to one animator; main thread
// only, like the animator.

#include <cstdint>
#include <vector>

#include "goanna_strokes.h"

namespace goanna {

enum class StrokeDetail : uint8_t { Full, Reduced, Clip };

// Distances from the camera, nodes. A body keeps its tier until it is
// STROKE_DETAIL_HYSTERESIS past the boundary, so one standing on it does
// not flicker between tiers.
constexpr float STROKE_FULL_DISTANCE = 16.0f;
constexpr float STROKE_REDUCED_DISTANCE = 48.0f;
constexpr float STROKE_DETAIL_HYSTERESIS = 2.0f;
// Evaluations and ground queries a second in the Reduced tier.
constexpr float STROKE_REDUCED_RATE = 15.0f;
// Seconds to fade the stroke pose in or out at the Clip boundary.
constexpr float STROKE_DETAIL_BLEND = 0.25f;

// The tier for a body at a distance (nodes) from the camera, on screen or
// not, given the tier it had last step.
StrokeDetail chooseStrokeDetail(float distance, bool on_screen, StrokeDetail previous);

// Interpolates two evaluations of the same body bone by bone: positions
// linearly, rotations by slerp. `a` and `b` list the same bones in the same
// order (one evaluator's output); otherwise `out` is `b`.
void blendStrokePoses(const std::vector<StrokeBonePose> &a, const std::vector<StrokeBonePose> &b, float f,
        std::vector<StrokeBonePose> &out);

// One body's stroke and ground queries at its tier.
class StrokeLod {
public:
    // Once a step, before pose() and groundDue(): the tier for this step,
    // which moves the shown weight towards it. The first call takes the
    // tier's weight at once, so a body that appears far off does not fade.
    void step(float dt, StrokeDetail detail);
    StrokeDetail detail() const { return m_detail; }
    // How much of the stroke pose to show over the game's animation, 0 to
    // 1, eased; 0 means pose() need not be called.
    float weight() const;
    // The stroke pose at angle (degrees) and stroke time t (seconds), into
    // `out`: evaluated now in Full, interpolated in Reduced and while
    // fading out of Clip. restart is true for a new stroke, which drops
    // the evaluations kept for interpolation.
    void pose(const StrokeEvaluator &evaluator, float angle, float t, bool restart,
            std::vector<StrokeBonePose> &out);
    // Whether the feet should ask the map for the ground this step: every
    // step in Full, STROKE_REDUCED_RATE times a second in Reduced, never
    // in Clip.
    bool groundDue(float dt);
    // Evaluator calls this body has made, for tests.
    uint64_t evaluations() const { return m_evaluations; }

private:
    StrokeDetail m_detail = StrokeDetail::Full;
    bool m_started = false;
    float m_w = 1.0f; // linear; weight() eases it
    float m_ground_clock = 0.0f;
    // Reduced: the evaluations either side of now and their stroke times.
    bool m_have = false;
    float m_ta = 0.0f, m_tb = 0.0f;
    std::vector<StrokeBonePose> m_a, m_b;
    uint64_t m_evaluations = 0;
};

} // namespace goanna
