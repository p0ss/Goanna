// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_materials.h"

#include "nodedef.h"

#include <algorithm>
#include <fstream>

namespace goanna {

namespace {

// Mirrors tools/pbr_bake.py CLASS_SPEC and CLASS_SSS. Real material
// knowledge, not measured; the bake's comment records that a learned
// roughness estimator was tried and rejected for a spread too narrow to trust.
const ClassSpec kSpecs[(int)MaterialClass::Count] = {
    {0.20f, 0.04f, false, 0.0f},  // None: the bake's dull default
    {0.12f, 0.04f, false, 0.0f},  // Stone
    {0.22f, 0.04f, false, 0.0f},  // Wood
    {0.30f, 0.04f, false, 0.5f},  // Leaves
    {0.92f, 0.04f, false, 0.0f},  // Glass
    {0.08f, 0.04f, false, 0.0f},  // Sand
    {0.10f, 0.04f, false, 0.0f},  // Gravel
    {0.35f, 0.04f, false, 0.2f},  // Snow
    {0.88f, 0.04f, false, 0.35f}, // Ice
    {0.05f, 0.04f, false, 0.0f},  // Soil
    {0.55f, 1.00f, true, 0.0f},   // Metal
    {0.08f, 0.04f, false, 0.0f},  // Cloth
};
const char *kNames[(int)MaterialClass::Count] = {
    "none", "stone", "wood", "leaves", "glass", "sand", "gravel", "snow", "ice", "soil", "metal", "cloth",
};

struct NameClass {
    const char *token;
    MaterialClass cls;
};

// The footstep token, from default_<token>_footstep. The strongest signal by
// far: it names the material for the overwhelming majority of Mineclonia's
// nodes, and Minetest Game's too.
const NameClass kFootstep[] = {
    {"hard", MaterialClass::Stone}, {"stone", MaterialClass::Stone}, {"wood", MaterialClass::Wood},
    {"metal", MaterialClass::Metal}, {"grass", MaterialClass::Leaves}, {"dirt", MaterialClass::Soil},
    {"glass", MaterialClass::Glass}, {"sand", MaterialClass::Sand}, {"gravel", MaterialClass::Gravel},
    {"ice", MaterialClass::Ice}, {"snow", MaterialClass::Snow}, {"cloth", MaterialClass::Cloth},
    {"wool", MaterialClass::Cloth},
};
// Groups. Mineclonia's own vocabulary first (it has no cracky, crumbly or
// choppy), then Minetest Game's.
const NameClass kGroups[] = {
    {"material_stone", MaterialClass::Stone}, {"material_wood", MaterialClass::Wood},
    {"material_glass", MaterialClass::Glass}, {"material_sand", MaterialClass::Sand},
    {"axey", MaterialClass::Wood}, {"shearsy", MaterialClass::Cloth}, {"hoey", MaterialClass::Soil},
    {"cracky", MaterialClass::Stone}, {"crumbly", MaterialClass::Soil}, {"choppy", MaterialClass::Wood},
    {"snappy", MaterialClass::Leaves}, {"sand", MaterialClass::Sand}, {"soil", MaterialClass::Soil},
    {"snowy", MaterialClass::Snow}, {"leaves", MaterialClass::Leaves}, {"wood", MaterialClass::Wood},
    {"stone", MaterialClass::Stone}, {"glass", MaterialClass::Glass}, {"wool", MaterialClass::Cloth},
    {"tree", MaterialClass::Wood},
};
// Name fragments, the last resort: a guess, counted separately so the audit
// can say how much of a game rests on it.
const NameClass kNameHints[] = {
    {"snow", MaterialClass::Snow}, {"ice", MaterialClass::Ice}, {"glass", MaterialClass::Glass},
    {"wool", MaterialClass::Cloth}, {"carpet", MaterialClass::Cloth}, {"cloth", MaterialClass::Cloth},
    {"leaves", MaterialClass::Leaves}, {"leaf", MaterialClass::Leaves}, {"sapling", MaterialClass::Leaves},
    {"flower", MaterialClass::Leaves}, {"grass", MaterialClass::Leaves}, {"fern", MaterialClass::Leaves},
    {"vine", MaterialClass::Leaves}, {"bush", MaterialClass::Leaves}, {"mushroom", MaterialClass::Leaves},
    {"gravel", MaterialClass::Gravel}, {"sand", MaterialClass::Sand},
    {"dirt", MaterialClass::Soil}, {"soil", MaterialClass::Soil}, {"mud", MaterialClass::Soil},
    {"clay", MaterialClass::Soil}, {"podzol", MaterialClass::Soil}, {"mycelium", MaterialClass::Soil},
    {"plank", MaterialClass::Wood}, {"wood", MaterialClass::Wood}, {"log", MaterialClass::Wood},
    {"tree", MaterialClass::Wood}, {"fence", MaterialClass::Wood}, {"door", MaterialClass::Wood},
    {"iron", MaterialClass::Metal}, {"gold", MaterialClass::Metal}, {"steel", MaterialClass::Metal},
    {"copper", MaterialClass::Metal}, {"metal", MaterialClass::Metal}, {"anvil", MaterialClass::Metal},
    {"rail", MaterialClass::Metal}, {"lantern", MaterialClass::Metal}, {"chain", MaterialClass::Metal},
    {"stone", MaterialClass::Stone}, {"brick", MaterialClass::Stone}, {"cobble", MaterialClass::Stone},
    {"ore", MaterialClass::Stone}, {"obsidian", MaterialClass::Stone}, {"rock", MaterialClass::Stone},
    {"granite", MaterialClass::Stone}, {"andesite", MaterialClass::Stone}, {"diorite", MaterialClass::Stone},
    {"deepslate", MaterialClass::Stone}, {"netherrack", MaterialClass::Stone}, {"basalt", MaterialClass::Stone},
    {"concrete", MaterialClass::Stone}, {"terracotta", MaterialClass::Stone}, {"quartz", MaterialClass::Stone},
    {"prismarine", MaterialClass::Stone}, {"furnace", MaterialClass::Stone}, {"glowstone", MaterialClass::Stone},
};

bool contains(const std::string &s, const char *needle) {
    return s.find(needle) != std::string::npos;
}

} // namespace

const ClassSpec &classSpec(MaterialClass c) {
    int i = (int)c;
    if (i < 0 || i >= (int)MaterialClass::Count)
        i = 0;
    return kSpecs[i];
}

const char *className(MaterialClass c) {
    int i = (int)c;
    if (i < 0 || i >= (int)MaterialClass::Count)
        i = 0;
    return kNames[i];
}

std::string tileBaseName(const std::string &tile) {
    // What is before the first modifier. A tile can be a generator
    // ("[combine:...", "(foo.png^[transformR180)") or a name with a colon,
    // none of which is a file, as tools/goanna_nodedef_dump.lua also rules.
    size_t caret = tile.find('^');
    std::string base = caret == std::string::npos ? tile : tile.substr(0, caret);
    if (base.empty())
        return base;
    if (base[0] == '[' || base[0] == '(' || base.find(':') != std::string::npos)
        return std::string();
    return base;
}

MaterialClass classifyNode(const NodeDefManager *ndef, content_t c, int *signal) {
    if (signal)
        *signal = 0;
    if (!ndef)
        return MaterialClass::None;
    const ContentFeatures &f = ndef->get(c);
    if (f.name.empty() || f.name == "unknown" || f.name == "air" || f.name == "ignore")
        return MaterialClass::None;
    // 1. footstep
    const std::string &fs = f.sound_footstep.name;
    const std::string pre = "default_", post = "_footstep";
    if (fs.size() > pre.size() + post.size() && fs.compare(0, pre.size(), pre) == 0 &&
            fs.compare(fs.size() - post.size(), post.size(), post) == 0) {
        std::string token = fs.substr(pre.size(), fs.size() - pre.size() - post.size());
        for (const NameClass &nc : kFootstep)
            if (token == nc.token) {
                if (signal) *signal = 1;
                return nc.cls;
            }
    }
    if (!fs.empty()) {
        if (contains(fs, "snow")) { if (signal) *signal = 1; return MaterialClass::Snow; }
        if (contains(fs, "cloth") || contains(fs, "wool")) { if (signal) *signal = 1; return MaterialClass::Cloth; }
        if (contains(fs, "metal")) { if (signal) *signal = 1; return MaterialClass::Metal; }
        if (contains(fs, "glass")) { if (signal) *signal = 1; return MaterialClass::Glass; }
        if (contains(fs, "wood")) { if (signal) *signal = 1; return MaterialClass::Wood; }
        if (contains(fs, "stone") || contains(fs, "hard")) { if (signal) *signal = 1; return MaterialClass::Stone; }
        if (contains(fs, "grass") || contains(fs, "leaves")) { if (signal) *signal = 1; return MaterialClass::Leaves; }
        if (contains(fs, "sand")) { if (signal) *signal = 1; return MaterialClass::Sand; }
        if (contains(fs, "gravel")) { if (signal) *signal = 1; return MaterialClass::Gravel; }
        if (contains(fs, "dirt")) { if (signal) *signal = 1; return MaterialClass::Soil; }
        if (contains(fs, "ice")) { if (signal) *signal = 1; return MaterialClass::Ice; }
    }
    // 2. groups
    for (const NameClass &nc : kGroups)
        if (f.groups.count(nc.token)) {
            if (signal) *signal = 2;
            return nc.cls;
        }
    // 3. drawtype
    switch (f.drawtype) {
    case NDT_PLANTLIKE:
    case NDT_PLANTLIKE_ROOTED:
    case NDT_ALLFACES:
    case NDT_ALLFACES_OPTIONAL:
    case NDT_FIRELIKE:
        if (signal) *signal = 3;
        return MaterialClass::Leaves;
    case NDT_GLASSLIKE:
    case NDT_GLASSLIKE_FRAMED:
    case NDT_GLASSLIKE_FRAMED_OPTIONAL:
        if (signal) *signal = 3;
        return MaterialClass::Glass;
    default:
        break;
    }
    // 4. the name, the part after the mod prefix
    MaterialClass by_name = classifyName(f.name);
    if (by_name != MaterialClass::None) {
        if (signal) *signal = 4;
        return by_name;
    }
    return MaterialClass::None;
}

// The name pass on its own, for something that is not a node and so has no
// footstep, no groups and no drawtype to ask: an item, the tool or the armour
// a player is carrying, a mob's skin. It is the weakest of the four signals
// and the node classifier only reaches it last, but for a texture that is not
// a node tile it is the only one there is, and "iron" in a name is a better
// guess than the flat dielectric default that stands in for knowing nothing.
MaterialClass classifyName(const std::string &raw) {
    std::string name = raw;
    size_t colon = name.find(':');
    if (colon != std::string::npos)
        name = name.substr(colon + 1);
    for (const NameClass &nc : kNameHints)
        if (contains(name, nc.token))
            return nc.cls;
    return MaterialClass::None;
}

std::map<std::string, std::string> readTextureMap(const std::string &csv_path) {
    std::map<std::string, std::string> out;
    if (csv_path.empty())
        return out;
    std::ifstream f(csv_path);
    if (!f)
        return out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#')
            continue;
        size_t comma = line.find(',');
        if (comma == std::string::npos)
            continue;
        std::string game_tex = line.substr(0, comma);
        std::string pack_path = line.substr(comma + 1);
        while (!pack_path.empty() && (pack_path.back() == '\r' || pack_path.back() == '\n' || pack_path.back() == ' '))
            pack_path.pop_back();
        if (game_tex == "game_texture" || pack_path.empty())
            continue;
        out[game_tex] = pack_path;
    }
    return out;
}

void buildMaterialTable(const NodeDefManager *ndef,
        const std::map<std::string, std::string> &texture_to_block, MaterialTable &out) {
    out = MaterialTable();
    out.block_names.push_back(std::string());
    if (!ndef)
        return;
    out.node_class.assign(65536, 0);
    out.node_block.assign(65536, 0);
    // votes per texture: class -> count; and per texture the minimum light
    struct Vote {
        int count[(int)MaterialClass::Count] = {0};
        int min_light = -1;
    };
    std::unordered_map<std::string, Vote> votes;
    std::map<std::string, uint16_t> block_ids;
    auto blockNameOf = [&](const std::string &base) -> std::string {
        auto it = texture_to_block.find(base);
        if (it == texture_to_block.end())
            return std::string();
        // "block/oak_planks.png" -> "oak_planks"
        std::string p = it->second;
        size_t slash = p.rfind('/');
        if (slash != std::string::npos)
            p = p.substr(slash + 1);
        size_t dot = p.rfind('.');
        if (dot != std::string::npos)
            p = p.substr(0, dot);
        return p;
    };
    for (u32 c = 0; c < 65536; ++c) {
        const ContentFeatures &f = ndef->get((content_t)c);
        if (f.name.empty() || f.name == "unknown" || f.name == "air" || f.name == "ignore")
            continue;
        ++out.nodes;
        int signal = 0;
        MaterialClass cls = classifyNode(ndef, (content_t)c, &signal);
        out.node_class[c] = (uint8_t)cls;
        switch (signal) {
        case 1: ++out.by_footstep; break;
        case 2: ++out.by_group; break;
        case 3: ++out.by_drawtype; break;
        case 4: ++out.by_name; break;
        default: ++out.unclassed; break;
        }
        // Tiles: the six faces and their overlays; special tiles (flowing
        // liquid) count too, they are textures a node shows.
        std::map<std::string, int> block_votes;
        auto tile = [&](const TileDef &td) {
            std::string base = tileBaseName(td.name);
            if (base.empty() || base == "blank.png")
                return;
            Vote &v = votes[base];
            if (cls != MaterialClass::None)
                ++v.count[(int)cls];
            const int light = f.light_source;
            v.min_light = v.min_light < 0 ? light : std::min(v.min_light, light);
            std::string bn = blockNameOf(base);
            if (!bn.empty())
                ++block_votes[bn];
        };
        for (int i = 0; i < 6; ++i) {
            tile(f.tiledef[i]);
            tile(f.tiledef_overlay[i]);
        }
        for (int i = 0; i < CF_SPECIAL_COUNT; ++i)
            tile(f.tiledef_special[i]);
        if (!block_votes.empty()) {
            auto best = std::max_element(block_votes.begin(), block_votes.end(),
                    [](const auto &a, const auto &b) { return a.second < b.second; });
            auto id = block_ids.find(best->first);
            if (id == block_ids.end()) {
                id = block_ids.emplace(best->first, (uint16_t)out.block_names.size()).first;
                out.block_names.push_back(best->first);
            }
            out.node_block[c] = id->second;
        }
    }
    for (auto &kv : votes) {
        int best = 0;
        for (int i = 1; i < (int)MaterialClass::Count; ++i)
            if (kv.second.count[i] > kv.second.count[best])
                best = i;
        if (kv.second.count[best] > 0)
            out.texture_class[kv.first] = (uint8_t)best;
        // Emission as the array shader's _s alpha reads it: EMISSION =
        // ALBEDO * a * emission_strength (4 by default), and the standard
        // material path gives a glowing node 1.8 * (level / 14)^2, so the
        // two agree when a = 0.45 * (level / 14)^2. Dim sources (level
        // below 6, firefly bushes) stay unlit here as they do there; the
        // light pool covers them.
        if (kv.second.min_light >= 6) {
            float lvl = kv.second.min_light / 14.0f;
            out.texture_emission[kv.first] = std::min(0.998f, 0.45f * lvl * lvl);
        }
    }
}

} // namespace goanna
