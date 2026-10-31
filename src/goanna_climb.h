// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Climb planner: where the hands and feet of a planned body hold while it
// climbs a ladder or mantles onto a ledge, beside the step planner
// (goanna_steps.h), which keeps the feet on the ground. Presentation only:
// the server (or the local player's own physics) moves the body; this
// puts its limbs on what it is climbing as it goes.
//
// Nothing is sent for it. The client sees what it needs: a climbable node
// at the body, or the body rising with a walkable ledge ahead of it.
//
// Ladder: every limb holds a rung on the climbed face (rungs every
// RUNG nodes), and steps to a rung further along when it falls far enough
// behind where it would rest, hand over hand, a hand and the opposite foot
// together. Mantle: both hands go to the ledge's edge as the body starts
// to rise and push until the arms are straight; the leading foot comes up
// onto the ledge as soon as its hip can reach it, the other pushes from
// below until it cannot, then follows. The step planner takes the feet
// back where the climb left them.
//
// The legs own the pelvis: nothing here moves it. Pure C++ with no Godot
// types, like the step planner. Positions are Luanti world nodes (y up).

#include "goanna_steps.h"

#include <vector>

namespace goanna {

enum class ClimbMode { None, Ladder, Mantle };

struct ClimbLimb {
    float length = 0.8f; // root of the limb (hip or shoulder) to its end at full reach, nodes
    float end = 0.0f; // for a leg, its ankle above the sole; zero for an arm
    bool arm = false;
    int side = 1; // -1 left, 1 right
};

struct ClimbInput {
    float dt = 0.0f;
    StepVec root{}; // where the body stands, nodes
    float yaw = 0.0f; // the body's facing, as the step planner has it
    float vy = 0.0f; // the body's vertical speed, nodes a second
    bool grounded = true;
    bool striking = false; // a stroke is shown: no climb starts
    std::vector<StepVec> anchors; // each limb's hip or shoulder now
    // A climbable face at the body: a point on it and its outward normal
    // (towards the body, horizontal).
    bool ladder = false;
    StepVec face{};
    float face_nx = 0.0f, face_nz = 0.0f;
    // A ledge ahead: a point on its edge at the top, and the edge's outward
    // normal (from the ledge towards the body, horizontal).
    bool ledge = false;
    StepVec edge{};
    float edge_nx = 0.0f, edge_nz = 0.0f;
    // Where the step planner has each leg's sole now, in leg order, so a
    // mantle starts from the feet as they stand.
    std::vector<StepVec> soles;
};

struct ClimbContact {
    StepVec at{}; // the hand's wrist or the leg's sole, world
    float weight = 0.0f; // how much of the limb the climb poses, 0 to 1
    bool held = false; // on a hold (not swinging)
    float swing = 0.0f; // 0 to 1 through a move, 0 while held
};

struct ClimbStats {
    uint64_t ladder_frames = 0, mantle_frames = 0;
    uint64_t mantles = 0, ladders = 0; // climbs started
    uint64_t moves = 0; // limbs that left one hold for another
    uint64_t landed = 0; // mantles that ended on the ledge
    uint64_t abandoned = 0; // mantles that ended below it
    float most_stretch = 0.0f; // furthest a held limb was out of reach, nodes
};

constexpr float CLIMB_RUNG = 0.25f; // rung spacing, nodes
constexpr float CLIMB_REACH = 0.98f; // furthest a held limb may be, L
constexpr float CLIMB_LEDGE_LOW = 0.3f; // a ledge this far above the root, nodes
constexpr float CLIMB_LEDGE_HIGH = 1.6f; // up to this far
constexpr float CLIMB_RISE = 0.6f; // rising this fast starts a mantle, nodes/s
constexpr float CLIMB_MANTLE_MOST = 1.5f; // longest a mantle lasts, s
constexpr float CLIMB_HOLD_TOP = 0.25f; // hands stay this long on top, s

class ClimbPlanner {
public:
    explicit ClimbPlanner(std::vector<ClimbLimb> limbs);

    const std::vector<ClimbLimb> &limbs() const { return limbs_; }
    void reset();
    void step(const ClimbInput &in);

    ClimbMode mode() const { return mode_; }
    // The most any limb is posed by the climb: zero once it has let go.
    float weight() const;
    const std::vector<ClimbContact> &contacts() const { return contacts_; }
    const ClimbStats &stats() const { return stats_; }
    // True for the one step a climb ended in, with each leg's last sole in
    // contacts(): the step planner plants the feet from there.
    bool ended() const { return ended_; }

private:
    struct Move {
        StepVec from{}, to{}, arc{};
        float t = 0, time = 0;
        bool moving = false;
    };
    void start(ClimbMode mode, const ClimbInput &in);
    void stop(bool landed);
    void ladder(const ClimbInput &in);
    void mantle(const ClimbInput &in);
    void move(size_t i, const StepVec &to, float time, const StepVec &arc);
    void advance(size_t i, float dt);
    StepVec onFace(size_t i, const ClimbInput &in, float y) const;
    StepVec onLedge(size_t i, const ClimbInput &in, float inset) const;

    std::vector<ClimbLimb> limbs_;
    std::vector<ClimbContact> contacts_;
    std::vector<Move> moves_;
    std::vector<float> want_; // each contact's weight eases towards this
    ClimbMode mode_ = ClimbMode::None;
    float time_ = 0, top_time_ = 0, off_ = 0;
    float start_y_ = 0;
    StepVec edge_{};
    float enx_ = 0, enz_ = 0;
    StepVec face_{};
    float fnx_ = 0, fnz_ = 0;
    std::vector<int> stage_; // a mantle's legs: 0 pushing, 1 tucked, 2 on the ledge
    bool ended_ = false;
    int last_group_ = 1; // the ladder pair that moved last
    ClimbStats stats_;
};

} // namespace goanna
