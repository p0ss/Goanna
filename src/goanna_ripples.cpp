// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_ripples.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include <godot_cpp/core/class_db.hpp>

namespace goanna {

RippleField::RippleField(int nodes)
    : m_nodes(std::max(nodes, 2 * kSpongeNodes + 2)),
      m_cells(m_nodes * kCellsPerNode),
      m_h((size_t)m_cells * m_cells, 0.0f),
      m_v((size_t)m_cells * m_cells, 0.0f),
      m_sponge((size_t)m_cells * m_cells, 0.0f) {
    // Damping grows as the square of the depth into the sponge, which soaks
    // a wave up without the sponge's own edge reflecting it.
    const float width = (float)(kSpongeNodes * kCellsPerNode);
    for (int j = 0; j < m_cells; ++j)
        for (int i = 0; i < m_cells; ++i) {
            const float edge = (float)std::min(std::min(i, m_cells - 1 - i),
                    std::min(j, m_cells - 1 - j));
            const float into = std::max(0.0f, 1.0f - edge / width);
            m_sponge[(size_t)j * m_cells + i] = kSpongeDamping * into * into;
        }
}

bool RippleField::water(int i, int j) const {
    if (m_water.empty())
        return true;
    return m_water[(size_t)(j / kCellsPerNode) * m_nodes + i / kCellsPerNode] != 0;
}

void RippleField::setOrigin(int ox, int oz) {
    const int dx = (ox - m_ox) * kCellsPerNode;
    const int dz = (oz - m_oz) * kCellsPerNode;
    const int dnx = ox - m_ox, dnz = oz - m_oz;
    m_ox = ox;
    m_oz = oz;
    if (dx == 0 && dz == 0)
        return;
    if (m_asleep) {
        m_water.clear();
        return;
    }
    // Cell (i, j) of the moved patch is cell (i + dx, j + dz) of the old one.
    std::vector<float> h(m_h.size(), 0.0f), v(m_v.size(), 0.0f);
    for (int j = 0; j < m_cells; ++j) {
        const int sj = j + dz;
        if (sj < 0 || sj >= m_cells)
            continue;
        for (int i = 0; i < m_cells; ++i) {
            const int si = i + dx;
            if (si < 0 || si >= m_cells)
                continue;
            h[(size_t)j * m_cells + i] = m_h[(size_t)sj * m_cells + si];
            v[(size_t)j * m_cells + i] = m_v[(size_t)sj * m_cells + si];
        }
    }
    m_h.swap(h);
    m_v.swap(v);
    if (!m_water.empty()) {
        std::vector<uint8_t> w((size_t)m_nodes * m_nodes, 1);
        for (int j = 0; j < m_nodes; ++j)
            for (int i = 0; i < m_nodes; ++i) {
                const int si = i + dnx, sj = j + dnz;
                if (si >= 0 && si < m_nodes && sj >= 0 && sj < m_nodes)
                    w[(size_t)j * m_nodes + i] = m_water[(size_t)sj * m_nodes + si];
            }
        m_water.swap(w);
    }
}

void RippleField::setWater(const std::vector<uint8_t> &mask) {
    if (mask.size() == (size_t)m_nodes * m_nodes)
        m_water = mask;
    else
        m_water.clear();
}

template <typename Fn>
void RippleField::around(float x, float z, float radius, Fn &&fn) {
    const float r = std::max(radius, cellSize());
    const float reach = 2.5f * r;
    const float cs = cellSize();
    const int i0 = std::max(0, (int)std::floor((x - reach - cornerX()) / cs));
    const int i1 = std::min(m_cells - 1, (int)std::ceil((x + reach - cornerX()) / cs));
    const int j0 = std::max(0, (int)std::floor((z - reach - cornerZ()) / cs));
    const int j1 = std::min(m_cells - 1, (int)std::ceil((z + reach - cornerZ()) / cs));
    const float inv = 1.0f / (2.0f * r * r);
    for (int j = j0; j <= j1; ++j) {
        const float cz = cornerZ() + (j + 0.5f) * cs - z;
        for (int i = i0; i <= i1; ++i) {
            const float cx = cornerX() + (i + 0.5f) * cs - x;
            const float d2 = cx * cx + cz * cz;
            if (d2 > reach * reach)
                continue;
            fn((size_t)j * m_cells + i, std::exp(-d2 * inv));
        }
    }
}

// Raises the surface over a body by `amount` and lowers a ring round it by
// the same volume: a Gaussian of the body's radius less one twice as wide at
// a quarter of the height, whose integrals match. A negative amount is a
// body sinking, pushing the water out from under it into the ring.
void RippleField::lift(const RippleBody &b, float x, float z, float amount) {
    const float r = std::max(kLiftNarrow * b.radius, cellSize());
    around(x, z, r, [&](size_t c, float g) { m_h[c] += amount * g; });
    around(x, z, 2.0f * r, [&](size_t c, float g) { m_h[c] -= 0.25f * amount * g; });
}

// Pushes the surface's velocity down by a Gaussian of `amount` round (x, z).
void RippleField::press(const RippleBody &b, float x, float z, float amount) {
    around(x, z, b.radius, [&](size_t c, float g) { m_v[c] -= amount * g; });
}

// The body moved from (x0, z0) to (x1, z1). Where it arrives the surface
// rises, the water shoved ahead of it, and where it has left the surface
// falls back, each by the change in its footprint. The two cancel, so no
// water is made or lost.
void RippleField::shove(const RippleBody &b, float x0, float z0, float x1, float z1) {
    around(x1, z1, b.radius, [&](size_t c, float g) { m_h[c] += b.displace * g; });
    around(x0, z0, b.radius, [&](size_t c, float g) { m_h[c] -= b.displace * g; });
}

void RippleField::impulse(float x, float z, float amount, float radius) {
    // A kick to the surface's velocity all at once, where a body's press is
    // spread over the steps it lasts.
    RippleBody b;
    b.radius = radius;
    press(b, x, z, amount);
    m_asleep = false;
}

void RippleField::step(float dt, const std::vector<RippleBody> &bodies) {
    bool pressed = false;
    for (const RippleBody &b : bodies)
        if (b.press != 0.0f || (b.sink != 0.0f && b.sinking != 0.0f)
                || (b.displace != 0.0f && (b.vx != 0.0f || b.vz != 0.0f)))
            pressed = true;
    if (m_asleep && !pressed) {
        m_carry = 0.0f;
        return;
    }
    m_asleep = false;
    m_carry += std::max(dt, 0.0f);
    int steps = (int)(m_carry / kStep);
    if (steps > kMaxSteps) {
        steps = kMaxSteps;
        m_carry = 0.0f;
    } else {
        m_carry -= steps * kStep;
    }
    for (int s = 0; s < steps; ++s)
        substep(kStep, (steps - 1 - s) * kStep, bodies);
    if (!pressed) {
        float most = 0.0f;
        for (size_t k = 0; k < m_h.size(); ++k)
            most = std::max(most, std::max(std::fabs(m_h[k]), std::fabs(m_v[k])));
        if (most < kStill) {
            std::fill(m_h.begin(), m_h.end(), 0.0f);
            std::fill(m_v.begin(), m_v.end(), 0.0f);
            m_asleep = true;
        }
    }
}

// One step of v' = c^2 lap(h) - restore h - damping v - pressure, h' = v,
// semi-implicit (velocity first, then height from the new velocity), which
// is stable here with a wide margin: c dt / dx is 0.16. Cells that are not
// water hold still at zero, which reflects a wave at the bank the way a
// wall does.
void RippleField::substep(float h, float t_back, const std::vector<RippleBody> &bodies) {
    for (const RippleBody &b : bodies) {
        const float x1 = b.x - b.vx * t_back, z1 = b.z - b.vz * t_back;
        if (b.press != 0.0f)
            press(b, x1, z1, b.press * h);
        if (b.sink != 0.0f && b.sinking != 0.0f)
            lift(b, x1, z1, -b.sink * b.sinking * h);
        if (b.displace != 0.0f && (b.vx != 0.0f || b.vz != 0.0f))
            shove(b, x1 - b.vx * h, z1 - b.vz * h, x1, z1);
    }
    const float cs = cellSize();
    const float k = kWaveSpeed * kWaveSpeed / (cs * cs);
    const int n = m_cells;
    for (int j = 0; j < n; ++j) {
        for (int i = 0; i < n; ++i) {
            const size_t c = (size_t)j * n + i;
            if (!water(i, j)) {
                m_h[c] = 0.0f;
                m_v[c] = 0.0f;
                continue;
            }
            // Past the edge of the patch the water is flat.
            const float hc = m_h[c];
            const float l = i > 0 ? m_h[c - 1] : 0.0f;
            const float r = i < n - 1 ? m_h[c + 1] : 0.0f;
            const float d = j > 0 ? m_h[c - n] : 0.0f;
            const float u = j < n - 1 ? m_h[c + n] : 0.0f;
            const float lap = l + r + d + u - 4.0f * hc;
            const float damp = kDamping + m_sponge[c];
            m_v[c] += h * (k * lap - kRestore * hc - damp * m_v[c]);
        }
    }
    for (size_t c = 0; c < m_h.size(); ++c)
        m_h[c] += h * m_v[c];
}

RippleBody RippleField::swimmer(float x, float z, float vx, float vz, float sinking, float scale) {
    RippleBody b;
    b.x = x;
    b.z = z;
    b.vx = vx;
    b.vz = vz;
    b.sinking = std::clamp(sinking, -kSwimMaxSinking, kSwimMaxSinking);
    b.radius = kSwimRadius * std::sqrt(std::max(scale, 0.1f));
    b.sink = kSwimSink * scale;
    const float speed = std::sqrt(vx * vx + vz * vz);
    const float gain = speed > 1e-3f
            ? std::clamp(kSwimFullSpeed / speed, 1.0f, kSwimSlowGain) : kSwimSlowGain;
    b.displace = kSwimDisplace * scale * gain;
    return b;
}

float RippleField::height(float x, float z) const {
    const float fx = (x - cornerX()) / cellSize() - 0.5f;
    const float fz = (z - cornerZ()) / cellSize() - 0.5f;
    const int i = (int)std::floor(fx), j = (int)std::floor(fz);
    const float ax = fx - i, az = fz - j;
    auto at = [&](int ii, int jj) -> float {
        if (ii < 0 || jj < 0 || ii >= m_cells || jj >= m_cells)
            return 0.0f;
        return m_h[(size_t)jj * m_cells + ii];
    };
    return (at(i, j) * (1 - ax) + at(i + 1, j) * ax) * (1 - az)
            + (at(i, j + 1) * (1 - ax) + at(i + 1, j + 1) * ax) * az;
}

float RippleField::peak() const {
    float most = 0.0f;
    for (float v : m_h)
        most = std::max(most, std::fabs(v));
    return most;
}

// GoannaRipples

GoannaRipples::GoannaRipples() {
    m_bytes.resize((int64_t)m_field.cells() * m_field.cells() * 4);
}

void GoannaRipples::set_origin(const godot::Vector2i &origin) {
    m_field.setOrigin(origin.x, origin.y);
    m_dirty = true;
}

godot::Vector2i GoannaRipples::get_origin() const {
    return godot::Vector2i(m_field.originX(), m_field.originZ());
}

godot::Vector2 GoannaRipples::get_corner() const {
    return godot::Vector2(m_field.cornerX(), m_field.cornerZ());
}

void GoannaRipples::set_water(const godot::PackedByteArray &mask) {
    std::vector<uint8_t> m((size_t)mask.size());
    if (!m.empty())
        std::memcpy(m.data(), mask.ptr(), m.size());
    m_field.setWater(m);
}

void GoannaRipples::impulse(const godot::Vector2 &pos, float amount, float radius) {
    m_field.impulse(pos.x, pos.y, amount, radius);
    m_dirty = true;
}

void GoannaRipples::step(float delta, const godot::PackedFloat32Array &bodies) {
    std::vector<RippleBody> list;
    const int64_t n = bodies.size() / 6;
    list.reserve((size_t)n);
    const float *p = bodies.ptr();
    for (int64_t b = 0; b < n; ++b, p += 6)
        list.push_back(RippleField::swimmer(p[0], p[1], p[2], p[3], p[4], p[5]));
    const bool was_asleep = m_field.asleep();
    m_field.step(delta, list);
    // Asleep and still asleep: the texture already holds flat water.
    if (!(was_asleep && m_field.asleep()))
        m_dirty = true;
}

float GoannaRipples::height_at(const godot::Vector2 &pos) const {
    return m_field.height(pos.x, pos.y);
}

void GoannaRipples::upload() {
    const int n = m_field.cells();
    std::memcpy(m_bytes.ptrw(), m_field.heights().data(), (size_t)n * n * 4);
    if (m_image.is_null()) {
        m_image = godot::Image::create_from_data(n, n, false, godot::Image::FORMAT_RF, m_bytes);
        m_texture = godot::ImageTexture::create_from_image(m_image);
    } else {
        m_image->set_data(n, n, false, godot::Image::FORMAT_RF, m_bytes);
        m_texture->update(m_image);
    }
    m_dirty = false;
}

godot::Ref<godot::ImageTexture> GoannaRipples::get_texture() {
    if (m_dirty || m_texture.is_null())
        upload();
    return m_texture;
}

void GoannaRipples::_bind_methods() {
    using godot::ClassDB;
    using godot::D_METHOD;
    ClassDB::bind_method(D_METHOD("get_nodes"), &GoannaRipples::get_nodes);
    ClassDB::bind_method(D_METHOD("get_cells"), &GoannaRipples::get_cells);
    ClassDB::bind_method(D_METHOD("get_cell_size"), &GoannaRipples::get_cell_size);
    ClassDB::bind_method(D_METHOD("set_origin", "origin"), &GoannaRipples::set_origin);
    ClassDB::bind_method(D_METHOD("get_origin"), &GoannaRipples::get_origin);
    ClassDB::bind_method(D_METHOD("get_corner"), &GoannaRipples::get_corner);
    ClassDB::bind_method(D_METHOD("set_water", "mask"), &GoannaRipples::set_water);
    ClassDB::bind_method(D_METHOD("impulse", "pos", "amount", "radius"), &GoannaRipples::impulse);
    ClassDB::bind_method(D_METHOD("step", "delta", "bodies"), &GoannaRipples::step);
    ClassDB::bind_method(D_METHOD("is_asleep"), &GoannaRipples::is_asleep);
    ClassDB::bind_method(D_METHOD("height_at", "pos"), &GoannaRipples::height_at);
    ClassDB::bind_method(D_METHOD("peak"), &GoannaRipples::peak);
    ClassDB::bind_method(D_METHOD("get_texture"), &GoannaRipples::get_texture);
}

} // namespace goanna
