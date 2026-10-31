// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_climb.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

constexpr float kPi = 3.14159265358979f;

float clampf(float x, float a, float b) { return std::max(a, std::min(b, x)); }
float smooth(float t) {
    t = clampf(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}
float ease(float dt, float tau) { return 1.0f - std::exp(-dt / tau); }
float dist(const StepVec &a, const StepVec &b) {
    return std::hypot(std::hypot(a[0] - b[0], a[1] - b[1]), a[2] - b[2]);
}
float rung(float y) { return std::round(y / CLIMB_RUNG) * CLIMB_RUNG; }

} // namespace

ClimbPlanner::ClimbPlanner(std::vector<ClimbLimb> limbs) : limbs_(std::move(limbs)) {
    reset();
}

void ClimbPlanner::reset() {
    contacts_.assign(limbs_.size(), ClimbContact());
    moves_.assign(limbs_.size(), Move());
    want_.assign(limbs_.size(), 0.0f);
    stage_.assign(limbs_.size(), 0);
    mode_ = ClimbMode::None;
    time_ = top_time_ = off_ = 0;
    ended_ = false;
}

float ClimbPlanner::weight() const {
    float w = 0;
    for (const ClimbContact &c : contacts_)
        w = std::max(w, c.weight);
    return w;
}

StepVec ClimbPlanner::onFace(size_t i, const ClimbInput &in, float y) const {
    // The limb's own line across the face, a little out from it.
    const StepVec &a = in.anchors[i];
    const float d = (a[0] - face_[0]) * fnx_ + (a[2] - face_[2]) * fnz_;
    return {a[0] - fnx_ * (d - 0.06f), y, a[2] - fnz_ * (d - 0.06f)};
}

StepVec ClimbPlanner::onLedge(size_t i, const ClimbInput &in, float inset) const {
    // Along the edge where the limb is, `inset` back from it onto the top.
    const StepVec &a = in.anchors[i];
    const float tx = -enz_, tz = enx_;
    const float along = (a[0] - edge_[0]) * tx + (a[2] - edge_[2]) * tz;
    return {edge_[0] + tx * along - enx_ * inset, edge_[1], edge_[2] + tz * along - enz_ * inset};
}

void ClimbPlanner::move(size_t i, const StepVec &to, float time, const StepVec &arc) {
    Move &m = moves_[i];
    m.from = contacts_[i].at;
    m.to = to;
    m.arc = arc;
    m.t = 0;
    m.time = std::max(time, 0.05f);
    m.moving = true;
    contacts_[i].held = false;
    ++stats_.moves;
}

void ClimbPlanner::advance(size_t i, float dt) {
    Move &m = moves_[i];
    ClimbContact &c = contacts_[i];
    if (!m.moving)
        return;
    m.t += dt;
    const float p = clampf(m.t / m.time, 0.0f, 1.0f);
    const float k = smooth(p), lift = std::sin(kPi * p);
    for (int a = 0; a < 3; ++a)
        c.at[a] = m.from[a] + (m.to[a] - m.from[a]) * k + m.arc[a] * lift;
    c.swing = p;
    if (p >= 1.0f) {
        c.at = m.to;
        c.held = true;
        c.swing = 0;
        m.moving = false;
    }
}

void ClimbPlanner::start(ClimbMode mode, const ClimbInput &in) {
    mode_ = mode;
    time_ = top_time_ = off_ = 0;
    start_y_ = in.root[1];
    size_t leg = 0;
    for (size_t i = 0; i < limbs_.size(); ++i) {
        moves_[i] = Move();
        stage_[i] = 0;
        want_[i] = 1.0f;
        ClimbContact &c = contacts_[i];
        c.held = true;
        c.swing = 0;
        const ClimbLimb &l = limbs_[i];
        const StepVec &a = in.anchors[i];
        if (mode == ClimbMode::Ladder) {
            c.at = onFace(i, in, rung(l.arm ? a[1] + 0.4f * l.length : a[1] - 0.6f * l.length));
        } else if (l.arm) {
            c.at = onLedge(i, in, 0.08f);
        } else {
            // A leg pushes from where it stands.
            c.at = leg < in.soles.size() ? in.soles[leg] : StepVec{a[0], in.root[1], a[2]};
        }
        if (!l.arm)
            ++leg;
    }
    if (mode == ClimbMode::Ladder)
        ++stats_.ladders;
    else
        ++stats_.mantles;
}

void ClimbPlanner::stop(bool landed) {
    if (mode_ == ClimbMode::Mantle)
        ++(landed ? stats_.landed : stats_.abandoned);
    mode_ = ClimbMode::None;
    ended_ = true;
    for (float &w : want_)
        w = 0.0f;
}

void ClimbPlanner::ladder(const ClimbInput &in) {
    // Hand over hand: a hand and the opposite foot are a group (left hand
    // with right foot), and one group moves at a time.
    const float dir = in.vy > 0.1f ? 1.0f : in.vy < -0.1f ? -1.0f : 0.0f;
    const float speed = std::fabs(in.vy);
    bool moving[2] = {false, false};
    auto group = [&](size_t i) { return (limbs_[i].arm == (limbs_[i].side < 0)) ? 0 : 1; };
    for (size_t i = 0; i < limbs_.size(); ++i)
        if (moves_[i].moving)
            moving[group(i)] = true;
    std::vector<float> score(limbs_.size(), 0.0f);
    std::vector<float> target(limbs_.size(), 0.0f);
    for (size_t i = 0; i < limbs_.size(); ++i) {
        const ClimbLimb &l = limbs_[i];
        const StepVec &a = in.anchors[i];
        if (moves_[i].moving)
            continue;
        const float rest = l.arm ? a[1] + 0.4f * l.length : a[1] - 0.6f * l.length;
        const float th = std::max(2.0f * CLIMB_RUNG, 0.4f * l.length);
        const float behind = (rest - contacts_[i].at[1]) * dir;
        float s = dir != 0.0f ? behind / (0.5f * th) : std::fabs(rest - contacts_[i].at[1]) / th;
        const float reach = dist(a, contacts_[i].at) - (l.arm ? 0.0f : l.end);
        if (reach > CLIMB_REACH * l.length)
            s = std::max(s, 2.0f);
        score[i] = s;
        target[i] = rung(rest + dir * 0.5f * th);
    }
    for (int pass = 0; pass < 2; ++pass) {
        // The pair that wants to move most goes, but pairs take turns: one
        // that just moved waits while the other wants to.
        if (moving[0] || moving[1])
            break;
        float most[2] = {0.0f, 0.0f};
        for (size_t i = 0; i < limbs_.size(); ++i)
            most[group(i)] = std::max(most[group(i)], score[i]);
        int g = most[1] > most[0] ? 1 : 0;
        if (g == last_group_ && most[1 - g] >= 1.0f)
            g = 1 - g;
        if (most[g] < 1.0f)
            break;
        last_group_ = g;
        for (size_t i = 0; i < limbs_.size(); ++i) {
            if (group(i) != g || moves_[i].moving || score[i] < 0.3f)
                continue;
            const float time = clampf(0.4f * std::max(2.0f * CLIMB_RUNG, 0.4f * limbs_[i].length)
                            / std::max(speed, 0.5f),
                    0.08f, 0.3f);
            move(i, onFace(i, in, target[i]), time, {fnx_ * 0.08f, 0.0f, fnz_ * 0.08f});
        }
        moving[g] = true;
    }
    for (size_t i = 0; i < limbs_.size(); ++i) {
        // Each hold stays on the face as the body sways across it.
        if (!moves_[i].moving) {
            const float y = contacts_[i].at[1];
            contacts_[i].at = onFace(i, in, y);
        } else {
            moves_[i].to = onFace(i, in, moves_[i].to[1]);
        }
    }
}

void ClimbPlanner::mantle(const ClimbInput &in) {
    const bool on_top = in.root[1] >= edge_[1] - 0.05f && (in.grounded || in.vy < 0.3f);
    if (on_top)
        top_time_ += in.dt;
    for (size_t i = 0; i < limbs_.size(); ++i) {
        const ClimbLimb &l = limbs_[i];
        const StepVec &a = in.anchors[i];
        if (l.arm) {
            // The hands push until the arms are straight above the edge, and
            // let go a moment after the body is up.
            const float reach = dist(a, contacts_[i].at);
            if (reach > CLIMB_REACH * l.length && a[1] > edge_[1] + 0.1f)
                want_[i] = 0.0f;
            if (top_time_ >= CLIMB_HOLD_TOP)
                want_[i] = 0.0f;
            if (reach > CLIMB_REACH * l.length)
                stats_.most_stretch = std::max(stats_.most_stretch, reach - CLIMB_REACH * l.length);
            continue;
        }
        const float hip_above = a[1] - (edge_[1] + l.end);
        const StepVec tuck{a[0] - enx_ * 0.2f * l.length, a[1] - 0.55f * l.length, a[2] - enz_ * 0.2f * l.length};
        if (stage_[i] == 0) {
            const float reach = dist(a, contacts_[i].at) - l.end;
            // Up first: the leg nearer the edge, as soon as the hip can
            // reach the top; the other when it can no longer push.
            auto out = [&](const StepVec &p) { return (p[0] - edge_[0]) * enx_ + (p[2] - edge_[2]) * enz_; };
            bool near = true;
            for (size_t j = 0; j < limbs_.size(); ++j)
                if (j != i && !limbs_[j].arm && out(in.anchors[j]) < out(a) - 1e-4f)
                    near = false;
            if (reach > CLIMB_REACH * l.length || (near && hip_above > -0.1f && hip_above < 0.9f * l.length)) {
                stage_[i] = 1;
                move(i, tuck, 0.14f, {0, 0.05f, 0});
            }
        }
        if (stage_[i] == 1) {
            moves_[i].to = tuck;
            if (!moves_[i].moving)
                contacts_[i].at = tuck;
            if (hip_above > -0.1f && hip_above < 0.9f * l.length) {
                stage_[i] = 2;
                move(i, onLedge(i, in, 0.2f), 0.2f, {0, 0.12f * l.length, 0});
            }
        }
        if (stage_[i] == 2 && moves_[i].moving)
            moves_[i].to = onLedge(i, in, 0.2f);
    }
    bool all_up = true;
    for (size_t i = 0; i < limbs_.size(); ++i)
        if (!limbs_[i].arm && (stage_[i] != 2 || moves_[i].moving))
            all_up = false;
    if (top_time_ >= CLIMB_HOLD_TOP && all_up)
        stop(true);
    else if (in.root[1] < start_y_ - 0.3f || time_ > CLIMB_MANTLE_MOST
            || (in.grounded && std::fabs(in.vy) < 0.3f && in.root[1] < edge_[1] - 0.3f && time_ > 0.3f))
        stop(false);
    else if (top_time_ >= CLIMB_HOLD_TOP + 0.4f)
        stop(true); // a foot that never made it: the step planner sorts it out
}

void ClimbPlanner::step(const ClimbInput &in) {
    ended_ = false;
    const size_t n = limbs_.size();
    if (n == 0 || in.dt <= 0.0f || in.anchors.size() != n)
        return;
    time_ += in.dt;
    if (in.striking && mode_ != ClimbMode::None)
        stop(false);
    if (mode_ == ClimbMode::None && !in.striking) {
        const float up = in.edge[1] - in.root[1];
        if (in.ladder && (!in.grounded || std::fabs(in.vy) > 0.3f)) {
            face_ = in.face;
            fnx_ = in.face_nx;
            fnz_ = in.face_nz;
            start(ClimbMode::Ladder, in);
        } else if (in.ledge && in.vy > CLIMB_RISE && up > CLIMB_LEDGE_LOW && up <= CLIMB_LEDGE_HIGH) {
            edge_ = in.edge;
            enx_ = in.edge_nx;
            enz_ = in.edge_nz;
            start(ClimbMode::Mantle, in);
        }
    }
    if (mode_ == ClimbMode::Ladder) {
        ++stats_.ladder_frames;
        off_ = !in.ladder || (in.grounded && std::fabs(in.vy) < 0.3f) ? off_ + in.dt : 0.0f;
        if (off_ > 0.15f)
            stop(false);
        else
            ladder(in);
    } else if (mode_ == ClimbMode::Mantle) {
        ++stats_.mantle_frames;
        mantle(in);
    }
    for (size_t i = 0; i < n; ++i) {
        advance(i, in.dt);
        ClimbContact &c = contacts_[i];
        c.weight += (want_[i] - c.weight) * ease(in.dt, want_[i] > c.weight ? 0.05f : 0.08f);
        if (c.weight < 1e-3f && want_[i] == 0.0f)
            c.weight = 0.0f;
    }
}

} // namespace goanna
