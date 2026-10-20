// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The shadow settings and matrices. See iris_shadow.h.

#include "iris/iris_shadow.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace goanna {
namespace iris {

namespace {

// A const's value as a number: a literal (1024, 120.0f, -40.0) or the name
// of an option whose value is one.
bool constNumber(const std::map<std::string, std::string> &consts, const std::map<std::string, std::string> &options,
        const char *name, double &out) {
    auto it = consts.find(name);
    if (it == consts.end()) return false;
    std::string v = it->second;
    for (int depth = 0; depth < 4; ++depth) {
        while (!v.empty() && std::isspace((unsigned char)v.back())) v.pop_back();
        while (!v.empty() && (v.back() == 'f' || v.back() == 'F')) v.pop_back();
        size_t a = 0;
        while (a < v.size() && (std::isspace((unsigned char)v[a]) || v[a] == '(')) ++a;
        v = v.substr(a);
        while (!v.empty() && v.back() == ')') v.pop_back();
        char *end = nullptr;
        double d = std::strtod(v.c_str(), &end);
        if (end && end != v.c_str() && *end == '\0') {
            out = d;
            return true;
        }
        auto o = options.find(v);
        if (o == options.end()) return false;
        v = o->second;
    }
    return false;
}

// A boolean const: true or false, or the name of a boolean option, which
// is on when the options hold it.
bool constFlag(const std::map<std::string, std::string> &consts, const std::map<std::string, std::string> &options,
        const std::string &name, bool &out) {
    auto it = consts.find(name);
    if (it == consts.end()) return false;
    std::string v = it->second;
    while (!v.empty() && std::isspace((unsigned char)v.back())) v.pop_back();
    size_t a = 0;
    while (a < v.size() && std::isspace((unsigned char)v[a])) ++a;
    v = v.substr(a);
    if (v == "true" || v == "false") {
        out = v == "true";
        return true;
    }
    auto o = options.find(v);
    out = o != options.end() && o->second != "false";
    return true;
}

} // namespace

ShadowSettings readShadowSettings(const std::map<std::string, std::string> &consts,
        const std::map<std::string, std::string> &options) {
    ShadowSettings s;
    double v;
    if (constNumber(consts, options, "shadowMapResolution", v)) {
        int r = (int)std::lround(v);
        // Iris takes any size; 8192 is the largest a pack's menu offers.
        s.resolution = std::clamp(r, 16, 8192);
        if (s.resolution != r) s.notes.push_back("shadowMapResolution " + std::to_string(r) + " clamped");
    }
    if (constNumber(consts, options, "shadowDistance", v) && v > 0.0) s.distance = (float)v;
    if (constNumber(consts, options, "shadowIntervalSize", v) && v >= 0.0) s.interval = (float)v;
    if (constNumber(consts, options, "shadowNearPlane", v) && v >= 0.0) s.near_plane = (float)v;
    if (constNumber(consts, options, "shadowFarPlane", v) && v > 0.0) s.far_plane = (float)v;
    if (constNumber(consts, options, "sunPathRotation", v)) {
        s.sun_path_rotation = (float)v;
    }
    bool hardware = false, flag = false;
    constFlag(consts, options, "shadowHardwareFiltering", hardware);
    for (int i = 0; i < 2; ++i) {
        bool filtered = hardware;
        if (constFlag(consts, options, "shadowHardwareFiltering" + std::to_string(i), flag)) filtered = flag;
        bool nearest = false;
        constFlag(consts, options, "shadowtex" + std::to_string(i) + "Nearest", nearest);
        s.linear_compare[i] = filtered && !nearest;
    }
    if (constNumber(consts, options, "shadowMapFov", v) && v > 0.0)
        s.notes.push_back("shadowMapFov (a perspective shadow map) is not supported; the map is orthographic");
    return s;
}

void mul(const Mat4 a, const Mat4 b, Mat4 out) {
    float r[16];
    for (int c = 0; c < 4; ++c)
        for (int row = 0; row < 4; ++row) {
            float s = 0.0f;
            for (int k = 0; k < 4; ++k) s += a[k * 4 + row] * b[c * 4 + k];
            r[c * 4 + row] = s;
        }
    std::memcpy(out, r, sizeof(r));
}

void affineInverse(const Mat4 m, Mat4 out) {
    // the upper 3x3 by cofactors, then the translation through it
    auto at = [&](int row, int col) { return (double)m[col * 4 + row]; };
    double a = at(0, 0), b = at(0, 1), c = at(0, 2);
    double d = at(1, 0), e = at(1, 1), f = at(1, 2);
    double g = at(2, 0), h = at(2, 1), i = at(2, 2);
    double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
    double det = a * A + b * B + c * C;
    double inv = det != 0.0 ? 1.0 / det : 0.0;
    double r[3][3] = {{A * inv, -(b * i - c * h) * inv, (b * f - c * e) * inv},
            {B * inv, (a * i - c * g) * inv, -(a * f - c * d) * inv},
            {C * inv, -(a * h - b * g) * inv, (a * e - b * d) * inv}};
    double t[3] = {at(0, 3), at(1, 3), at(2, 3)};
    float o[16] = {};
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 3; ++col) o[col * 4 + row] = (float)r[row][col];
        o[12 + row] = (float)-(r[row][0] * t[0] + r[row][1] * t[1] + r[row][2] * t[2]);
    }
    o[15] = 1.0f;
    std::memcpy(out, o, sizeof(o));
}

void transform(const Mat4 m, const float in[4], float out[4]) {
    float r[4];
    for (int row = 0; row < 4; ++row)
        r[row] = m[row] * in[0] + m[4 + row] * in[1] + m[8 + row] * in[2] + m[12 + row] * in[3];
    std::memcpy(out, r, sizeof(r));
}

void shadowModelView(const float light[3], const float camera[3], float interval, Mat4 out) {
    // z towards the light, so the light's eye looks down -z at the player.
    double z[3] = {light[0], light[1], light[2]};
    double zl = std::sqrt(z[0] * z[0] + z[1] * z[1] + z[2] * z[2]);
    if (zl < 1e-9) {
        z[0] = 0.0;
        z[1] = 1.0;
        z[2] = 0.0;
    } else {
        for (double &v : z) v /= zl;
    }
    // x across the sun's path. The sun turns about the z axis (it rises in
    // the east, +x, and sets in the west), so x = axis cross z stays put
    // through the day and the map does not spin as the sun moves. A light
    // along the axis itself, which no sun reaches, falls back to +x.
    double axis[3] = {0.0, 0.0, 1.0};
    double x[3] = {axis[1] * z[2] - axis[2] * z[1], axis[2] * z[0] - axis[0] * z[2], axis[0] * z[1] - axis[1] * z[0]};
    double xl = std::sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
    if (xl < 1e-6) {
        axis[0] = 1.0;
        axis[2] = 0.0;
        x[0] = axis[1] * z[2] - axis[2] * z[1];
        x[1] = axis[2] * z[0] - axis[0] * z[2];
        x[2] = axis[0] * z[1] - axis[1] * z[0];
        xl = std::sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
    }
    for (double &v : x) v /= xl;
    double y[3] = {z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]};
    // The camera's position modulo the interval, in [0, interval): player
    // space plus this is the world less a grid point.
    double off[3] = {0.0, 0.0, 0.0};
    if (interval > 0.0f)
        for (int k = 0; k < 3; ++k) {
            double m = std::fmod((double)camera[k], (double)interval);
            if (m < 0.0) m += interval;
            off[k] = m;
        }
    const double *rows[3] = {x, y, z};
    float o[16] = {};
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 3; ++col) o[col * 4 + row] = (float)rows[row][col];
        double t = rows[row][0] * off[0] + rows[row][1] * off[1] + rows[row][2] * off[2];
        o[12 + row] = (float)t;
    }
    o[15] = 1.0f;
    std::memcpy(out, o, sizeof(o));
}

void shadowProjection(float distance, float near_plane, float far_plane, Mat4 out) {
    float o[16] = {};
    const float d = std::max(distance, 1e-3f);
    // The 100 node eye offset belongs to the projection, not the modelview.
    // A pack may project a normal with w = 1 when computing its shadow bias,
    // so moving that offset between matrices changes the pack's arithmetic
    // even when their product is unchanged. Measured from shader uniforms on
    // Minecraft 26.2 / Iris 1.11.4, including the near extent towards the light.
    const float depth = std::max(far_plane + near_plane, 1e-3f);
    o[0] = 1.0f / d;
    o[5] = 1.0f / d;
    o[10] = -2.0f / depth;
    o[14] = (200.0f - far_plane + near_plane) / depth;
    o[15] = 1.0f;
    std::memcpy(out, o, sizeof(o));
}

} // namespace iris
} // namespace goanna
