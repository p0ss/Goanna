// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_climate.h"

#include <algorithm>
#include <cmath>

namespace goanna {

namespace {

constexpr int kBlock = 16;

int floor_div(int a, int b) {
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

uint8_t to_byte(float v) {
    return (uint8_t)std::lround(std::clamp(v, 0.0f, 1.0f) * 255.0f);
}

} // namespace

uint64_t ClimateStore::key(int bx, int by, int bz) {
    constexpr uint64_t mask = (1u << 21) - 1;
    return ((uint64_t)(bx + (1 << 20)) & mask) | (((uint64_t)(by + (1 << 20)) & mask) << 21) |
            (((uint64_t)(bz + (1 << 20)) & mask) << 42);
}

bool ClimateStore::setBands(const std::vector<float> &temp, const std::vector<float> &wet,
        const std::vector<float> &hum) {
    auto fits = [](const std::vector<float> &v) { return v.size() == 15 || v.size() == 16; };
    if (!fits(temp) || !fits(wet) || !fits(hum))
        return false;
    auto copy = [](const std::vector<float> &v, float *out) {
        const size_t skip = v.size() == 16 ? 1 : 0;
        out[0] = 0;
        for (size_t i = 0; i < 15; ++i)
            out[i + 1] = v[i + skip];
    };
    copy(temp, m_temp);
    copy(wet, m_wet);
    copy(hum, m_hum);
    m_bands = true;
    for (auto &kv : m_blocks)
        decode(kv.second, m_raw[kv.first]);
    ++m_revision;
    return true;
}

// A cell is known when both its temperature and its wetness are. Humidity
// alone unknown falls back to the wetness, which is what the air reads
// before the day's swing.
void ClimateStore::decode(Block &b, const std::string &bytes) const {
    const int cells = b.n * b.n * b.n;
    b.temp.assign(cells, 0.0f);
    b.wet.assign(cells, 0.0f);
    b.hum.assign(cells, 0.0f);
    b.known.assign(cells, 0.0f);
    b.mean = ClimateValue();
    if (!m_bands || (int)bytes.size() != cells * 2)
        return;
    for (int i = 0; i < cells; ++i) {
        const uint8_t first = (uint8_t)bytes[i * 2], second = (uint8_t)bytes[i * 2 + 1];
        const int t = first >> 4, w = first & 15, h = second & 15;
        if (t == 0 || w == 0)
            continue;
        b.temp[i] = m_temp[t];
        b.wet[i] = m_wet[w];
        b.hum[i] = h == 0 ? m_wet[w] : m_hum[h];
        b.known[i] = 1.0f;
        b.mean.temp += b.temp[i];
        b.mean.wet += b.wet[i];
        b.mean.hum += b.hum[i];
        b.mean.known += 1.0f;
    }
    if (b.mean.known > 0) {
        b.mean.temp /= b.mean.known;
        b.mean.wet /= b.mean.known;
        b.mean.hum /= b.mean.known;
        b.mean.known = 1.0f;
    }
}

bool ClimateStore::put(int bx, int by, int bz, int size, const std::string &bytes) {
    if (size < 1 || size > kBlock || kBlock % size != 0)
        return false;
    const int n = kBlock / size;
    if ((int)bytes.size() != n * n * n * 2)
        return false;
    const uint64_t k = key(bx, by, bz);
    Block &b = m_blocks[k];
    b.size = size;
    b.n = n;
    m_raw[k] = bytes;
    decode(b, bytes);
    ++m_revision;
    return true;
}

void ClimateStore::drop(int bx, int by, int bz) {
    const uint64_t k = key(bx, by, bz);
    if (m_blocks.erase(k)) {
        m_raw.erase(k);
        ++m_revision;
    }
}

void ClimateStore::clear() {
    if (m_blocks.empty())
        return;
    m_blocks.clear();
    m_raw.clear();
    ++m_revision;
}

const ClimateStore::Block *ClimateStore::find(int bx, int by, int bz) const {
    if (m_dense) {
        const int x = bx - m_dx0, y = by - m_dy0, z = bz - m_dz0;
        if (x >= 0 && y >= 0 && z >= 0 && x < m_dnx && y < m_dny && z < m_dnz)
            return m_dense[((size_t)z * m_dny + y) * m_dnx + x];
    }
    auto it = m_blocks.find(key(bx, by, bz));
    return it == m_blocks.end() ? nullptr : &it->second;
}

// Node n's centre is at n, so a block's cells run from bx * 16 - 0.5.
ClimateValue ClimateStore::at(float x, float y, float z, int s) const {
    const float ex = x + 0.5f, ey = y + 0.5f, ez = z + 0.5f;
    const int bx = (int)std::floor(ex / kBlock), by = (int)std::floor(ey / kBlock), bz = (int)std::floor(ez / kBlock);
    const Block *b = find(bx, by, bz);
    if (!b)
        return ClimateValue();
    const float lx = ex - bx * kBlock, ly = ey - by * kBlock, lz = ez - bz * kBlock;
    auto cell = [&](int i, int j, int k) { return ((size_t)k * b->n + j) * b->n + i; };
    if (b->size >= s) {
        // The block's own cell, or the coarser cell the point lies in.
        const int i = std::clamp((int)(lx / b->size), 0, b->n - 1);
        const int j = std::clamp((int)(ly / b->size), 0, b->n - 1);
        const int k = std::clamp((int)(lz / b->size), 0, b->n - 1);
        const size_t c = cell(i, j, k);
        return {b->temp[c], b->wet[c], b->hum[c], b->known[c]};
    }
    if (s >= kBlock)
        return b->mean;
    // A finer block, read by a coarser reader: the mean of its cells inside
    // the reader's cell, which lies wholly in this block since both sizes
    // divide 16.
    const int per = s / b->size;
    const int i0 = std::clamp((int)((lx - s * 0.5f) / b->size + 0.5f), 0, b->n - per);
    const int j0 = std::clamp((int)((ly - s * 0.5f) / b->size + 0.5f), 0, b->n - per);
    const int k0 = std::clamp((int)((lz - s * 0.5f) / b->size + 0.5f), 0, b->n - per);
    ClimateValue v;
    for (int k = k0; k < k0 + per; ++k)
        for (int j = j0; j < j0 + per; ++j)
            for (int i = i0; i < i0 + per; ++i) {
                const size_t c = cell(i, j, k);
                v.temp += b->temp[c] * b->known[c];
                v.wet += b->wet[c] * b->known[c];
                v.hum += b->hum[c] * b->known[c];
                v.known += b->known[c];
            }
    if (v.known > 0) {
        v.temp /= v.known;
        v.wet /= v.known;
        v.hum /= v.known;
        v.known /= (float)(per * per * per);
    }
    return v;
}

// Trilinear over the eight cell centres round the point at cell size s,
// each corner read by `corner`, unknown corners left out.
template <class F>
static ClimateValue trilinear(float x, float y, float z, int s, F corner) {
    const float fx = (x + 0.5f) / s - 0.5f, fy = (y + 0.5f) / s - 0.5f, fz = (z + 0.5f) / s - 0.5f;
    const float ix = std::floor(fx), iy = std::floor(fy), iz = std::floor(fz);
    const float tx = fx - ix, ty = fy - iy, tz = fz - iz;
    ClimateValue sum;
    float weight = 0;
    for (int c = 0; c < 8; ++c) {
        const int dx = c & 1, dy = (c >> 1) & 1, dz = (c >> 2) & 1;
        const float w = (dx ? tx : 1 - tx) * (dy ? ty : 1 - ty) * (dz ? tz : 1 - tz);
        if (w <= 0)
            continue;
        const ClimateValue v = corner((ix + dx + 0.5f) * s - 0.5f, (iy + dy + 0.5f) * s - 0.5f,
                (iz + dz + 0.5f) * s - 0.5f);
        const float k = w * v.known;
        sum.temp += v.temp * k;
        sum.wet += v.wet * k;
        sum.hum += v.hum * k;
        weight += k;
    }
    if (weight > 0) {
        sum.temp /= weight;
        sum.wet /= weight;
        sum.hum /= weight;
    }
    sum.known = weight;
    return sum;
}

static ClimateValue mix(const ClimateValue &a, const ClimateValue &b, float t) {
    // Weighted by how known each side is, so blending into an unknown
    // value fades the known one rather than pulling it towards zero.
    ClimateValue v;
    const float ka = a.known * (1 - t), kb = b.known * t;
    v.known = ka + kb;
    if (v.known > 0) {
        v.temp = (a.temp * ka + b.temp * kb) / v.known;
        v.wet = (a.wet * ka + b.wet * kb) / v.known;
        v.hum = (a.hum * ka + b.hum * kb) / v.known;
    }
    return v;
}

// The field at 16 nodes: block centres, a finer block as its mean.
ClimateValue ClimateStore::coarse(float x, float y, float z) const {
    if (m_means) {
        // build's fast path: the block means in an array.
        return trilinear(x, y, z, kBlock, [this](float cx, float cy, float cz) {
            const int bx = (int)std::floor((cx + 0.5f) / kBlock) - m_dx0;
            const int by = (int)std::floor((cy + 0.5f) / kBlock) - m_dy0;
            const int bz = (int)std::floor((cz + 0.5f) / kBlock) - m_dz0;
            if (bx < 0 || by < 0 || bz < 0 || bx >= m_dnx || by >= m_dny || bz >= m_dnz)
                return ClimateValue();
            return m_means[((size_t)bz * m_dny + by) * m_dnx + bx];
        });
    }
    return trilinear(x, y, z, kBlock, [this](float cx, float cy, float cz) { return at(cx, cy, cz, kBlock); });
}

// The field at a finer cell size s: cells of blocks at s, the mean of finer
// ones, the cell of coarser ones, and the 16-node field itself where a
// corner lies in a wild block. Reading the wild field there, not the wild
// block's constant cell, is what lets the wild side meet a claim's edge.
ClimateValue ClimateStore::fine(float x, float y, float z, int s) const {
    return trilinear(x, y, z, s, [this, s](float cx, float cy, float cz) {
        const Block *b = find((int)std::floor((cx + 0.5f) / kBlock), (int)std::floor((cy + 0.5f) / kBlock),
                (int)std::floor((cz + 0.5f) / kBlock));
        if (b && b->size == kBlock)
            return coarse(cx, cy, cz);
        return at(cx, cy, cz, s);
    });
}

ClimateValue ClimateStore::sample(float x, float y, float z) const {
    const float ex = x + 0.5f, ey = y + 0.5f, ez = z + 0.5f;
    const int bx = (int)std::floor(ex / kBlock), by = (int)std::floor(ey / kBlock), bz = (int)std::floor(ez / kBlock);
    const Block *home = find(bx, by, bz);
    if (home && home->size < kBlock)
        return fine(x, y, z, home->size);
    ClimateValue v = coarse(x, y, z);
    // A wild block beside a claim's finer block: over the half block next
    // to it, blend towards the field at the finer size, which at the face
    // is exactly what the claim's side reads, so the two meet without a
    // step. The nearest such face decides.
    const float l[3] = {ex - bx * kBlock, ey - by * kBlock, ez - bz * kBlock};
    float best = 0;
    int size = 0;
    for (int axis = 0; axis < 3; ++axis)
        for (int side = 0; side < 2; ++side) {
            const float d = side ? kBlock - l[axis] : l[axis];
            const float w = 1.0f - d / (kBlock * 0.5f);
            if (w <= best)
                continue;
            int n[3] = {bx, by, bz};
            n[axis] += side ? 1 : -1;
            const Block *b = find(n[0], n[1], n[2]);
            if (b && b->size < kBlock) {
                best = w;
                size = b->size;
            }
        }
    if (size)
        v = mix(v, fine(x, y, z, size), best);
    return v;
}

void ClimateStore::build(const ClimateGrid &grid, std::vector<uint8_t> &rgba) const {
    rgba.assign((size_t)grid.nx * grid.ny * grid.nz * 4, 0);
    if (grid.nx <= 0 || grid.ny <= 0 || grid.nz <= 0)
        return;
    // Every block a texel's corners can reach: the grid's span and one
    // block beyond it each way.
    auto lo = [](float o) { return floor_div((int)std::floor(o + 0.5f), kBlock) - 1; };
    auto hi = [](float o, float span) { return floor_div((int)std::floor(o + span + 0.5f), kBlock) + 1; };
    m_dx0 = lo(grid.ox);
    m_dy0 = lo(grid.oy);
    m_dz0 = lo(grid.oz);
    m_dnx = hi(grid.ox, grid.nx * grid.cell) - m_dx0 + 1;
    m_dny = hi(grid.oy, grid.ny * grid.cell) - m_dy0 + 1;
    m_dnz = hi(grid.oz, grid.nz * grid.cell) - m_dz0 + 1;
    std::vector<const Block *> dense((size_t)m_dnx * m_dny * m_dnz, nullptr);
    for (const auto &kv : m_blocks) {
        const int bx = (int)(kv.first & ((1u << 21) - 1)) - (1 << 20);
        const int by = (int)((kv.first >> 21) & ((1u << 21) - 1)) - (1 << 20);
        const int bz = (int)((kv.first >> 42) & ((1u << 21) - 1)) - (1 << 20);
        const int x = bx - m_dx0, y = by - m_dy0, z = bz - m_dz0;
        if (x >= 0 && y >= 0 && z >= 0 && x < m_dnx && y < m_dny && z < m_dnz)
            dense[((size_t)z * m_dny + y) * m_dnx + x] = &kv.second;
    }
    std::vector<ClimateValue> means(dense.size());
    for (size_t i = 0; i < dense.size(); ++i)
        if (dense[i])
            means[i] = dense[i]->mean;
    m_dense = dense.data();
    m_means = means.data();
    // A block is plain when neither it nor a face neighbour has finer
    // cells: there sample is the 16-node field alone, done here straight
    // from the means.
    auto fine_at = [&](int x, int y, int z) {
        if (x < 0 || y < 0 || z < 0 || x >= m_dnx || y >= m_dny || z >= m_dnz)
            return false;
        const Block *b = dense[((size_t)z * m_dny + y) * m_dnx + x];
        return b && b->size < kBlock;
    };
    std::vector<uint8_t> plain(dense.size(), 0);
    for (int z = 0; z < m_dnz; ++z)
        for (int y = 0; y < m_dny; ++y)
            for (int x = 0; x < m_dnx; ++x)
                plain[((size_t)z * m_dny + y) * m_dnx + x] = !fine_at(x, y, z) && !fine_at(x - 1, y, z) &&
                        !fine_at(x + 1, y, z) && !fine_at(x, y - 1, z) && !fine_at(x, y + 1, z) &&
                        !fine_at(x, y, z - 1) && !fine_at(x, y, z + 1);
    auto mean_at = [&](int x, int y, int z) -> const ClimateValue * {
        if (x < 0 || y < 0 || z < 0 || x >= m_dnx || y >= m_dny || z >= m_dnz)
            return nullptr;
        return &means[((size_t)z * m_dny + y) * m_dnx + x];
    };
    size_t o = 0;
    for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
            for (int i = 0; i < grid.nx; ++i, o += 4) {
                const float x = grid.ox + (i + 0.5f) * grid.cell, y = grid.oy + (j + 0.5f) * grid.cell,
                            z = grid.oz + (k + 0.5f) * grid.cell;
                const int hx = (int)std::floor((x + 0.5f) / kBlock) - m_dx0;
                const int hy = (int)std::floor((y + 0.5f) / kBlock) - m_dy0;
                const int hz = (int)std::floor((z + 0.5f) / kBlock) - m_dz0;
                ClimateValue v;
                if (plain[((size_t)hz * m_dny + hy) * m_dnx + hx]) {
                    const float fx = (x + 0.5f) / kBlock - 0.5f, fy = (y + 0.5f) / kBlock - 0.5f,
                                fz = (z + 0.5f) / kBlock - 0.5f;
                    const float ix = std::floor(fx), iy = std::floor(fy), iz = std::floor(fz);
                    const float t[3] = {fx - ix, fy - iy, fz - iz};
                    const int bx = (int)ix - m_dx0, by = (int)iy - m_dy0, bz = (int)iz - m_dz0;
                    float weight = 0;
                    for (int c = 0; c < 8; ++c) {
                        const int dx = c & 1, dy = (c >> 1) & 1, dz = (c >> 2) & 1;
                        const ClimateValue *m = mean_at(bx + dx, by + dy, bz + dz);
                        if (!m || m->known <= 0)
                            continue;
                        const float w = (dx ? t[0] : 1 - t[0]) * (dy ? t[1] : 1 - t[1]) *
                                (dz ? t[2] : 1 - t[2]) * m->known;
                        v.temp += m->temp * w;
                        v.wet += m->wet * w;
                        v.hum += m->hum * w;
                        weight += w;
                    }
                    if (weight > 0) {
                        v.temp /= weight;
                        v.wet /= weight;
                        v.hum /= weight;
                    }
                    v.known = weight;
                } else {
                    v = sample(x, y, z);
                }
                if (v.known <= 0)
                    continue;
                const float k = std::min(v.known, 1.0f);
                rgba[o] = to_byte((v.temp - kClimateTempMin) / kClimateTempSpan * k);
                rgba[o + 1] = to_byte(v.wet * k);
                rgba[o + 2] = to_byte(v.hum * k);
                rgba[o + 3] = to_byte(k);
            }
    m_dense = nullptr;
    m_means = nullptr;
}

} // namespace goanna
