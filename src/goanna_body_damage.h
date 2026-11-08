// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Wounds cut on the client. A paired server mod (DorfCraft's creature kit,
// mods/kindred_creatures/kit/damage/wire.lua and net.lua) sends a body's
// damage state instead of a whole new model for every wound; this rebuilds
// the model the server's own runtime mesh (kit/damage/mesh.lua) would have
// sent, from the base model the client already has. It is a port of
// mesh.lua's M.build: the same cells, the same merged quads, the same
// texture coordinates, written into the same glTF accessors, so a client
// draws exactly what a stock client was sent before. Nothing is decided
// here: the server names every lost cell, every severed part, every
// released socket and the support fracture, and this only draws them.
//
// The protocol (wire version 1, docs/systems/body-damage.md):
//   form   once per form: every part's damage grid (cell places, authored
//          box per cell, bone scaffold and attachment routes, bone shells)
//          and the render source fields mesh.lua reads (primitives, UV
//          locations, wound patches, bones, clothing layers).
//   state  a body's parts that do not draw whole, as runs of cell numbers.
//   parts  the parts that changed since the last revision.
// A body carries its token on the bone override "kindred_damage"
// (position x the low 24 bits, y the high 24).
//
// Threads: pure, no Godot. DamageStore is main thread only. Main types:
// DamageForm, DamageBase, DamageState, DamageMesh, DamageStore.

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <json/json.h>

namespace goanna {

struct DamagePart {
    std::string id, parent, socket, bone, mode;
    std::map<std::string, std::string> materials;
    double origin[3] = {0, 0, 0};
    struct Box {
        std::string name;
        double lo[3], hi[3];
    };
    std::vector<Box> boxes;
    // The compiled grid (kit/damage/core.lua D.compile), cells numbered
    // j = 0..count-1 here (the wire's j - 1).
    double lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0}, step = 1;
    int n[3] = {0, 0, 0};
    std::vector<int> place;           // per cell: x + n1 * (y + n2 * z)
    std::vector<int> box;             // per cell: authored box, 1-based
    std::vector<int> dense;           // per place: cell + 1, or 0
    std::vector<uint8_t> scaffold;    // per cell
    std::map<std::string, std::vector<int>> paths; // socket -> cells
    std::vector<int> shell;           // per cell: index into shell_materials, or -1
    std::vector<std::string> shell_materials;
    void coords(int j, int &x, int &y, int &z) const {
        int g = place[j];
        x = g % n[0];
        g /= n[0];
        y = g % n[1];
        z = g / n[1];
    }
    // The face neighbour (faces 1..6: x+ x- y+ y- z+ z-), or -1.
    int neighbour(int j, int face) const;
};

struct DamageForm {
    int version = 0;
    std::string key, id, model, texture;
    std::vector<std::string> order;
    std::map<std::string, DamagePart> parts;
    // The render source fields: parts, locations, patches, patch_size,
    // width, height, units_per_node, material, bones, layers.
    Json::Value source;
    size_t cells = 0;
};

// What one part draws: whole (absent from the map), severed, or carved.
struct DamagePartState {
    bool severed = false;
    std::vector<uint8_t> removed; // per cell
    bool any_removed = false;
    std::set<std::string> released;
    int fracture = -1;
};

struct DamageState {
    std::string key;
    int revision = 0;
    std::vector<std::string> textures;
    std::map<std::string, DamagePartState> parts;
};

// The base model, read once per form: its glTF with buffer 0's data URI
// taken out, and buffer 0's bytes.
struct DamageBase {
    Json::Value gltf;
    std::string bin;
    // The JSON written once, in pieces to splice a build into
    // (damageGlb): everything but accessors, bufferViews, buffers and
    // meshes; the base accessors and views as array items; the first
    // mesh without its primitives, and the other meshes.
    std::string rest, accessors, views, mesh0, other_meshes;
    unsigned accessor_count = 0, view_count = 0;
};

// What a build adds to the base model: the first mesh's primitives, the
// accessors and buffer views past the base's (indices following on from
// them), and buffer 1's bytes.
struct DamageMesh {
    Json::Value primitives, accessors, views;
    std::string generated;
    int generated_triangles = 0, generated_quads = 0, layer_quads = 0;
    int damaged = 0, severed = 0, intact = 0;
};

bool parseDamageForm(const Json::Value &v, DamageForm &out, std::string *error = nullptr);
// Apply a state's or parts message's "parts" to a state of this form.
// full: the parts not named draw whole.
bool applyDamageParts(const DamageForm &form, const Json::Value &parts, bool full,
        DamageState &state, std::string *error = nullptr);
bool loadDamageBase(const std::string &gltf_text, DamageBase &out, std::string *error = nullptr);
// mesh.lua's M.build.
bool buildDamageMesh(const DamageForm &form, const DamageBase &base, const DamageState &state,
        DamageMesh &out, std::string *error = nullptr);
// One binary glTF of base and generated buffers together, for the
// model loader: the base buffer, padded, then the generated one.
std::string damageGlb(const DamageBase &base, const DamageMesh &mesh);
std::string damageBase64Decode(const std::string &in);

// The client's damage state by token, and the meshes waiting to be built.
// Main thread only.
class DamageStore {
public:
    // A decoded server message (JSON). Returns false for one it ignores.
    bool message(const std::string &json);
    // Forms arrive as base64 pieces of zstd'd JSON. Pieces wait here by
    // key until all have come; the whole base64 text then goes to
    // completed_forms, for the caller to decode, decompress and hand to
    // addForm (this file links no compressor).
    std::map<std::string, std::vector<std::string>> pending_forms;
    std::vector<std::pair<std::string, std::string>> completed_forms;
    bool addForm(const std::string &json, std::string *error = nullptr);
    const DamageForm *form(const std::string &key) const;
    const DamageState *state(const std::string &token) const;
    // Tokens whose state changed since they were last built.
    std::set<std::string> dirty;
    void forget(const std::string &token);
    std::map<std::string, std::shared_ptr<DamageForm>> forms;
    std::map<std::string, DamageState> states;
    // States that arrived before their form: built once it does.
    std::map<std::string, std::string> waiting;
    uint64_t messages = 0, bytes = 0, rejected = 0;
};

// The 48-bit token on a body's "kindred_damage" bone override, as 12 hex
// (the server's spelling), or "" for none.
std::string damageToken(float lo, float hi);

} // namespace goanna
