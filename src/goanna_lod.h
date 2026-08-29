// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Far rendering: the derived occupancy chain per mapblock and the per region
// tier mesher. docs/far-rendering.md rungs 2 and 3, docs/mesh-attributes.md
// for the vertex layout the output meets.
//
// Each mapblock that is drawn coarsely, or that neighbours one, gets a chain
// of levels at cell 1, 2, 4, 8 and 16 nodes: which cells are filled, which block
// light, what is seen from each side, and how lit the air in them is. Regions
// of blocks at one tier are then meshed from those chains alone, never from
// the nodes, which is what lets a tier be rebuilt cheaply and is the shape the
// local store will persist at rung 5.
//
// No Godot types: the client converts the output to arrays. The occupancy
// tracer is the one in goanna_occlusion.h, run against a field at the tier's
// cell size, which is the far field term in docs/far-rendering.md.

#include <array>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
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
        // Legacy heightfield marker. Protocol-v5 summaries and chains built
        // by buildLodChain leave it unset, so every occupied coarse voxel is
        // handled by the six-face box mesher.
        kTerrain = 16,
        // Liquid exists independently of solid occupancy. It is rendered as
        // an exterior surface envelope, never as a transparent filled box.
        kLiquid = 32,
    };
    struct Cell {
        // Representative content for each side, in Luanti's tile order
        // (+Y, -Y, +X, -X, +Z, -Z). Volumetric mips currently put the same
        // representative in all six entries. CONTENT_AIR means none.
        content_t face[6] = {CONTENT_AIR, CONTENT_AIR, CONTENT_AIR, CONTENT_AIR, CONTENT_AIR, CONTENT_AIR};
        // That node's param2, for palette coloured nodes (biome grass).
        uint8_t param2[6] = {0, 0, 0, 0, 0, 0};
        // Mean decoded light of the lit nodes in the cell. Valid when kLit.
        uint8_t day = 255, night = 0;
        uint8_t flags = 0;
        // Legacy solid partial-height support. Zero means a volumetric solid
        // occupies the complete cell, including its lower face.
        uint8_t top = 0;
        // Independent liquid envelope. A solid seabed and water may coexist
        // in one coarse cell. Zero top means the liquid reaches the cell top.
        content_t liquid = CONTENT_AIR;
        uint8_t liquid_param2 = 0;
        uint8_t liquid_top = 0;
    };
    int cell = 0; // nodes per cell
    int n = 0;    // cells per axis, MAP_BLOCKSIZE / cell
    std::vector<Cell> cells;
    // Optional legacy per-column height data. The volumetric path keeps this
    // empty, which disables the old surface pass and leaves all occupied
    // cells to the six-face voxel mesher.
    std::vector<uint8_t> terrain;
    Cell &at(int x, int y, int z) { return cells[((size_t)z * n + y) * n + x]; }
    const Cell &at(int x, int y, int z) const { return cells[((size_t)z * n + y) * n + x]; }
    uint8_t terrainAt(int x, int z) const { return terrain.empty() ? 0 : terrain[(size_t)z * n + x]; }
    bool built() const { return !cells.empty(); }
};

struct BlockLodChain {
    static constexpr int kLevels = 5; // cell 1, 2, 4, 8, 16
    LodLevel level[kLevels];
    // Cell-1 is retained as a sparse boundary after its coarser mips have
    // been built. `fine_filled` is the exact occupancy used to cull inward
    // faces; records contain exposed filled nodes plus adjacent lit air, so
    // the mesher also has the material and light needed at the boundary.
    struct FineRecord {
        uint16_t index = 0;
        LodLevel::Cell cell;
    };
    bool fine_available = false;
    std::array<uint64_t, 64> fine_filled{}; // 4096 node bits
    std::array<uint64_t, 64> fine_occludes{};
    std::array<uint64_t, 64> fine_record_mask{};
    std::array<uint16_t, 64> fine_record_base{};
    std::vector<FineRecord> fine_records;   // sorted by index
    // Derived from the store rather than from a live block: what the far
    // tiers mark as stale (docs/far-rendering.md, "Staleness").
    bool stored = false;
    // Built from a server summary rather than from nodes. A later summary of
    // the same block replaces it; a chain from nodes is never replaced by one.
    bool summary = false;
    // 1 -> 0, 2 -> 1, 4 -> 2, 8 -> 3, 16 -> 4; -1 otherwise.
    static int levelForCell(int cell);
    static int cellForLevel(int level) { return 1 << level; }
    const LodLevel *forCell(int cell) const {
        int l = levelForCell(cell);
        return l < 0 || !level[l].built() ? nullptr : &level[l];
    }
    bool hasCell(int cell) const {
        return cell == 1 ? (fine_available || forCell(1) != nullptr) : forCell(cell) != nullptr;
    }
    const LodLevel::Cell *cellAt(int cell, int x, int y, int z) const;
    bool filledAt(int cell, int x, int y, int z) const;
    bool occludesAt(int cell, int x, int y, int z) const;
    // Whether the cell holds liquid. filledAt counts water as filled (a
    // liquid is drawable content), so a face-culling test that must not let
    // transparent water cover a solid face asks this as well. The fine
    // (cell 1) path has no liquid bitset and answers false when only the
    // bitsets are available, which errs toward culling, the old behaviour.
    bool liquidAt(int cell, int x, int y, int z) const;
};

// Build a three-dimensional voxel mip chain from the nodes. A full block can
// retain cell 1, so the mesher emits its exact exposed voxel boundary: thin
// trunks, leaves, cave walls and island undersides all remain on the node
// grid. Every occupied cell remains a voxel at coarser levels; terrain is not
// reconstructed from a heightfield.
void buildLodChain(const NodeDefManager *ndef, MapBlock *block, BlockLodChain &out, int min_level = 0);

// Build every level above first_level from its 2 by 2 by 2 children. Summary
// records fill the cell-4 level directly and use this same reducer as live and
// stored blocks, so changing source cannot change the shape of the mip.
void buildLodMipLevels(BlockLodChain &out, int first_level);

// Compact an already-built dense cell-1 level into the sparse exact boundary
// representation. Public for focused regression tests; normal callers use
// buildLodChain, which invokes it after deriving the coarser mips.
void compactLodFineBoundary(BlockLodChain &out);

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
    // Ground cells drawn as part of the connected surface, and the skirts
    // dropped at its edges (docs/far-rendering.md, "The far field as a
    // surface"). Neither goes through the merge.
    int surface_cells = 0;
    int skirts = 0;
    // Of those faces, how many are side faces that do not span their whole
    // cell vertically. Each such face sits at its own height inside its own
    // row of cells, so it can only ever merge along one axis, and a field of
    // them is a field of strips. The ratio is the instrument for whether a
    // tier is meshing a surface or a staircase (docs/far-rendering.md,
    // "Strips, and what the merge can and cannot do").
    int partial = 0;
    // The widest a single merged quad got, in nodes along its longer edge,
    // which is also how many times its tile repeats across it (UV runs one
    // unit per node). Handed to the region's MeshInstance3D as an instance
    // uniform so the shader can flatten a panel that is merged flat and wide
    // even where it sits close to the camera, not only where it is far
    // (docs/far-rendering.md, "Shade the far field as a far field").
    int max_span = 0;
    bool empty() const { return surfaces.empty(); }
};

// Per (content, side) tile lookup, cached because it walks the node
// definition and the texture source. Content ids are per session, so the
// owner clears it when the session changes.
struct LodTileCache {
    // Shared by every mesh worker (goanna_mesh_pool.h) and cleared on the
    // main thread when the textures change, so both the map and the texture
    // source calls that fill it are taken under this lock. tileFor returns a
    // copy rather than a reference for the same reason: a clear must not be
    // able to invalidate something a worker is still reading.
    mutable std::mutex mutex;
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

// How many blocks beyond its own bounds meshLodRegion reads, given the cell
// size and occlusion radius it was handed. Capture and mesher must agree
// exactly or the faces on a region's skin are culled against nothing, so the
// rule lives here rather than being written out twice.
int lodRegionMarginBlocks(int cell, float ao_radius);

// Everything meshLodRegion reads about a region, captured on the main thread
// so a worker can mesh it (goanna_mesh_pool.h). The three callbacks on
// LodRegionSpec reach into live client state, which a worker must not touch;
// bind() replaces them with lookups into this instead.
//
// The cube covered is the region plus `margin` blocks on every side, which is
// exactly meshLodRegion's own walk. Chains are held by shared_ptr, so the
// main thread may erase and rebuild any chain while a worker still reads the
// version it was given.
struct LodRegionSpec;

struct LodRegionSnapshot {
    v3s16 origin;   // block position of the region's low corner
    int blocks = 8; // blocks per axis, the region proper
    int margin = 1; // blocks of halo, from lodRegionMarginBlocks()

    struct Entry {
        std::shared_ptr<const BlockLodChain> chain;
        // What cell size this block is drawn at by whoever draws it: 0 for
        // full detail, -1 for not drawn. Not the region's own cell.
        int drawn_cell = -1;
        // Whether this region draws this block at all, before the cell test
        // that bind() adds, because that test differs between the exact and
        // fallback passes over the same capture.
        bool member = false;
    };

    int edge() const { return blocks + 2 * margin; }
    void reset(v3s16 origin_, int blocks_, int margin_);
    Entry *at(v3s16 bp);
    const Entry *at(v3s16 bp) const;
    // Point a spec's callbacks at this snapshot. Call after spec.cell is set:
    // the member test depends on it. The snapshot must outlive the
    // meshLodRegion call it is bound into.
    void bind(LodRegionSpec &spec) const;

    std::vector<Entry> entries; // edge() cubed
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
    // The cell size any block is currently drawn at: this tier's cell for a
    // block in a region of this tier, another tier's cell, 0 for a block
    // drawn at full detail, -1 for one not drawn at all. The far surface
    // joins onto a neighbour drawn at the same cell and drops a skirt
    // against anything else.
    std::function<int(v3s16)> drawn_cell;
};

// materials may be null, in which case every block ID is 0.
LodRegionMesh meshLodRegion(const LodRegionSpec &spec, const NodeDefManager *ndef,
        GoannaTextureSource *tsrc, const MaterialTable *materials, LodTileCache &tiles);

} // namespace goanna
