// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_trees.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <queue>

namespace goanna {

namespace {

// Six connected, not twenty six. Luanti crowns are dense enough that diagonal
// neighbours join trees standing a node apart, and a stand welded into one
// component is the thing this is trying not to draw.
constexpr int kNeighbours = 6;
const int kDx[kNeighbours] = {1, -1, 0, 0, 0, 0};
const int kDy[kNeighbours] = {0, 0, 1, -1, 0, 0};
const int kDz[kNeighbours] = {0, 0, 0, 0, 1, -1};

struct Column {
    int x = 0, z = 0;
    int foot = 0;          // lowest trunk voxel
    int top = 0;           // highest trunk voxel
    content_t wood = CONTENT_AIR;
    int voxels = 0;
};

// The trunks inside one component, as columns. A trunk is a run of wood in one
// x/z column; two runs in the same column are a tree standing on a log, which
// is one trunk for this purpose because only the foot is drawn from.
std::vector<Column> trunksOf(const TreeField &field, const std::vector<int> &label,
        int want, const v3s16 &lo, const v3s16 &hi) {
    std::map<std::pair<int, int>, Column> columns;
    for (int z = lo.Z; z <= hi.Z; ++z)
        for (int x = lo.X; x <= hi.X; ++x)
            for (int y = lo.Y; y <= hi.Y; ++y) {
                const size_t i = field.index(x, y, z);
                if (label[i] != want || !field.trunk[i])
                    continue;
                auto key = std::make_pair(x, z);
                auto it = columns.find(key);
                if (it == columns.end()) {
                    Column c;
                    c.x = x;
                    c.z = z;
                    c.foot = y;
                    c.top = y;
                    c.wood = field.content[i];
                    c.voxels = 1;
                    columns.emplace(key, c);
                } else {
                    it->second.foot = std::min(it->second.foot, y);
                    it->second.top = std::max(it->second.top, y);
                    ++it->second.voxels;
                }
            }

    // Adjacent wood columns are one trunk seen twice: a two by two jungle stem,
    // or a leaning trunk. Merge them and keep the tallest as the stem, so a
    // thick tree gets one impostor rather than four.
    std::vector<Column> out;
    std::vector<bool> taken(columns.size(), false);
    std::vector<Column> flat;
    flat.reserve(columns.size());
    for (auto &kv : columns)
        flat.push_back(kv.second);
    for (size_t i = 0; i < flat.size(); ++i) {
        if (taken[i])
            continue;
        // Breadth first over columns within one voxel of each other.
        std::vector<size_t> group{i};
        taken[i] = true;
        for (size_t g = 0; g < group.size(); ++g)
            for (size_t j = 0; j < flat.size(); ++j) {
                if (taken[j])
                    continue;
                if (std::abs(flat[group[g]].x - flat[j].x) <= 1 &&
                        std::abs(flat[group[g]].z - flat[j].z) <= 1) {
                    taken[j] = true;
                    group.push_back(j);
                }
            }
        Column merged = flat[group[0]];
        int sx = 0, sz = 0, n = 0;
        for (size_t j : group) {
            merged.foot = std::min(merged.foot, flat[j].foot);
            merged.top = std::max(merged.top, flat[j].top);
            merged.voxels += (j == group[0]) ? 0 : flat[j].voxels;
            sx += flat[j].x;
            sz += flat[j].z;
            ++n;
        }
        merged.x = sx / n;
        merged.z = sz / n;
        out.push_back(merged);
    }
    return out;
}

} // namespace

std::vector<TreeInstance> detectTrees(const TreeField &field, const TreeDetectOptions &opt,
        std::vector<TreeMask> *masks) {
    std::vector<TreeInstance> trees;
    const size_t n = (size_t)field.size.X * field.size.Y * field.size.Z;
    if (n == 0 || field.canopy.size() != n || field.trunk.size() != n ||
            field.content.size() != n || field.cell <= 0)
        return trees;

    std::vector<int> label(n, -1);
    int next = 0;
    std::vector<v3s16> lows, highs;
    std::vector<int> counts;

    std::queue<v3s16> open;
    for (int z = 0; z < field.size.Z; ++z)
        for (int y = 0; y < field.size.Y; ++y)
            for (int x = 0; x < field.size.X; ++x) {
                const size_t start = field.index(x, y, z);
                if (!field.canopy[start] || label[start] != -1)
                    continue;
                const int id = next++;
                v3s16 lo(x, y, z), hi(x, y, z);
                int count = 0;
                label[start] = id;
                open.push(v3s16(x, y, z));
                while (!open.empty()) {
                    const v3s16 p = open.front();
                    open.pop();
                    ++count;
                    lo.X = std::min(lo.X, p.X); hi.X = std::max(hi.X, p.X);
                    lo.Y = std::min(lo.Y, p.Y); hi.Y = std::max(hi.Y, p.Y);
                    lo.Z = std::min(lo.Z, p.Z); hi.Z = std::max(hi.Z, p.Z);
                    for (int d = 0; d < kNeighbours; ++d) {
                        const int nx = p.X + kDx[d], ny = p.Y + kDy[d], nz = p.Z + kDz[d];
                        if (!field.inside(nx, ny, nz))
                            continue;
                        const size_t ni = field.index(nx, ny, nz);
                        if (!field.canopy[ni] || label[ni] != -1)
                            continue;
                        label[ni] = id;
                        open.push(v3s16(nx, ny, nz));
                    }
                }
                lows.push_back(lo);
                highs.push_back(hi);
                counts.push_back(count);
            }

    // Whether anything else's canopy stands within one voxel of this one. A
    // component that touches another is part of a stand, and a stand at this
    // resolution is not separable into trees.
    auto crowded = [&](int id, const v3s16 &lo, const v3s16 &hi) {
        for (int z = lo.Z - 1; z <= hi.Z + 1; ++z)
            for (int y = lo.Y - 1; y <= hi.Y + 1; ++y)
                for (int x = lo.X - 1; x <= hi.X + 1; ++x) {
                    if (!field.inside(x, y, z))
                        continue;
                    const size_t i = field.index(x, y, z);
                    if (field.canopy[i] && label[i] != id)
                        return true;
                }
        return false;
    };

    const float cell = (float)field.cell;
    for (int id = 0; id < next; ++id) {
        if (counts[id] < opt.min_voxels)
            continue;
        const v3s16 lo = lows[id], hi = highs[id];
        if (opt.isolated_only && crowded(id, lo, hi))
            continue;
        std::vector<Column> stems = trunksOf(field, label, id, lo, hi);
        // More than one stem in one component is a stand whose crowns have
        // grown together. At node resolution that splits cleanly; at four it
        // does not, and the split produced a couple of lumps the size of half
        // the wood instead of the hundreds of trees actually standing there.
        if (opt.isolated_only && stems.size() > 1)
            continue;

        if (stems.empty()) {
            if (!opt.allow_trunkless)
                continue;
            Column c;
            c.x = (lo.X + hi.X) / 2;
            c.z = (lo.Z + hi.Z) / 2;
            c.foot = lo.Y;
            c.top = lo.Y;
            stems.push_back(c);
        }

        // Assign every canopy voxel of the component to its nearest stem, so a
        // stand touching at the leaves is split between its trunks instead of
        // becoming one enormous tree. With a single stem this is just the
        // component.
        std::vector<int> assigned(stems.size(), 0);
        std::vector<int> owner(n, -1);
        std::vector<v3s16> mlo(stems.size(), v3s16(32767, 32767, 32767));
        std::vector<v3s16> mhi(stems.size(), v3s16(-32768, -32768, -32768));
        std::vector<float> reach(stems.size(), 0.0f);
        std::vector<int> crown_top(stems.size(), 0);
        std::vector<std::map<content_t, int>> foliage(stems.size());
        // Light, gathered separately for the lower and upper half of each tree.
        const bool has_light = field.day.size() == n && field.night.size() == n;
        std::vector<long> day_lo(stems.size(), 0), day_hi(stems.size(), 0);
        std::vector<long> night_lo(stems.size(), 0), night_hi(stems.size(), 0);
        std::vector<int> count_lo(stems.size(), 0), count_hi(stems.size(), 0);
        const int mid_y = (lo.Y + hi.Y) / 2;
        for (int z = lo.Z; z <= hi.Z; ++z)
            for (int y = lo.Y; y <= hi.Y; ++y)
                for (int x = lo.X; x <= hi.X; ++x) {
                    const size_t i = field.index(x, y, z);
                    if (label[i] != id)
                        continue;
                    size_t best = 0;
                    float best_d = 1e30f;
                    for (size_t s = 0; s < stems.size(); ++s) {
                        const float dx = (float)(x - stems[s].x);
                        const float dz = (float)(z - stems[s].z);
                        // Plan distance decides, but not alone. A crown sits
                        // on top of its own trunk, so anything reaching well
                        // above a stem's head belongs to a taller neighbour:
                        // without this a short trunk beside a tall tree claimed
                        // its crown and measured forty nodes high.
                        const float above = (float)std::max(0, y - stems[s].top);
                        const float below = (float)std::max(0, stems[s].foot - y);
                        const float dy = (above + below) * 0.75f;
                        const float d = dx * dx + dz * dz + dy * dy;
                        if (d < best_d) {
                            best_d = d;
                            best = s;
                        }
                    }
                    owner[i] = (int)best;
                    ++assigned[best];
                    crown_top[best] = std::max(crown_top[best], y);
                    reach[best] = std::max(reach[best],
                            std::max(std::abs((float)(x - stems[best].x)),
                                    std::abs((float)(z - stems[best].z))));
                    mlo[best].X = std::min(mlo[best].X, (s16)x);
                    mlo[best].Y = std::min(mlo[best].Y, (s16)y);
                    mlo[best].Z = std::min(mlo[best].Z, (s16)z);
                    mhi[best].X = std::max(mhi[best].X, (s16)x);
                    mhi[best].Y = std::max(mhi[best].Y, (s16)y);
                    mhi[best].Z = std::max(mhi[best].Z, (s16)z);
                    if (!field.trunk[i])
                        ++foliage[best][field.content[i]];
                    if (has_light) {
                        if (y <= mid_y) {
                            day_lo[best] += field.day[i];
                            night_lo[best] += field.night[i];
                            ++count_lo[best];
                        } else {
                            day_hi[best] += field.day[i];
                            night_hi[best] += field.night[i];
                            ++count_hi[best];
                        }
                    }
                }

        for (size_t s = 0; s < stems.size(); ++s) {
            if (assigned[s] < opt.min_voxels)
                continue;
            // Reach is counted in voxels, and the crown's real edge lies
            // somewhere inside the outermost one, so widening by half a voxel
            // is right at one node and badly wrong at four. Measured against a
            // lone tree in Asuna: a crown of 3.5 nodes read as 6.0 at cell 4,
            // and as 4.5 with the bias taken out.
            const float radius = (float)reach[s] * cell + 0.5f;
            if (radius > opt.max_radius)
                continue;   // a closed canopy: the aggregate tier draws this
            const float height = (float)(crown_top[s] - stems[s].foot + 1) * cell;
            if (height < opt.min_height)
                continue;

            TreeInstance t;
            t.base = v3f(
                    (float)field.origin.X + ((float)stems[s].x + 0.5f) * cell,
                    (float)field.origin.Y + (float)stems[s].foot * cell,
                    (float)field.origin.Z + ((float)stems[s].z + 0.5f) * cell);
            t.height = height;
            t.radius = radius;
            t.trunk = stems[s].wood;
            t.voxels = assigned[s];
            t.cell = (uint8_t)std::min(255, field.cell);
            if (has_light) {
                // A half with nothing in it borrows the other's, which is what
                // a tree whose crown starts at the ground should read as.
                const int lo_n = count_lo[s] > 0 ? count_lo[s] : 1;
                const int hi_n = count_hi[s] > 0 ? count_hi[s] : 1;
                const long base_day = count_lo[s] > 0 ? day_lo[s] / lo_n : day_hi[s] / hi_n;
                const long top_day = count_hi[s] > 0 ? day_hi[s] / hi_n : day_lo[s] / lo_n;
                const long base_night = count_lo[s] > 0 ? night_lo[s] / lo_n : night_hi[s] / hi_n;
                const long top_night = count_hi[s] > 0 ? night_hi[s] / hi_n : night_lo[s] / lo_n;
                t.day_base = (uint8_t)std::min<long>(255, base_day);
                t.day_top = (uint8_t)std::min<long>(255, top_day);
                t.night_base = (uint8_t)std::min<long>(255, base_night);
                t.night_top = (uint8_t)std::min<long>(255, top_night);
            }
            int most = 0;
            for (const auto &kv : foliage[s])
                if (kv.second > most) {
                    most = kv.second;
                    t.leaves = kv.first;
                }
            trees.push_back(t);

            if (masks) {
                TreeMask m;
                m.cell = field.cell;
                m.size = v3s16(mhi[s].X - mlo[s].X + 1, mhi[s].Y - mlo[s].Y + 1,
                        mhi[s].Z - mlo[s].Z + 1);
                m.origin = v3s16(
                        field.origin.X + mlo[s].X * field.cell,
                        field.origin.Y + mlo[s].Y * field.cell,
                        field.origin.Z + mlo[s].Z * field.cell);
                m.content.assign((size_t)m.size.X * m.size.Y * m.size.Z, CONTENT_AIR);
                for (int z = mlo[s].Z; z <= mhi[s].Z; ++z)
                    for (int y = mlo[s].Y; y <= mhi[s].Y; ++y)
                        for (int x = mlo[s].X; x <= mhi[s].X; ++x) {
                            const size_t i = field.index(x, y, z);
                            if (owner[i] != (int)s)
                                continue;
                            m.content[m.index(x - mlo[s].X, y - mlo[s].Y, z - mlo[s].Z)] =
                                    field.content[i];
                        }
                masks->push_back(std::move(m));
            }
        }
    }

    return trees;
}

} // namespace goanna
