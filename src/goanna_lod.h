// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Far rendering: the derived occupancy chain per mapblock and the per region
// tier mesher. docs/far-rendering.md rungs 2 and 3, docs/mesh-attributes.md
// for the vertex layout the output meets.
//
// Each mapblock that is drawn coarsely, or that neighbours one, gets a chain
// of levels at cell 2, 4, 8 and 16 nodes: which cells are filled, which block
// light, what is seen from each side, and how lit the air in them is. Regions
// of blocks at one tier are then meshed from those chains alone, never from
// the nodes, which is what lets a tier be rebuilt cheaply and is the shape the
// local store will persist at rung 5.
//
// No Godot types: the client converts the output to arrays. The occupancy
// tracer is the one in goanna_occlusion.h, run against a field at the tier's
// cell size, which is the far field term in docs/far-rendering.md.

#include <cstdint>
#include <functional>
#include <map>
#include <vector>

#include "irrlichttypes_bloated.h"
#include "mapnode.h"

class MapBlock;
class NodeDefManager;

namespace goanna {

class GoannaTextureSource;
struct MaterialTable;

// One coarse level of one block.
struct LodLevel {
    enum : uint8_t {
        kFilled = 1,   // any solid or liquid node: draws
        kOccludes = 2, // enough solid nodes to block light: traced against
        kLit = 4,      // has nodes light propagates through, so day/night mean something
        kKnown = 8,    // at least one node that is not CONTENT_IGNORE
    };
    struct Cell {
        // What is seen looking into the cell from each of the six sides, in
        // Luanti's tile order (+Y, -Y, +X, -X, +Z, -Z): the commonest content
        // among the first filled node down each column. CONTENT_AIR if none.
        content_t face[6] = {CONTENT_AIR, CONTENT_AIR, CONTENT_AIR, CONTENT_AIR, CONTENT_AIR, CONTENT_AIR};
        // That node's param2, for palette coloured nodes (biome grass).
        uint8_t param2[6] = {0, 0, 0, 0, 0, 0};
        // Mean decoded light of the lit nodes in the cell. Valid when kLit.
        uint8_t day = 255, night = 0;
        uint8_t flags = 0;
        // Height of the highest filled node, plus one, 0 to cell: where a
        // liquid's surface is drawn, so a sea at a coarse tier lies at sea
        // level and not at the top of its cell.
        uint8_t top = 0;
    };
    int cell = 0; // nodes per cell
    int n = 0;    // cells per axis, MAP_BLOCKSIZE / cell
    std::vector<Cell> cells;
    const Cell &at(int x, int y, int z) const { return cells[((size_t)z * n + y) * n + x]; }
    bool built() const { return !cells.empty(); }
};

struct BlockLodChain {
    static constexpr int kLevels = 4; // cell 2, 4, 8, 16
    LodLevel level[kLevels];
    // Derived from the store rather than from a live block: what the far
    // tiers mark as stale (docs/far-rendering.md, "Staleness").
    bool stored = false;
    // 2 -> 0, 4 -> 1, 8 -> 2, 16 -> 3; -1 for anything else.
    static int levelForCell(int cell);
    static int cellForLevel(int level) { return 2 << level; }
    const LodLevel *forCell(int cell) const {
        int l = levelForCell(cell);
        return l < 0 || !level[l].built() ? nullptr : &level[l];
    }
};

// Build the levels from min_level up. The finer a level the more it costs to
// keep, and a tier at cell 4 never reads the cell 2 level, so the caller says
// how fine it needs.
void buildLodChain(const NodeDefManager *ndef, MapBlock *block, BlockLodChain &out, int min_level = 0);

// Output, in Godot space (nodes, z mirrored), world absolute, one surface per
// array texture. texture_id 0 is the flat colour fallback for tiles that have
// no array texture, where col carries the average tile colour instead of a
// tint. Everything else follows docs/mesh-attributes.md.
struct LodSurface {
    u32 texture_id = 0;
    // A liquid surface: texture_id is then the 2D image of the liquid's
    // tile (its first animation frame), for the water shader, not an array.
    bool liquid = false;
    std::vector<v3f> pos, nrm;
    std::vector<v2f> uv, uv2;
    std::vector<u32> col; // 0xAARRGGBB
    std::vector<uint8_t> custom0; // block light, sky light, occlusion, freshness
    std::vector<u32> idx;
};
struct LodRegionMesh {
    std::vector<LodSurface> surfaces;
    int faces = 0; // cell faces before merging
    int quads = 0; // after
    bool empty() const { return surfaces.empty(); }
};

// Per (content, side) tile lookup, cached because it walks the node
// definition and the texture source. Content ids are per session, so the
// owner clears it when the session changes.
struct LodTileCache {
    struct Entry {
        u32 texture_id = 0;   // array texture id, or 0 for the fallback
        u16 layer = 0;        // layer into the array
        u32 tint = 0xffffffff; // tile's own colour, or white if it takes the node's
        bool tile_has_color = false;
        u32 fallback = 0xff808080; // average colour when there is no array
        uint16_t block_id = 0;     // the semantic block ID, UV2.y
        bool liquid = false;       // draw with the water shader, texture_id is 2D
    };
    std::map<u32, Entry> entries; // key content * 6 + side
};

struct LodRegionSpec {
    v3s16 origin;       // block position of the low corner
    int blocks = 8;     // blocks per axis
    int cell = 4;       // nodes per cell; must be a chain level
    float ao_radius = 0.0f; // nodes; 0 skips the trace and writes unoccluded
    // Which blocks this region draws at this tier. Every other block in and
    // around it is consulted for occupancy only, which is the residency rule:
    // a block drawn finer still culls this tier's faces against its own
    // occupancy at this tier's cell, not against whatever it is drawn at.
    std::function<bool(v3s16)> member;
    // The chain of any block, or nullptr if nothing is known about it.
    std::function<const BlockLodChain *(v3s16)> chain;
};

// materials may be null, in which case every block ID is 0.
LodRegionMesh meshLodRegion(const LodRegionSpec &spec, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials, LodTileCache &tiles);

} // namespace goanna
