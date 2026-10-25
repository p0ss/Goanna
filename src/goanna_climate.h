// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The server's temperature and wetness field, for the shaders that draw
// frost, wet ground, dust and mist from it (docs/systems/climate.md).
//
// A paired server mod (DorfCraft's kindred seasons field) sends the field a
// map block at a time: cells of 16 nodes in the wild and finer inside a
// fortress claim, two bytes a cell. The first byte is the temperature level
// times 16 plus the wetness level, the second the air's humidity level; each
// level is 1 to 15 and 0 is unknown. The header gives every level's
// representative value, so the store turns levels into degrees and
// fractions before it interpolates: the bands are uneven, and blending band
// numbers would put the halfway point between -20 and 30 C at the wrong
// temperature.
//
// buildClimate samples the store onto a regular grid round the camera for
// a 3D texture. Each texel is interpolated from the cells round it at the
// resolution of the block it lies in, reading across into neighbouring
// blocks of other resolutions (a finer block gives the mean of its cells
// there, a coarser one its own cell), so a 16-node field shows no edge at a
// block boundary and a claim's 4-node cells keep their detail. Unknown cells
// are left out and the rest renormalised; the texel's alpha says how much of
// it was known.
//
// Pure data, no Godot or Luanti: the caller (GoannaClient::updateClimate)
// decodes the messages and uploads the grid.
#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace goanna {

// The texture's red channel: temperature from kClimateTempMin, in
// kClimateTempSpan degrees across the byte.
constexpr float kClimateTempMin = -60.0f;
constexpr float kClimateTempSpan = 170.0f;

struct ClimateValue {
    float temp = 0, wet = 0, hum = 0; // C, 0 to 1, 0 to 1
    float known = 0;                  // 0 to 1, how much of the value was known
};

struct ClimateGrid {
    float ox = 0, oy = 0, oz = 0; // world position of texel (0, 0, 0)'s low corner
    float cell = 4.0f;            // nodes per texel
    int nx = 0, ny = 0, nz = 0;
};

class ClimateStore {
public:
    // Representative values for levels 1 to 15, in C and fractions. Fifteen
    // values each, or sixteen with level 0 first (ignored). False, and the
    // old bands kept, for anything else.
    bool setBands(const std::vector<float> &temp, const std::vector<float> &wet, const std::vector<float> &hum);
    bool hasBands() const { return m_bands; }
    // One map block's cells, `size` nodes each (16, 8, 4, 2 or 1), two
    // bytes a cell, x fastest then y then z. False, and nothing stored, for
    // a size or length that does not fit.
    bool put(int bx, int by, int bz, int size, const std::string &bytes);
    void drop(int bx, int by, int bz);
    void clear();
    size_t blocks() const { return m_blocks.size(); }
    // Bumped by every change that can alter what build gives.
    uint64_t revision() const { return m_revision; }

    // The interpolated field at a world point; known 0 where nothing is.
    ClimateValue sample(float x, float y, float z) const;
    // Four bytes a texel, x fastest then y then z: temperature (see
    // kClimateTempMin), wetness and humidity, each times known, and known.
    // Premultiplied so the GPU's filter between a known texel and an
    // unknown one blends only what is known; the shader divides by alpha.
    void build(const ClimateGrid &grid, std::vector<uint8_t> &rgba) const;

private:
    struct Block {
        int size = 16;
        int n = 1; // cells along an edge
        std::vector<float> temp, wet, hum, known;
        ClimateValue mean;
    };
    static uint64_t key(int bx, int by, int bz);
    const Block *find(int bx, int by, int bz) const;
    // The value a reader at cell size `s` sees at world point (x, y, z),
    // which is the centre of one of its cells.
    ClimateValue at(float x, float y, float z, int s) const;
    ClimateValue coarse(float x, float y, float z) const;
    ClimateValue fine(float x, float y, float z, int s) const;
    void decode(Block &b, const std::string &bytes) const;

    std::unordered_map<uint64_t, Block> m_blocks;
    std::unordered_map<uint64_t, std::string> m_raw; // kept to decode again on new bands
    float m_temp[16] = {}, m_wet[16] = {}, m_hum[16] = {};
    bool m_bands = false;
    uint64_t m_revision = 0;
    // build's block lookup, set while it runs, so a texel's eight corners
    // index an array rather than hash.
    mutable const Block *const *m_dense = nullptr;
    mutable const ClimateValue *m_means = nullptr;
    mutable int m_dx0 = 0, m_dy0 = 0, m_dz0 = 0, m_dnx = 0, m_dny = 0, m_dnz = 0;
};

} // namespace goanna
