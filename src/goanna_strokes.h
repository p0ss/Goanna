// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Stroke family evaluator: poses a body for a melee stroke from its drag
// angle and stroke time, so a server need send only those two numbers.
// Ports tools/kindred_creatures/animation/melee_reference/strokes/evaluate.lua
// from DorfCraft (and the forward kinematics of its
// mods/kindred_creatures/kit/targeting.lua); the two must agree, which
// goanna_strokes_test checks against fixtures that Lua produced.
//
// A family is a set of whole-body strokes, one per drag angle, stored
// relative to the body. evaluate() blends the two strokes either side of
// the angle, then retargets onto this body: trunk rotations, the weapon and
// offhand limb chains solved to their grips (an exact hinge for two
// segments, FABRIK for more) with an elbow swivel chosen by a soft minimum
// over limb intrusion, blade clearance against the body's own boxes, and
// the legs planted at a stance. Purely cosmetic on the client: it uses only
// what the server sent and the model already loaded.
//
// Pure C++ with no Godot types. evaluate() is const and keeps no state
// between calls (its scratch is local to the call), so one evaluator may
// serve many animators, from any thread.
//
// Coordinates: the plan's model units (bone translations, binds, boxes,
// with `units` per node) in the model's own frame. Quaternions are
// {x, y, z, w}.

#include <array>
#include <memory>
#include <string>
#include <vector>

#include <json/json.h>

namespace goanna {

using StrokeVec = std::array<double, 3>;
using StrokeQuat = std::array<double, 4>; // x, y, z, w

// One sample of a stroke. Grips and wrists are in the chest's frame, grips
// as a fraction of the limb's reach from the shoulder; item and hand
// rotations are in the chest's frame, trunk rotations in the parent's.
struct StrokeSample {
    StrokeQuat blade, chest, hand, head, off, off_hand, pelvis;
    StrokeVec drop, grip, off_grip, off_wrist, wrist;
};

struct Stroke {
    double angle = 0; // degrees
    std::vector<StrokeSample> samples; // at family rate, from time 0
};

struct StrokeFamily {
    double rate = 30; // samples a second
    double reach_weapon = 1, reach_off = 1; // the authoring body's limb reach
    StrokeVec hilt{}, tip{}; // blade ends in the weapon item's frame
    // Timing, seconds, carried for callers (the evaluator does not use it).
    double length = 0, commit = 0, active_from = 0, active_to = 0;
    std::vector<Stroke> strokes; // sorted by angle
};

// False if the JSON does not parse or lacks a field the evaluator needs.
// The object is a glTF's root extras "stroke_family", or the same as text.
bool parseStrokeFamily(const Json::Value &json, StrokeFamily &out);
bool parseStrokeFamily(const std::string &json, StrokeFamily &out);

// What a client needs to evaluate strokes on one body.
struct StrokePlanBone {
    std::string name;
    std::string parent; // empty for a root
    StrokeVec translation{}; // from the parent, model units
    StrokeVec bind{}; // model space at rest
};

struct StrokePlanBox {
    std::string bone;
    std::string name;
    StrokeVec lo{}, hi{}; // model space at rest
};

struct StrokePlan {
    double units = 16; // model units a node
    std::vector<StrokePlanBone> bones; // parent first
    std::vector<StrokePlanBox> boxes;
};

bool parseStrokePlan(const Json::Value &json, StrokePlan &out);
bool parseStrokePlan(const std::string &json, StrokePlan &out);

// One bone's override, as Luanti takes it: position in nodes and rotation
// as Euler radians, both absolute, already in the convention the old pose
// stream used (z of the position negated, rotation {-x, -y, z}).
struct StrokeBonePose {
    std::string bone;
    float p[3];
    float r[3];
};

// The evaluator's tuning, the values evaluate.lua uses when its plan
// gives none.
constexpr double STROKE_MARGIN = 0.35; // blade clearance, model units
constexpr int STROKE_CLEARANCE_ITERATIONS = 40;
constexpr double STROKE_EXTENSION = 0.995; // furthest reach, of the limb's
constexpr double STROKE_POLE_OUT = 1.0;
constexpr int STROKE_FABRIK_ITERATIONS = 24;

class StrokeEvaluator {
public:
    StrokeEvaluator(const StrokePlan &plan, std::shared_ptr<const StrokeFamily> family);

    // False when the plan lacks a role bone (body, chest, arm_right,
    // arm_left, sword, offhand), an arm has no segment, or the family is
    // missing or empty. evaluate() then returns nothing.
    bool valid() const { return valid_; }
    // The family's stroke length (timing.length), seconds; 0 without one.
    float length() const { return family_ ? float(family_->length) : 0.0f; }

    // The pose at drag angle (degrees) and stroke time t (seconds), legs
    // planted: one entry for each bone the evaluator moves, in plan order.
    std::vector<StrokeBonePose> evaluate(float angle_deg, float t) const;
    // The same, filling `out` (resized) to save the allocation.
    void evaluate(float angle_deg, float t, std::vector<StrokeBonePose> &out) const;

private:
    struct Bone {
        std::string name;
        int parent = -1;
        StrokeVec translation{}, bind{};
    };
    struct Limb {
        std::vector<int> chain;
        std::vector<double> segments;
        std::vector<StrokeVec> rest;
        std::vector<char> own; // by bone index
        double reach = 0, sign = 1;
        int hand = -1, item = -1;
        StrokeVec bend{1, 0, 0};
        StrokeVec stance{}; // legs only, in hip heights
    };
    struct Obstacle {
        int bone = -1;
        StrokeVec lo{}, hi{}, centre{};
        double radius = 0;
    };
    struct Work;

    std::vector<int> chainOf(int first) const;
    Limb limb(const std::vector<int> &chain, double sign) const;
    void forward(Work &w) const;
    double worldBox(const Work &w, int box, const StrokeVec &p, double limit, StrokeVec *normal) const;
    bool solve(const Limb &arm, const StrokeVec &root, StrokeVec wrist, const StrokeVec &pole,
            std::vector<StrokeQuat> *worlds, std::vector<StrokeVec> &points) const;
    void locals(Work &w, const Limb &arm, const std::vector<StrokeQuat> &worlds) const;

    bool valid_ = false;
    std::shared_ptr<const StrokeFamily> family_;
    std::vector<Bone> bones_;
    std::vector<std::vector<int>> children_;
    double units_ = 16, hip_ = 0;
    int pelvis_ = -1, chest_ = -1, head_ = -1;
    Limb weapon_, off_;
    std::vector<Limb> legs_;
    std::vector<Obstacle> obstacles_;
};

} // namespace goanna
