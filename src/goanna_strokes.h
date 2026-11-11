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

// The server's action state rides on one bone override (the plan's
// "state"): its scale Z is the action's format plus 8 times the stroke
// family's index. Format 1 is a stroke, 2 a looping task, 3 a climb, 4 a
// flier in the air; the family (a weapon's strokes: 0 the one-handed
// sword, then the plan's "families" in order) applies to strokes only, so
// a sword stroke is Z 1 as before families existed. DorfCraft's
// strike.lua (M.stroke_format, M.decode_format) is the other side.
constexpr int STROKE_FAMILY_STEP = 8;
struct StrokeFormat {
    int format = 0; // 0 none or unknown
    int family = 0;
};
StrokeFormat decodeStrokeFormat(float z);

// Confirmed response phases: 4 hard recoil, 5 resisted follow-through.
// Mirrors DorfCraft response.lua. These times never authorise damage.
float strokeResponseTime(int phase, float contact, float age, float length);

// The own body's stroke shown ahead of the server, for a server-marked
// Kindred weapon (DorfCraft's docs/tasks/first-person-melee-combat.md,
// "Client prediction"). Presentation only: it sends nothing, and contact,
// damage, guard and recovery stay the server's.
//
// A press, when the server shows no stroke and nothing but air or a
// fighter is under the crosshair, draws at once, as the server's input
// machine will (DorfCraft's input.lua): the angle is the look's pull since
// LEAD seconds before the press, the draw grows over FULL_DRAW seconds. The
// release strikes at once from the drawn point (draw x commit) on the
// client's own clock. The server's answer is the first stroke state with
// an action serial other than the one the bone held at the press: from
// then its angle, phase and pitch are shown on the client's clock, which
// runs ahead by about the round trip, so the stroke is neither restarted
// nor rewound. Corrections replace the prediction at once: a confirmed
// recovery (format 5), a family other than the one predicted (a thrust),
// the answer cut short, or a phase 0 after the server had shown the draw
// (no stroke: a feint, exhaustion, a stagger). A newer serial while the
// stroke plays replaces the answer (the server missed an earlier hold, so
// its strokes answer later presses). A stroke the client has played
// through is not played again when a late answer arrives, and a press
// after it has run its length draws at once.
struct StrokeServerState {
    bool present = false; // a stroke state (format 1 or 5) on the bone
    int serial = 0, phase = 0, format = 0, family = 0;
    float told = 0, t = 0;
    float length = 0; // its family's stroke length, seconds; 0 unknown
    float pitch = 0; // its accepted weapon elevation, radians
};

struct StrokePreviewInput {
    float dt = 0; // the animator's step, which the shown clock keeps
    // The real time since the last step, which the renderer's dt may fall
    // short of (it caps a slow frame): the server's clock is real time.
    // Negative: the same as dt.
    float real_dt = -1;
    bool armed = false; // a server-marked Kindred weapon, alive
    bool open = false; // a press may draw: no node pointed
    bool digging = false; // the client is digging a node
    bool dig = false, place = false;
    int family = 0; // the marker's stroke family
    float commit = 0, length = 0; // that family's timing, seconds
    float yaw = 0, pitch = 0; // the look, radians
    StrokeServerState server;
};

struct StrokePreview {
    // input.lua's FULL_DRAW and LEAD, and its DEAD in radians.
    static constexpr float FULL_DRAW = 0.8f, LEAD = 0.15f, DEAD = 0.026179939f;
    // An unanswered stroke is let go this long after its release.
    static constexpr float ANSWER = 4.0f;
    // The serials the anticipated state carries, never the server's, so
    // the animator takes a draw, a strike and the server's own state as
    // three actions.
    static constexpr int DRAW_SERIAL = -1, STRIKE_SERIAL = -2;

    enum class Mode { Idle, Draw, Strike };
    Mode mode = Mode::Idle;
    bool previous_dig = false;
    float age = 0; // Draw: since the press; Strike: since the release
    float real_age = 0; // the same, in real time
    float start = 0; // the strike's clock at the release, seconds
    float angle = 0, yaw = 0, pitch = 0; // drawn angle (degrees), the look pulled from
    int family = 0;
    int press_serial = 0; // the server's serial on the bone at the press
    int answer = 0; // the server's serial for this stroke, once answered
    bool answered = false, saw_draw = false;
    // How long the bone has held the same state. Not its dtime_passed:
    // Luanti resends every override whenever any one is set, and each
    // resend starts that again.
    float held = 0;
    bool held_present = false;
    int held_serial = 0, held_phase = 0;
    float held_told = 0, held_t = 0;
    struct Look { float age, yaw, pitch; };
    std::vector<Look> looks; // the look over the last LEAD and a little

    // What to show in place of the server's state, when shown: the state
    // bone's fields as the server would set them.
    struct Out {
        bool shown = false;
        int serial = 0, phase = 0, family = 0;
        float angle = 0, t = 0, since = 0, pitch = 0;
    };
    Out step(const StrokePreviewInput &in);
    bool active() const { return mode != Mode::Idle; }
    // Why the last press did not draw, for tests: 0 it drew (or none yet),
    // 1 not armed, 2 a node under the crosshair, 3 guarding, 4 the
    // server's stroke still playing, 5 the server still drawing.
    int refused = 0;
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
    // When the stroke commits (timing.commit), seconds; 0 without one.
    float commit() const { return family_ ? float(family_->commit) : 0.0f; }

    // The pose at drag angle (degrees) and stroke time t (seconds), legs
    // planted: one entry for each bone the evaluator moves, in plan order.
    std::vector<StrokeBonePose> evaluate(float angle_deg, float t) const;
    // The same, filling `out` (resized) to save the allocation.
    void evaluate(float angle_deg, float t, std::vector<StrokeBonePose> &out, float pitch = 0.0f) const;

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
