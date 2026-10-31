// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_stroke_detail.h"

#include <algorithm>
#include <cmath>

#include <quaternion.h>
#include <vector3d.h>

namespace goanna {

StrokeDetail chooseStrokeDetail(float distance, bool on_screen, StrokeDetail previous) {
    const float full = STROKE_FULL_DISTANCE + (previous == StrokeDetail::Full ? STROKE_DETAIL_HYSTERESIS : 0.0f);
    const float reduced =
            STROKE_REDUCED_DISTANCE + (previous != StrokeDetail::Clip ? STROKE_DETAIL_HYSTERESIS : 0.0f);
    if (on_screen && distance <= full)
        return StrokeDetail::Full;
    if (distance <= reduced)
        return StrokeDetail::Reduced;
    return StrokeDetail::Clip;
}

void blendStrokePoses(const std::vector<StrokeBonePose> &a, const std::vector<StrokeBonePose> &b, float f,
        std::vector<StrokeBonePose> &out) {
    out = b;
    if (a.size() != b.size())
        return;
    for (size_t i = 0; i < b.size(); ++i) {
        if (a[i].bone != b[i].bone)
            return void(out = b);
        for (int k = 0; k < 3; ++k)
            out[i].p[k] = a[i].p[k] + (b[i].p[k] - a[i].p[k]) * f;
        core::quaternion qa(core::vector3df(a[i].r[0], a[i].r[1], a[i].r[2]));
        core::quaternion qb(core::vector3df(b[i].r[0], b[i].r[1], b[i].r[2]));
        core::quaternion q;
        q.slerp(qa, qb, f);
        core::vector3df euler;
        q.toEuler(euler);
        out[i].r[0] = euler.X;
        out[i].r[1] = euler.Y;
        out[i].r[2] = euler.Z;
    }
}

void StrokeLod::step(float dt, StrokeDetail detail) {
    const float target = detail == StrokeDetail::Clip ? 0.0f : 1.0f;
    if (!m_started) {
        m_started = true;
        m_w = target;
    } else {
        const float move = dt / STROKE_DETAIL_BLEND;
        m_w = m_w < target ? std::min(target, m_w + move) : std::max(target, m_w - move);
    }
    if (detail != m_detail) {
        // A tier change asks for the ground at once, and an interpolation
        // started now does not reuse evaluations from before it.
        m_ground_clock = 1.0f / STROKE_REDUCED_RATE;
        if (detail != StrokeDetail::Full)
            m_have = false;
    }
    m_detail = detail;
}

float StrokeLod::weight() const {
    // Smoothstep, so the fade starts and ends without a kink.
    return m_w * m_w * (3.0f - 2.0f * m_w);
}

void StrokeLod::pose(const StrokeEvaluator &evaluator, float angle, float t, bool restart,
        std::vector<StrokeBonePose> &out) {
    if (m_detail == StrokeDetail::Full) {
        evaluator.evaluate(angle, t, out);
        ++m_evaluations;
        m_have = false;
        return;
    }
    const float h = 1.0f / STROKE_REDUCED_RATE;
    const float length = evaluator.length();
    auto ahead = [&](float from) { return length > 0.0f ? std::min(from + h, length) : from + h; };
    if (restart || !m_have || t < m_ta - 1e-4f || t > m_tb + h) {
        // A new stroke, or the clock jumped (a phase change resets it to
        // the server's): start again from now.
        evaluator.evaluate(angle, t, m_a);
        m_ta = t;
        m_tb = ahead(t);
        evaluator.evaluate(angle, m_tb, m_b);
        m_evaluations += 2;
        m_have = true;
    } else if (t >= m_tb) {
        std::swap(m_a, m_b);
        m_ta = m_tb;
        m_tb = ahead(t);
        evaluator.evaluate(angle, m_tb, m_b);
        ++m_evaluations;
    }
    const float span = m_tb - m_ta;
    const float f = span > 1e-6f ? std::clamp((t - m_ta) / span, 0.0f, 1.0f) : 1.0f;
    blendStrokePoses(m_a, m_b, f, out);
}

bool StrokeLod::groundDue(float dt) {
    switch (m_detail) {
    case StrokeDetail::Full:
        return true;
    case StrokeDetail::Clip:
        return false;
    case StrokeDetail::Reduced:
        break;
    }
    m_ground_clock += dt;
    if (m_ground_clock + 1e-6f < 1.0f / STROKE_REDUCED_RATE)
        return false;
    m_ground_clock = 0.0f;
    return true;
}

} // namespace goanna
