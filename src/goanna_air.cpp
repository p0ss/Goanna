// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_air.h"

#include <algorithm>
#include <cmath>

#include <json/json.h>

namespace goanna {

bool parseAirPlan(const Json::Value &v, AirPlan &out) {
    if (!v.isObject() || !v["state"].isString() || !v["legs"].isArray())
        return false;
    AirPlan p;
    p.state = v["state"].asString();
    if (v["clips"].isObject()) {
        const Json::Value &c = v["clips"];
        if (c["fly"].isString())
            p.fly = c["fly"].asString();
        if (c["stand"].isString())
            p.stand = c["stand"].asString();
        if (c["talons"].isString())
            p.talons = c["talons"].asString();
    }
    for (const Json::Value &l : v["legs"]) {
        if (!l.isObject() || !l["upper"].isString() || !l["lower"].isString())
            return false;
        p.legs.push_back({l["upper"].asString(), l["lower"].asString()});
    }
    if (v["wings"].isArray())
        for (const Json::Value &w : v["wings"])
            if (w.isString())
                p.wings.push_back(w.asString());
    if (v["leg_length"].isNumeric())
        p.leg_length = v["leg_length"].asFloat();
    if (p.legs.empty() || p.leg_length <= 0.0f)
        return false;
    out = std::move(p);
    return true;
}

namespace {
float clamp01(float v) { return std::clamp(v, 0.0f, 1.0f); }
// Towards target with time constant tau seconds.
float ease(float cur, float target, float dt, float tau) {
    return cur + (target - cur) * (1.0f - std::exp(-dt / tau));
}
} // namespace

AirOutput AirMotion::step(const AirInput &in) {
    AirOutput out;
    const float dt = std::max(in.dt, 0.0f);
    // A first frame, or a jump no flier makes in one frame (a teleport):
    // start over rather than read a speed from it.
    const float dx = in.x - m_px, dy = in.y - m_py, dz = in.z - m_pz;
    if (!m_have || dt <= 0.0f || dx * dx + dy * dy + dz * dz > 25.0f) {
        m_have = true;
        m_px = in.x, m_py = in.y, m_pz = in.z, m_pyaw = in.yaw;
        m_vx = m_vy = m_vz = m_turn = 0.0f;
        m_moving = false;
        if (dt <= 0.0f) {
            out.flying = m_weight > 0.5f;
            out.beat_rate = m_rate, out.bank = m_bank, out.reach = m_reach;
            out.talons = m_talons, out.weight = m_weight;
            return out;
        }
    } else {
        m_vx = ease(m_vx, dx / dt, dt, 0.12f);
        m_vy = ease(m_vy, dy / dt, dt, 0.12f);
        m_vz = ease(m_vz, dz / dt, dt, 0.12f);
        // The turn: from the heading of the velocity while it moves (yaw
        // in Luanti's sense, the way (-sin, cos) points), so it does not
        // depend on how the model faces; from the yaw when hovering.
        const bool moving = m_vx * m_vx + m_vz * m_vz > 0.25f;
        const float heading = moving ? std::atan2(-m_vx, m_vz) : in.yaw;
        if (moving == m_moving) {
            const float dyaw = std::remainder(heading - m_pyaw, 2.0f * (float)M_PI);
            m_turn = ease(m_turn, dyaw / dt, dt, 0.15f);
        }
        m_moving = moving;
        m_pyaw = heading;
    }
    m_px = in.x, m_py = in.y, m_pz = in.z;
    if (!m_moving)
        m_pyaw = in.yaw;

    const float leg = std::max(in.leg, 0.05f);
    const float above = in.floor ? in.y - *in.floor : 1e9f;
    const bool pushed = in.manoeuvre == AirManoeuvre::TakeOff || in.manoeuvre == AirManoeuvre::Swoop
            || in.manoeuvre == AirManoeuvre::Strike;
    // In the air: off the floor, or going up or down faster than a step.
    const bool flying = above > 0.1f || std::fabs(m_vy) > 0.6f || (pushed && above > 0.02f);
    out.flying = flying;

    // Legs: tucked high up; reaching down as the floor comes within a few
    // leg lengths (further out once the server says it is landing), so the
    // feet meet the floor that is there, whatever the clip's timing. A
    // swoop keeps them tucked; its talons are below.
    float reach = 1.0f;
    if (flying) {
        const float range = (in.manoeuvre == AirManoeuvre::Land ? 4.0f : 2.0f) * leg;
        reach = 1.0f - clamp01((above - leg) / (range - leg));
        if (in.manoeuvre == AirManoeuvre::Swoop)
            reach = 0.0f;
    }
    m_reach = ease(m_reach, reach, dt, 0.12f);

    // Talons: forward for the last 0.45 s before a swoop's contact, held
    // 0.35 s past it; at once for a strike, for 0.45 s.
    float talons = 0.0f;
    if (in.manoeuvre == AirManoeuvre::Swoop) {
        const float c = in.param;
        if (in.since >= c - 0.45f && in.since <= c + 0.35f)
            talons = clamp01((in.since - (c - 0.45f)) / 0.3f);
    } else if (in.manoeuvre == AirManoeuvre::Strike && in.since < 0.45f) {
        talons = 1.0f;
    }
    m_talons = ease(m_talons, talons, dt, 0.08f);

    // The wingbeat: faster climbing and hovering, a little slower at speed.
    float rate = 1.0f;
    if (flying) {
        const float h = std::sqrt(m_vx * m_vx + m_vz * m_vz);
        rate = 1.0f + 0.45f * clamp01(m_vy / 2.0f) + 0.3f * clamp01(1.0f - h / 1.5f)
                - 0.15f * clamp01((h - 3.0f) / 3.0f);
        rate = std::clamp(rate, 0.7f, 1.7f);
    }
    m_rate = ease(m_rate, rate, dt, 0.25f);

    // The wings bank into a turn: turning left, the left wing goes down.
    const float bank = flying ? std::clamp(m_turn * 0.3f, -0.5f, 0.5f) : 0.0f;
    m_bank = ease(m_bank, bank, dt, 0.15f);

    // The leg pose is Goanna's in the air, the clip's on the ground.
    m_weight = ease(m_weight, flying ? 1.0f : 0.0f, dt, flying ? 0.1f : 0.15f);

    out.beat_rate = m_rate, out.bank = m_bank, out.reach = m_reach;
    out.talons = m_talons, out.weight = m_weight;
    return out;
}

} // namespace goanna
