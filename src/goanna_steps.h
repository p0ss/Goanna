// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Step planner: where each foot of a walking body stands, so feet are
// planted and re-planted instead of sliding with a baked walk clip. The
// design is in docs/systems/melee-strokes.md, "Planned steps".
//
// Each leg has a rest place: where its sole would be if the body stood
// still as it is now. A planted foot stays fixed in the world. It steps
// when it falls far enough behind its rest place (or strays from it, or
// can no longer be reached), never while a leg of another gait group is
// in the air, and lands where its rest place will be when it comes down,
// half a stride ahead. The body is lowered for the lower foot and for any
// foot it could not otherwise reach. Any number of legs: legs of one group
// step together, groups take turns.
//
// Pure C++ with no Godot types, so goanna_steps_test can drive it over
// scripted terrain. Positions are Luanti world nodes (y up); yaws are
// radians about y, in whatever sense the caller uses consistently.

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <vector>

namespace goanna {

using StepVec = std::array<float, 3>;

// The highest walkable surface under (x, z) between two heights, if any.
using StepFloor = std::function<std::optional<float>(float x, float z, float top, float bottom)>;

struct StepLeg {
    float length = 0.8f; // hip to ankle at full reach, nodes
    float ankle = 0.09f; // ankle above the sole, nodes
    int group = 0; // legs of one group step together; groups take turns
};

struct StepInput {
    float dt = 0.0f;
    StepVec root{}; // where the body stands: the model's origin, nodes
    float yaw = 0.0f; // the body's facing
    bool grounded = true;
    // A committed stroke: a foot steps only when it is well out of place
    // or cannot be reached, so the stroke does not shuffle the feet.
    bool hold = false;
    // A crouch the pose asks for (a stroke's pelvis drop), nodes, zero or
    // negative: honoured up to STEP_CROUCH_MOST, on top of the feet's own.
    float crouch = 0.0f;
    std::vector<StepVec> hips; // each hip now, before the body is lowered
    std::vector<StepVec> rest; // each sole's rest place now (y ignored)
    StepFloor floor;
};

struct StepFoot {
    StepVec sole{}; // where the sole is, world
    float yaw = 0.0f; // which way the foot points
    bool planted = true;
    bool supported = true; // false: no foothold found, the foot hangs
    float swing = 0.0f; // 0 to 1 through a step, 0 while planted
};

// Counts since construction or reset(), for tests and status.
struct StepStats {
    uint64_t frames = 0; // steps of the planner while grounded
    uint64_t steps = 0; // feet that lifted and landed
    uint64_t settles = 0; // of those, steps back to rest while standing
    uint64_t forced = 0; // lifts forced by reach or lost ground
    uint64_t rejected = 0; // landings where the first foothold was refused
    uint64_t unreachable = 0; // landings with no foothold at all
    uint64_t stretched = 0; // frames a planted foot was out of reach
    float most_stretch = 0.0f; // furthest out of reach, nodes
    uint64_t airborne = 0; // frames off the ground
};

// Tuning, in leg lengths (L) and seconds unless said otherwise.
constexpr float STEP_REACH = 0.97f; // furthest a planted foot may be, L
constexpr float STEP_DROP_MOST = 0.6f; // furthest the body is lowered, L
constexpr float STEP_UP = 0.6f; // highest foothold above the root, nodes
constexpr float STEP_DOWN = 0.8f; // lowest below it, nodes
constexpr float STEP_SETTLE = 0.06f; // stray to step back to rest, nodes
constexpr float STEP_SETTLE_AFTER = 0.15f; // still this long first
constexpr float STEP_TURN = 0.9f; // foot turned this far from the body, rad
constexpr float STEP_SWING_MIN = 0.14f; // shortest swing, s, for L = 0.8
constexpr float STEP_SWING_MAX = 0.36f; // longest
constexpr float STEP_HOLD = 2.0f; // stride threshold scale while holding
constexpr float STEP_HALF_STRIDE = 0.35f; // furthest ahead or behind rest, L
constexpr float STEP_CROUCH_MOST = 0.2f; // most crouch honoured, L
constexpr float STEP_TWIST_MOST = 0.5f; // most pelvis twist to the feet, rad

class StepPlanner {
public:
    explicit StepPlanner(std::vector<StepLeg> legs);

    const std::vector<StepLeg> &legs() const { return legs_; }
    // Forget where the feet are: the next step plants them at rest.
    void reset();
    void step(const StepInput &in);

    const std::vector<StepFoot> &feet() const { return feet_; }
    // How far the body is lowered now, nodes (zero or negative).
    float drop() const { return drop_; }
    // The pelvis's turn from the body's facing towards where the planted
    // feet point, eased and bounded by STEP_TWIST_MOST: the legs own the
    // pelvis, the chest keeps the look.
    float pelvisYaw() const { return pelvis_yaw_; }
    const StepStats &stats() const { return stats_; }

    // The gait for a foot whose rest place moves at `speed` nodes a
    // second: its stride (how far it travels a cycle), its swing time,
    // and how far behind rest it may fall before it steps, for a body
    // whose legs step in `groups` turns.
    struct Gait {
        float stride = 0, swing = 0, threshold = 0, cycle = 0;
    };
    static Gait gait(float length, float speed, int groups = 2);

private:
    struct Leg {
        StepFoot foot;
        StepVec from{}, to{}, last_rest{}, rest_vel{};
        float from_yaw = 0, to_yaw = 0;
        float t = 0, swing_time = 0;
        float planted_for = 0, still = 0;
        bool settle = false, rejected = false;
        bool have_rest = false;
    };
    struct Hold {
        StepVec sole{};
        bool supported = true, rejected = false;
    };

    Hold foothold(size_t i, float x, float z, const StepInput &in) const;
    void lift(size_t i, const StepInput &in, bool settle, bool forced);
    void target(size_t i, const StepInput &in);
    void swing(size_t i, const StepInput &in);
    void plantAll(const StepInput &in, bool at_rest);
    void settleBody(const StepInput &in, bool at_once);

    std::vector<StepLeg> legs_;
    std::vector<Leg> state_;
    std::vector<StepFoot> feet_;
    int groups_ = 1;
    bool have_ = false, airborne_ = false;
    StepVec last_root_{};
    float last_yaw_ = 0, yaw_rate_ = 0;
    float drop_ = 0, soft_drop_ = 0, pelvis_yaw_ = 0, hurry_ = 1;
    StepStats stats_;
};

} // namespace goanna
