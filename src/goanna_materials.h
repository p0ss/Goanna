// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// The per node classifier, docs/pbr-plan.md step 2: one table with two
// columns, built once from the node definitions the server sent.
//
// Column one is a material class, from what Luanti already says about a
// node: its footstep sound first, then its groups, then its drawtype, and
// only then its name. The class gives every texture layer that has no
// authored LabPBR companion a plausible one (smoothness, F0, metalness,
// scattering) in place of the neutral filler, which is what takes material
// coverage from the authored fraction to all of it. The tables mirror
// tools/pbr_bake.py, which classifies the same way offline for the bake.
//
// Column two is the Minecraft block a node most resembles, through the
// texture map (a game_texture,pack_path CSV), for the semantic ID an Iris
// shader pack reads as mc_Entity.x (docs/iris-compat.md); it rides in UV2.y,
// per docs/mesh-attributes.md. It is a lookup here because the texture
// map alone cannot give it: in Mineclonia more than half the textures are
// shared between nodes, so it takes the nodedef to say which block a tile
// belongs to, and that read is this one.

#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

#include "mapnode.h"

class NodeDefManager;

namespace goanna {

enum class MaterialClass : uint8_t {
    None = 0,
    Stone,
    Wood,
    Leaves,
    Glass,
    Sand,
    Gravel,
    Snow,
    Ice,
    Soil,
    Metal,
    Cloth,
    Count
};

// Smoothness and F0 as LabPBR stores them (0 to 1), metalness, and the
// subsurface scattering share (0 is none). Real material knowledge, the same
// values as the bake's CLASS_SPEC and CLASS_SSS.
struct ClassSpec {
    float smoothness;
    float f0;
    bool metal;
    float sss;
};
const ClassSpec &classSpec(MaterialClass c);
const char *className(MaterialClass c);

// The base image of a tile string: what is before the first texture
// modifier, or empty when the tile is a generator with no file behind it.
std::string tileBaseName(const std::string &tile);

struct MaterialTable {
    std::vector<uint8_t> node_class;  // by content id; MaterialClass
    std::vector<uint16_t> node_block; // by content id; index into block_names, 0 none
    std::unordered_map<std::string, uint8_t> texture_class; // by base image name
    // Emission for a texture, as LabPBR's _s alpha wants it: 1.0 is none.
    // The minimum over the nodes that show the texture, as the emissive
    // material path already does, so a texture a plain node shares with a
    // hidden glowing variant does not glow.
    std::unordered_map<std::string, float> texture_emission;
    std::vector<std::string> block_names; // [0] is ""
    // Coverage, for the audit: how many nodes got a class by each signal.
    int nodes = 0, by_footstep = 0, by_group = 0, by_drawtype = 0, by_name = 0, unclassed = 0;

    MaterialClass classOf(content_t c) const {
        return c < node_class.size() ? (MaterialClass)node_class[c] : MaterialClass::None;
    }
    uint16_t blockOf(content_t c) const { return c < node_block.size() ? node_block[c] : 0; }
    MaterialClass textureClass(const std::string &base) const {
        auto it = texture_class.find(base);
        return it == texture_class.end() ? MaterialClass::None : (MaterialClass)it->second;
    }
    float textureEmission(const std::string &base) const {
        auto it = texture_emission.find(base);
        return it == texture_emission.end() ? 1.0f : it->second;
    }
    bool empty() const { return node_class.empty(); }
};

// Classify one node from its definition.
MaterialClass classifyNode(const NodeDefManager *ndef, content_t c, int *signal = nullptr);
// Classify by name alone: items, tools, armour and mob skins are textures
// rather than nodes, so the other three signals do not exist for them.
MaterialClass classifyName(const std::string &name);

// game_texture -> pack path, from the CSV tools/mc_texture_map.py writes.
// Empty if the path does not read.
std::map<std::string, std::string> readTextureMap(const std::string &csv_path);

// Build the whole table. texture_to_block may be empty, in which case every
// node's block column is 0.
void buildMaterialTable(const NodeDefManager *ndef,
        const std::map<std::string, std::string> &texture_to_block, MaterialTable &out);

} // namespace goanna
