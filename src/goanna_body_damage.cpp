// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_body_damage.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>
#include <tuple>

namespace goanna {

namespace {

bool fail(std::string *error, const std::string &what) {
    if (error)
        *error = what;
    return false;
}

// Runs {first, count, ...} of 1-based cell numbers, into a per-cell mask.
bool runsInto(const Json::Value &runs, std::vector<uint8_t> &mask, bool *any = nullptr) {
    if (runs.isNull())
        return true;
    if (!runs.isArray() || runs.size() % 2)
        return false;
    for (Json::ArrayIndex i = 0; i + 1 < runs.size(); i += 2) {
        int64_t a = runs[i].asInt64(), c = runs[i + 1].asInt64();
        if (a < 1 || c < 1 || a - 1 + c > (int64_t)mask.size())
            return false;
        for (int64_t j = a - 1; j < a - 1 + c; ++j)
            mask[j] = 1;
        if (any)
            *any = true;
    }
    return true;
}

bool runsList(const Json::Value &runs, size_t count, std::vector<int> &out) {
    if (runs.isNull())
        return true;
    if (!runs.isArray() || runs.size() % 2)
        return false;
    for (Json::ArrayIndex i = 0; i + 1 < runs.size(); i += 2) {
        int64_t a = runs[i].asInt64(), c = runs[i + 1].asInt64();
        if (a < 1 || c < 1 || a - 1 + c > (int64_t)count)
            return false;
        for (int64_t j = a - 1; j < a - 1 + c; ++j)
            out.push_back((int)j);
    }
    return true;
}

bool vec3(const Json::Value &v, double out[3]) {
    if (!v.isArray() || v.size() != 3)
        return false;
    for (int a = 0; a < 3; ++a) {
        if (!v[a].isNumeric())
            return false;
        out[a] = v[a].asDouble();
    }
    return true;
}

// mesh.lua's quad(): the face's four corners, in its winding.
void quad(const double lo[3], const double hi[3], int face, double out[4][3]) {
    const double x = lo[0], y = lo[1], z = lo[2], X = hi[0], Y = hi[1], Z = hi[2];
    const double q[6][4][3] = {
            {{X, Y, Z}, {X, Y, z}, {X, y, z}, {X, y, Z}},
            {{x, Y, z}, {x, Y, Z}, {x, y, Z}, {x, y, z}},
            {{x, Y, z}, {X, Y, z}, {X, Y, Z}, {x, Y, Z}},
            {{x, y, Z}, {X, y, Z}, {X, y, z}, {x, y, z}},
            {{x, Y, Z}, {X, Y, Z}, {X, y, Z}, {x, y, Z}},
            {{X, Y, z}, {x, Y, z}, {x, y, z}, {X, y, z}},
    };
    std::memcpy(out, q[face - 1], sizeof(q[0]));
}

const char *kFaceNames[6] = {"east", "west", "up", "down", "south", "north"};
const int kNormals[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
const int kFaceAxis[6] = {1, 1, 2, 2, 3, 3};

void putU16(std::string &s, uint32_t n) {
    s.push_back((char)(n & 0xff));
    s.push_back((char)((n >> 8) & 0xff));
}
void putU32(std::string &s, uint32_t n) {
    for (int i = 0; i < 4; ++i)
        s.push_back((char)((n >> (8 * i)) & 0xff));
}
void putF32(std::string &s, double v) {
    float f = (float)v;
    uint32_t u;
    std::memcpy(&u, &f, 4);
    putU32(s, u);
}

// One stream of generated quads drawn with one material (mesh.lua stream()).
struct Stream {
    std::string position, normal, uv, joint, weight;
    std::vector<uint32_t> index;
    uint32_t count = 0;
    int material = 0;
    double minp[3] = {HUGE_VAL, HUGE_VAL, HUGE_VAL}, maxp[3] = {-HUGE_VAL, -HUGE_VAL, -HUGE_VAL};
};

void put(Stream &st, const double v[4][3], int face, const double uv[4][2], int joint, double unit) {
    for (int i = 0; i < 4; ++i) {
        for (int a = 0; a < 3; ++a) {
            double p = v[i][a] / unit;
            putF32(st.position, p);
            putF32(st.normal, kNormals[face - 1][a]);
            st.minp[a] = std::min(st.minp[a], p);
            st.maxp[a] = std::max(st.maxp[a], p);
        }
        putF32(st.uv, uv[i][0]);
        putF32(st.uv, uv[i][1]);
        putU16(st.joint, joint);
        putU16(st.joint, 0);
        putU16(st.joint, 0);
        putU16(st.joint, 0);
        putF32(st.weight, 1);
        putF32(st.weight, 0);
        putF32(st.weight, 0);
        putF32(st.weight, 0);
    }
    for (int o : {0, 2, 1, 0, 3, 2})
        st.index.push_back(st.count + o);
    st.count += 4;
}

// D.cells' output: one cell and its exposed faces' materials ("" none).
struct Cell {
    int j;
    int c[3];
    int box;
    std::string faces[6];
};

bool isProtected(const DamagePart &p, const DamagePartState *s, int j) {
    if (p.scaffold[j])
        return true;
    for (const auto &path : p.paths) {
        if (s && s->released.count(path.first))
            continue;
        if (std::binary_search(path.second.begin(), path.second.end(), j))
            return true;
    }
    return false;
}

std::vector<Cell> cellsOf(const DamagePart &p, const DamagePartState *s) {
    std::vector<Cell> out;
    const int count = (int)p.place.size();
    std::vector<uint8_t> locked(count);
    for (int j = 0; j < count; ++j)
        locked[j] = isProtected(p, s, j);
    auto gone = [&](int j) {
        return j < 0 || (s && (s->removed.size() == (size_t)count && s->removed[j])) || (s && j == s->fracture);
    };
    for (int j = 0; j < count; ++j) {
        if ((s && !s->removed.empty() && s->removed[j]) || (s && j == s->fracture))
            continue;
        Cell c;
        c.j = j;
        p.coords(j, c.c[0], c.c[1], c.c[2]);
        c.box = p.box[j];
        for (int face = 1; face <= 6; ++face) {
            int nj = p.neighbour(j, face);
            if (nj < 0 || gone(nj)) {
                if (nj < 0)
                    c.faces[face - 1] = "exterior";
                else if (locked[j])
                    c.faces[face - 1] = "support";
                else if (p.shell[j] >= 0)
                    c.faces[face - 1] = "cut_support:" + p.shell_materials[p.shell[j]];
                else
                    c.faces[face - 1] = "interior";
            }
        }
        out.push_back(std::move(c));
    }
    return out;
}

// mesh.lua stump(): the cut on the surface that survives, near the child's
// socket.
int stump(const DamagePart &grid, std::vector<Cell> &cells, const DamagePart &child,
        const DamagePartState *s) {
    const double *anchor = child.origin;
    const Cell *best = nullptr;
    int best_face = 0;
    double best_distance = 0, best_point[3] = {0, 0, 0};
    for (const Cell &cell : cells)
        for (int face = 1; face <= 6; ++face) {
            if (cell.faces[face - 1].empty())
                continue;
            int axis = (face + 1) / 2;
            double point[3], distance = 0;
            for (int a = 1; a <= 3; ++a) {
                double lo = grid.lo[a - 1] + cell.c[a - 1] * grid.step;
                if (a == axis)
                    point[a - 1] = lo + (face % 2 == 1 ? grid.step : 0);
                else
                    point[a - 1] = std::max(lo, std::min(lo + grid.step, anchor[a - 1]));
                distance += (point[a - 1] - anchor[a - 1]) * (point[a - 1] - anchor[a - 1]);
            }
            if (!best || distance < best_distance) {
                best_distance = distance;
                best = &cell;
                best_face = face;
                std::memcpy(best_point, point, sizeof(point));
            }
        }
    if (!best)
        return 0;
    double thickness = HUGE_VAL;
    for (int a = 0; a < 3; ++a)
        thickness = std::min(thickness, child.hi[a] - child.lo[a]);
    double radius = std::max(grid.step * .75, std::min(2.0, thickness / 2));
    int count = 0;
    int axis = (best_face + 1) / 2;
    auto material = [&](const std::string &k) {
        auto it = child.materials.find(k);
        return it == child.materials.end() ? std::string() : it->second;
    };
    for (Cell &cell : cells) {
        if (cell.faces[best_face - 1].empty())
            continue;
        double distance = 0;
        for (int a = 1; a <= 3; ++a) {
            double off = a == axis ? (best_face % 2 == 1 ? 1 : 0) : .5;
            double point = grid.lo[a - 1] + (cell.c[a - 1] + off) * grid.step;
            distance += (point - best_point[a - 1]) * (point - best_point[a - 1]);
        }
        if (&cell == best || distance <= radius * radius + 1e-9) {
            std::string support = isProtected(grid, s, cell.j) ? material("support") : std::string();
            cell.faces[best_face - 1] = !support.empty() ? "cut_support:" + support
                                                          : "cut_interior:" + material("interior");
            ++count;
        }
    }
    return count;
}

template <class Emit>
void merged(const DamagePart &grid, const std::vector<Cell> &cells, Emit emit) {
    struct Group {
        int face, axis, axes[2], plane, source;
        std::string material;
        std::set<std::pair<int, int>> rows;
        std::vector<std::pair<int, int>> points;
    };
    std::map<std::tuple<int, int, int, std::string>, size_t> index;
    std::vector<Group> groups;
    for (const Cell &cell : cells)
        for (int face = 1; face <= 6; ++face) {
            const std::string &material = cell.faces[face - 1];
            if (material.empty() || material == "-")
                continue;
            int axis = (face + 1) / 2;
            int axes[2], n = 0;
            for (int a = 1; a <= 3; ++a)
                if (a != axis)
                    axes[n++] = a;
            int plane = cell.c[axis - 1] + (face % 2 == 1 ? 1 : 0);
            auto key = std::make_tuple(face, plane, cell.box, material);
            auto it = index.find(key);
            size_t g;
            if (it == index.end()) {
                g = groups.size();
                index[key] = g;
                Group grp;
                grp.face = face;
                grp.axis = axis;
                grp.axes[0] = axes[0];
                grp.axes[1] = axes[1];
                grp.plane = plane;
                grp.source = cell.box;
                grp.material = material;
                groups.push_back(std::move(grp));
            } else {
                g = it->second;
            }
            int x = cell.c[axes[0] - 1], y = cell.c[axes[1] - 1];
            groups[g].rows.insert({x, y});
            groups[g].points.push_back({x, y});
        }
    for (Group &g : groups) {
        std::sort(g.points.begin(), g.points.end());
        auto has = [&](int x, int y) { return g.rows.count({x, y}) > 0; };
        for (const auto &pt : g.points) {
            int x = pt.first, y = pt.second;
            if (!has(x, y))
                continue;
            int width = 1, height = 1;
            while (has(x + width, y))
                ++width;
            while (true) {
                bool full = true;
                for (int q = x; q < x + width; ++q)
                    if (!has(q, y + height)) {
                        full = false;
                        break;
                    }
                if (!full)
                    break;
                ++height;
            }
            for (int q = x; q < x + width; ++q)
                for (int r = y; r < y + height; ++r)
                    g.rows.erase({q, r});
            double lo[3], hi[3];
            int ilo[3], ihi[3];
            ilo[g.axis - 1] = g.plane - (g.face % 2 == 1 ? 1 : 0);
            ihi[g.axis - 1] = ilo[g.axis - 1] + 1;
            ilo[g.axes[0] - 1] = x;
            ilo[g.axes[1] - 1] = y;
            ihi[g.axes[0] - 1] = x + width;
            ihi[g.axes[1] - 1] = y + height;
            for (int a = 0; a < 3; ++a) {
                lo[a] = grid.lo[a] + ilo[a] * grid.step;
                hi[a] = grid.lo[a] + ihi[a] * grid.step;
            }
            emit(lo, hi, g.face, g.source, g.material);
        }
    }
}

// mesh.lua shell(): one layer quad over a hurt component, cut on its grid.
template <class Emit>
int shellQuad(const DamagePart &grid, const DamagePartState *s, const Json::Value &q, Emit emit) {
    double qlo[3], qhi[3];
    vec3(q["lo"], qlo);
    vec3(q["hi"], qhi);
    bool hurt = s && s->any_removed;
    if (!hurt || !q.isMember("b") || q["b"].isNull()) {
        emit(qlo, qhi);
        return 1;
    }
    int f = q["f"].asInt();
    int axis = kFaceAxis[f - 1];
    int t1 = axis == 1 ? 2 : 1, t2 = axis == 3 ? 2 : 3;
    double blo[3], bhi[3];
    vec3(q["b"][0], blo);
    vec3(q["b"][1], bhi);
    auto edges = [&](int t) {
        std::vector<double> out{qlo[t - 1]};
        int k = (int)std::floor((qlo[t - 1] - grid.lo[t - 1]) / grid.step) + 1;
        while (true) {
            double x = grid.lo[t - 1] + k * grid.step;
            if (x >= qhi[t - 1] - 1e-6)
                break;
            if (x > qlo[t - 1] + 1e-6)
                out.push_back(x);
            ++k;
        }
        out.push_back(qhi[t - 1]);
        return out;
    };
    std::vector<double> e1 = edges(t1), e2 = edges(t2);
    double depth = std::min(grid.step / 2, (bhi[axis - 1] - blo[axis - 1]) / 2);
    double inward = f % 2 == 1 ? bhi[axis - 1] - depth : blo[axis - 1] + depth;
    auto clamp = [](double v, double lo, double hi) { return std::max(lo + 1e-3, std::min(hi - 1e-3, v)); };
    int ni = (int)e1.size() - 1, nj = (int)e2.size() - 1;
    std::vector<std::vector<char>> keep(ni, std::vector<char>(nj, 1));
    bool cut = false;
    for (int i = 0; i < ni; ++i)
        for (int j = 0; j < nj; ++j) {
            double p[3];
            p[axis - 1] = inward;
            p[t1 - 1] = clamp((e1[i] + e1[i + 1]) / 2, blo[t1 - 1], bhi[t1 - 1]);
            p[t2 - 1] = clamp((e2[j] + e2[j + 1]) / 2, blo[t2 - 1], bhi[t2 - 1]);
            int c[3];
            bool inside = true;
            for (int a = 0; a < 3; ++a) {
                c[a] = (int)std::floor((p[a] - grid.lo[a]) / grid.step);
                if (c[a] < 0 || c[a] >= grid.n[a])
                    inside = false;
            }
            bool gone = false;
            if (inside) {
                int cell = grid.dense[c[0] + grid.n[0] * (c[1] + grid.n[1] * c[2])] - 1;
                gone = cell >= 0 && s->removed[cell];
            }
            keep[i][j] = !gone;
            cut = cut || gone;
        }
    if (!cut) {
        emit(qlo, qhi);
        return 1;
    }
    int n = 0;
    for (int i = 0; i < ni; ++i)
        for (int j = 0; j < nj; ++j) {
            if (!keep[i][j])
                continue;
            int w = 1;
            while (j + w < nj && keep[i][j + w])
                ++w;
            int h = 1;
            while (i + h < ni) {
                bool full = true;
                for (int q2 = j; q2 < j + w; ++q2)
                    if (!keep[i + h][q2]) {
                        full = false;
                        break;
                    }
                if (!full)
                    break;
                ++h;
            }
            for (int r = i; r < i + h; ++r)
                for (int q2 = j; q2 < j + w; ++q2)
                    keep[r][q2] = 0;
            double lo[3] = {qlo[0], qlo[1], qlo[2]}, hi[3] = {qhi[0], qhi[1], qhi[2]};
            lo[t1 - 1] = e1[i];
            hi[t1 - 1] = e1[i + h];
            lo[t2 - 1] = e2[j];
            hi[t2 - 1] = e2[j + w];
            emit(lo, hi);
            ++n;
        }
    return n;
}

const char *kB64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

} // namespace

std::string damageBase64Decode(const std::string &in) {
    static int8_t table[256];
    static bool ready = false;
    if (!ready) {
        std::memset(table, -1, sizeof(table));
        for (int i = 0; i < 64; ++i)
            table[(unsigned char)kB64[i]] = (int8_t)i;
        ready = true;
    }
    std::string out;
    out.reserve(in.size() * 3 / 4);
    uint32_t acc = 0;
    int bits = 0;
    for (unsigned char c : in) {
        int8_t v = table[c];
        if (v < 0)
            continue;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back((char)((acc >> bits) & 0xff));
        }
    }
    return out;
}

int DamagePart::neighbour(int j, int face) const {
    int x, y, z;
    coords(j, x, y, z);
    int g = place[j];
    int nj = 0;
    switch (face) {
    case 1: nj = x + 1 < n[0] ? dense[g + 1] : 0; break;
    case 2: nj = x > 0 ? dense[g - 1] : 0; break;
    case 3: nj = y + 1 < n[1] ? dense[g + n[0]] : 0; break;
    case 4: nj = y > 0 ? dense[g - n[0]] : 0; break;
    case 5: nj = z + 1 < n[2] ? dense[g + n[0] * n[1]] : 0; break;
    default: nj = z > 0 ? dense[g - n[0] * n[1]] : 0; break;
    }
    return nj - 1;
}

bool parseDamageForm(const Json::Value &v, DamageForm &out, std::string *error) {
    if (!v.isObject() || v["v"].asInt() != 1 || v["kind"].asString() != "form")
        return fail(error, "not a version 1 form");
    out = DamageForm();
    out.version = 1;
    out.key = v["key"].asString();
    out.id = v["id"].asString();
    out.model = v["model"].asString();
    out.texture = v["texture"].asString();
    out.source = v["source"];
    if (!v["order"].isArray() || !v["parts"].isObject() || !out.source.isObject())
        return fail(error, "form needs order, parts and source");
    for (const auto &id : v["order"])
        out.order.push_back(id.asString());
    for (const std::string &id : out.order) {
        const Json::Value &p = v["parts"][id];
        if (!p.isObject())
            return fail(error, "form part missing: " + id);
        DamagePart part;
        part.id = id;
        part.parent = p["parent"].asString();
        part.socket = p["socket"].asString();
        part.bone = p["bone"].asString();
        part.mode = p["mode"].asString();
        if (p["materials"].isObject())
            for (const auto &k : p["materials"].getMemberNames())
                part.materials[k] = p["materials"][k].asString();
        vec3(p["origin"], part.origin);
        for (const auto &b : p["boxes"]) {
            DamagePart::Box box;
            box.name = b["name"].asString();
            if (!vec3(b["lo"], box.lo) || !vec3(b["hi"], box.hi))
                return fail(error, "bad box in " + id);
            part.boxes.push_back(box);
        }
        const Json::Value &g = p["grid"];
        if (!vec3(g["lo"], part.lo) || !vec3(g["hi"], part.hi) || !g["n"].isArray() || g["n"].size() != 3)
            return fail(error, "bad grid in " + id);
        part.step = g["step"].asDouble();
        int64_t total = 1;
        for (int a = 0; a < 3; ++a) {
            part.n[a] = g["n"][a].asInt();
            if (part.n[a] <= 0)
                return fail(error, "bad grid size in " + id);
            total *= part.n[a];
        }
        if (total > 32768 || part.step <= 0)
            return fail(error, "grid over budget in " + id);
        size_t count = g["count"].asUInt();
        part.dense.assign((size_t)total, 0);
        const Json::Value &cells = g["cells"];
        for (Json::ArrayIndex i = 0; i + 1 < cells.size(); i += 2) {
            int64_t a = cells[i].asInt64(), c = cells[i + 1].asInt64();
            if (a < 0 || c < 1 || a + c > total)
                return fail(error, "bad cell run in " + id);
            for (int64_t q = a; q < a + c; ++q) {
                part.place.push_back((int)q);
                part.dense[q] = (int)part.place.size();
            }
        }
        const Json::Value &boxes = g["box"];
        for (Json::ArrayIndex i = 0; i + 1 < boxes.size(); i += 2)
            for (int64_t q = 0; q < boxes[i + 1].asInt64(); ++q)
                part.box.push_back(boxes[i].asInt());
        if (part.place.size() != count || part.box.size() != count)
            return fail(error, "cell count mismatch in " + id);
        for (int b : part.box)
            if (b < 1 || b > (int)part.boxes.size())
                return fail(error, "cell box out of range in " + id);
        part.scaffold.assign(count, 0);
        if (!runsInto(g["scaffold"], part.scaffold))
            return fail(error, "bad scaffold in " + id);
        if (g["paths"].isObject())
            for (const auto &socket : g["paths"].getMemberNames()) {
                std::vector<int> list;
                if (!runsList(g["paths"][socket], count, list))
                    return fail(error, "bad path in " + id);
                std::sort(list.begin(), list.end());
                part.paths[socket] = std::move(list);
            }
        part.shell.assign(count, -1);
        for (const auto &s : g["shells"]) {
            std::vector<int> list;
            if (!runsList(s["c"], count, list))
                return fail(error, "bad shell in " + id);
            int index = (int)part.shell_materials.size();
            part.shell_materials.push_back(s["m"].asString());
            for (int j : list)
                part.shell[j] = index;
        }
        out.cells += count;
        out.parts[id] = std::move(part);
    }
    return true;
}

bool applyDamageParts(const DamageForm &form, const Json::Value &parts, bool full, DamageState &state,
        std::string *error) {
    if (full)
        state.parts.clear();
    if (parts.isNull())
        return true;
    if (!parts.isObject())
        return fail(error, "parts must be an object");
    for (const auto &id : parts.getMemberNames()) {
        auto it = form.parts.find(id);
        if (it == form.parts.end())
            return fail(error, "unknown part " + id);
        const Json::Value &p = parts[id];
        if (p.isNull() || (p.isObject() && p.empty()) || (p.isArray() && p.empty())) {
            state.parts.erase(id);
            continue;
        }
        DamagePartState s;
        if (p["s"].asInt() == 1) {
            s.severed = true;
        } else {
            s.removed.assign(it->second.place.size(), 0);
            if (!runsInto(p["x"], s.removed, &s.any_removed))
                return fail(error, "bad removed runs in " + id);
            for (const auto &r : p["rel"])
                s.released.insert(r.asString());
            if (p.isMember("f") && !p["f"].isNull()) {
                int f = p["f"].asInt() - 1;
                if (f < 0 || f >= (int)it->second.place.size())
                    return fail(error, "bad fracture in " + id);
                s.fracture = f;
            }
        }
        state.parts[id] = std::move(s);
    }
    return true;
}

bool loadDamageBase(const std::string &text, DamageBase &out, std::string *error) {
    Json::CharReaderBuilder b;
    std::string errs;
    std::unique_ptr<Json::CharReader> reader(b.newCharReader());
    if (!reader->parse(text.data(), text.data() + text.size(), &out.gltf, &errs))
        return fail(error, "base glTF does not parse: " + errs);
    Json::Value &buffers = out.gltf["buffers"];
    if (!buffers.isArray() || buffers.size() != 1)
        return fail(error, "base glTF needs one buffer");
    std::string uri = buffers[0]["uri"].asString();
    size_t comma = uri.find(',');
    if (uri.compare(0, 5, "data:") != 0 || comma == std::string::npos)
        return fail(error, "base buffer is not a data URI");
    out.bin = damageBase64Decode(uri.substr(comma + 1));
    buffers[0].removeMember("uri");
    // The pieces damageGlb splices.
    Json::StreamWriterBuilder w;
    w["indentation"] = "";
    w["precision"] = 17;
    auto items = [&](const Json::Value &array) {
        std::string t = Json::writeString(w, array.isArray() ? array : Json::Value(Json::arrayValue));
        return t.size() >= 2 ? t.substr(1, t.size() - 2) : std::string();
    };
    const Json::Value &meshes = out.gltf["meshes"];
    if (!meshes.isArray() || meshes.empty())
        return fail(error, "base glTF has no mesh");
    out.accessor_count = out.gltf["accessors"].size();
    out.view_count = out.gltf["bufferViews"].size();
    out.accessors = items(out.gltf["accessors"]);
    out.views = items(out.gltf["bufferViews"]);
    Json::Value mesh0 = meshes[0];
    mesh0.removeMember("primitives");
    out.mesh0 = Json::writeString(w, mesh0);
    out.mesh0.pop_back(); // the closing brace
    Json::Value others(Json::arrayValue);
    for (Json::ArrayIndex i = 1; i < meshes.size(); ++i)
        others.append(meshes[i]);
    out.other_meshes = items(others);
    Json::Value rest = out.gltf;
    for (const char *k : {"accessors", "bufferViews", "buffers", "meshes"})
        rest.removeMember(k);
    // An empty top-level array is invalid glTF and the loader refuses the
    // whole model (a model with no clips was written with
    // "animations": []); leave such arrays out.
    for (const auto &k : rest.getMemberNames())
        if (rest[k].isArray() && rest[k].empty())
            rest.removeMember(k);
    out.rest = Json::writeString(w, rest);
    out.rest.pop_back();
    // Only the pieces are needed from here on.
    out.gltf = Json::Value();
    return true;
}

bool buildDamageMesh(const DamageForm &form, const DamageBase &base, const DamageState &state, DamageMesh &out,
        std::string *error) {
    const Json::Value &src = form.source;
    const double width = src["width"].asDouble(), height = src["height"].asDouble();
    const double unit = src["units_per_node"].isNumeric() ? src["units_per_node"].asDouble() : 16;
    if (!(width > 0 && height > 0 && unit > 0))
        return fail(error, "atlas dimensions required");
    out = DamageMesh();
    out.primitives = Json::Value(Json::arrayValue);
    out.accessors = Json::Value(Json::arrayValue);
    out.views = Json::Value(Json::arrayValue);
    Json::Value &primitives = out.primitives;
    const Json::Value &bones = src["bones"];
    const Json::Value &locations = src["locations"];
    const Json::Value &patches = src["patches"];
    const bool patch_size = src.isMember("patch_size") && !src["patch_size"].isNull();
    const double psize = patch_size ? src["patch_size"].asDouble() : 0;
    Stream body;
    body.material = src["material"].asInt();
    std::vector<Stream> layer_streams;

    std::map<std::string, bool> missing;
    std::map<std::string, std::vector<const DamagePart *>> cuts;
    for (const std::string &id : form.order) {
        const DamagePart &part = form.parts.at(id);
        auto r = state.parts.find(id);
        bool m = (r != state.parts.end() && r->second.severed) || (!part.parent.empty() && missing[part.parent]);
        missing[id] = m;
        if (m && !part.parent.empty() && !missing[part.parent])
            cuts[part.parent].push_back(&part);
    }
    std::string err;
    auto append_quad = [&](const DamagePart &part, const double lo[3], const double hi[3], int face, int box_index,
                               const std::string &material) -> bool {
        const DamagePart::Box &box = part.boxes[box_index - 1];
        if (material == "exterior" && !locations.isMember(box.name)) {
            // Whole thin parts' carving envelopes and attachment cores have
            // no authored skin (mesh.lua: never invent an exterior).
            bool envelope = box.name.size() > 9 && box.name.compare(box.name.size() - 9, 9, "_envelope") == 0;
            bool core = box.name.find("_core_") != std::string::npos;
            if (!envelope && !core) {
                err = "box UVs missing: " + box.name;
                return false;
            }
            return true;
        }
        ++out.generated_quads;
        double v[4][3];
        quad(lo, hi, face, v);
        double uv[4][2];
        if (material == "exterior") {
            const Json::Value &rect = locations[box.name][kFaceNames[face - 1]];
            if (!rect.isArray() || rect.size() < 4) {
                err = "face UVs missing: " + box.name;
                return false;
            }
            double original[4][3];
            quad(box.lo, box.hi, face, original);
            double du[3], dv[3], uu = 0, vv = 0;
            for (int a = 0; a < 3; ++a) {
                du[a] = original[1][a] - original[0][a];
                dv[a] = original[3][a] - original[0][a];
                uu += du[a] * du[a];
                vv += dv[a] * dv[a];
            }
            if (!(uu > 0 && vv > 0)) {
                err = "degenerate source UV face";
                return false;
            }
            const double r0 = rect[0].asDouble(), r1 = rect[1].asDouble(), r2 = rect[2].asDouble(),
                         r3 = rect[3].asDouble();
            for (int i = 0; i < 4; ++i) {
                double u = 0, w = 0;
                for (int a = 0; a < 3; ++a) {
                    double d = v[i][a] - original[0][a];
                    u += d * du[a];
                    w += d * dv[a];
                }
                uv[i][0] = (r0 + (r2 - r0) * u / uu) / width;
                uv[i][1] = (r1 + (r3 - r1) * w / vv) / height;
            }
        } else {
            std::string role, substance;
            bool cut = false;
            if (material.compare(0, 4, "cut_") == 0) {
                size_t colon = material.find(':');
                if (colon != std::string::npos && colon > 4 && colon + 1 < material.size()) {
                    bool letters = true;
                    for (size_t i = 4; i < colon; ++i)
                        letters = letters && std::isalpha((unsigned char)material[i]);
                    if (letters) {
                        role = material.substr(4, colon - 4);
                        substance = material.substr(colon + 1);
                        cut = true;
                    }
                }
            }
            bool have_substance = cut;
            if (!cut) {
                role = material == "support" ? "support" : "interior";
                auto it = part.materials.find(role);
                have_substance = it != part.materials.end();
                if (have_substance)
                    substance = it->second;
                if (material == "horn") {
                    substance = "horn";
                    have_substance = true;
                }
            }
            std::string fallback = have_substance && substance == "horn" ? "horn" : role;
            const Json::Value *rect = nullptr;
            if (have_substance && patches.isMember(substance))
                rect = &patches[substance];
            else if (patches.isMember(fallback))
                rect = &patches[fallback];
            if (!rect || !rect->isArray() || rect->size() < 4) {
                err = "material patch missing: " + substance;
                return false;
            }
            const double r0 = (*rect)[0].asDouble(), r1 = (*rect)[1].asDouble(), r2 = (*rect)[2].asDouble(),
                         r3 = (*rect)[3].asDouble();
            if (patch_size) {
                int axis = kFaceAxis[face - 1];
                int a = axis == 1 ? 3 : 1, b = axis == 2 ? 3 : 2;
                double top = part.lo[1] + std::ceil((part.hi[1] - part.lo[1]) / part.step) * part.step;
                for (int i = 0; i < 4; ++i) {
                    double u = v[i][a - 1] - part.lo[a - 1];
                    double w = b == 2 ? top - v[i][1] : v[i][b - 1] - part.lo[b - 1];
                    if (!(u >= -1e-6 && w >= -1e-6 && u <= psize + 1e-6 && w <= psize + 1e-6)) {
                        err = "component larger than its wound texture";
                        return false;
                    }
                    uv[i][0] = (r0 + u) / width;
                    uv[i][1] = (r1 + w) / height;
                }
            } else {
                const double c[4][2] = {{r0, r1}, {r2, r1}, {r2, r3}, {r0, r3}};
                for (int i = 0; i < 4; ++i) {
                    uv[i][0] = c[i][0] / width;
                    uv[i][1] = c[i][1] / height;
                }
            }
        }
        const std::string &bone = part.bone.empty() ? part.id : part.bone;
        if (!bones.isMember(bone)) {
            err = "skin joint missing: " + bone;
            return false;
        }
        put(body, v, face, uv, bones[bone].asInt(), unit);
        return true;
    };

    for (const std::string &id : form.order) {
        const DamagePart &part = form.parts.at(id);
        auto r = state.parts.find(id);
        const DamagePartState *s = r == state.parts.end() ? nullptr : &r->second;
        bool has_cuts = cuts.count(id) > 0;
        if (missing[id]) {
            ++out.severed;
        } else if (has_cuts || (s && (s->any_removed || s->fracture >= 0))) {
            ++out.damaged;
            if (has_cuts && part.mode == "whole" && !(s && s->any_removed)) {
                if (!src["parts"].isMember(id))
                    return fail(error, "intact primitive missing: " + id);
                primitives.append(src["parts"][id]);
            }
            std::vector<Cell> cells = cellsOf(part, s);
            if (has_cuts)
                for (const DamagePart *child : cuts[id])
                    stump(part, cells, *child, s);
            bool ok = true;
            merged(part, cells, [&](const double lo[3], const double hi[3], int face, int box, const std::string &m) {
                if (ok)
                    ok = append_quad(part, lo, hi, face, box, m);
            });
            if (!ok)
                return fail(error, err);
        } else {
            ++out.intact;
            if (!src["parts"].isMember(id))
                return fail(error, "intact primitive missing: " + id);
            primitives.append(src["parts"][id]);
        }
    }
    // Layers: clothing, armour and beards over the parts (mesh.lua).
    for (const Json::Value &layer : src["layers"]) {
        Stream st;
        st.material = layer["material"].asInt();
        for (const std::string &id : form.order) {
            const DamagePart &part = form.parts.at(id);
            const Json::Value &quads = layer["quads"][id];
            if (!quads.isArray() || missing[id])
                continue;
            auto r = state.parts.find(id);
            const DamagePartState *s = r == state.parts.end() ? nullptr : &r->second;
            bool hurt = s && s->any_removed;
            if (!hurt && layer["parts"].isMember(id)) {
                primitives.append(layer["parts"][id]);
                continue;
            }
            for (const Json::Value &q : quads) {
                int f = q["f"].asInt();
                double qlo[3], qhi[3];
                vec3(q["lo"], qlo);
                vec3(q["hi"], qhi);
                const Json::Value &quv = q["uv"];
                double U[6];
                for (int i = 0; i < 6; ++i)
                    U[i] = quv[i].asDouble();
                std::string bone = q["bone"].isString() ? q["bone"].asString()
                                                        : (part.bone.empty() ? part.id : part.bone);
                if (!bones.isMember(bone))
                    return fail(error, "layer joint missing: " + bone);
                int joint = bones[bone].asInt();
                out.layer_quads += shellQuad(part, s, q, [&](const double lo[3], const double hi[3]) {
                    double c[4][3], v[4][3];
                    quad(qlo, qhi, f, c);
                    quad(lo, hi, f, v);
                    double du[3], dv[3], uu = 0, vv = 0;
                    for (int a = 0; a < 3; ++a) {
                        du[a] = c[1][a] - c[0][a];
                        dv[a] = c[3][a] - c[0][a];
                        uu += du[a] * du[a];
                        vv += dv[a] * dv[a];
                    }
                    double uv[4][2];
                    for (int i = 0; i < 4; ++i) {
                        double s2 = 0, t = 0;
                        for (int a = 0; a < 3; ++a) {
                            double d = v[i][a] - c[0][a];
                            s2 += d * du[a];
                            t += d * dv[a];
                        }
                        s2 = uu > 0 ? s2 / uu : 0;
                        t = vv > 0 ? t / vv : 0;
                        uv[i][0] = U[0] + s2 * (U[2] - U[0]) + t * (U[4] - U[0]);
                        uv[i][1] = U[1] + s2 * (U[3] - U[1]) + t * (U[5] - U[1]);
                    }
                    put(st, v, f, uv, joint, unit);
                });
            }
        }
        if (st.count > 0)
            layer_streams.push_back(std::move(st));
    }
    // The buffer: each stream's accessors, 4-byte aligned, as mesh.lua.
    Json::Value &views = out.views;
    Json::Value &accessors = out.accessors;
    std::string &bin = out.generated;
    auto accessor = [&](const std::string &raw, const char *kind, int component, uint32_t n, const double *minv,
                            const double *maxv) {
        size_t padding = (4 - bin.size() % 4) % 4;
        bin.append(padding, '\0');
        Json::Value view;
        view["buffer"] = 1;
        view["byteOffset"] = (Json::UInt64)bin.size();
        view["byteLength"] = (Json::UInt64)raw.size();
        views.append(view);
        Json::Value a;
        a["bufferView"] = (int)(base.view_count + views.size()) - 1;
        a["componentType"] = component;
        a["count"] = n;
        a["type"] = kind;
        if (minv) {
            for (int i = 0; i < 3; ++i) {
                a["min"].append(minv[i]);
                a["max"].append(maxv[i]);
            }
        }
        accessors.append(a);
        bin += raw;
        return (int)(base.accessor_count + accessors.size()) - 1;
    };
    auto emit_stream = [&](Stream &st, bool is_body) {
        if (st.count == 0)
            return;
        Json::Value attrs;
        attrs["POSITION"] = accessor(st.position, "VEC3", 5126, st.count, st.minp, st.maxp);
        attrs["NORMAL"] = accessor(st.normal, "VEC3", 5126, st.count, nullptr, nullptr);
        attrs["TEXCOORD_0"] = accessor(st.uv, "VEC2", 5126, st.count, nullptr, nullptr);
        attrs["JOINTS_0"] = accessor(st.joint, "VEC4", 5123, st.count, nullptr, nullptr);
        attrs["WEIGHTS_0"] = accessor(st.weight, "VEC4", 5126, st.count, nullptr, nullptr);
        bool wide = st.count > 65535;
        std::string packed;
        packed.reserve(st.index.size() * (wide ? 4 : 2));
        for (uint32_t i : st.index) {
            if (wide)
                putU32(packed, i);
            else
                putU16(packed, i);
        }
        int indices = accessor(packed, "SCALAR", wide ? 5125 : 5123, (uint32_t)st.index.size(), nullptr, nullptr);
        Json::Value prim;
        prim["attributes"] = attrs;
        prim["indices"] = indices;
        prim["material"] = st.material;
        prim["mode"] = 4;
        primitives.append(prim);
        if (is_body)
            out.generated_triangles = (int)st.index.size() / 3;
    };
    emit_stream(body, true);
    for (Stream &st : layer_streams)
        emit_stream(st, false);
    if (primitives.empty())
        return fail(error, "all creature geometry is absent");
    return true;
}

std::string damageGlb(const DamageBase &base, const DamageMesh &mesh) {
    size_t base_len = base.bin.size();
    size_t offset = (base_len + 3) & ~(size_t)3;
    Json::StreamWriterBuilder w;
    w["indentation"] = "";
    w["precision"] = 17;
    // The generated views move into the one buffer, past the base's bytes.
    Json::Value views = mesh.views;
    for (Json::Value &view : views) {
        view["buffer"] = 0;
        view["byteOffset"] = (Json::UInt64)(view["byteOffset"].asUInt64() + offset);
    }
    auto items = [&](const Json::Value &array) {
        std::string t = Json::writeString(w, array);
        return t.size() >= 2 ? t.substr(1, t.size() - 2) : std::string();
    };
    auto join = [](const std::string &a, const std::string &b) {
        return a.empty() ? b : b.empty() ? a : a + "," + b;
    };
    std::string json = base.rest;
    if (json.size() > 1)
        json += ",";
    json += "\"accessors\":[" + join(base.accessors, items(mesh.accessors)) + "]";
    json += ",\"bufferViews\":[" + join(base.views, items(views)) + "]";
    json += ",\"buffers\":[{\"byteLength\":" + std::to_string(offset + mesh.generated.size()) + "}]";
    std::string mesh0 = base.mesh0;
    if (mesh0.size() > 1)
        mesh0 += ",";
    mesh0 += "\"primitives\":" + Json::writeString(w, mesh.primitives) + "}";
    json += ",\"meshes\":[" + join(mesh0, base.other_meshes) + "]}";
    while (json.size() % 4)
        json.push_back(' ');
    size_t bin_len = offset + mesh.generated.size();
    size_t bin_pad = (4 - bin_len % 4) % 4;
    std::string out;
    out.reserve(28 + json.size() + bin_len + bin_pad);
    putU32(out, 0x46546C67);
    putU32(out, 2);
    putU32(out, (uint32_t)(12 + 8 + json.size() + 8 + bin_len + bin_pad));
    putU32(out, (uint32_t)json.size());
    putU32(out, 0x4E4F534A);
    out += json;
    putU32(out, (uint32_t)(bin_len + bin_pad));
    putU32(out, 0x004E4942);
    out += base.bin;
    out.append(offset - base_len, '\0');
    out += mesh.generated;
    out.append(bin_pad, '\0');
    return out;
}

std::string damageToken(float lo, float hi) {
    if (!(lo >= 1 && lo < 16777216.0f && hi >= 0 && hi < 16777216.0f))
        return "";
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%06x%06x", (unsigned)hi, (unsigned)lo);
    return buf;
}

static bool parseJson(const std::string &text, Json::Value &v) {
    Json::CharReaderBuilder b;
    std::string errs;
    std::unique_ptr<Json::CharReader> reader(b.newCharReader());
    return reader->parse(text.data(), text.data() + text.size(), &v, &errs);
}

bool DamageStore::message(const std::string &json) {
    ++messages;
    bytes += json.size();
    Json::Value v;
    if (!parseJson(json, v) || !v.isObject() || v["v"].asInt() != 1) {
        ++rejected;
        return false;
    }
    const std::string kind = v["kind"].asString();
    if (kind == "form") {
        std::string key = v["key"].asString();
        int i = v["i"].asInt(), n = v["n"].asInt();
        if (key.empty() || n < 1 || n > 1024 || i < 1 || i > n) {
            ++rejected;
            return false;
        }
        auto &pieces = pending_forms[key];
        if ((int)pieces.size() != n)
            pieces.assign(n, std::string());
        pieces[i - 1] = v["z"].asString();
        for (const auto &p : pieces)
            if (p.empty())
                return true;
        std::string all;
        for (const auto &p : pieces)
            all += p;
        pending_forms.erase(key);
        completed_forms.push_back({key, all});
        return true;
    }
    if (kind == "state") {
        std::string token = v["t"].asString();
        auto f = forms.find(v["key"].asString());
        if (f == forms.end()) {
            waiting[token] = json;
            return true;
        }
        DamageState s;
        s.key = f->first;
        s.revision = v["r"].asInt();
        for (const auto &t : v["tex"])
            s.textures.push_back(t.asString());
        if (!applyDamageParts(*f->second, v["parts"], true, s)) {
            ++rejected;
            return false;
        }
        states[token] = std::move(s);
        dirty.insert(token);
        return true;
    }
    if (kind == "parts") {
        std::string token = v["t"].asString();
        auto it = states.find(token);
        if (it == states.end())
            return false;
        auto f = forms.find(it->second.key);
        if (f == forms.end() || !applyDamageParts(*f->second, v["parts"], false, it->second)) {
            ++rejected;
            return false;
        }
        it->second.revision = v["r"].asInt();
        if (v.isMember("tex") && v["tex"].isArray()) {
            it->second.textures.clear();
            for (const auto &t : v["tex"])
                it->second.textures.push_back(t.asString());
        }
        dirty.insert(token);
        return true;
    }
    return kind == "hello";
}

bool DamageStore::addForm(const std::string &json, std::string *error) {
    Json::Value v;
    if (!parseJson(json, v))
        return fail(error, "form does not parse");
    auto form = std::make_shared<DamageForm>();
    if (!parseDamageForm(v, *form, error))
        return false;
    forms[form->key] = form;
    std::vector<std::string> ready;
    for (auto &w : waiting) {
        Json::Value s;
        if (parseJson(w.second, s) && s["key"].asString() == form->key)
            ready.push_back(w.first);
    }
    for (const std::string &t : ready) {
        std::string text = waiting[t];
        waiting.erase(t);
        message(text);
    }
    return true;
}

const DamageForm *DamageStore::form(const std::string &key) const {
    auto it = forms.find(key);
    return it == forms.end() ? nullptr : it->second.get();
}

const DamageState *DamageStore::state(const std::string &token) const {
    auto it = states.find(token);
    return it == states.end() ? nullptr : &it->second;
}

void DamageStore::forget(const std::string &token) {
    states.erase(token);
    waiting.erase(token);
    dirty.erase(token);
}

} // namespace goanna
