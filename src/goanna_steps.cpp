// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_steps.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace goanna {

namespace {

constexpr float kPi = 3.14159265358979f;

float clampf(float x, float a, float b) { return std::max(a, std::min(b, x)); }
float smooth(float t) {
    t = clampf(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}
float wrap(float a) { return std::remainder(a, 2.0f * kPi); }
float flat(const StepVec &a, const StepVec &b) { return std::hypot(a[0] - b[0], a[2] - b[2]); }
float ease(float dt, float tau) { return 1.0f - std::exp(-dt / tau); }

} // namespace

StepPlanner::StepPlanner(std::vector<StepLeg> legs) : legs_(std::move(legs)) {
    state_.resize(legs_.size());
    feet_.resize(legs_.size());
    for (const StepLeg &l : legs_)
        groups_ = std::max(groups_, l.group + 1);
}

void StepPlanner::reset() {
    have_ = false;
    airborne_ = false;
    drop_ = soft_drop_ = 0;
    pelvis_yaw_ = 0;
    for (Leg &l : state_)
        l = Leg();
}

StepPlanner::Gait StepPlanner::gait(float length, float speed, int groups) {
    // Longer legs swing slower and stride further (a pendulum's time goes
    // with the root of its length); faster bodies stride further.
    const float k = std::sqrt(std::max(length, 0.05f) / 0.8f);
    Gait g;
    g.stride = clampf(length * (0.6f + 0.6f * speed / k), 0.3f * length, 2.2f * length);
    g.swing = clampf(0.4f * g.stride / std::max(speed, 1e-3f), STEP_SWING_MIN * k, STEP_SWING_MAX * k);
    // A foot lands half the threshold ahead of its rest place and lifts
    // half behind it: at most STEP_HALF_STRIDE leg lengths either way, so
    // the hip can still reach it with the body only a little lowered.
    // Past that a faster body steps more often, not further.
    g.threshold = clampf(g.stride - speed * g.swing, 0.1f * length, 2.0f * STEP_HALF_STRIDE * length);
    // Every other group swings while this one stands, so a stance must
    // last as long as the others' swings: past that the swing shortens
    // (to a floor of 50 ms; faster than that the feet fall behind).
    if (groups > 1 && speed > 1e-3f)
        g.swing = std::max(0.05f, std::min(g.swing, g.threshold / speed / (groups - 1)));
    g.stride = g.threshold + speed * g.swing;
    g.cycle = speed > 1e-3f ? g.stride / speed : std::numeric_limits<float>::infinity();
    return g;
}

StepPlanner::Hold StepPlanner::foothold(size_t i, float x, float z, const StepInput &in) const {
    const StepLeg &leg = legs_[i];
    const StepVec &hip = in.hips[i];
    const float reach = STEP_REACH * leg.length;
    auto ok = [&](float px, float pz, float y) {
        const float across = std::hypot(px - hip[0], pz - hip[2]);
        if (across > reach)
            return false;
        const float below = hip[1] - (y + leg.ankle);
        if (below < 0.25f * leg.length)
            return false; // as high as the hip
        return below <= std::sqrt(reach * reach - across * across) + STEP_DROP_MOST * leg.length;
    };
    Hold h;
    const float top = in.root[1] + STEP_UP, bottom = in.root[1] - STEP_DOWN;
    // The place asked for, then nearer the hip a quarter at a time, then
    // nearer the body's centre (a hip can be over an edge the body is not).
    for (int k = 8; k >= 0; --k) {
        const StepVec &to = k > 4 ? hip : in.root;
        const float f = (k > 4 ? k - 4 : k) / 4.0f;
        if (k == 4)
            continue;
        const float px = to[0] + (x - to[0]) * f, pz = to[2] + (z - to[2]) * f;
        if (in.floor) {
            if (auto y = in.floor(px, pz, top, bottom); y && ok(px, pz, *y)) {
                h.sole = {px, *y, pz};
                return h;
            }
        }
        h.rejected = true;
    }
    h.supported = false;
    h.sole = {x, in.root[1], z};
    return h;
}

void StepPlanner::target(size_t i, const StepInput &in) {
    Leg &l = state_[i];
    const float speed = std::hypot(l.rest_vel[0], l.rest_vel[2]);
    const Gait g = gait(legs_[i].length, speed, groups_);
    const float remaining = std::max(0.0f, l.swing_time - l.t);
    // Land half a stride ahead of where rest will be when the foot is down.
    const float lead = speed > 0.05f ? std::min(0.5f * g.threshold / speed, 0.5f) : 0.0f;
    const float x = in.rest[i][0] + l.rest_vel[0] * (remaining + lead);
    const float z = in.rest[i][2] + l.rest_vel[2] * (remaining + lead);
    const Hold h = foothold(i, x, z, in);
    l.to = h.sole;
    l.foot.supported = h.supported;
    l.rejected = h.rejected;
    l.to_yaw = in.yaw + yaw_rate_ * remaining;
}

void StepPlanner::lift(size_t i, const StepInput &in, bool settle, bool forced) {
    Leg &l = state_[i];
    const float speed = std::hypot(l.rest_vel[0], l.rest_vel[2]);
    const float k = std::sqrt(std::max(legs_[i].length, 0.05f) / 0.8f);
    l.from = l.foot.sole;
    l.from_yaw = l.foot.yaw;
    l.t = 0;
    l.swing_time = settle ? 0.8f * STEP_SWING_MAX * k : gait(legs_[i].length, speed, groups_).swing;
    l.settle = settle;
    l.foot.planted = false;
    if (forced)
        ++stats_.forced;
    target(i, in);
}

void StepPlanner::swing(size_t i, const StepInput &in) {
    Leg &l = state_[i];
    const StepLeg &leg = legs_[i];
    // Hurried by a foot waiting on this one, but never down in one frame.
    l.t += std::min(in.dt * hurry_, 0.5f * l.swing_time);
    const float p = clampf(l.t / std::max(l.swing_time, 1e-3f), 0.0f, 1.0f);
    // Aim at where rest will be until most of the way there, so a turn or
    // a change of pace mid-step still lands right.
    if (p < 0.7f)
        target(i, in);
    const float k = smooth(p);
    StepVec at;
    at[0] = l.from[0] + (l.to[0] - l.from[0]) * k;
    at[2] = l.from[2] + (l.to[2] - l.from[2]) * k;
    // Up early onto a higher foothold, down late to a lower one.
    const float rise = l.to[1] > l.from[1] ? smooth(p * 1.6f) : smooth((p - 0.375f) * 1.6f);
    const float clear = clampf(0.15f * leg.length + 0.1f * flat(l.from, l.to), 0.04f, 0.3f);
    at[1] = l.from[1] + (l.to[1] - l.from[1]) * rise + std::sin(kPi * p) * clear;
    // Over anything higher on the way (a slab's edge between the two).
    if (in.floor && p > 0.1f && p < 0.9f) {
        const float hi = std::max(l.from[1], l.to[1]);
        if (auto y = in.floor(at[0], at[2], hi + STEP_UP, hi + 0.01f))
            at[1] = std::max(at[1], *y + 0.3f * clear);
    }
    l.foot.sole = at;
    l.foot.yaw = l.from_yaw + wrap(l.to_yaw - l.from_yaw) * k;
    l.foot.swing = p;
    if (p >= 1.0f) {
        l.foot.sole = l.to;
        l.foot.yaw = wrap(l.to_yaw);
        l.foot.planted = true;
        l.foot.swing = 0;
        l.planted_for = 0;
        ++stats_.steps;
        if (l.settle)
            ++stats_.settles;
        if (!l.foot.supported)
            ++stats_.unreachable;
        else if (l.rejected)
            ++stats_.rejected;
    }
}

void StepPlanner::plantAll(const StepInput &in, bool at_rest) {
    for (size_t i = 0; i < state_.size(); ++i) {
        Leg &l = state_[i];
        const StepVec &want = at_rest ? in.rest[i] : l.foot.sole;
        const Hold h = foothold(i, want[0], want[2], in);
        l.foot.sole = h.sole;
        l.foot.supported = h.supported;
        l.foot.planted = true;
        l.foot.swing = 0;
        l.foot.yaw = in.yaw;
        l.planted_for = 1.0f;
        l.still = 0;
    }
}

void StepPlanner::settleBody(const StepInput &in, bool at_once) {
    // The body down for the lower foot (eased), and at once for any planted
    // foot it could not reach otherwise; never above where the server has
    // it. A root that jumps up a step leaves the body where it was.
    float soft = 0, hard = 0, lowest = 0, shortest = std::numeric_limits<float>::infinity();
    for (size_t i = 0; i < legs_.size(); ++i) {
        const Leg &l = state_[i];
        const StepLeg &leg = legs_[i];
        shortest = std::min(shortest, leg.length);
        if (!l.foot.supported)
            continue;
        const StepVec &stand = l.foot.planted ? l.foot.sole : l.to;
        soft = std::min(soft, stand[1] - in.root[1]);
        if (!l.foot.planted)
            continue;
        lowest = std::min(lowest, l.foot.sole[1] - in.root[1]);
        const float reach = STEP_REACH * leg.length;
        const float across = flat(in.hips[i], l.foot.sole);
        const float up = std::sqrt(std::max(0.0f, reach * reach - across * across));
        hard = std::min(hard, l.foot.sole[1] + leg.ankle + up - in.hips[i][1]);
    }
    soft += std::clamp(in.crouch, -STEP_CROUCH_MOST * shortest, 0.0f);
    soft_drop_ = at_once ? soft : soft_drop_ + (soft - soft_drop_) * ease(in.dt, 0.08f);
    // No deeper than a crouch below standing on the lowest planted foot: a
    // root that jumps up a step leaves the body where it was until the
    // trailing foot follows.
    drop_ = std::max(std::min(soft_drop_, hard), lowest - STEP_DROP_MOST * shortest);
}

void StepPlanner::step(const StepInput &in) {
    const size_t n = legs_.size();
    if (n == 0 || in.dt <= 0.0f || in.hips.size() != n || in.rest.size() != n)
        return;
    const float dt = in.dt;
    // Rest places' velocities, eased: the body's own and its turning.
    const bool jump = have_
            && std::hypot(std::hypot(in.root[0] - last_root_[0], in.root[1] - last_root_[1]),
                       in.root[2] - last_root_[2])
                    > 2.0f;
    for (size_t i = 0; i < n; ++i) {
        Leg &l = state_[i];
        if (l.have_rest && !jump) {
            const float e = ease(dt, 0.08f);
            for (int a : {0, 2})
                l.rest_vel[a] += ((in.rest[i][a] - l.last_rest[a]) / dt - l.rest_vel[a]) * e;
        } else {
            l.rest_vel = {0, 0, 0};
        }
        l.last_rest = in.rest[i];
        l.have_rest = true;
    }
    if (have_ && !jump)
        yaw_rate_ += (wrap(in.yaw - last_yaw_) / dt - yaw_rate_) * ease(dt, 0.08f);
    else
        yaw_rate_ = 0;
    last_root_ = in.root;
    last_yaw_ = in.yaw;

    // Off the ground: the feet hang under their hips, where they would be
    // standing, and are planted afresh on landing.
    if (!in.grounded) {
        airborne_ = true;
        have_ = true;
        ++stats_.airborne;
        for (size_t i = 0; i < n; ++i) {
            Leg &l = state_[i];
            l.foot.sole = {in.rest[i][0], in.root[1], in.rest[i][2]};
            l.foot.planted = false;
            l.foot.supported = false;
            l.foot.swing = 0;
            l.foot.yaw = in.yaw;
        }
        drop_ += (0.0f - drop_) * ease(dt, 0.08f);
        soft_drop_ = drop_;
        pelvis_yaw_ += (0.0f - pelvis_yaw_) * ease(dt, 0.08f);
        feet_.clear();
        for (const Leg &l : state_)
            feet_.push_back(l.foot);
        return;
    }
    ++stats_.frames;
    if (!have_ || jump) {
        plantAll(in, true);
        have_ = true;
        airborne_ = false;
        settleBody(in, true);
    } else if (airborne_) {
        plantAll(in, false);
        airborne_ = false;
        settleBody(in, true);
    }

    // Each planted foot: how badly it wants to step.
    std::vector<float> score(n, 0.0f);
    std::vector<char> settle(n, 0), forced(n, 0);
    for (size_t i = 0; i < n; ++i) {
        Leg &l = state_[i];
        const StepLeg &leg = legs_[i];
        const float speed = std::hypot(l.rest_vel[0], l.rest_vel[2]);
        l.still = speed < 0.05f && std::fabs(yaw_rate_) < 0.2f ? l.still + dt : 0.0f;
        if (!l.foot.planted)
            continue;
        l.planted_for += dt;
        // A foot that found nowhere to stand hangs under its hip, and steps
        // as soon as there is somewhere.
        if (!l.foot.supported) {
            l.foot.sole = {in.rest[i][0], in.root[1], in.rest[i][2]};
            l.foot.yaw = in.yaw;
            if (foothold(i, in.rest[i][0], in.rest[i][2], in).supported) {
                score[i] = 1.5f;
                forced[i] = 1;
            }
            continue;
        }
        const Gait g = gait(leg.length, speed, groups_);
        const float th = g.threshold * (in.hold ? STEP_HOLD : 1.0f);
        const float ex = l.foot.sole[0] - in.rest[i][0], ez = l.foot.sole[2] - in.rest[i][2];
        const float d = std::hypot(ex, ez);
        float s = 0;
        if (speed > 0.05f) {
            const float behind = -(ex * l.rest_vel[0] + ez * l.rest_vel[2]) / speed;
            s = behind / (0.5f * th);
        }
        s = std::max(s, d / th);
        const float turned = std::fabs(wrap(l.foot.yaw - in.yaw));
        if (turned > STEP_TURN * (in.hold ? 1.5f : 1.0f))
            s = std::max(s, 1.01f);
        if (s < 1.0f && !in.hold && l.still >= STEP_SETTLE_AFTER
                && (d > std::max(STEP_SETTLE, 0.06f * leg.length) || turned > 0.35f)) {
            s = 1.0f;
            settle[i] = 1;
        }
        // Out of reach, or the ground under the foot is gone.
        const StepVec &hip = in.hips[i];
        const float reach_now = std::hypot(std::hypot(hip[0] - l.foot.sole[0], hip[2] - l.foot.sole[2]),
                hip[1] + drop_ - (l.foot.sole[1] + leg.ankle));
        bool lost = false;
        if (l.foot.supported && in.floor)
            lost = !in.floor(l.foot.sole[0], l.foot.sole[2], l.foot.sole[1] + 0.05f, l.foot.sole[1] - 0.05f);
        if (reach_now > 0.995f * leg.length || lost) {
            s = std::max(s, 2.0f);
            forced[i] = 1;
        }
        score[i] = s;
    }

    // Lift the most wanting foot whose turn it is, and its group with it.
    std::vector<char> swinging_group(groups_, 0);
    std::vector<float> least_planted(groups_, std::numeric_limits<float>::infinity());
    for (size_t i = 0; i < n; ++i) {
        const Leg &l = state_[i];
        if (!l.foot.planted)
            swinging_group[legs_[i].group] = 1;
        else
            least_planted[legs_[i].group] = std::min(least_planted[legs_[i].group], l.planted_for);
    }
    std::vector<size_t> order(n);
    for (size_t i = 0; i < n; ++i)
        order[i] = i;
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return score[a] > score[b]; });
    for (size_t i : order) {
        if (score[i] < 1.0f || !state_[i].foot.planted)
            continue;
        const int grp = legs_[i].group;
        bool blocked = false;
        const float speed = std::hypot(state_[i].rest_vel[0], state_[i].rest_vel[2]);
        const Gait g = gait(legs_[i].length, speed, groups_);
        // Each other group down long enough that the groups share the
        // cycle evenly: this is what makes a biped alternate.
        const float dwell = groups_ > 1 ? clampf(g.cycle / groups_ - g.swing, 0.04f, 0.25f) : 0.0f;
        for (int o = 0; o < groups_; ++o) {
            if (o == grp)
                continue;
            if (swinging_group[o] || (!forced[i] && least_planted[o] < dwell))
                blocked = true;
        }
        if (blocked)
            continue;
        lift(i, in, settle[i] != 0, forced[i] != 0);
        swinging_group[grp] = 1;
        for (size_t j = 0; j < n; ++j)
            if (j != i && legs_[j].group == grp && state_[j].foot.planted && score[j] >= 0.3f)
                lift(j, in, settle[j] != 0, forced[j] != 0);
    }

    // A foot that must step but waits on a swinging one hurries it down.
    float urgent = 0;
    for (size_t i = 0; i < n; ++i)
        if (state_[i].foot.planted && state_[i].foot.supported)
            urgent = std::max(urgent, score[i]);
    hurry_ = clampf(urgent, 1.0f, 4.0f);
    for (size_t i = 0; i < n; ++i)
        if (!state_[i].foot.planted)
            swing(i, in);

    settleBody(in, false);

    // Planted feet the body cannot reach: the leg falls short, which shows
    // as a slide.
    bool stretched = false;
    for (size_t i = 0; i < n; ++i) {
        const Leg &l = state_[i];
        if (!l.foot.planted || !l.foot.supported)
            continue;
        const StepVec &hip = in.hips[i];
        const float r = std::hypot(std::hypot(hip[0] - l.foot.sole[0], hip[2] - l.foot.sole[2]),
                hip[1] + drop_ - (l.foot.sole[1] + legs_[i].ankle));
        const float over = r - legs_[i].length;
        if (over > 1e-4f) {
            stretched = true;
            stats_.most_stretch = std::max(stats_.most_stretch, over);
        }
    }
    if (stretched)
        ++stats_.stretched;

    // The pelvis turns towards where the feet point (a planted foot lags a
    // turn), half way, within bounds.
    float sx = 0, sz = 0;
    for (const Leg &l : state_) {
        const float a = wrap((l.foot.planted ? l.foot.yaw : l.to_yaw) - in.yaw);
        sx += std::sin(a);
        sz += std::cos(a);
    }
    const float twist = clampf(0.5f * std::atan2(sx, sz), -STEP_TWIST_MOST, STEP_TWIST_MOST);
    pelvis_yaw_ += (twist - pelvis_yaw_) * ease(dt, 0.08f);

    feet_.clear();
    for (const Leg &l : state_)
        feet_.push_back(l.foot);
}

} // namespace goanna
