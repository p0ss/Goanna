// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Ports DorfCraft's tools/kindred_creatures/animation/melee_reference/strokes/evaluate.lua.
// The structure follows the Lua closely, step for step, so that a change
// there can be carried here by reading the two side by side. Doubles
// throughout, as Lua's numbers are.

#include "goanna_strokes.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>

#include <json/json.h>

namespace goanna {

namespace {

using V = StrokeVec;
using Q = StrokeQuat;

constexpr double PI = 3.14159265358979323846;

inline V add(const V &a, const V &b) { return {a[0] + b[0], a[1] + b[1], a[2] + b[2]}; }
inline V sub(const V &a, const V &b) { return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}; }
inline V mul(const V &a, double s) { return {a[0] * s, a[1] * s, a[2] * s}; }
inline double dot(const V &a, const V &b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline V cross(const V &a, const V &b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline double norm(const V &a) { return std::sqrt(dot(a, a)); }
inline V unit(const V &a) {
    double n = norm(a);
    if (n < 1e-9)
        return {0, 0, 0};
    return mul(a, 1 / n);
}
inline V lerp(const V &a, const V &b, double t) { return add(a, mul(sub(b, a), t)); }
inline double clamp(double x, double a, double b) { return std::max(a, std::min(b, x)); }

// targeting.lua's rotate, inverse and product.
inline V rotate(const Q &q, const V &v) {
    double x = q[0], y = q[1], z = q[2], w = q[3];
    double tx = 2 * (y * v[2] - z * v[1]), ty = 2 * (z * v[0] - x * v[2]), tz = 2 * (x * v[1] - y * v[0]);
    return {v[0] + w * tx + y * tz - z * ty, v[1] + w * ty + z * tx - x * tz, v[2] + w * tz + x * ty - y * tx};
}
inline Q inverse(const Q &q) { return {-q[0], -q[1], -q[2], q[3]}; }
inline Q product(const Q &a, const Q &b) {
    double x = a[0], y = a[1], z = a[2], w = a[3];
    double X = b[0], Y = b[1], Z = b[2], W = b[3];
    return {w * X + x * W + y * Z - z * Y, w * Y - x * Z + y * W + z * X, w * Z + x * Y - y * X + z * W,
            w * W - x * X - y * Y - z * Z};
}
inline double qdot(const Q &a, const Q &b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]; }

Q slerp(const Q &a, const Q &b, double t) {
    double d = qdot(a, b);
    double s = d < 0 ? -1 : 1;
    d = std::min(1.0, std::fabs(d));
    double x = 1 - t, y = t;
    if (d < .9995) {
        double w = std::acos(d);
        double n = std::sin(w);
        x = std::sin((1 - t) * w) / n;
        y = std::sin(t * w) / n;
    }
    Q q;
    double n = 0;
    for (int i = 0; i < 4; ++i) {
        q[i] = a[i] * x + b[i] * s * y;
        n += q[i] * q[i];
    }
    n = std::sqrt(n);
    for (int i = 0; i < 4; ++i)
        q[i] /= n;
    return q;
}

inline Q axisAngle(const V &a, double w) {
    double s = std::sin(w / 2);
    return {a[0] * s, a[1] * s, a[2] * s, std::cos(w / 2)};
}

// Shortest rotation taking direction a onto direction b.
Q align(V a, V b) {
    a = unit(a);
    b = unit(b);
    V c = cross(a, b);
    double d = dot(a, b);
    if (d < -.99999) {
        V o = std::fabs(a[0]) < .9 ? V{1, 0, 0} : V{0, 1, 0};
        return axisAngle(unit(cross(a, o)), PI);
    }
    Q q{c[0], c[1], c[2], 1 + d};
    double n = std::sqrt(dot(c, c) + q[3] * q[3]);
    for (int i = 0; i < 4; ++i)
        q[i] /= n;
    return q;
}

// Inverse of R = Rz Ry Rx.
V euler(const Q &q) {
    double x = q[0], y = q[1], z = q[2], w = q[3];
    return {std::atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)), std::asin(clamp(2 * (w * y - z * x), -1, 1)),
            std::atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))};
}

// Lua's % on numbers: the result takes the divisor's sign.
inline double luaMod(double a, double b) { return a - std::floor(a / b) * b; }

StrokeSample sampleLerp(const StrokeSample &x, const StrokeSample &y, double a) {
    StrokeSample o;
    o.blade = slerp(x.blade, y.blade, a);
    o.chest = slerp(x.chest, y.chest, a);
    o.hand = slerp(x.hand, y.hand, a);
    o.head = slerp(x.head, y.head, a);
    o.off = slerp(x.off, y.off, a);
    o.off_hand = slerp(x.off_hand, y.off_hand, a);
    o.pelvis = slerp(x.pelvis, y.pelvis, a);
    o.drop = lerp(x.drop, y.drop, a);
    o.grip = lerp(x.grip, y.grip, a);
    o.off_grip = lerp(x.off_grip, y.off_grip, a);
    o.off_wrist = lerp(x.off_wrist, y.off_wrist, a);
    o.wrist = lerp(x.wrist, y.wrist, a);
    return o;
}

// One stroke's channels at time t: linear between samples, slerp rotations.
StrokeSample at(const Stroke &stroke, double rate, double t) {
    const std::vector<StrokeSample> &s = stroke.samples;
    double f = clamp(t * rate, 0, double(s.size() - 1));
    size_t i = size_t(std::floor(f));
    size_t j = std::min(s.size() - 1, i + 1);
    return sampleLerp(s[i], s[j], f - double(i));
}

// Neighbouring strokes far apart in rotation have no meaningful midpoint:
// past 90 degrees the weight sharpens towards the nearer stroke, becoming a
// step at 180 (just off the exact midpoint).
Q blendRotation(const Q &v, const Q &y, double w) {
    double d = std::fabs(qdot(v, y));
    double sep = 2 * std::acos(std::min(1.0, d)) * 180 / PI;
    double sharp = clamp((sep - 90) / 90, 0, 1);
    double x2 = w - .5 - 1e-3;
    double w2 = sharp > 0 ? .5 + .5 * (x2 < 0 ? -1 : 1) * std::pow(std::fabs(2 * x2), 1 - sharp * .999) : w;
    return slerp(v, y, clamp(w2, 0, 1));
}

bool readVec(const Json::Value &v, V &out) {
    if (!v.isArray() || v.size() != 3)
        return false;
    for (Json::ArrayIndex i = 0; i < 3; ++i) {
        if (!v[i].isNumeric())
            return false;
        out[i] = v[i].asDouble();
    }
    return true;
}

bool readQuat(const Json::Value &v, Q &out) {
    if (!v.isArray() || v.size() != 4)
        return false;
    for (Json::ArrayIndex i = 0; i < 4; ++i) {
        if (!v[i].isNumeric())
            return false;
        out[i] = v[i].asDouble();
    }
    return true;
}

bool parseJson(const std::string &text, Json::Value &root) {
    Json::CharReaderBuilder builder;
    std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
    std::string errors;
    return reader->parse(text.data(), text.data() + text.size(), &root, &errors);
}

} // namespace

bool parseStrokeFamily(const std::string &json, StrokeFamily &out) {
    Json::Value root;
    return parseJson(json, root) && parseStrokeFamily(root, out);
}

bool parseStrokeFamily(const Json::Value &root, StrokeFamily &out) {
    if (!root.isObject())
        return false;
    StrokeFamily f;
    const Json::Value &rate = root["rate"];
    const Json::Value &reach = root["reach"];
    const Json::Value &weapon = root["weapon"];
    if (!rate.isNumeric() || rate.asDouble() <= 0 || !reach.isObject() || !weapon.isObject())
        return false;
    f.rate = rate.asDouble();
    if (!reach["weapon"].isNumeric() || !reach["off"].isNumeric())
        return false;
    f.reach_weapon = reach["weapon"].asDouble();
    f.reach_off = reach["off"].asDouble();
    if (f.reach_weapon <= 0 || f.reach_off <= 0)
        return false;
    if (!readVec(weapon["hilt"], f.hilt) || !readVec(weapon["tip"], f.tip))
        return false;
    const Json::Value &timing = root["timing"];
    if (timing.isObject()) {
        f.length = timing.get("length", 0).asDouble();
        f.commit = timing.get("commit", 0).asDouble();
        const Json::Value &active = timing["active"];
        if (active.isArray() && active.size() == 2) {
            f.active_from = active[0].asDouble();
            f.active_to = active[1].asDouble();
        }
    }
    const Json::Value &strokes = root["strokes"];
    if (!strokes.isArray() || strokes.empty())
        return false;
    for (const Json::Value &s : strokes) {
        Stroke stroke;
        if (!s["angle"].isNumeric())
            return false;
        stroke.angle = s["angle"].asDouble();
        const Json::Value &samples = s["samples"];
        if (!samples.isArray() || samples.empty())
            return false;
        for (const Json::Value &x : samples) {
            StrokeSample o;
            if (!readQuat(x["blade"], o.blade) || !readQuat(x["chest"], o.chest) || !readQuat(x["hand"], o.hand) ||
                    !readQuat(x["head"], o.head) || !readQuat(x["off"], o.off) ||
                    !readQuat(x["off_hand"], o.off_hand) || !readQuat(x["pelvis"], o.pelvis) ||
                    !readVec(x["drop"], o.drop) || !readVec(x["grip"], o.grip) ||
                    !readVec(x["off_grip"], o.off_grip) || !readVec(x["off_wrist"], o.off_wrist) ||
                    !readVec(x["wrist"], o.wrist))
                return false;
            stroke.samples.push_back(o);
        }
        f.strokes.push_back(std::move(stroke));
    }
    std::stable_sort(f.strokes.begin(), f.strokes.end(),
            [](const Stroke &a, const Stroke &b) { return a.angle < b.angle; });
    out = std::move(f);
    return true;
}

bool parseStrokePlan(const Json::Value &root, StrokePlan &out) {
    if (!root.isObject())
        return false;
    StrokePlan plan;
    const Json::Value &units = root["units"];
    if (!units.isNumeric() || units.asDouble() <= 0)
        return false;
    plan.units = units.asDouble();
    const Json::Value &bones = root["bones"];
    if (!bones.isArray())
        return false;
    for (const Json::Value &b : bones) {
        StrokePlanBone bone;
        if (!b["name"].isString() || !readVec(b["translation"], bone.translation) || !readVec(b["bind"], bone.bind))
            return false;
        bone.name = b["name"].asString();
        if (b["parent"].isString())
            bone.parent = b["parent"].asString();
        plan.bones.push_back(std::move(bone));
    }
    const Json::Value &boxes = root["boxes"];
    if (boxes.isArray()) {
        for (const Json::Value &b : boxes) {
            StrokePlanBox box;
            if (!b["bone"].isString() || !readVec(b["lo"], box.lo) || !readVec(b["hi"], box.hi))
                return false;
            box.bone = b["bone"].asString();
            if (b["name"].isString())
                box.name = b["name"].asString();
            plan.boxes.push_back(std::move(box));
        }
    }
    out = std::move(plan);
    return true;
}

bool parseStrokePlan(const std::string &json, StrokePlan &out) {
    Json::Value root;
    return parseJson(json, root) && parseStrokePlan(root, out);
}

// Per evaluation state: the layer being built and the pose it gives.
struct StrokeEvaluator::Work {
    struct Entry {
        bool present = false, has_q = false, has_p = false;
        Q q{0, 0, 0, 1};
        V p{0, 0, 0};
    };
    struct Posed {
        V p;
        Q q;
    };
    std::vector<Entry> layer;
    std::vector<Posed> pose;
    std::vector<V> centres; // each obstacle's posed centre
    V escape{0, 0, -1}; // the chest's forward direction
    // Scratch for the limb solver.
    std::vector<V> points;
    std::vector<Q> worlds;
};

std::vector<int> StrokeEvaluator::chainOf(int first) const {
    // A limb chain: from its root bone, follow the single child to the end.
    std::vector<int> c{first};
    while (children_[c.back()].size() == 1 && c.size() <= bones_.size())
        c.push_back(children_[c.back()][0]);
    return c;
}

StrokeEvaluator::Limb StrokeEvaluator::limb(const std::vector<int> &chain, double sign) const {
    Limb l;
    l.chain = chain;
    l.sign = sign;
    l.hand = chain.back();
    // Every bone but the last spans to the next pivot; the last is the hand.
    for (size_t i = 0; i + 1 < chain.size(); ++i) {
        V span = sub(bones_[chain[i + 1]].bind, bones_[chain[i]].bind);
        double s = norm(span);
        l.segments.push_back(s);
        l.reach += s;
        l.rest.push_back(unit(span));
    }
    l.own.assign(bones_.size(), 0);
    for (int n : chain)
        l.own[n] = 1;
    return l;
}

StrokeEvaluator::StrokeEvaluator(const StrokePlan &plan, std::shared_ptr<const StrokeFamily> family) :
        family_(std::move(family)) {
    units_ = plan.units;
    std::map<std::string, int> index;
    for (const StrokePlanBone &b : plan.bones) {
        if (index.count(b.name))
            return;
        Bone bone;
        bone.name = b.name;
        bone.translation = b.translation;
        bone.bind = b.bind;
        if (!b.parent.empty()) {
            auto it = index.find(b.parent);
            // Parents must come first, as the forward pass needs them.
            if (it == index.end())
                return;
            bone.parent = it->second;
        }
        index[b.name] = int(bones_.size());
        bones_.push_back(std::move(bone));
    }
    auto find = [&](const char *name) {
        auto it = index.find(name);
        return it == index.end() ? -1 : it->second;
    };
    children_.assign(bones_.size(), {});
    for (size_t i = 0; i < bones_.size(); ++i)
        if (bones_[i].parent >= 0)
            children_[bones_[i].parent].push_back(int(i));

    pelvis_ = find("body");
    chest_ = find("chest");
    head_ = find("head");
    int weapon_arm = find("arm_right"), off_arm = find("arm_left");
    int weapon_item = find("sword"), off_item = find("offhand");
    if (!family_ || family_->strokes.empty() || pelvis_ < 0 || chest_ < 0 || weapon_arm < 0 || off_arm < 0 ||
            weapon_item < 0 || off_item < 0 || units_ <= 0)
        return;
    for (const Stroke &s : family_->strokes)
        if (s.samples.empty())
            return;
    weapon_ = limb(chainOf(weapon_arm), 1);
    weapon_.item = weapon_item;
    off_ = limb(chainOf(off_arm), -1);
    off_.item = off_item;
    if (weapon_.segments.empty() || off_.segments.empty() || weapon_.reach <= 0 || off_.reach <= 0)
        return;
    hip_ = bones_[pelvis_].bind[1];

    // Legs: chains from the pelvis whose names start with "leg", planted
    // at their rest footprint plus a stance offset in hip heights.
    for (size_t i = 0; i < bones_.size(); ++i) {
        if (bones_[i].name.compare(0, 3, "leg") == 0 && bones_[i].parent == pelvis_) {
            Limb l = limb(chainOf(int(i)), 1);
            l.bend = {-1, 0, 0};
            if (bones_[i].name == "leg_left")
                l.stance = {-.1, 0, -.2};
            else if (bones_[i].name == "leg_right")
                l.stance = {.1, 0, .2};
            legs_.push_back(std::move(l));
        }
    }

    // Boxes the blade must keep clear of: everything but the weapon limb,
    // the weapon itself, the offhand limb's own segments and declared free
    // cosmetic parts. Hair is soft cover, not a surface. One box per bone,
    // the union of its boxes: pushing out of stacked boxes one at a time
    // can oscillate between them.
    std::vector<char> skip(bones_.size(), 0);
    skip[weapon_.item] = 1;
    for (int n : weapon_.chain)
        skip[n] = 1;
    for (int n : off_.chain)
        skip[n] = 1;
    for (const char *name : {"hair_free", "hair_tip"}) {
        int n = find(name);
        if (n >= 0)
            skip[n] = 1;
    }
    std::vector<int> unionOf(bones_.size(), -1);
    for (const StrokePlanBox &b : plan.boxes) {
        int bone = find(b.bone.c_str());
        if (bone < 0 || skip[bone] || b.name.compare(0, 4, "hair") == 0)
            continue;
        int o = unionOf[bone];
        if (o < 0) {
            unionOf[bone] = int(obstacles_.size());
            Obstacle ob;
            ob.bone = bone;
            ob.lo = b.lo;
            ob.hi = b.hi;
            obstacles_.push_back(ob);
        } else {
            for (int i = 0; i < 3; ++i) {
                obstacles_[o].lo[i] = std::min(obstacles_[o].lo[i], b.lo[i]);
                obstacles_[o].hi[i] = std::max(obstacles_[o].hi[i], b.hi[i]);
            }
        }
    }
    // Broad phase: each obstacle's centre and bounding radius; a point
    // further than radius + limit from the posed centre cannot be within
    // limit.
    for (Obstacle &o : obstacles_) {
        double r = 0;
        for (int i = 0; i < 3; ++i) {
            o.centre[i] = (o.lo[i] + o.hi[i]) / 2 - bones_[o.bone].bind[i];
            r += ((o.hi[i] - o.lo[i]) / 2) * ((o.hi[i] - o.lo[i]) / 2);
        }
        o.radius = std::sqrt(r);
    }
    valid_ = true;
}

// targeting.lua's T.pose with one computed layer: local pose from the bone
// translations, layer entries replacing q and p, composed parent first.
void StrokeEvaluator::forward(Work &w) const {
    for (size_t i = 0; i < bones_.size(); ++i) {
        const Work::Entry &e = w.layer[i];
        V lp = e.has_p ? e.p : bones_[i].translation;
        Q lq = e.has_q ? e.q : Q{0, 0, 0, 1};
        int parent = bones_[i].parent;
        if (parent >= 0) {
            const Work::Posed &pp = w.pose[parent];
            w.pose[i].p = add(pp.p, rotate(pp.q, lp));
            w.pose[i].q = product(pp.q, lq);
        } else {
            w.pose[i].p = lp;
            w.pose[i].q = lq;
        }
    }
    for (size_t k = 0; k < obstacles_.size(); ++k) {
        const Work::Posed &b = w.pose[obstacles_[k].bone];
        w.centres[k] = add(b.p, rotate(b.q, obstacles_[k].centre));
    }
}

// Distance from p to an obstacle (negative inside, by the shallowest
// face), with the outward normal. Past radius + limit from its centre,
// HUGE_VAL and no normal.
double StrokeEvaluator::worldBox(const Work &w, int k, const V &p, double limit, V *normal) const {
    const Obstacle &box = obstacles_[k];
    const Work::Posed &b = w.pose[box.bone];
    const V &c0 = w.centres[k];
    double dx = p[0] - c0[0], dy = p[1] - c0[1], dz = p[2] - c0[2];
    double reach = box.radius + limit;
    if (dx * dx + dy * dy + dz * dz > reach * reach)
        return HUGE_VAL;
    V l = add(rotate(inverse(b.q), sub(p, b.p)), bones_[box.bone].bind);
    V c;
    bool inside = true;
    double best = HUGE_VAL;
    for (int i = 0; i < 3; ++i) {
        c[i] = clamp(l[i], box.lo[i], box.hi[i]);
        if (l[i] <= box.lo[i] || l[i] >= box.hi[i])
            inside = false;
        double d = std::min(l[i] - box.lo[i], box.hi[i] - l[i]);
        if (d < best)
            best = d;
    }
    if (inside) {
        // Outward from the box centre, by fraction of each half extent (a
        // nearest-face normal flips between neighbouring parts), biased to
        // the front of the chest, which is always a way out.
        if (normal) {
            V n;
            for (int i = 0; i < 3; ++i) {
                double half = (box.hi[i] - box.lo[i]) / 2;
                n[i] = (l[i] - (box.lo[i] + box.hi[i]) / 2) / std::max(half, .1);
            }
            V out = rotate(b.q, unit(n));
            *normal = unit(add(out, mul(w.escape, 1.5)));
        }
        return -best;
    }
    V d = sub(l, c);
    double dist = norm(d);
    if (normal)
        *normal = rotate(b.q, mul(d, 1 / std::max(dist, 1e-9)));
    return dist;
}

// Solve a limb chain from its posed root to a wrist target. Two segments:
// an exact hinge towards the pole. More: FABRIK from an arc bent towards
// the pole. Rotations keep each bone's bend axis on the chain's bend
// plane. Fills `points` (the pivots, root first) and, when given, the
// world rotation of each bone but the hand; true if the target had to be
// pulled in to stay attached.
bool StrokeEvaluator::solve(const Limb &arm, const V &root, V wrist, const V &pole, std::vector<Q> *worlds,
        std::vector<V> &points) const {
    size_t n = arm.segments.size();
    double reach = arm.reach * STROKE_EXTENSION;
    V delta = sub(wrist, root);
    double d = norm(delta);
    bool pulled = false;
    if (d > reach) {
        wrist = add(root, mul(delta, reach / d));
        delta = sub(wrist, root);
        d = reach;
        pulled = true;
    }
    d = std::max(d, 1e-6);
    V v = mul(delta, 1 / d);
    V p = unit(sub(pole, mul(v, dot(pole, v))));
    points.resize(n + 1);
    points[0] = root;
    if (n == 2) {
        double l1 = arm.segments[0], l2 = arm.segments[1];
        d = std::max(d, std::fabs(l1 - l2) + 1e-4);
        double a = (l1 * l1 - l2 * l2 + d * d) / (2 * d);
        double h = std::sqrt(std::max(0.0, l1 * l1 - a * a));
        points[1] = add(root, add(mul(v, a), mul(p, h)));
        points[2] = add(root, mul(v, d));
    } else if (n > 0) {
        double bow = std::sqrt(std::max(0.0, arm.reach * arm.reach - d * d)) * .25;
        double run = 0;
        for (size_t i = 0; i < n; ++i) {
            run += arm.segments[i];
            double s = arm.reach > 0 ? run / arm.reach : 0;
            points[i + 1] = add(root, add(mul(v, d * s), mul(p, bow * std::sin(PI * s))));
        }
        for (int k = 0; k < STROKE_FABRIK_ITERATIONS; ++k) {
            points[n] = wrist;
            for (size_t i = n; i-- > 0;)
                points[i] = add(points[i + 1], mul(unit(sub(points[i], points[i + 1])), arm.segments[i]));
            points[0] = root;
            for (size_t i = 0; i < n; ++i)
                points[i + 1] = add(points[i], mul(unit(sub(points[i + 1], points[i])), arm.segments[i]));
        }
    }
    if (worlds) {
        worlds->resize(n + 1);
        V normal = unit(cross(p, v));
        for (size_t i = 0; i < n; ++i) {
            V dir = unit(sub(points[i + 1], points[i]));
            Q q = align(arm.rest[i], dir);
            V b = rotate(q, arm.bend);
            V want = unit(sub(normal, mul(dir, dot(normal, dir))));
            b = unit(sub(b, mul(dir, dot(b, dir))));
            double twist = std::atan2(dot(cross(b, want), dir), dot(b, want));
            (*worlds)[i] = product(axisAngle(dir, twist), q);
        }
    }
    return pulled;
}

// World rotations of a chain (hand included) into the layer as local ones.
void StrokeEvaluator::locals(Work &w, const Limb &arm, const std::vector<Q> &worlds) const {
    for (size_t i = 0; i < arm.chain.size(); ++i) {
        int name = arm.chain[i];
        int parent = bones_[name].parent;
        Work::Entry &e = w.layer[name];
        e.present = true;
        e.has_q = true;
        if (i > 0)
            e.q = product(inverse(worlds[i - 1]), worlds[i]);
        else if (parent >= 0)
            e.q = product(inverse(w.pose[parent].q), worlds[i]);
        else
            e.q = worlds[i];
    }
}

std::vector<StrokeBonePose> StrokeEvaluator::evaluate(float angle_deg, float t) const {
    std::vector<StrokeBonePose> out;
    evaluate(angle_deg, t, out);
    return out;
}

void StrokeEvaluator::evaluate(float angle_deg, float t_f, std::vector<StrokeBonePose> &result) const {
    result.clear();
    if (!valid_)
        return;
    const StrokeFamily &family = *family_;
    const double angle_in = angle_deg, t = t_f;

    // The two neighbouring strokes and the weight between them.
    const std::vector<Stroke> &strokes = family.strokes;
    const Stroke *sa = &strokes[0], *sb = &strokes[0];
    double weight = 0;
    {
        double angle = luaMod(angle_in, 360);
        for (size_t i = 0; i < strokes.size(); ++i) {
            const Stroke &a = strokes[i], &b = strokes[(i + 1) % strokes.size()];
            double span = luaMod(b.angle - a.angle, 360);
            if (span == 0)
                span = 360;
            double d = luaMod(angle - a.angle, 360);
            if (d < span) {
                sa = &a;
                sb = &b;
                weight = d / span;
                break;
            }
        }
    }
    StrokeSample s;
    {
        StrokeSample x = at(*sa, family.rate, t), y = at(*sb, family.rate, t);
        s.blade = blendRotation(x.blade, y.blade, weight);
        s.chest = blendRotation(x.chest, y.chest, weight);
        s.hand = blendRotation(x.hand, y.hand, weight);
        s.head = blendRotation(x.head, y.head, weight);
        s.off = blendRotation(x.off, y.off, weight);
        s.off_hand = blendRotation(x.off_hand, y.off_hand, weight);
        s.pelvis = blendRotation(x.pelvis, y.pelvis, weight);
        s.drop = lerp(x.drop, y.drop, weight);
        s.grip = lerp(x.grip, y.grip, weight);
        s.off_grip = lerp(x.off_grip, y.off_grip, weight);
        s.off_wrist = lerp(x.off_wrist, y.off_wrist, weight);
        s.wrist = lerp(x.wrist, y.wrist, weight);
    }

    Work w;
    w.layer.resize(bones_.size());
    w.pose.resize(bones_.size());
    w.centres.resize(obstacles_.size());
    w.points.reserve(16);
    w.worlds.reserve(16);

    auto setQ = [&](int bone, const Q &q) {
        Work::Entry &e = w.layer[bone];
        e.present = e.has_q = true;
        e.q = q;
    };
    {
        Work::Entry &e = w.layer[pelvis_];
        e.present = e.has_p = true;
        e.p = add(bones_[pelvis_].translation, mul(s.drop, hip_));
    }
    setQ(pelvis_, s.pelvis);
    setQ(chest_, s.chest);
    if (head_ >= 0)
        setQ(head_, s.head);
    forward(w);
    const Q chest = w.pose[chest_].q;
    w.escape = rotate(chest, {0, 0, -1});

    // Item placements from the family, scaled by this limb's reach.
    struct Item {
        V grip, wrist, root;
        Q q, hand;
    };
    auto place = [&](const Limb &arm, const V &grip_n, const Q &item_q, const V &wrist_b, const Q &hand_b) {
        Item it;
        it.root = w.pose[arm.chain[0]].p;
        it.grip = add(it.root, rotate(chest, mul(grip_n, arm.reach)));
        it.q = product(chest, item_q);
        it.wrist = wrist_b;
        it.hand = hand_b;
        return it;
    };
    Item wi = place(weapon_, s.grip, s.blade, s.wrist, s.hand);
    Item oi = place(off_, s.off_grip, s.off, s.off_wrist, s.off_hand);
    const double scale_weapon = weapon_.reach / family.reach_weapon;
    const double scale_off = off_.reach / family.reach_off;

    static const int SWIVELS[] = {-120, -100, -80, -60, -40, -20, 0, 20, 40, 60, 80, 100, 120};
    auto attach = [&](const Limb &arm, Item &it, double scale) {
        // Wrist from the item: the hand's offset scales with the limb.
        V wrist = add(it.grip, rotate(it.q, mul(it.wrist, scale)));
        V pole = rotate(chest, {arm.sign * STROKE_POLE_OUT, -1, .6});
        // Elbow swivel about the shoulder to wrist line: a soft minimum
        // over candidate turns, weighing limb intrusion into the body
        // against the size of the turn, so the elbow stays continuous.
        V axis = unit(sub(wrist, it.root));
        double total = 0, sum = 0;
        for (int deg : SWIVELS) {
            solve(arm, it.root, wrist, rotate(axisAngle(axis, deg * PI / 180), pole), nullptr, w.points);
            double depth = 0;
            for (size_t i = 0; i + 1 < w.points.size(); ++i) {
                for (int k = (i == 0 ? 2 : 0); k <= 4; ++k) {
                    V x = lerp(w.points[i], w.points[i + 1], k / 4.0);
                    for (size_t b = 0; b < obstacles_.size(); ++b) {
                        int bone = obstacles_[b].bone;
                        if (bone == arm.item || arm.own[bone])
                            continue;
                        double d = worldBox(w, int(b), x, 0, nullptr);
                        if (d < 0)
                            depth = std::max(depth, -d);
                    }
                }
            }
            double wt = std::exp(-(depth / .25) - (std::fabs(double(deg)) / 45) * (std::fabs(double(deg)) / 45));
            total += wt;
            sum += wt * deg;
        }
        double chosen = total > 1e-12 ? sum / total : 0;
        bool pulled =
                solve(arm, it.root, wrist, rotate(axisAngle(axis, chosen * PI / 180), pole), &w.worlds, w.points);
        w.worlds.back() = product(it.q, it.hand);
        if (pulled) {
            // Keep the item in the hand: move the grip with the clamped wrist.
            it.grip = sub(w.points.back(), rotate(it.q, mul(it.wrist, scale)));
        }
        locals(w, arm, w.worlds);
        // The item against its parent as posed before this limb moved, as
        // the Lua does.
        int parent = bones_[arm.item].parent;
        Q pq = parent >= 0 ? w.pose[parent].q : Q{0, 0, 0, 1};
        V pp = parent >= 0 ? w.pose[parent].p : V{0, 0, 0};
        Work::Entry &e = w.layer[arm.item];
        e.present = e.has_q = e.has_p = true;
        e.q = product(inverse(pq), it.q);
        e.p = rotate(inverse(pq), sub(it.grip, pp));
    };
    attach(off_, oi, scale_off);
    forward(w);

    // Clearance, as a relaxation: every intruding point of the hand and
    // blade pushes along its outward normal by its depth. Pushes near the
    // hand move the grip; pushes along the blade turn it about the grip.
    const V &hilt = family.hilt, &tip = family.tip;
    const V wrist_b = mul(wi.wrist, scale_weapon);
    const double blade_len = norm(sub(tip, hilt)) + norm(hilt);
    for (int iter = 0; iter < STROKE_CLEARANCE_ITERATIONS; ++iter) {
        V h = add(wi.grip, rotate(wi.q, hilt)), tp = add(wi.grip, rotate(wi.q, tip));
        V wr = add(wi.grip, rotate(wi.q, wrist_b));
        V move{0, 0, 0}, torque{0, 0, 0};
        double worst = 0;
        V pts[11];
        double along[11];
        pts[0] = wr;
        along[0] = 0;
        pts[1] = wi.grip;
        along[1] = 0;
        V hg = sub(h, wi.grip), tg = sub(tp, wi.grip);
        for (int i = 0; i <= 8; ++i) {
            pts[2 + i] = lerp(h, tp, i / 8.0);
            along[2 + i] = norm(lerp(hg, tg, i / 8.0));
        }
        for (int k = 0; k < 11; ++k) {
            for (size_t b = 0; b < obstacles_.size(); ++b) {
                V n;
                double d = worldBox(w, int(b), pts[k], STROKE_MARGIN, &n);
                double pen = STROKE_MARGIN - d;
                if (pen > 0) {
                    worst = std::max(worst, pen);
                    double share = clamp(along[k] / blade_len * 1.5, 0, 1);
                    V f = mul(n, pen + .03);
                    move = add(move, mul(f, 1 - share));
                    if (share > 0) {
                        double m = std::max(along[k], 1.0);
                        torque = add(torque, mul(cross(sub(pts[k], wi.grip), f), share / (m * m)));
                    }
                }
            }
        }
        if (worst <= 0)
            break;
        wi.grip = add(wi.grip, mul(move, .5));
        double turn = norm(torque) * .5;
        if (turn > 1e-6)
            wi.q = product(axisAngle(mul(torque, 1 / norm(torque)), std::min(turn, .3)), wi.q);
    }
    attach(weapon_, wi, scale_weapon);

    // Legs planted at their rest footprint plus the stance offset.
    forward(w);
    for (const Limb &l : legs_) {
        V target = add(bones_[l.hand].bind, mul(l.stance, hip_));
        solve(l, w.pose[l.chain[0]].p, target, {0, 0, -1}, &w.worlds, w.points);
        w.worlds.back() = {0, 0, 0, 1};
        locals(w, l, w.worlds);
    }

    // Luanti bone overrides: absolute rotations, positions in nodes, in
    // the old stream's convention (z negated; rotation {-x, -y, z}).
    for (size_t i = 0; i < bones_.size(); ++i) {
        const Work::Entry &e = w.layer[i];
        if (!e.present)
            continue;
        const V &tr = bones_[i].translation;
        V offset{0, 0, 0};
        if (e.has_p)
            offset = mul(sub(e.p, tr), 1 / units_);
        V r = euler(e.q);
        StrokeBonePose o;
        o.bone = bones_[i].name;
        o.p[0] = float(tr[0] / units_ + offset[0]);
        o.p[1] = float(tr[1] / units_ + offset[1]);
        o.p[2] = float(-(tr[2] / units_ + offset[2]));
        o.r[0] = float(-r[0]);
        o.r[1] = float(-r[1]);
        o.r[2] = float(r[2]);
        result.push_back(std::move(o));
    }
}

} // namespace goanna
